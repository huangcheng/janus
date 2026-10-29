%%%-------------------------------------------------------------------
%%% @doc Internal-hop wire compression codec
%%% (spec 2026-10-12-wire-compression rows D2/D3/D4/D7/D11 — PR1
%%% Task A).
%%%
%%% Each compressed payload is ONE INDEPENDENT COMPLETE zlib stream
%%% (RFC 1950 wrapper): open/deflateInit/deflate(finish)/deflateEnd/
%%% close per message — NO Z_SYNC_FLUSH continuing state, NO
%%% cross-message dictionaries (D2). The zlib handles are closed in
%%% every path (after/finally discipline).
%%%
%%% Encode is CAPABILITY-gated by the caller (worker dispatch owns
%%% the hello-ack capability bit); this module additionally honors
%%% its own env switch and threshold. Decode is TAG-DRIVEN (F1):
%%% `inflate(zlib, _)` never consults enablement — a compressed
%%% message decodes regardless of the decoder's env/capability
%%% state; only the output cap applies (F3).
%%%
%%% Env knobs (D10, env-only, boot-time, default OFF):
%%%   JANUS_WIRE_ENC            repo truthy tokens ("1"/"true"/"yes"/
%%%                             "on") enable; anything else off
%%%   JANUS_WIRE_ENC_LEVEL      1..9 (default 1; 0 => identity —
%%%                             NEVER emit store-only tagged zlib;
%%%                             out-of-range integers clamp into
%%%                             1..9 and warn once; garbage => default)
%%%   JANUS_WIRE_ENC_MIN_BYTES  payload threshold, default 256 (D3)
%%%   JANUS_WIRE_ENC_MAX_INFLATE inflate output cap, default 64 MiB
%%%   JANUS_WIRE_ENC_CORRUPT_AFTER TEST-ONLY fault injection (W.1b):
%%%                             integer >= 0 corrupts the compressed
%%%                             wire message at that seq; never in prod
%%%
%%% "Boot-time" is enforced EXACTLY by `init_config_cache/0` (boot
%%% wiring calls it once; the snapshot rides persistent_term — the
%%% AGENTS.md pattern for boot-stable cross-process values). Until
%%% then the /1 forms read the env LIVE (os:getenv per message — the
%%% eunit fixtures rely on that; the cost is negligible vs the zlib
%%% work and W.0 measures CPU anyway).
%%%
%%% Counters (D9): owner-local `janus_wire_enc_counters` ETS with the
%%% tolerant bump pattern — the same idiom as janus_geo /
%%% janus_worker_pool (`janus_metrics` lives in the janus_http app,
%%% unreachable from janus_core without inverting the dependency).
%%% Labeled series use `{Metric, {Dir, Enc}}` tuple keys, mirroring
%%% the /stats/sched `{Name, Label}` convention: wire_enc_chunks_total
%%% / wire_enc_bytes_total with Dir in out|in and Enc in
%%% identity|zlib|plain. `plain` is a SUPPLEMENTARY series for
%%% compressed messages only (never summed with the wire buckets);
%%% plain and zlib bytes are both counted at deflate time on the
%%% worker (D9 source-of-truth rule). Bumps NO-OP until
%%% `ensure_counters/0` has run (boot wiring rides the later PR1
%%% tasks; `bump/2` stays public for the master-side identity intake).
%%%
%%% The persistent_term warn-once flags below are log DEDUP only —
%%% the compression capability itself is NEVER cached in
%%% persistent_term (F1: per-session ack state).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_wire_enc).

%% Codec API.
-export([
    env_config/0,
    init_config_cache/0,
    maybe_deflate/1,
    inflate/2,
    inflate_chunk/1,
    self_check/0
]).

%% Explicit-config forms (eunit seams — the /1 forms read env) plus
%% the counters seam for boot wiring and master-side intake, and the
%% shared ROLE-AWARE boot wiring consumed by janus_worker_dispatch /
%% janus_worker_pool init (ocr review dedup — the two callers stay in
%% lockstep by construction).
-export([
    maybe_deflate/2,
    inflate/3,
    inflate_chunk/2,
    self_check/1,
    ensure_counters/0,
    bump/2,
    counters/0,
    boot/1,
    %% W.1b fault-injection seam env parse (spec §4; TEST-ONLY —
    %% consumed by janus_worker_session at run start and warned about
    %% at worker dispatch boot).
    corrupt_after_from_env/0,
    %% Upstream gzip (PR2, spec 2026-10-12-wire-compression
    %% F3/F5/D5/D10): the shared env-truthy parser (single repo token
    %% set — janus_providers_http's request builders and BOTH boot
    %% wiring sites read these), the cached/shared inflate cap reader
    %% the seam calls, and the per-stream-ref streaming inflate API
    %% the seam's gun receive loops drive.
    env_flag/1,
    upstream_enc_enabled/0,
    upstream_enc_stream_enabled/0,
    max_inflate/0,
    inflate_stream_open/0,
    inflate_stream_open/1,
    inflate_stream_frame/2,
    inflate_stream_frame/3,
    inflate_stream_finish/1,
    inflate_stream_close/1,
    %% F5/D6: the bounded Content-Encoding grammar classifier and the
    %% unsolicited-gzip ops signal (janus_providers_http calls both).
    classify_content_encoding/1,
    bump_unsolicited_gzip/0,
    %% Downstream REST JSON gzip (PR3, spec 2026-10-12-wire-compression
    %% G3/F6/D8/D10; maturity batch H2): the env gate (exported for the
    %% D10 gate-surface symmetry with upstream_enc_enabled/0; consumed
    %% INTERNALLY by downstream_gzip_decide/3, which the janus_http
    %% reply seam calls), the pure RFC 7231 Accept-Encoding negotiation
    %% and F6 content-type enumeration, and the composed per-reply
    %% decision the helper consults.
    downstream_enc_enabled/0,
    accept_encoding_selects_gzip/1,
    compressible_content_type/1,
    downstream_gzip_decide/3,
    downstream_enc_negotiable/2
]).

-define(COUNTERS, janus_wire_enc_counters).
-define(DEFAULT_LEVEL, 1).
-define(DEFAULT_MIN_BYTES, 256).
%% 64 MiB default inflate cap (F3; W.0 re-sizes with headroom from
%% the observed max done-body before any prod enable). MEMORY NOTE
%% (ocr review): the cap is PER MESSAGE (the ratified F3/D7
%% mechanism) — one message may materialize up to the cap before
%% inflate_too_large fires, and concurrently in-flight messages EACH
%% hold their own budget on the master (N x cap aggregate); whether
%% an ADDITIONAL node-wide budget is needed is part of the W.0 sizing
%% decision, and the hop is an authenticated cluster (inet_tls dist).
%% The default is explicitly NOT final until W.0 sizes it.
-define(DEFAULT_MAX_INFLATE, 67_108_864).
%% Self-check per-round output bound (see self_check_bomb_bound/0) —
%% the SAME 1 MiB tolerance safeinflate_bounded_output_test pins, so
%% the boot gate is never stricter than the tested variance window.
-define(SELF_CHECK_ROUND_BOUND, 1_048_576).

