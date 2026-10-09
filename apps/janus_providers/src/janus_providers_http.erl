%%%-------------------------------------------------------------------
%%% @doc Shared gun HTTP client for upstream LLM providers.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_providers_http).

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
-define(CONNECT_MS, 5000).
-define(TTFB_MS, 60000).
-define(BODY_MS, 120000).

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

-spec join_path(binary(), binary()) -> binary().
join_path(Base, Suffix) ->
    B =
        case Base of
            <<>> ->
                <<>>;
            _ ->
                case binary:last(iolist_to_binary(Base)) of
                    $/ ->
                        binary:part(
                            iolist_to_binary(Base), 0, byte_size(iolist_to_binary(Base)) - 1
                        );
                    _ ->
                        iolist_to_binary(Base)
                end
        end,
    <<B/binary, Suffix/binary>>.

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
    post_timeout(Host, Port, Path, Tls, Headers, Body, ?TTFB_MS).

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
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            try
                case gun:await_up(Conn, ?CONNECT_MS) of
                    {ok, _} ->
                        Stream = gun:post(Conn, Path, Headers, Body),
                        case gun:await(Conn, Stream, TimeoutMs) of
                            {response, fin, Status, RespHeaders} ->
                                {ok, Status, headers_map(RespHeaders), <<>>};
                            {response, nofin, Status, RespHeaders} ->
                                case collect_body(Conn, Stream, TimeoutMs, <<>>) of
                                    {ok, RespBody} ->
                                        {ok, Status, headers_map(RespHeaders), RespBody};
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
        case maps:get(timeout, Target, ?TTFB_MS) of
            T when is_integer(T), T > 0 -> T;
            _ -> ?TTFB_MS
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
                        Stream = gun:get(Conn, Path, Headers),
                        case gun:await(Conn, Stream, TimeoutMs) of
                            {response, fin, Status, RespHeaders} ->
                                {ok, Status, headers_map(RespHeaders), <<>>};
                            {response, nofin, Status, RespHeaders} ->
                                case collect_body(Conn, Stream, TimeoutMs, <<>>) of
                                    {ok, RespBody} ->
                                        {ok, Status, headers_map(RespHeaders), RespBody};
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
%% DrainFun(ChunkFun) -> ok | {error, term()} where ChunkFun(binary()) -> ok.
-spec post_stream(map(), [{binary(), binary()}], binary()) ->
    {ok, pos_integer(), map(), fun((fun((binary()) -> ok)) -> ok | {error, term()})}
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
    case gun:open(Host, Port, Opts) of
        {ok, Conn} ->
            case gun:await_up(Conn, ?CONNECT_MS) of
                {ok, _} ->
                    Stream = gun:post(Conn, Path, Headers, Body),
                    case gun:await(Conn, Stream, ?TTFB_MS) of
                        {response, fin, Status, RespHeaders} ->
                            Drain = fun(_ChunkFun) ->
                                gun:close(Conn),
                                ok
                            end,
                            {ok, Status, headers_map(RespHeaders), Drain};
                        {response, nofin, Status, RespHeaders} ->
                            Drain = fun(ChunkFun) ->
                                try
                                    drain_stream(Conn, Stream, ChunkFun)
                                after
                                    gun:close(Conn)
                                end
                            end,
                            {ok, Status, headers_map(RespHeaders), Drain};
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

drain_stream(Conn, Stream, ChunkFun) ->
    case gun:await(Conn, Stream, ?BODY_MS) of
        {data, nofin, Data} ->
            _ = ChunkFun(Data),
            drain_stream(Conn, Stream, ChunkFun);
        {data, fin, Data} ->
            _ = ChunkFun(Data),
            ok;
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
    end.

collect_body(Conn, Stream, Acc) ->
    collect_body(Conn, Stream, ?BODY_MS, Acc).

collect_body(Conn, Stream, TimeoutMs, Acc) ->
    case gun:await(Conn, Stream, TimeoutMs) of
        {data, nofin, Data} ->
            collect_body(Conn, Stream, TimeoutMs, <<Acc/binary, Data/binary>>);
        {data, fin, Data} ->
            {ok, <<Acc/binary, Data/binary>>};
        {error, Reason} ->
            {error, {body, Reason}};
        Other ->
            {error, {unexpected_body, Other}}
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
