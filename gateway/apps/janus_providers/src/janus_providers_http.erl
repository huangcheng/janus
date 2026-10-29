%%%-------------------------------------------------------------------
%%% @doc Shared gun HTTP client for upstream LLM providers.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_providers_http).

%% Pure seam helpers (spec 2026-10-12-wire-compression F5/D5 — eunit;
%% mirrors the wire module's pure-seam export pattern).
-export([maybe_ae/2, upstream_ce_classify/2, ae_requested/1,
    %% Exported for eunit: the drain deadline arithmetic is pure, and a
    %% regression on the degraded/local path would otherwise only show
    %% up in production.
    next_tick/2,
    expired/1,
    idle_action/2
]).

-export([
    user_agent/0,
    parse_base/1,
    join_path/2,
    target_url/1,
    decrypt_key/1,
    post/3,
    post/6,
    post_stream/3,
    get/3
]).

-define(UA, <<"opencode/2.0.15">>).
-type drain_fun() :: fun((fun((binary()) -> ok), keepalive_fun()) -> ok | {error, term()}).
-type keepalive_fun() :: fun((binary()) -> ok) | undefined.
%% Exported so the adapters reference this shape instead of restating
%% it — there is no dialyzer gate in CI, so a drift would go unnoticed.
-export_type([drain_fun/0, keepalive_fun/0]).

-define(CONNECT_MS, 5000).
-define(TTFB_MS_DEFAULT, 120000).
-define(BODY_MS, 120000).

%% First-byte budget for non-stream upstream calls. Non-streaming
%% reasoning models (e.g. qwen3.8-max ultrathink on dashscope)
%% legitimately exceed 60 s for full-generation-before-first-byte —
%% a 60 s cap made such requests fail by construction (2026-10-21,
%% req_214630612184d5da). Hot-tunable via settings key "failover"
%% field "ttfb_ms"; the distributed failover budget must exceed this
%% or a stall can never be retried.
%% Mid-stream silence allowance for the local (non-worker) drain path.
%% Mirrors janus_worker_wire:stream_inactivity_timeout_ms/0 so both
%% dispatch paths agree on what "stalled" means.
drain_idle_ms() ->
    try janus_worker_wire:stream_inactivity_timeout_ms() of
        Ms when is_integer(Ms), Ms > 0 -> Ms;
        _ -> ?BODY_MS
    catch
        _:_ -> ?BODY_MS
    end.

%% janus_core is a hard dependency of this app and
%% janus_worker_wire:stream_keepalive_ms/0 is total (always a positive
%% integer below the inactivity ceiling), so this is a direct
%% delegation — no fallback, and no second copy of the default that
%% could drift.
keepalive_ms() ->
    janus_worker_wire:stream_keepalive_ms().

ttfb_ms() ->
    case persistent_term:get({janus, failover_cfg}, undefined) of
        #{<<"ttfb_ms">> := T} when is_integer(T), T >= 1000, T =< 600000 -> T;
        _ -> ?TTFB_MS_DEFAULT
    end.

%% Non-stream upstream response cap (raw wire bytes, before any gzip
%% decode): a hostile or broken upstream must not drive unbounded handler
%% memory. The gzip path is additionally capped post-decode by
%% janus_wire_enc; this bound covers the identity path and the raw body.
-define(MAX_BODY_BYTES, 32 * 1024 * 1024).

-spec user_agent() -> binary().
user_agent() ->
    case os:getenv("JANUS_UPSTREAM_UA") of
        false -> ?UA;
        "" -> ?UA;
        Val -> list_to_binary(Val)
    end.

-spec parse_base(binary() | string()) ->
    {ok, string(), inet:port_number(), binary(), boolean()} | {error, term()}.
parse_base(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U when
            Scheme =:= <<"https">>;
            Scheme =:= <<"http">>;
            Scheme =:= "https";
            Scheme =:= "http"
        ->
            Tls = scheme_tls(Scheme),
            Port =
                case maps:get(port, U, undefined) of
                    undefined when Tls -> 443;
                    undefined -> 80;
                    P -> P
                end,
            Path0 = maps:get(path, U, <<"/">>),
            Path =
                case Path0 of
                    <<>> -> <<"">>;
                    <<"/">> -> <<"">>;
                    Pth -> iolist_to_binary(Pth)
                end,
            HostBin = iolist_to_binary(Host),
            {ok, binary_to_list(HostBin), Port, Path, Tls};
        Other ->
            {error, {bad_base_url, Other}}
    end.

scheme_tls(<<"https">>) -> true;
scheme_tls("https") -> true;
scheme_tls(_) -> false.

%% Join a base path (as normalized by parse_base/1) with a suffix. The
%% boundary is normalized: exactly one `/` between a non-empty base and
%% the suffix, and an absolute `/`-prefixed result even when the base is
%% empty (a configured `https://host/` normalizes to `<<>>`, which must
%% not produce a relative request-target).
-spec join_path(binary(), binary()) -> binary().
join_path(Base, Suffix) ->
    Base1 = strip_trailing_slash(iolist_to_binary(Base)),
    Suffix1 = strip_leading_slash(iolist_to_binary(Suffix)),
    join_parts(Base1, Suffix1).

strip_trailing_slash(<<>>) ->
    <<>>;
strip_trailing_slash(Bin) ->
    case binary:last(Bin) of
        $/ -> strip_trailing_slash(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

strip_leading_slash(<<$/, Rest/binary>>) ->
    strip_leading_slash(Rest);
strip_leading_slash(Bin) ->
    Bin.

join_parts(<<>>, <<>>) ->
    <<"/">>;
join_parts(<<>>, Suffix) ->
    <<"/", Suffix/binary>>;
join_parts(Base, <<>>) ->
    Base;
join_parts(Base, Suffix) ->
    <<Base/binary, "/", Suffix/binary>>.

%% Rebuild an absolute URL from a gun target map (worker job payload).
-spec target_url(#{host := string(), port := inet:port_number(), path := binary(), tls := boolean()}) ->
    binary().
target_url(#{host := Host, port := Port, path := Path, tls := Tls}) ->
    Scheme =
        case Tls of
            true -> <<"https">>;
            false -> <<"http">>
        end,
    HostBin = bracket_host(iolist_to_binary(Host)),
    PathBin =
        case Path of
            <<>> -> <<"/">>;
            _ -> Path
        end,
    DefaultPort =
        case Tls of
            true -> 443;
            false -> 80
        end,
    case Port of
        DefaultPort ->
            <<Scheme/binary, "://", HostBin/binary, PathBin/binary>>;
        _ ->
            PortBin = integer_to_binary(Port),
            <<Scheme/binary, "://", HostBin/binary, ":", PortBin/binary, PathBin/binary>>
    end.

%% RFC 3986 §3.2.2: IPv6 literals in URLs must be bracketed.
bracket_host(Host) when is_binary(Host) ->
    case {binary:match(Host, <<":">>), Host} of
        {nomatch, _} ->
            Host;
        {_, <<$[, _/binary>>} ->
            Host;
        _ ->
            <<$[, Host/binary, $]>>
    end.

-spec decrypt_key(map()) -> {ok, binary()} | {error, term()}.
decrypt_key(#{secret_ref := {_KeyId, Cipher}}) when is_binary(Cipher) ->
    janus_secrets:decrypt(Cipher);
decrypt_key(#{secret_ref := Cipher}) when is_binary(Cipher) ->
    janus_secrets:decrypt(Cipher);
decrypt_key(_) ->
    {error, bad_secret_ref}.

%% Non-stream POST. Headers is [{binary(), binary()}].
-spec post(string(), inet:port_number(), binary(), boolean(), [{binary(), binary()}], binary()) ->
    {ok, pos_integer(), map(), binary()} | {error, term()}.
post(Host, Port, Path, Tls, Headers, Body) when is_list(Host), is_integer(Port) ->
    post_timeout(Host, Port, Path, Tls, Headers, Body, ttfb_ms()).

post_timeout(Host, Port, Path, Tls, Headers, Body, TimeoutMs) when
    is_list(Host), is_integer(Port), is_integer(TimeoutMs), TimeoutMs > 0
->
    Transport =
        case Tls of
            true -> tls;
            false -> tcp
        end,
    Opts = #{
        transport => Transport,
        tls_opts => janus_tls_opts(),
        connect_timeout => ?CONNECT_MS
    },
    Headers1 = maybe_ae(Headers, unary),
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            try
                case gun:await_up(Conn, ?CONNECT_MS) of
                    {ok, _} ->
                        Stream = gun:post(Conn, Path, Headers1, Body),
                        case gun:await(Conn, Stream, TimeoutMs) of
                            {response, fin, Status, RespHeaders} ->
                                upstream_decode_unary(Status, RespHeaders, <<>>, ae_requested(Headers1));
                            {response, nofin, Status, RespHeaders} ->
                                case collect_body(Conn, Stream, TimeoutMs, <<>>) of
                                    {ok, RespBody} ->
                                        upstream_decode_unary(Status, RespHeaders, RespBody, ae_requested(Headers1));
                                    {error, _} = Err ->
                                        Err
                                end;
                            {error, Reason} ->
                                {error, {await, Reason}};
                            Other ->
                                {error, {unexpected_await, Other}}
                        end;
                    {error, Reason} ->
                        {error, {await_up, Reason}}
                end
            after
                gun:close(Conn)
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

%% Compatibility arity used by adapters that pack opts.
%% Optional `timeout` (ms) overrides the default TTFB/body await budget
%% so modality local posts match worker `timeout_ms` (W2.2 OCR).
-spec post(map(), [{binary(), binary()}], binary()) ->
    {ok, pos_integer(), map(), binary()} | {error, term()}.
post(#{host := Host, port := Port, path := Path, tls := Tls} = Target, Headers, Body) ->
    Timeout =
        case maps:get(timeout, Target, ttfb_ms()) of
            T when is_integer(T), T > 0 -> T;
            _ -> ttfb_ms()
        end,
    post_timeout(Host, Port, Path, Tls, Headers, Body, Timeout).

%% Minimal GET (video job polls, spec M3.1): post/6's connection
%% logic with method GET and no body. The timeout applies to BOTH the
%% response await and each body chunk await, mirroring the caller's
%% per-request budget.
-spec get(map(), [{binary(), binary()}], timeout()) ->
    {ok, pos_integer(), map(), binary()} | {error, term()}.
get(#{host := Host, port := Port, path := Path, tls := Tls}, Headers, TimeoutMs)
    when is_list(Host), is_integer(Port), is_integer(TimeoutMs), TimeoutMs > 0
->
    Transport =
        case Tls of
            true -> tls;
            false -> tcp
        end,
    Opts = #{
        transport => Transport,
        tls_opts => janus_tls_opts(),
        connect_timeout => ?CONNECT_MS
    },
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            try
                case gun:await_up(Conn, ?CONNECT_MS) of
                    {ok, _} ->
                        Headers1 = maybe_ae(Headers, unary),
                        Stream = gun:get(Conn, Path, Headers1),
                        case gun:await(Conn, Stream, TimeoutMs) of
                            {response, fin, Status, RespHeaders} ->
                                upstream_decode_unary(Status, RespHeaders, <<>>, ae_requested(Headers1));
                            {response, nofin, Status, RespHeaders} ->
                                case collect_body(Conn, Stream, TimeoutMs, <<>>) of
                                    {ok, RespBody} ->
                                        upstream_decode_unary(Status, RespHeaders, RespBody, ae_requested(Headers1));
                                    {error, _} = Err ->
                                        Err
                                end;
                            {error, Reason} ->
                                {error, {await, Reason}};
                            Other ->
                                {error, {unexpected_await, Other}}
                        end;
                    {error, Reason} ->
                        {error, {await_up, Reason}}
                end
            after
                gun:close(Conn)
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

%% Stream POST: returns a drain fun that yields raw body chunks then closes gun.
%%
%% DrainFun(ChunkFun, KeepaliveFun) -> ok | {error, term()}
%%   ChunkFun(binary())     -> ok   consumes UPSTREAM bytes
%%   KeepaliveFun(binary()) -> ok   writes a CLIENT-facing SSE comment,
%%                                  or `undefined` when the caller has no
%%                                  client socket (an error-body collect).
%%
%% The two are separate because they are not the same sink: on the
%% translate path ChunkFun feeds an SSE PARSER, so a keepalive frame
%% written there would corrupt the upstream stream instead of
%% reassuring the client. KeepaliveFun is called from inside the drain
%% loop whenever it has been silent long enough, which is the only
%% place that can see the silence.
-spec post_stream(map(), [{binary(), binary()}], binary()) ->
    {ok, pos_integer(), map(), drain_fun()}
    | {error, term()}.
post_stream(#{host := Host, port := Port, path := Path, tls := Tls}, Headers, Body) ->
    Transport =
        case Tls of
            true -> tls;
            false -> tcp
        end,
    Opts = #{
        transport => Transport,
        tls_opts => janus_tls_opts(),
        connect_timeout => ?CONNECT_MS
    },
    Headers1 = maybe_ae(Headers, stream),
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECT_MS) of
                {ok, _} ->
                    Stream = gun:post(Conn, Path, Headers1, Body),
                    case gun:await(Conn, Stream, ttfb_ms()) of
                        {response, fin, Status, RespHeaders} ->
                            case upstream_ce_classify(RespHeaders, ae_requested(Headers1)) of
                                gzip ->
                                    %% A gzip'd FIN response with no body
                                    %% frames is a truncated stream by
                                    %% definition (no trailer ever
                                    %% arrives) — fail-closed on drain.
                                    Drain = fun(_ChunkFun, _KeepaliveFun) ->
                                        gun:close(Conn),
                                        {error, {body, {content_encoding, inflate_incomplete}}}
                                    end,
                                    {ok, Status, headers_map(RespHeaders), Drain};
                                identity ->
                                    Drain = fun(_ChunkFun, _KeepaliveFun) ->
                                        gun:close(Conn),
                                        ok
                                    end,
                                    {ok, Status, headers_map(RespHeaders), Drain};
                                {violation, V} ->
                                    gun:close(Conn),
                                    {error, {content_encoding, V}}
                            end;
                        {response, nofin, Status, RespHeaders} ->
                            case upstream_ce_classify(RespHeaders, ae_requested(Headers1)) of
                                gzip ->
                                    case janus_wire_enc:inflate_stream_open() of
                                        {ok, St0} ->
                                            Drain = fun(ChunkFun, KeepaliveFun) ->
                                                try
                                                    drain_stream_decoding(
                                                        Conn, Stream, ChunkFun, KeepaliveFun, St0
                                                    )
                                                after
                                                    _ = janus_wire_enc:inflate_stream_close(St0),
                                                    gun:close(Conn)
                                                end
                                            end,
                                            {ok, Status, headers_map(RespHeaders), Drain};
                                        {error, OpenReason} ->
                                            %% Never a badmatch into the data plane
                                            %% (D7 parity; ocr review), and the gun
                                            %% connection closes like every branch.
                                            gun:close(Conn),
                                            {error, {content_encoding, OpenReason}}
                                    end;
                                identity ->
                                    Drain = fun(ChunkFun, KeepaliveFun) ->
                                        try
                                            drain_stream(Conn, Stream, ChunkFun, KeepaliveFun)
                                        after
                                            gun:close(Conn)
                                        end
                                    end,
                                    {ok, Status, headers_map(RespHeaders), Drain};
                                {violation, V} ->
                                    gun:close(Conn),
                                    {error, {content_encoding, V}}
                            end;
                        {error, Reason} ->
                            gun:close(Conn),
                            {error, {await, Reason}};
                        Other ->
                            gun:close(Conn),
                            {error, {unexpected_await, Other}}
                    end;
                {error, Reason} ->
                    gun:close(Conn),
                    {error, {await_up, Reason}}
            end;
        {error, Reason} ->
            {error, {open, Reason}}
    end.

%% Per-frame wait for a plain (identity) stream: same reasoning as
%% drain_stream_decoding/5 — silence mid-stream is a stalled upstream,
%% not a slow one, so it is bounded by the shared inactivity ceiling.
drain_stream(Conn, Stream, ChunkFun, KeepaliveFun) ->
    KaMs = keepalive_ms(),
    drain_stream(Conn, Stream, ChunkFun, KeepaliveFun, KaMs, idle_deadline(), tick_deadline(KaMs)).

%% StallDeadline is an ABSOLUTE instant that only a forwarded chunk
%% resets — that is what makes the inactivity ceiling a real bound.
%% TickDeadline caps each individual wait so a silent stretch still gets
%% a keepalive, but it never moves StallDeadline, so a permanently
%% silent upstream trips the ceiling instead of keepaliving forever.
%% (gun:await/3 cannot be cancelled, so the tick IS the wait
%% granularity; the un-reset stall deadline is what keeps that safe.)
drain_stream(Conn, Stream, ChunkFun, KeepaliveFun, KaMs, StallDeadline, TickDeadline) ->
    case gun:await(Conn, Stream, next_tick(StallDeadline, TickDeadline)) of
        {data, nofin, Data} ->
            _ = ChunkFun(Data),
            drain_stream(
                Conn, Stream, ChunkFun, KeepaliveFun, KaMs, idle_deadline(), tick_deadline(KaMs)
            );
        {data, fin, Data} ->
            _ = ChunkFun(Data),
            ok;
        {error, timeout} ->
            case idle_action(StallDeadline, KeepaliveFun) of
                stalled ->
                    {error, {body, timeout}};
                keepalive ->
                    drain_stream(
                        Conn,
                        Stream,
                        ChunkFun,
                        KeepaliveFun,
                        KaMs,
                        StallDeadline,
                        tick_deadline(KaMs)
                    )
            end;
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
    end.

%% SSE comment frame: legal on every face, carries no data, discarded by
%% every conforming parser.
%%
%% Failures PROPAGATE, deliberately (OCR caught the opposite here): the
%% proxy signals a dead client with throw(janus_client_disconnect), and
%% both stream handlers depend on that throw to abort the drain, close
%% gun and account the request as cancelled/499. Swallowing it meant a
%% client dying during upstream silence went unnoticed — the loop held
%% the connection open, kept consuming (and billing) upstream tokens
%% until the stall ceiling fired, then blamed the UPSTREAM for it
%% ("upstream stalled", 502, provider benched). It also hid a genuine
%% wiring bug in KeepaliveFun, which is exactly what the live harness
%% exists to catch. Symmetric with the chunk path, which propagates.
emit_keepalive(undefined) ->
    ok;
emit_keepalive(KeepaliveFun) ->
    KeepaliveFun(<<": keepalive\n\n">>),
    ok.

%% Upstream gzip seam (spec 2026-10-12-wire-compression G2/F3/F5/D5).
%% Request side: Accept-Encoding: gzip is emitted ONLY here (structural
%% coupling — the module that inflates is the module that asks);
%% unary requests when JANUS_UPSTREAM_ENC, stream requests only when
%% JANUS_UPSTREAM_ENC_STREAM (provider proxies buffer gzip'd SSE
%% flushes — U.2 live-TTFB proof gates any stream enable). Callers
%% never send their own accept-encoding (read-verified); strip any
%% defensively so the value is OURS alone.
maybe_ae(Headers, Kind) ->
    Stripped = [
        H
     || H = {K, _} <- Headers,
        string:lowercase(K) =/= <<"accept-encoding">>
    ],
    On =
        case Kind of
            unary -> janus_wire_enc:upstream_enc_enabled();
            stream -> janus_wire_enc:upstream_enc_stream_enabled()
        end,
    case On of
        true -> [{<<"accept-encoding">>, <<"gzip">>} | Stripped];
        false -> Stripped
    end.

ae_requested(Headers) ->
    lists:any(
        fun({K, V}) ->
            string:lowercase(K) =:= <<"accept-encoding">> andalso
                string:lowercase(V) =:= <<"gzip">>
        end,
        Headers
    ).

%% Headers-driven classification (decode never depends on having
%% asked): absent/empty/identity pass; gzip decodes — bumping the
%% unsolicited counter when WE did not ask on this call; everything
%% else is a violation returned as {violation, Value} (the callers
%% route it to the failover cascade — never parsed, never passed
%% through).
upstream_ce_classify(RespHeaders, Requested) ->
    CE = maps:get(
        <<"content-encoding">>, headers_map(RespHeaders), undefined
    ),
    case janus_wire_enc:classify_content_encoding(CE) of
        gzip when Requested =:= false ->
            ok = janus_wire_enc:bump_unsolicited_gzip(),
            gzip;
        Other ->
            Other
    end.

%% Unary decode: the buffered body streams through the SAME capped
%% streaming state the stream loop uses (F3 cap, trailer verify) —
%% one seam, both shapes.
upstream_decode_unary(Status, RespHeaders, Body, Requested) ->
    case upstream_ce_classify(RespHeaders, Requested) of
        identity ->
            {ok, Status, headers_map(RespHeaders), Body};
        gzip ->
            case janus_wire_enc:inflate_stream_open() of
                {error, OpenReason} ->
                    {error, {content_encoding, OpenReason}};
                {ok, S0} ->
                    upstream_decode_gzip_body(Status, RespHeaders, Body, S0)
            end;
        {violation, V} ->
            {error, {content_encoding, V}}
    end.

upstream_decode_gzip_body(Status, RespHeaders, Body, S0) ->
            try
                case janus_wire_enc:inflate_stream_frame(S0, Body) of
                    {ok, Out, S1} ->
                        case janus_wire_enc:inflate_stream_finish(S1) of
                            ok -> {ok, Status, headers_map(RespHeaders), Out};
                            {error, Reason} -> {error, {content_encoding, Reason}}
                        end;
                    {error, Reason} ->
                        {error, {content_encoding, Reason}}
                end
            after
                ok = janus_wire_enc:inflate_stream_close(S0)
            end.

%% Stream drain with per-stream-ref decode state: every gun data frame
%% inflates BEFORE the consumer sees a byte; frame/finish failures map
%% to the {body, _} transport shape (the existing retryable/benching
%% taxonomy — is_transient({body, _}) is true; the session maps it to
%% upstream_closed) with the CE detail inside.
%% Per-frame wait for a DECODED (gzip) stream. Bounded by the shared
%% mid-stream inactivity ceiling rather than ?BODY_MS: 120s of silence
%% on a stream that has already started is a stalled upstream, and the
%% gateway must say so long before a client's own idle timer expires
%% (verified live 2026-10-29: a single-node deployment had no
%% inactivity bound at all on this path and a stalled stream hung until
%% the client gave up).
drain_stream_decoding(Conn, Stream, ChunkFun, KeepaliveFun, S0) ->
    KaMs = keepalive_ms(),
    drain_stream_decoding(
        Conn, Stream, ChunkFun, KeepaliveFun, S0, KaMs, idle_deadline(), tick_deadline(KaMs)
    ).

%% Same deadline discipline as drain_stream/7: StallDeadline resets only
%% on a forwarded chunk, the tick deadline only paces keepalives.
drain_stream_decoding(Conn, Stream, ChunkFun, KeepaliveFun, S0, KaMs, StallDeadline, TickDeadline) ->
    case gun:await(Conn, Stream, next_tick(StallDeadline, TickDeadline)) of
        {data, nofin, Data} ->
            case janus_wire_enc:inflate_stream_frame(S0, Data) of
                {ok, Out, S1} ->
                    _ = ChunkFun(Out),
                    drain_stream_decoding(
                        Conn,
                        Stream,
                        ChunkFun,
                        KeepaliveFun,
                        S1,
                        KaMs,
                        idle_deadline(),
                        tick_deadline(KaMs)
                    );
                {error, Reason} ->
                    {error, {body, {content_encoding, Reason}}}
            end;
        {data, fin, Data} ->
            case janus_wire_enc:inflate_stream_frame(S0, Data) of
                {ok, Out, S1} ->
                    _ = ChunkFun(Out),
                    case janus_wire_enc:inflate_stream_finish(S1) of
                        ok -> ok;
                        {error, Reason} -> {error, {body, {content_encoding, Reason}}}
                    end;
                {error, Reason} ->
                    {error, {body, {content_encoding, Reason}}}
            end;
        {error, timeout} ->
            case idle_action(StallDeadline, KeepaliveFun) of
                stalled ->
                    {error, {body, timeout}};
                keepalive ->
                    drain_stream_decoding(
                        Conn,
                        Stream,
                        ChunkFun,
                        KeepaliveFun,
                        S0,
                        KaMs,
                        StallDeadline,
                        tick_deadline(KaMs)
                    )
            end;
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
    end.

%% The inactivity ceiling: only a forwarded chunk resets this.
idle_deadline() ->
    erlang:monotonic_time(millisecond) + drain_idle_ms().

%% The next keepalive tick: a SHORTER, independent instant, re-armed on
%% every wakeup. Using one instant for both made next_tick/2 always
%% return the full stall window, so gun:await slept straight through it
%% and the keepalive branch was unreachable (0 frames observed live).
tick_deadline(KaMs) ->
    erlang:monotonic_time(millisecond) + KaMs.

expired(Deadline) ->
    Deadline - erlang:monotonic_time(millisecond) =< 0.

%% Never sleep past the stall deadline, and never past one keepalive
%% tick. Always at least 1ms so gun:await cannot spin.
next_tick(StallDeadline, TickDeadline) ->
    max(1, min(deadline_in(StallDeadline), deadline_in(TickDeadline))).

deadline_in(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

%% What a wakeup with no data means: the stall ceiling has passed (fail
%% closed) or this was merely a quiet stretch (reassure and re-arm).
%% Shared by both drain variants so the tick/stall interplay cannot
%% drift between them — the gzip loop is the harder one to notice.
idle_action(StallDeadline, KeepaliveFun) ->
    case expired(StallDeadline) of
        true ->
            stalled;
        false ->
            emit_keepalive(KeepaliveFun),
            keepalive
    end.

collect_body(Conn, Stream, Acc) ->
    collect_body(Conn, Stream, ?BODY_MS, Acc).

%% Accumulate in an iolist (no per-frame binary copy) while enforcing
%% the raw-byte cap. Past the cap the body is abandoned with the same
%% `{body, Reason}' transport shape the callers already pass through.
collect_body(Conn, Stream, TimeoutMs, Acc) ->
    collect_body(Conn, Stream, TimeoutMs, byte_size(Acc), [Acc]).

collect_body(Conn, Stream, TimeoutMs, Size, Chunks) ->
    case gun:await(Conn, Stream, TimeoutMs) of
        {data, nofin, Data} ->
            case account_body(Size, Data) of
                {ok, Size1} ->
                    collect_body(Conn, Stream, TimeoutMs, Size1, [Data | Chunks]);
                too_large ->
                    {error, {body, too_large}}
            end;
        {data, fin, Data} ->
            case account_body(Size, Data) of
                {ok, _Size1} ->
                    {ok, iolist_to_binary(lists:reverse([Data | Chunks]))};
                too_large ->
                    {error, {body, too_large}}
            end;
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
    end.

account_body(Size, Data) ->
    Size1 = Size + byte_size(Data),
    case Size1 > ?MAX_BODY_BYTES of
        true -> too_large;
        false -> {ok, Size1}
    end.

headers_map(Headers) when is_list(Headers) ->
    maps:from_list([{to_lower(K), V} || {K, V} <- Headers]);
headers_map(_) ->
    #{}.

to_lower(B) when is_binary(B) ->
    string:lowercase(B);
to_lower(L) when is_list(L) ->
    string:lowercase(list_to_binary(L)).

%% Upstream TLS verification: configurable via JANUS_UPSTREAM_TLS_VERIFY.
%% Default verify_peer (secure); set to "none" only for testing with
%% self-signed certs behind a trusted proxy.
janus_tls_opts() ->
    case os:getenv("JANUS_UPSTREAM_TLS_VERIFY") of
        "none" ->
            [{verify, verify_none}];
        _ ->
            [{verify, verify_peer},
             {cacerts, public_key:cacerts_get()},
             {depth, 3},
             {customize_hostname_check,
                 [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
    end.