%%%===================================================================
%%% Env config (D3/D4/D10)
%%%===================================================================

-spec env_config() ->
    #{enabled := boolean(), level := 1..9, min_bytes := non_neg_integer(), max_inflate := pos_integer()}.
env_config() ->
    case pt_read({?MODULE, cfg}, undefined) of
        undefined ->
            env_config_uncached();
        Cached ->
            Cached
    end.

%% Boot wiring seam (later PR1 tasks / ocr review perf rounds):
%% snapshot the env config ONCE into persistent_term — the blessed
%% AGENTS.md pattern for boot-stable cross-process values (NOT the
%% F1 capability bit, which stays per-session and never PT). Until
%% this runs, the /1 forms read the env live (tests rely on that);
%% after it runs, D10's boot-time semantics are exact. Re-runnable
%% (tests erase the key in cleanup).
-spec init_config_cache() -> ok.
init_config_cache() ->
    _ = persistent_term:put({?MODULE, cfg}, env_config_uncached()),
    ok.

env_config_uncached() ->
    Enabled0 = env_flag("JANUS_WIRE_ENC"),
    %% The level is parsed (and clamp-warned) ONLY when the feature is
    %% on (ocr review): a stray JANUS_WIRE_ENC_LEVEL=12 on a node with
    %% compression off must not emit a misleading boot warning.
    {Level, LevelOk} =
        case Enabled0 of
            true -> env_level();
            false -> {?DEFAULT_LEVEL, false}
        end,
    #{
        enabled => Enabled0 andalso LevelOk,
        level => Level,
        min_bytes => max(0, env_int("JANUS_WIRE_ENC_MIN_BYTES", ?DEFAULT_MIN_BYTES)),
        max_inflate => max_inflate_from_env()
    }.

pt_read(Key, Default) ->
    try
        persistent_term:get(Key, Default)
    catch
        _:_ -> Default
    end.

%% Repo-wide env_truthy token set (janus_core_app precedent — ocr
%% review): "1"/"true"/"yes"/"on" case-insensitive; anything else,
%% including unset and "0", keeps the feature OFF (D4:
%% JANUS_WIRE_ENC=0 kills it).
env_flag(Name) ->
    case os:getenv(Name) of
        Val when is_list(Val), Val =/= "" ->
            lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
        _ ->
            false
    end.

%% -> {Level, LevelUsable}: 0 folds into enabled=false (never
%% store-only tagged zlib, D4); out-of-range integers clamp with a
%% once-only warning; garbage keeps the default (repo env parse
%% precedent — silent default).
env_level() ->
    case env_int("JANUS_WIRE_ENC_LEVEL", ?DEFAULT_LEVEL) of
        0 ->
            {?DEFAULT_LEVEL, false};
        L when is_integer(L), L < 1 ->
            warn_once({?MODULE, level_clamped_low}, #{
                what => janus_wire_enc_level_clamped,
                env => "JANUS_WIRE_ENC_LEVEL",
                value => L,
                clamped => ?DEFAULT_LEVEL
            }),
            {?DEFAULT_LEVEL, true};
        L when is_integer(L), L > 9 ->
            warn_once({?MODULE, level_clamped_high}, #{
                what => janus_wire_enc_level_clamped,
                env => "JANUS_WIRE_ENC_LEVEL",
                value => L,
                clamped => 9
            }),
            {9, true};
        L ->
            {L, true}
    end.

%% A non-positive explicit cap is NOT clamped to 1 (ocr review): a
%% 1-byte cap would fail every message with inflate_too_large —
%% indistinguishable from a real decompression bomb in
%% wire_enc_inflate_fail_total (the rollout gate requires it to stay
%% 0). `JANUS_WIRE_ENC_MAX_INFLATE=0' (a natural "no cap" spelling)
%% falls back to the default instead.
max_inflate_from_env() ->
    case env_int("JANUS_WIRE_ENC_MAX_INFLATE", ?DEFAULT_MAX_INFLATE) of
        Max when is_integer(Max), Max >= 1 ->
            Max;
        _NonPositive ->
            ?DEFAULT_MAX_INFLATE
    end.

env_int(Name, Default) ->
    case os:getenv(Name) of
        Val when is_list(Val), Val =/= "" ->
            try
                list_to_integer(Val)
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

%% W.1b fault-injection seam (spec 2026-10-12-wire-compression §4,
%% TEST-ONLY): `JANUS_WIRE_ENC_CORRUPT_AFTER=<N>` arms the worker
%% session to corrupt the zlib payload of the compressed wire message
%% whose seq equals N, producing a REAL master-side inflate failure on
%% the REAL wire. Parse rules: an integer >= 0 arms the seam; unset,
%% empty, garbage, or negative => undefined (seam off — a negative
%% value can never name a chunk seq, so it must not arm anything).
%% This env must NEVER be set in production — janus_worker_dispatch
%% warns loudly at boot when it is.
-spec corrupt_after_from_env() -> non_neg_integer() | undefined.
corrupt_after_from_env() ->
    case os:getenv("JANUS_WIRE_ENC_CORRUPT_AFTER") of
        Val when is_list(Val), Val =/= "" ->
            try
                case list_to_integer(Val) of
                    N when N >= 0 -> N;
                    _Negative -> undefined
                end
            catch
                _:_ -> undefined
            end;
        _ ->
            undefined
    end.

%%%===================================================================
%%% Deflate (D2/D3/D4 — one independent zlib stream per message)
%%%===================================================================

-spec maybe_deflate(binary()) -> {identity | zlib, binary()}.
maybe_deflate(Bin) ->
    maybe_deflate(Bin, env_config()).

-spec maybe_deflate(binary(), map()) -> {identity | zlib, binary()}.
maybe_deflate(Bin, #{enabled := Enabled, level := Level, min_bytes := MinBytes}) when is_binary(Bin) ->
    case
        not is_boolean(Enabled) orelse
            not Enabled orelse
            not is_integer(Level) orelse
            Level < 1 orelse
            Level > 9 orelse
            not is_integer(MinBytes) orelse
            byte_size(Bin) < max(0, MinBytes)
    of
        true ->
            %% Env off / below threshold: identity, and the identity
            %% fallback emits NO enc key (D2/D3/D4). Every call to
            %% this seam is one wire message — counted. An EXPLICIT
            %% enabled config with a mistyped or out-of-range
            %% level/min_bytes/enabled also lands here (the env path
            %% folds level 0 into disabled; the explicit seam must
            %% not silently disagree with the caller's intent — warn
            %% once, ocr review; a FLOAT level would otherwise spam
            %% deflate_fail per message, and a non-integer min_bytes
            %% would silently disable compression via term order).
            BadCfg =
                (not is_boolean(Enabled) orelse Enabled) andalso
                    (not is_boolean(Enabled) orelse
                        not is_integer(Level) orelse Level < 1 orelse Level > 9 orelse
                        not is_integer(MinBytes)),
            case BadCfg of
                true ->
                    warn_once({?MODULE, explicit_bad_cfg}, #{
                        what => janus_wire_enc_explicit_bad_cfg,
                        level => Level,
                        min_bytes => MinBytes
                    });
                false ->
                    ok
            end,
            count_identity_out(Bin),
            {identity, Bin};
        false ->
            T0 = erlang:monotonic_time(microsecond),
            case deflate_stream(Bin, Level) of
                {ok, Out} ->
                    bump(wire_enc_deflate_time_us_total, erlang:monotonic_time(microsecond) - T0),
                    case byte_size(Out) < byte_size(Bin) of
                        true ->
                            bump({wire_enc_chunks_total, {out, zlib}}, 1),
                            bump({wire_enc_bytes_total, {out, zlib}}, byte_size(Out)),
                            bump({wire_enc_bytes_total, {out, plain}}, byte_size(Bin)),
                            {zlib, Out};
                        false ->
                            %% Not smaller than the input: identity
                            %% fallback — no expansion on the wire.
                            count_identity_out(Bin),
                            {identity, Bin}
                    end;
                {error, _Reason} ->
                    %% Deflate failure => identity fallback (D7); the
                    %% warning was logged in deflate_stream. The CPU
                    %% spent is still recorded (ocr review — a
                    %% systematically failing deflate must be visible
                    %% in the W.0 deflate-time distribution, not only
                    %% in the warning log).
                    bump(wire_enc_deflate_time_us_total, erlang:monotonic_time(microsecond) - T0),
                    count_identity_out(Bin),
                    {identity, Bin}
            end
    end.

%% One complete RFC 1950 zlib stream (default windowBits 15): deflate
%% FIRST, then the caller chooses tag-or-identity (D2 ordering).
-spec deflate_stream(binary(), 1..9) -> {ok, binary()} | {error, term()}.
deflate_stream(Bin, Level) ->
    try
        Z = zlib:open(),
        try
            zlib:deflateInit(Z, Level),
            Out0 = zlib:deflate(Z, Bin, finish),
            zlib:deflateEnd(Z),
            {ok, iolist_to_binary(Out0)}
        after
            zlib:close(Z)
        end
    catch
        Class:Reason ->
            %% warn_once, not a bare warning (ocr review): a
            %% SYSTEMATIC failure (port exhaustion under memory
            %% pressure) fires per message — the first line is the
            %% incident signal; volume rides the counters.
            warn_once({?MODULE, deflate_fail}, #{
                what => janus_wire_enc_deflate_fail,
                class => Class,
                reason => Reason
            }),
            {error, Reason}
    end.

count_identity_out(Bin) ->
    bump({wire_enc_chunks_total, {out, identity}}, 1),
    bump({wire_enc_bytes_total, {out, identity}}, byte_size(Bin)).

%%%===================================================================
%%% Inflate (F2/F3/D7 — tag-driven, capped, closed on every path)
%%%===================================================================

-spec inflate(zlib, binary()) -> {ok, binary()} | {error, term()}.
inflate(zlib, Bin) ->
    %% Decode needs ONLY the cap — PT cache first (boot snapshot),
    %% live env when unwired; no encode-side parsing on this path.
    inflate(zlib, Bin, #{max_inflate => max_inflate()}).

%% The shared F3 cap (JANUS_WIRE_ENC_MAX_INFLATE) as read by BOTH
%% inflate sites: the internal-hop per-message decode above AND the
%% PR2 upstream per-stream-ref streaming inflate (spec F3: "applies
%% to BOTH"). Exported for the seam (janus_providers_http opens its
%% streaming state with this value).
-spec max_inflate() -> pos_integer().
max_inflate() ->
    case pt_read({?MODULE, cfg}, undefined) of
        undefined ->
            max_inflate_from_env();
        #{max_inflate := Max} when is_integer(Max), Max >= 1 ->
            Max;
        %% Unexpected snapshot shape (ocr review): degrade to the
        %% live-env cap — this sits in inflate/2's argument position,
        %% OUTSIDE the tolerant catch-alls, so it must never raise.
        _Unexpected ->
            max_inflate_from_env()
    end.

-spec inflate(zlib, binary(), map()) -> {ok, binary()} | {error, term()}.
inflate(zlib, Bin, #{max_inflate := Max}) when is_binary(Bin), is_integer(Max), Max >= 1 ->
    T0 = erlang:monotonic_time(microsecond),
    Res = do_inflate(Bin, Max),
    bump(wire_enc_inflate_time_us_total, erlang:monotonic_time(microsecond) - T0),
    bump({wire_enc_chunks_total, {in, zlib}}, 1),
    case Res of
        {ok, Plain} ->
            bump({wire_enc_bytes_total, {in, zlib}}, byte_size(Bin)),
            bump({wire_enc_bytes_total, {in, plain}}, byte_size(Plain)),
            {ok, Plain};
        {error, _Reason} = Err ->
            %% The received wire bytes are counted on the failure path
            %% too (ocr review): D9's identity|zlib labels PARTITION
            %% wire bytes — every message lands in exactly one bucket,
            %% a failed decode included.
            bump({wire_enc_bytes_total, {in, zlib}}, byte_size(Bin)),
            bump(wire_enc_inflate_fail_total, 1),
            Err
    end;
%% Tolerant catch-all (ocr review): the decode path never raises into
%% the data-plane caller (D7/F2) — a stale/partial explicit config
%% degrades to a clean {error, bad_config}, not function_clause. The
%% ENCODE side (maybe_deflate/2) deliberately stays strict: a bad
%% config there is a worker-side programming error and crashes loud
%% (same philosophy as the chunk/4 constructor badmatch). Counted
%% like every other failed decode (consistency, ocr review); a
%% non-binary payload is a DIFFERENT fault (bad argument, not bad
%% config — kept distinguishable for the rollout gate, ocr review).
inflate(zlib, Bin, _BadCfg) when is_binary(Bin) ->
    warn_once({?MODULE, inflate_bad_config}, #{
        what => janus_wire_enc_inflate_bad_config
    }),
    bump({wire_enc_chunks_total, {in, zlib}}, 1),
    bump({wire_enc_bytes_total, {in, zlib}}, byte_size(Bin)),
    %% A DISTINCT counter (ocr review): a local config/wiring fault
    %% must never pollute wire_enc_inflate_fail_total — the §5
    %% rollout gate requires THAT counter to stay 0 for the whole
    %% bake, and a bad config is not wire corruption.
    bump(wire_enc_bad_config_total, 1),
    {error, bad_config};
inflate(zlib, _NotABinary, _Cfg) ->
    {error, bad_bin};
%% Unknown tag (ocr review): the wire boundary owns tag discipline
%% (non-zlib enc is bad_enc BEFORE the codec, F1) — this clause only
%% makes the never-raise contract total for a mis-dispatching caller.
inflate(_OtherTag, _Bin, _Cfg) ->
    {error, unknown_codec}.

%% Convenience for chunk data — same tag-driven decode (D2).
-spec inflate_chunk(binary()) -> {ok, binary()} | {error, term()}.
inflate_chunk(WireBin) ->
    inflate(zlib, WireBin).

-spec inflate_chunk(binary(), map()) -> {ok, binary()} | {error, term()}.
inflate_chunk(WireBin, Cfg) ->
    inflate(zlib, WireBin, Cfg).


%%%===================================================================
%%% Upstream gzip (PR2 — spec 2026-10-12-wire-compression G2/F3/F5/D5)
%%%===================================================================

%% D10: PR2's two env gates. JANUS_UPSTREAM_ENC adds Accept-Encoding:
%% gzip to UNARY provider requests; JANUS_UPSTREAM_ENC_STREAM (default
%% off, requires U.2 live-TTFB proof before any prod enable) extends it
%% to stream requests — provider-side proxies buffer gzip'd SSE flushes
%% and would silently destroy TTFB (qwen/stepfun audit).
-spec upstream_enc_enabled() -> boolean().
upstream_enc_enabled() ->
    env_flag("JANUS_UPSTREAM_ENC").

-spec upstream_enc_stream_enabled() -> boolean().
upstream_enc_stream_enabled() ->
    env_flag("JANUS_UPSTREAM_ENC_STREAM").

%% F5/D6: the bounded Content-Encoding grammar. absent/empty/identity
%% pass through; gzip decodes; EVERYTHING else (br, zstd, compound
%% \"gzip, br\", x-gzip, garbage) is a provider contract violation — the
%% caller routes it to the existing failover/reject cascade, never
%% parses, never passes through. Case-insensitive, trimmed.
-spec classify_content_encoding(undefined | binary()) ->
    identity | gzip | {violation, binary()}.
classify_content_encoding(undefined) ->
    identity;
classify_content_encoding(Value0) when is_binary(Value0) ->
    Value = string:trim(string:lowercase(Value0)),
    case Value of
        <<>> -> identity;
        <<"identity">> -> identity;
        <<"gzip">> -> gzip;
        _ -> {violation, Value0}
    end.

%% F5: a STREAM response arriving gzip'd when none was requested is
%% decoded anyway (decode is headers-driven, not request-driven) — but
%% it is the ops signal for provider/proxy flush-buffering TTFB risk.
-spec bump_unsolicited_gzip() -> ok.
bump_unsolicited_gzip() ->
    bump({upstream_enc_unsolicited_total, {in, gzip}}, 1).

%%%===================================================================
%%% Downstream REST JSON gzip (PR3 — spec
%%% 2026-10-12-wire-compression G3/F6/D8/D10; maturity batch H2)
%%%===================================================================

%% D10: PR3's env gate, default OFF. Read LIVE per reply (the
%% upstream_enc_enabled precedent: env cannot change under a running
%% VM, so a live read is exact; one BIF against the zlib work that
%% follows — no PT cache needed). The gate applies on the MASTER only
%% in practice (workers serve no :8080), but nothing here is
%% role-aware: the reply sites are.
-spec downstream_enc_enabled() -> boolean().
downstream_enc_enabled() ->
    env_flag("JANUS_DOWNSTREAM_ENC").

%% RFC 7231 §5.3.4 Accept-Encoding negotiation for `gzip' (pure).
%%
%% Pinned semantics (F6 + the eunit cells):
%%   - absent header => NOT selected. RFC 7231 would allow any coding
%%     for an absent field, but serving identity is ALWAYS legal and
%%     never breaks a client that never named gzip — the conservative
%%     pin (nginx / Cowboy negotiate the same way).
%%   - empty field value => identity-only (RFC 7231: "an empty
%%     combined field-value implies the sender is willing to accept
%%     only the identity coding").
%%   - duplicate tokens: the MINIMUM weight wins — any explicit
%%     `gzip;q=0' excludes gzip regardless of other spellings or of a
%%     permissive wildcard.
%%   - a MALFORMED or out-of-range qvalue degrades to weight 1 (the
%%     nginx precedent: a broken intermediary rewriting the header
%%     must not silently strip gzip).
%%   - the wildcard `*' admits gzip when gzip is not explicitly
%%     listed; an explicit `gzip;q=0' beats the wildcard.
%%   - non-q parameters (`level=9') are ignored (weight 1).
%%   - only the standard `gzip' token counts — `x-gzip' is historical
%%     and never promised downstream.
%% term()-wide domain on purpose (ocr r3): the catch-all below IS
%% the never-raise contract — a narrower spec would hide it.
-spec accept_encoding_selects_gzip(term()) -> boolean().
accept_encoding_selects_gzip(undefined) ->
    false;
accept_encoding_selects_gzip(AE) when is_binary(AE) ->
    case ae_elements(AE) of
        [] ->
            false;
        Elems ->
            select_gzip(Elems)
    end;
%% Totality for the never-raise decision contract (ocr review): the
%% parsers are EXPORTED, so a mis-dispatching caller can reach the
%% decision with a non-binary — degrade to "not selected" like
%% inflate/3's unknown-tag clause, never a function_clause 500.
accept_encoding_selects_gzip(_Other) ->
    false.

%% -> [{Coding (lowercase binary()), Weight (float())}] — empty and
%% whitespace-only comma elements dropped (list continuations).
ae_elements(AE) ->
    lists:filtermap(
        fun(Raw) ->
            Elem = string:trim(Raw),
            case Elem of
                <<>> ->
                    false;
                _ ->
                    [Name | Params] = binary:split(Elem, <<";">>, [global]),
                    {true, {string:lowercase(string:trim(Name)), ae_weight(Params)}}
            end
        end,
        binary:split(AE, <<",">>, [global])
    ).

select_gzip(Elems) ->
    case [W || {<<"gzip">>, W} <- Elems] of
        [] ->
            %% gzip unlisted: the wildcard decides (absent wildcard =
            %% gzip not acceptable; `*;q=0' refuses all unlisted).
            case [W || {<<"*">>, W} <- Elems] of
                [] -> false;
                Stars -> lists:min(Stars) > 0.0
            end;
        GzipQs ->
            %% Duplicate tokens: minimum weight wins.
            lists:min(GzipQs) > 0.0
    end.

%% Weight of ONE codeweight element: the MINIMUM over every `q'
%% parameter present (`gzip;q=1;q=0' is a malformed-but-decodable
%% spelling of refusal — a first-q-wins shortcut would contradict the
%% documented "any explicit q=0 excludes" pin; ocr review), and 1
%% when none is present (or none parses).
ae_weight(Params) when is_list(Params) ->
    case [Q || {ok, Q} <- [q_param(P) || P <- Params]] of
        [] -> 1.0;
        Qs -> lists:min(Qs)
    end.

q_param(Param) ->
    case binary:split(string:trim(Param), <<"=">>) of
        [K, V] ->
            case string:lowercase(string:trim(K)) of
                <<"q">> -> {ok, parse_qvalue(string:trim(V))};
                _OtherParam -> skip
            end;
        _NotAPair ->
            skip
    end.

%% qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] ).
%% Trailing-dot spellings ("0.", "1." — RFC-legal, 0*3DIGIT admits
%% zero digits) normalize through the same clauses; anything not
%% parsing to an integer 0|1 or a float in 0..1 is MALFORMED =>
%% weight 1 (see accept_encoding_selects_gzip/1 pins).
parse_qvalue(V0) when is_binary(V0) ->
    parse_qvalue1(strip_trailing_dot(V0)).

parse_qvalue1(<<"0">>) -> 0.0;
parse_qvalue1(<<"1">>) -> 1.0;
parse_qvalue1(V) when byte_size(V) >= 3 ->
    try
        case binary_to_float(V) of
            Q when Q >= 0.0, Q =< 1.0 -> Q;
            _OutOfRange -> 1.0
        end
    catch
        _:_ -> 1.0
    end;
parse_qvalue1(_Other) ->
    1.0.

strip_trailing_dot(V) ->
    N = byte_size(V),
    case N of
        0 ->
            V;
        _ ->
            case binary:part(V, N - 1, 1) of
                <<".">> -> binary:part(V, 0, N - 1);
                _ -> V
            end
    end.

%% F6 content-type enumeration (pure): `application/json' and `text/*'
%% ONLY — parameters stripped, case-insensitive (RFC 7231 media types
%% are case-insensitive). `text/event-stream' is NEVER compressible
%% (TTFB is the product), binary types never.
-spec compressible_content_type(term()) -> boolean().
compressible_content_type(undefined) ->
    false;
compressible_content_type(Ct) when is_binary(Ct) ->
    Base = string:lowercase(string:trim(hd(binary:split(Ct, <<";">>)))),
    case Base of
        <<"application/json">> -> true;
        <<"text/event-stream">> -> false;
        <<"text/", _/binary>> -> true;
        _ -> false
    end;
%% Totality for the never-raise decision contract (see
%% accept_encoding_selects_gzip/1's catch-all).
compressible_content_type(_Other) ->
    false.

%% The composed per-reply decision consumed by the janus_http unary
%% reply helper (janus_downstream_enc). BodySize is the PLAINTEXT
%% size; the threshold rides JANUS_WIRE_ENC_MIN_BYTES (D3 — the
%% single threshold knob in the ratified env inventory), read LIVE
%% exactly like the gate (see downstream_min_bytes/0). Composed OVER
%% downstream_enc_negotiable/2 — the negotiability conjunction (gate
%% + content type + threshold) has ONE source of truth shared with
%% the Vary predicate (ocr review: two hand-written copies of the
%% same conjunction can drift into e.g. gzip-without-Vary). The
%% no-expansion check (gzip must be strictly smaller) and the zlib
%% failure fallback live at the REPLY seam — they need the actual
%% bytes.
-spec downstream_gzip_decide(
    AE :: term(),
    ContentType :: term(),
    BodySize :: term()
) -> gzip | identity.
downstream_gzip_decide(AE, Ct, BodySize) ->
    case downstream_enc_negotiable(Ct, BodySize) andalso accept_encoding_selects_gzip(AE) of
        true -> gzip;
        false -> identity
    end.

%% Would this reply's REPRESENTATION vary with Accept-Encoding at all
%% (gate on + compressible content type + above threshold)? The reply
%% seam attaches `Vary: Accept-Encoding` for every negotiable reply —
%% not only the actually-gzipped one (ocr review / RFC 7231 §7.1.4):
%% an identity reply served to a non-gzip client is a DIFFERENT
%% representation from the gzip reply a gzip client would get for the
%% same URL, and a cache must not replay one for the other.
-spec downstream_enc_negotiable(term(), term()) -> boolean().
downstream_enc_negotiable(Ct, BodySize) ->
    downstream_enc_enabled() andalso
        compressible_content_type(Ct) andalso
        is_integer(BodySize) andalso BodySize >= downstream_min_bytes().

downstream_min_bytes() ->
    %% LIVE read, deliberately matching the gate's liveness (ocr
    %% review): the decision must source BOTH inputs from ONE config
    %% view — routing the threshold through the boot PT snapshot would
    %% make the two halves disagree the moment a snapshot is installed.
    %% On a running node env cannot change, so live == boot-time.
    max(0, env_int("JANUS_WIRE_ENC_MIN_BYTES", ?DEFAULT_MIN_BYTES)).

%% Streaming inflate state (F5): one state per gun STREAM REF (each
%% providers_http call owns its connection+stream pair — read-verified
%% — so the state lives in the call's closure scope). Auto-detecting
%% window bits (32 + 15) accept BOTH the RFC 1952 gzip wrapper upstream
%% speaks and the RFC 1950 zlib wrapper — the two formats NEVER share
%% init code blindly (qwen audit: a bare inflateInit/1 fails on gzip).
%% Completeness is OURS to prove (Task A probe: safeInflate's
%% `finished' does NOT prove stream end and a wrong checksum does not
%% raise) — finish/1 verifies the wrapper trailer from the rolling raw
%% head/tail: gzip => CRC32 (little) + ISIZE (little) of the OUTPUT;
%% zlib => adler32 (big). The per-round bound is safeInflate's own
%% ~16 KiB buffer; the CUMULATIVE cap is F3's authority (shared
%% JANUS_WIRE_ENC_MAX_INFLATE — \"applies to BOTH inflate sites\").
-define(GZIP_MAGIC, <<31, 139>>).
-define(STREAM_TAIL_LEN, 8).

-spec inflate_stream_open() -> {ok, map()} | {error, term()}.
inflate_stream_open() ->
    inflate_stream_open(max_inflate()).

%% Explicit-cap form (eunit seam / the seam's stream-ref state): the
%% INTEGER cap override, mirroring inflate/3's explicit-config idiom.
-spec inflate_stream_open(pos_integer()) -> {ok, map()} | {error, term()}.
inflate_stream_open(Max) when is_integer(Max), Max >= 1 ->
    try
        Z = zlib:open(),
        try
            zlib:inflateInit(Z, 32 + 15),
            {ok, stream_state_new(Z, Max)}
        catch
            Class:Reason ->
                _ = zlib:close(Z),
                {error, {Class, Reason}}
        end
    catch
        Class1:Reason1 ->
            {error, {Class1, Reason1}}
    end.

stream_state_new(Z, Max) ->
    #{
        z => Z,
        max => Max,
        total => 0,
        crc => 0,
        head => <<>>,
        tail => <<>>%% (done dropped: zlib reports finished at
        %% deflate-end before the trailer — an input-side latch was
        %% premature, and nothing else sets it; ocr review dead-code)
    }.

-spec inflate_stream_frame(map(), binary()) -> {ok, binary(), map()} | {error, term()}.
inflate_stream_frame(S, Bin) ->
    inflate_stream_frame(S, Bin, #{}).

%% NOTE (probe-verified by the byte-at-a-time fixture cell): zlib
%% reports `finished' at deflate-end BEFORE the 8 trailer bytes are
%% fed, so `done' is NOT a rejection latch here — later frames still
%% carry the trailer (finish/1's verify is the fail-closed authority,
%% and post-finish frames hit a CLOSED handle). Trailing garbage after
%% the trailer corrupts the rolling tail and fails the verify.
%% Cfg's optional `max_inflate` is a SINGLE-FRAME override (the
%% open-time cap stays in effect for drain rounds and finish — the /3
%% is an eunit seam; production callers use /2; ocr review doc pin).
-spec inflate_stream_frame(map(), binary(), map()) -> {ok, binary(), map()} | {error, term()}.
inflate_stream_frame(#{z := Z} = S, Bin, Cfg) when is_binary(Bin) ->
    Max = maps:get(max_inflate, Cfg, maps:get(max, S)),
    try
        case zlib:safeInflate(Z, Bin) of
            {need_dictionary, _Adler, _Out} ->
                %% FDICT-set stream (hostile/corrupt): the documented
                %% atom, never a badmatch masquerade (ocr review).
                _ = inflate_stream_close(S),
                {error, need_dictionary};
            {Status, Out} ->
                OutBin = iolist_to_binary(Out),
                S1 = stream_acc(S, Bin, OutBin, Max),
                case {Status, OutBin} of
                    {continue, <<>>} ->
                        %% Starved mid-stream (input consumed, no
                        %% output yet): wait for the next frame.
                        {ok, <<>>, S1};
                    _ ->
                        %% The one-shot drain discipline (drain/5): a
                        %% round with output — continue OR finished —
                        %% means more may be pending; keep draining
                        %% until an empty round.
                        stream_drain_pending(S1, Max, [OutBin])
                end
        end
    catch
        bomb ->
            _ = inflate_stream_close(S),
            {error, inflate_too_large};
        error:data_error ->
            _ = inflate_stream_close(S),
            {error, data_error};
        Class:Reason ->
            _ = inflate_stream_close(S),
            {error, {Class, Reason}}
    end.

%% Accumulate the decode-side accounting: cumulative output cap (F3),
%% rolling output checksums, and the raw wire head/tail the trailer
%% verify reads. Throws `bomb' — the caller maps it to the one-shot
%% path's inflate_too_large atom so ops sees ONE bomb semantics across
%% both inflate sites (F3).
stream_acc(S, WireIn, OutBin, Max) ->
    Total1 = maps:get(total, S) + byte_size(OutBin),
    case Total1 > Max of
        true ->
            throw(bomb);
        false ->
            S#{
                total => Total1,
                crc => erlang:crc32(maps:get(crc, S), OutBin),
                head => stream_head_keep(maps:get(head, S), WireIn),
                tail => stream_tail_keep(maps:get(tail, S), WireIn)
            }
    end.

stream_head_keep(<<>>, WireIn) when byte_size(WireIn) >= 2 ->
    binary:part(WireIn, 0, 2);
stream_head_keep(Head, WireIn) when byte_size(Head) < 2 ->
    Need = 2 - byte_size(Head),
    Take = min(Need, byte_size(WireIn)),
    <<Add:Take/binary, _/binary>> = WireIn,
    <<Head/binary, Add/binary>>;
stream_head_keep(Head, _WireIn) ->
    Head.

stream_tail_keep(Tail, WireIn) ->
    Merged = <<Tail/binary, WireIn/binary>>,
    case byte_size(Merged) > ?STREAM_TAIL_LEN of
        true -> binary:part(Merged, byte_size(Merged), -?STREAM_TAIL_LEN);
        false -> Merged
    end.

%% Drain pending output: empty-input rounds until one yields NOTHING
%% (continue-with-empty = starved awaiting input; finished-with-empty =
%% stream end — both stop; a round WITH output — continue or finished —
%% recurses: the one-shot drain/5 discipline, probe-verified to be the
%% only way a bounded-buffer safeInflate delivers large payloads).
stream_drain_pending(S, Max, Acc) ->
    stream_drain_round(S, Max, Acc).

stream_drain_round(#{z := Z} = S, Max, Acc) ->
    case zlib:safeInflate(Z, <<>>) of
        {need_dictionary, _Adler, _Out} ->
            _ = inflate_stream_close(S),
            {error, need_dictionary};
        {_Status, Out} ->
            OutBin = iolist_to_binary(Out),
            case OutBin of
                <<>> ->
                    {ok, iolist_to_binary(lists:reverse(Acc)), S};
                _ ->
                    try
                        S1 = stream_acc(S, <<>>, OutBin, Max),
                        stream_drain_round(S1, Max, [OutBin | Acc])
                    catch
                        bomb ->
                            %% Every-exit close contract (ocr review):
                            %% the cap path closes like the others.
                            _ = inflate_stream_close(S),
                            {error, inflate_too_large}
                    end
            end
    end.

%% Finish: final pending-output drain (must yield NOTHING — frame/2,3
%% already drained to quiescence), then the wrapper trailer verify —
%% the completeness authority — and ALWAYS closes the handle
%% (every-exit discipline, F5). Returns ok | {error, _}: all decoded
%% output was delivered by frame/2,3; a non-empty final drain is an
%% internal leak (fail loud, never silently drop bytes).
-spec inflate_stream_finish(map()) -> ok | {error, term()}.
inflate_stream_finish(S) ->
    try
        FinishDrain = stream_drain_round(S, maps:get(max, S), []),
        case FinishDrain of
            {ok, <<>>, S1} ->
                stream_verify_trailer(S1);
            {ok, _Leaked, _S1} ->
                {error, stream_drain_leak};
            {error, Reason} ->
                {error, Reason}
        end
    catch
        Class2:Reason2 ->
            {error, {Class2, Reason2}}
    after
        _ = inflate_stream_close(S)
    end.

%% Trailer verify from the rolling raw wire head/tail: gzip =>
%% CRC32 + ISIZE (both little-endian, RFC 1952 2.3). Any OTHER
%% wrapper head is the FORMAT-MIXING rejection (r4 audit: a zlib
%% RFC 1950 stream decodes fine through 32+15 auto-detect — the seam
%% still refuses it, because upstream Content-Encoding: gzip is RFC
%% 1952 by contract; the internal hop's RFC 1950 wrapper never rides
%% this path). A starved/truncated stream mismatches => data_error
%% (fail-closed — same atom as the one-shot path).
stream_verify_trailer(#{head := ?GZIP_MAGIC, tail := Tail, total := Total, crc := Crc}) ->
    case byte_size(Tail) >= 8 of
        true ->
            Trailer = binary:part(Tail, byte_size(Tail), -8),
            <<CrcWire:32/little, ISize:32/little>> = Trailer,
            case {Crc =:= CrcWire, (Total band 16#FFFFFFFF) =:= ISize} of
                {true, true} -> ok;
                _ -> {error, data_error}
            end;
        false ->
            {error, inflate_incomplete}
    end;
stream_verify_trailer(#{head := _OtherHead}) ->
    {error, data_error}.

-spec inflate_stream_close(map()) -> ok.
inflate_stream_close(#{z := Z}) ->
    try
        zlib:close(Z)
    catch
        _:_ -> ok
    end;
inflate_stream_close(_) ->
    ok.

do_inflate(Wire, _Max) when byte_size(Wire) < 6 ->
    %% Cannot hold the RFC 1950 header (2) + trailer (4): truncated.
    {error, inflate_incomplete};
do_inflate(Wire, Max) ->
    %% The open sits INSIDE the outer try (deflate_stream symmetry):
    %% even an open failure must surface as {error, _}, never an
    %% exception into the data-plane caller (D7/F2 contract).
    try
        Z = zlib:open(),
        try
            zlib:inflateInit(Z),
            case drain(Z, Wire, [], 0, Max) of
                {ok, Plain} ->
                    verify_adler(Wire, Plain);
                {error, _Reason} = Err ->
                    Err
            end
        after
            zlib:close(Z)
        end
    catch
        %% The only EXPECTED raise is data_error on corrupt wire bytes
        %% (the caller logs the normal inflate-fail; keep it quiet
        %% here). Anything else is an internal fault — logged, so a
        %% real bug never masquerades silently as corrupt wire (ocr
        %% review).
        error:data_error ->
            {error, data_error};
        Class:Reason ->
            warn_once({?MODULE, inflate_unexpected}, #{
                what => janus_wire_enc_inflate_unexpected,
                class => Class,
                reason => Reason
            }),
            {error, Reason}
    end.

%% Incremental capped inflate via zlib:safeInflate/2. Probe-verified
%% on OTP 27 (see janus_wire_enc_tests): each call returns a BOUNDED
%% output chunk (the ~16 KiB internal buffer) — that bound is the
%% decompression-bomb guard; the cumulative check after every round
%% is the cap authority (output EXCEEDING Max => inflate_too_large;
%% exactly-Max output is legal). Status semantics: `continue` means
%% more output is pending (drain again with empty input); `finished`
%% does NOT prove stream end — a starved (truncated) stream also
%% reports finished — so completeness is proven by verify_adler/2
%% below. Corrupt stream bytes raise inside safeInflate => {error, _}
%% via the catch in do_inflate. `need_dictionary` (never sent by our
%% encoder — D2 forbids dictionaries) is a malformed/hostile stream.
%% A zero-progress empty-input round is refused (termination guard —
%% no spin on a pathological status sequence; unreachable by
%% construction given OTP's continue-means-pending-output contract,
%% kept as a guard, cf. the eunit note on the FDICT fixture).
drain(Z, Input, Acc, Total, Max) ->
    case zlib:safeInflate(Z, Input) of
        {need_dictionary, _Adler, _Out} ->
            {error, need_dictionary};
        {Status, Out} ->
            OutBytes = iolist_size(Out),
            Total1 = Total + OutBytes,
            case Total1 > Max of
                true ->
                    {error, inflate_too_large};
                false ->
                    case {Status, Input, OutBytes} of
                        {finished, <<>>, _} ->
                            {ok, iolist_to_binary(lists:reverse([Out | Acc]))};
                        {continue, <<>>, 0} ->
                            {error, inflate_stalled};
                        {_Status, _Input, _OutBytes} ->
                            %% More output pending (continue), or the
                            %% defensive confirming drain after the
                            %% first round — never re-feeds input.
                            drain(Z, <<>>, [Out | Acc], Total1, Max)
                    end
            end
    end.

%% RFC 1950 trailer: the last 4 wire bytes are the big-endian
%% adler32 of the PLAINTEXT. zlib's own checksum verification does
%% not surface through safeInflate/2 (probe-verified: a flipped
%% trailer byte decodes without raising), so the end-of-stream proof
%% is ours — and it simultaneously decides complete-vs-truncated (a
%% starved stream yields a prefix whose adler cannot match).
%%
%% Documented behavior (ocr review, corrected): for a payload
%% `[valid stream] ++ [trailing bytes]' the trailer is read from the
%% payload END — the trailing bytes' last 4 — so the adler almost
%% always mismatches and the message is REJECTED {error, data_error}
%% (fail-closed; pinned by a test). Only a CRAFTED tail whose last 4
%% bytes equal adler32(plaintext) slips through, and that case is
%% decode-inert (the trailing bytes are never parsed; the decoded
%% output is exactly the legitimate plaintext) on an authenticated
%% internal hop (inet_tls dist) whose encoder never emits trailing
%% bytes (D2 one-stream-per-message). Known and accepted, not silent.
verify_adler(Wire, Plain) ->
    Trailer = binary:part(Wire, byte_size(Wire), -4),
    <<Expect:32/big>> = Trailer,
    case erlang:adler32(Plain) of
        Expect ->
            {ok, Plain};
        _Other ->
            {error, data_error}
    end.

%%%===================================================================
%%% Boot self-check (D11)
%%%===================================================================

-spec self_check() -> ok | {error, term()}.
self_check() ->
    self_check(env_config()).

%% D11's ROLE-AWARE gates (master: JANUS_WIRE_ENC=1 OR
%% JANUS_UPSTREAM_ENC=1; worker: JANUS_WIRE_ENC=1) live in the BOOT
%% WIRING of the later PR1 tasks (and PR2 for the upstream knob) —
%% it drives this /1 seam with an explicit config; /0 is the
%% env-driven convenience for the wire knob alone (ocr review).
-spec self_check(map()) -> ok | {error, term()}.
self_check(#{enabled := false}) ->
    %% A default-OFF node never refuses boot over an unused feature
    %% (D11 verbatim — deliberately NOT running the bomb probe when
    %% disabled, ocr review declined: advertisement — the only way
    %% compressed traffic starts — requires enabled=true, so an
    %% off-node's decode path is unreachable by cluster traffic).
    ok;
self_check(#{enabled := true, level := Level, max_inflate := Max}) when
    is_integer(Level), Level >= 1, Level =< 9, is_integer(Max), Max >= 1
->
    Payload = self_check_payload(),
    case deflate_stream(Payload, Level) of
        {ok, Wire} when byte_size(Wire) < byte_size(Payload) ->
            case do_inflate(Wire, Max) of
                {ok, Payload} ->
                    self_check_bomb_bound();
                {ok, _Other} ->
                    {error, self_check_mismatch};
                {error, Reason} ->
                    {error, Reason}
            end;
        {ok, _NotSmaller} ->
            {error, self_check_incompressible};
        {error, Reason} ->
            {error, Reason}
    end;
self_check(_BadCfg) ->
    %% An explicit config with an invalid/missing level or cap gets a
    %% CLEAR error (ocr review) — never a spurious
    %% self_check_incompressible from store-only deflate, never a
    %% function_clause.
    {error, bad_config}.

%% Deterministic, clearly compressible, production-shaped payload
%% (real SSE frame text, cf. the fixture cited in the eunit module).
self_check_payload() ->
    Frame =
        <<"data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,"
            "\"delta\":{\"content\":\"janus wire enc self check\"}}]}\n\n">>,
    binary:copy(Frame, 8).

%% Boot-time re-validation of the bomb-cap's load-bearing OTP
%% assumption (ocr review security round): the `Total1 > Max` post-
%% check only bounds memory if zlib:safeInflate/2 delivers output in
%% bounded rounds (pinned by safeinflate_bounded_output_test; here we
%% cheaply re-probe with a 1 MiB zero bomb — a master that advertises
%% compression must know its inflate is bomb-safe at boot, D11). The
%% round bound is ?SELF_CHECK_ROUND_BOUND (1 MiB) against a 4 MiB
%% payload — strictly below the payload (a payload-size bound would
%% be vacuous: valid output can never exceed the input, ocr review),
%% shared with the eunit tolerance so the boot gate never refuses a
%% build the tests accept.
self_check_bomb_bound() ->
    Plain = binary:copy(<<0>>, 4_194_304),
    case deflate_stream(Plain, 1) of
        {ok, Wire} ->
            try
                Z = zlib:open(),
                try
                    zlib:inflateInit(Z),
                    case zlib:safeInflate(Z, Wire) of
                        {need_dictionary, _Adler, _Out} ->
                            {error, need_dictionary};
                        {_Status, Out} ->
                            case iolist_size(Out) =< ?SELF_CHECK_ROUND_BOUND of
                                true -> ok;
                                false -> {error, self_check_unbounded_round}
                            end
                    end
                after
                    zlib:close(Z)
                end
            catch
                %% The boot gate never raises either (ocr review): a
                %% probe failure degrades to {error, _}.
                Class:Reason ->
                    {error, {Class, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% Boot wiring (D10/D11 — shared by BOTH roles' init; ocr review
%%% dedup: janus_worker_dispatch and janus_worker_pool delegate here)
%%%===================================================================

%% Given the ROLE-AWARE enable gate (worker: JANUS_WIRE_ENC; master:
%% JANUS_WIRE_ENC — D11's JANUS_UPSTREAM_ENC disjunct is a PR2 CALLER
%% change that composes as `WireEnabled orelse UpstreamEnabled`):
%% snapshot the enabled config (boot-time exactness where observable —
%% env cannot change under a running VM anyway; an env-OFF boot must
%% NOT leave a persistent_term snapshot behind or the live-env /1
%% forms would read a stale disabled config forever), run the
%% self-check — refusing boot LOUD on failure (a node that would
%% compress with a broken zlib is worse than one that never starts;
%% the permanent-restart supervisor exhausts and stops the node, the
%% janus_geo refuse-boot precedent) — and own the counters table
%% EITHER WAY (decode is tag-driven: an env-off master still decodes
%% stale zlib into the in-buckets).
-spec boot(boolean()) -> ok | {stop, wire_enc_self_check_failed}.
boot(true) ->
    ok = init_config_cache(),
    %% D11 (ocr review): the caller's gate decides the probe, not the
    %% wire-enc env — a JANUS_UPSTREAM_ENC-only master (PR2
    %% composition `WireEnabled orelse UpstreamEnabled`) must still run
    %% the self-check even though the snapshot says enabled=false.
    case self_check(maps:put(enabled, true, env_config())) of
        ok ->
            ensure_counters();
        {error, Reason} ->
            logger:error(#{
                what => janus_wire_enc_self_check_failed,
                reason => Reason
            }),
            {stop, wire_enc_self_check_failed}
    end;
boot(false) ->
    ensure_counters().

%%%===================================================================
%%% Counters (D9 — owner-local ETS, tolerant bump; NO-OP until
%%% ensure_counters/0 ran)
%%%===================================================================

%% Idempotent and race-free (ocr review): create-or-adopt — a
%% concurrent creator losing the ets:new race sees error:badarg
%% (name already exists) and treats it as success, not a boot error.
%% Production wiring (a long-lived owner) rides the later PR1 tasks —
%% worker-session processes must NOT own this table (they die per
%% job).
-spec ensure_counters() -> ok.
ensure_counters() ->
    try
        _ = ets:new(?COUNTERS, [
            set, public, named_table, {write_concurrency, true}
        ]),
        ok
    catch
        error:badarg ->
            %% Already created by a concurrent caller — fine.
            ok;
        Class:Reason ->
            logger:error(#{
                what => janus_wire_enc_counters_init_failed,
                class => Class,
                reason => Reason
            }),
            ok
    end.

%% Tolerant bump (janus_geo / janus_worker_pool precedent): missing
%% table, dead owner, or a non-integer increment never crashes the
%% data plane — observability only. A dropped counter is not fully
%% silent: the first drop after boot logs once (ocr review — a
%% mis-wired owner must be visible), never per message. Hot-path
%% note (ocr perf round, declined): try/catch setup is zero-cost in
%% modern OTP; the raise runs only in the TRANSITIONAL unwired state
%% (the later PR1 tasks wire ensure_counters at boot) and the
%% once-only warning adds a single persistent_term read.
-spec bump(term(), integer()) -> ok.
bump(Key, Incr) when is_integer(Incr) ->
    try
        _ = ets:update_counter(?COUNTERS, Key, Incr, {Key, 0}),
        ok
    catch
        _:_ ->
            warn_once({?MODULE, counters_absent}, #{
                what => janus_wire_enc_counters_absent
            }),
            ok
    end;
bump(_Key, _Incr) ->
    ok.

-spec counters() -> map().
counters() ->
    try
        maps:from_list(ets:tab2list(?COUNTERS))
    catch
        _:_ -> #{}
    end.

%%%===================================================================
%%% Internals
%%%===================================================================

%% Log-once dedup for per-message hot-path env clamps. A benign get/
%% put race can emit the warning twice; it can never spam per chunk.
warn_once(PTKey, Extra) ->
    try
        case persistent_term:get(PTKey, false) of
            false ->
                persistent_term:put(PTKey, true),
                logger:warning(Extra);
            true ->
                ok
        end
    catch
        _:_ -> ok
    end.
