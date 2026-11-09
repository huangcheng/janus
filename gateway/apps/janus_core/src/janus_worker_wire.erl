%%% @doc Pure constructors and validators for master/worker dist messages
%%% (spec §4). No I/O; safe redaction for verify artifacts.
%%%
%%% Wire compression extensions (spec 2026-10-12-wire-compression
%%% D2/F1): `chunk/4` carries the optional 5th Meta element
%%% (`#{enc => zlib}` — the 4-tuple stays the identity form), `done`
%%% gains the optional top-level `enc => zlib` map key (body-only
%%% compression), the hello_ack advertises the additive
%%% `wire_enc => [zlib]` capability, and `error` payloads are NEVER
%%% compressed. Old-peer validators tolerate every additive key.
-module(janus_worker_wire).

-export([
    credit_window_initial/0,
    non_stream_timeout_ms/0,
    stream_timeout_ms/0,
    stream_inactivity_timeout_ms/0,
    stream_keepalive_ms/0,
    ack_deadline_ms/0,
    initial_chunk_seq/0,
    hello/3,
    hello_ack/1,
    hello_ack/2,
    hello_nack/2,
    drain/1,
    job/3,
    job_ack/2,
    chunk/3,
    chunk/4,
    done/2,
    error/3,
    error/4,
    cancel/1,
    credit/2,
    redact_job/1,
    validate/1,
    %% Cadence for an already-resolved ceiling, so a caller reporting or
    %% anchoring the ceilings stays within one config generation.
    keepalive_for/1,
    %% One resolution of the two ceilings, for callers that need both.
    %% Reading them through the individual accessors can straddle a config
    %% generation swap and yield one value from each, transiently inverting
    %% `inactivity < total` inside a single stream.
    stream_budgets/0
]).

%% Floors for the two stream-timing knobs. MIN_IDLE_MS exists so the
%% ceiling is always meaningfully larger than the keepalive cadence
%% (ceiling - 1 must be > 0 for the cadence to be strictly below it);
%% MIN_KEEPALIVE_MS stops an explicit tiny cadence from turning the
%% drain loop and the client into a ~1 kHz wakeup flood.
-define(MIN_IDLE_MS, 1_000).
-define(MIN_KEEPALIVE_MS, 50).

%% Shipped total stream budget. Named because it now has two readers — the
%% `stream_total_timeout_ms` setting and the invalid-pair fallback below —
%% and the incident history in this file makes a future retune of it
%% plausible. Two literals would let the "unset" and "invalid pair" paths
%% silently disagree about the same constant.
-define(DEFAULT_TOTAL_MS, 600_000).
%% Shipped inactivity default, named for the same reason: the garbage-pair
%% fallback needs it, and it must not drift from the value used when the
%% settings row is simply absent.
-define(DEFAULT_IDLE_MS, 180_000).
%% Hard upper bound on the inactivity ceiling. The point of the ceiling is to
%% speak BEFORE the client gives up: pi (and most HTTP clients) default the
%% request idle timeout to 300s, so a ceiling above that leaves the gateway
%% detecting a stall the client never lives to read — the 2026-10-29
%% incident shape, where 15 turns died blind. Now that the ceiling is a hot
%% knob this must be enforced in the resolver, not just by the shipped
%% default: the dashboard range alone cannot express it.
%%
%% COUPLED TO THE CLIENT. 299_000 is one second under that 300s default, and
%% it is a hard cap, not a suggestion: a stream that goes genuinely quiet
%% longer than this is still torn down here. Raising it means keeping FOUR
%% sites in step:
%%
%%   1. the client's own stream idle timeout (for the pi-based harness,
%%      `streamIdleTimeoutMs`, default 300_000) — raise it first;
%%   2. this macro;
%%   3. `_TRANSLATE_CAP_LIMITS["stream_inactivity_timeout_ms"]` in
%%      dashboard/app/routers/settings.py, whose upper bound is this same
%%      value. The dashboard REFUSES a larger entry with a 400 rather than
%%      clamping it, so raising the macro alone leaves the knob unsettable
%%      through the UI (env var or a direct settings-row edit would still
%%      work);
%%   4. the pinned expectations in
%%      gateway/apps/janus_http/test/janus_stream_inactivity_hot_tests.erl,
%%      which fail until updated.
%%
%% Raising this macro above 300_000 ALSO needs a total budget raised with
%% it, because idle_lead/2 additionally caps the idle deadline at
%% `Total div 2` and the dashboard's total ceiling is 3_600_000 — so an
%% inactivity ceiling above 1_800_000 can never be honoured through the UI,
%% however high this macro goes.
%%
%% Any configured value above ?MAX_IDLE_MS is CLAMPED here, whichever path
%% supplied it — dashboard, direct settings-row edit, or the env var — and
%% `/stats.stream_budgets` then reports the clamped `inactivity_ms` without
%% labelling it as a clamp. So a configured-but-ignored ceiling is silent,
%% and the value in force is never higher than this macro.
-define(MAX_IDLE_MS, 299_000).

-define(VSN, 1).
-define(METHODS, [get, post, put, delete, patch]).
-define(ERROR_CODES, [timeout, connect, tls, upstream_closed, internal]).
-define(NACK_REASONS, [drained, vsn, role, node]).

-spec credit_window_initial() -> pos_integer().
credit_window_initial() -> 32.

-spec non_stream_timeout_ms() -> pos_integer().
non_stream_timeout_ms() -> 120_000.

%% TOTAL age cap for one stream, anchored once at drain start (2026-10-29).
%%
%% Before that change the drain recomputed this instant on every
%% forwarded chunk, so a healthy stream could never reach it and the cap
%% was effectively inert. It is now a real ceiling: a stream still open
%% at 600s is torn down whichever of the two budgets fires.
%%
%% Why 600s: production logs on the aliyun master (4.3h window, 1840
%% requests, 1616 streaming) show p50 7.2s, p90 22.6s, p99 150s,
%% p99.9 250s, max 295.8s. There are ZERO completed requests at or above
%% 300s, which is exactly pi's client idle timeout — those streams were
%% cut client-side and never recorded, so the tail is LEFT-CENSORED and
%% this data cannot measure the real upper bound. What it does show is
%% that the healthy long tail sits around 250s, so 600s keeps ~2.4x
%% headroom on a normal stream. Raising it would only extend how long a
%% pathological non-terminating provider holds a pool slot (the trip
%% path releases on inactivity but NOT on the total budget, matching the
%% long-standing "no release on timeout" policy). Revisit if a
%% legitimately longer generation shape appears — that would need a
%% configurable knob, not a bigger constant.
%%
%% Operator-adjustable since 2026-11-05 (settings key `translate`
%% -> `stream_total_timeout_ms`). The constant below is the shipped
%% default; the setting is read on every call (a persistent_term read,
%% no I/O), so raising it needs no release.
%%
%% The 600s ceiling was sized from a window whose tail was LEFT-CENSORED
%% at pi's 300s client timeout, so it could not measure the real upper
%% bound. A reasoning-heavy long task then hit it live: 141,960 chars of
%% reasoning streamed steadily for 600s and was torn down before the
%% first byte of the answer, with the provider perfectly healthy. A total
%% budget cannot tell "still thinking" from "stuck"; the inactivity
%% deadline (stream_inactivity_timeout_ms/0) already draws that line, so
%% the total cap only needs to be generous enough not to cut a working
%% stream.
-spec stream_timeout_ms() -> pos_integer().
stream_timeout_ms() ->
    element(1, resolve_stream_budgets()).

%% Both ceilings from ONE resolution. Prefer this over the two individual
%% accessors whenever a caller needs the pair, so a reload landing between
%% the calls cannot mix generations.
-spec stream_budgets() -> {pos_integer(), pos_integer()}.
stream_budgets() ->
    resolve_stream_budgets().

%% The two ceilings are resolved TOGETHER so `inactivity < total` holds for
%% every input rather than for the one the old code happened to compare.
%%
%% The ordering is load-bearing: the inactivity deadline is what
%% distinguishes a stuck stream from a slow one, and a total budget at or
%% below it would tear down a healthy stream before the stall detector
%% could ever speak. Both halves of that rule are now enforced in one
%% place, because the value can arrive from the dashboard PUT, a direct
%% settings-row edit, or an ops script — a guarantee that only holds for
%% one writer is not a guarantee:
%%
%%   1. The total is never LOWERED below ?DEFAULT_TOTAL_MS. When the pair
%%      inverts, a total under the constant is lifted to it (the
%%      pre-2026-11-09 fallback, kept: the incident behind it was a 60s
%%      total tearing down a healthy stream), while a total the operator
%%      raised ABOVE the constant is preserved — substituting the constant
%%      there would re-arm the very teardown the raise was meant to avoid.
%%   2. The inactivity side yields instead: it is capped at half the
%%      resolved total, so neither an inverted pair nor a merely
%%      above-half one can leave the stall detector unable to fire first.
%%
%% `/stats.stream_budgets` reports the resolved pair, so the effective
%% value is never a guess.
resolve_stream_budgets() ->
    %% ONE snapshot of the settings map for both keys. Reading it twice (as
    %% the two accessors would) lets a put land between the reads and mix
    %% generations — an idle value neither generation configured. The
    %% reconciliation below still repairs the ordering, but the pair would
    %% then be one no operator ever wrote.
    Cfg = persistent_term:get({janus, translate_cfg}, undefined),
    Total0 = total_budget_ms(Cfg),
    Idle0 = inactivity_budget_ms(Cfg),
    %% The garbage threshold is 2 * ?MIN_IDLE_MS, not ?MIN_IDLE_MS, on
    %% purpose: BELOW twice the idle floor, `Total div 2` in idle_lead/2
    %% lands under ?MIN_IDLE_MS, so the half-total cap degenerates to a flat
    %% idle floor and the stall detector loses the lead it needs to fire
    %% first. Lowering this threshold breaks that invariant.
    %%
    %% The guard is `=<` while that rationale only demands `<`. At EXACTLY
    %% 2 * ?MIN_IDLE_MS (2000ms) the pair would still be valid — (2000, 1000)
    %% gives a real half-total lead — so the inclusive edge is a deliberately
    %% conservative call, not a derivation: a total of two seconds is not a
    %% budget anyone means, and treating the boundary as garbage keeps the
    %% rule simple to state. It is pinned by
    %% sub_second_total_resolves_to_the_constant_pair_test/0.
    case Total0 =< 2 * ?MIN_IDLE_MS of
        true ->
            %% BOTH keys are garbage: a total mistyped in seconds implies an
            %% idle value in the same wrong unit. Falling back on the total
            %% alone would then clamp a 180 (seconds intent) up to the 1s
            %% floor and hand the gateway a 1-second silence ceiling — every
            %% stream killed after a second of quiet, a fresh incident
            %% instead of a recovery. Discard the pair together.
            Total = max(?DEFAULT_TOTAL_MS, Total0),
            {Total, idle_lead(?DEFAULT_IDLE_MS, Total)};
        false ->
            resolve_pair(Total0, Idle0)
    end.

%% Only reached once the garbage-total `case` in resolve_stream_budgets/0
%% has been ruled out, so this is the ordinary path: pick the total, then
%% let the idle side yield to it. See resolve_total/2 and idle_lead/2 for
%% why a lowered, inverted, or raised total is handled the way it is.
resolve_pair(Total0, Idle0) ->
    Total = resolve_total(Total0, Idle0),
    Inactivity = idle_lead(Idle0, Total),
    {Total, Inactivity}.

%% The two ways a configured total is not intent, and therefore yields to
%% the shipped constant:
%%
%%   - Garbage: at or below 2*MIN_IDLE_MS. A mistyped 600 (seconds entered
%%     as ms) honoured literally would tear down every stream after ~1s and
%%     drag the worker job timeout and the listener idle timeout down with
%%     it — the teardown class the constant fallback exists to prevent.
%%   - Inverted below the constant: `total =< inactivity` with a total
%%     under ?DEFAULT_TOTAL_MS. This is the 2026-11-09-era incident shape (a
%%     60s total cutting a healthy stream), and trusting the operator to
%%     have meant a total that low is worse than ignoring it.
%%
%% An inversion where the total is already ABOVE the constant is kept: the
%% operator raised that total deliberately and the idle cap restores the
%% ordering without discarding it.
resolve_total(Total0, Idle0) when Total0 =< Idle0, Total0 < ?DEFAULT_TOTAL_MS ->
    ?DEFAULT_TOTAL_MS;
resolve_total(Total0, _Idle0) ->
    Total0.

%% Keep a USABLE lead between the two deadlines, not merely a satisfied
%% inequality. `Total - 1` passes the ordering on paper and still loses in
%% practice: stream_drain restarts the inactivity deadline on every
%% forwarded chunk, so once any chunk lands the idle deadline sits later
%% than the total one and `deadline_remaining/2` picks the total every
%% tick — the stall detector never speaks and the stream dies with the
%% total-budget wording even though silence is what happened.
%%
%% EVERY idle value above half the total is capped to half, not only one
%% above the total. Honouring a value in `(total/2, total)` would satisfy
%% the ordering and still lose the lead: a chunk landing past `total - idle`
%% re-arms the idle deadline beyond the total, total wins every tick from
%% then on, and the stall path is silent for the rest of the stream. Above
%% half the total a stall-first deadline is not expressible, so the cap is
%% the honest resolution and `/stats.stream_budgets` reports what is in
%% force.
%%
%% No log line: these readers sit on the per-request (and per-tick) hot
%% path, so a warning here would flood. The ordinary path cannot reach a
%% substitution — the dashboard PUT cross-checks the pair and refuses a
%% violating one (the gateway stays the enforcement point for direct
%% settings-row edits and ops scripts). Should a substitute happen anyway,
%% `/stats.stream_budgets` reports the value actually in force, so it is
%% discoverable without log noise.
idle_lead(Idle0, Total) ->
    %% Three bounds, innermost first:
    %%   1. the configured value;
    %%   2. ?MAX_IDLE_MS, the client-idle ceiling (defined with the other
    %%      macros at the top of this module) — this is what keeps a stall
    %%      reportable before the client's own timeout;
    %%   3. the half-total lead — this is what keeps the stall path reachable
    %%      within the stream.
    Capped = min(Idle0, ?MAX_IDLE_MS),
    max(?MIN_IDLE_MS, min(Capped, Total div 2)).

total_budget_ms(Cfg) ->
    setting_ms(Cfg, <<"stream_total_timeout_ms">>, ?DEFAULT_TOTAL_MS).

%% Where the inactivity ceiling comes from, in precedence order:
%%
%%   1. JANUS_STREAM_INACTIVITY_TIMEOUT_MS, when set and parseable.
%%   2. The hot `translate` settings row, `stream_inactivity_timeout_ms`.
%%   3. The shipped 180_000 default.
%%
%% The env var outranks the row because it is an explicit operator/CI
%% override, and the live verification drivers (run_matrix_b.sh,
%% verify_stream_live.sh) shrink the window through it so a B6-style case
%% does not idle out the real ceiling. Letting the row win would let the
%% dashboard's materialized default shadow that override the moment
%% anything wrote the row — silently reverting a driver run to the
%% production ceiling and hanging the case for minutes. An override that
%% can be shadowed is not an override.
%%
%% The row is the ordinary path, and it is what this change adds: the
%% ceiling moved from env-only to a settings write plus a generation bump,
%% so tuning it no longer needs a container restart — the behaviour every
%% other knob in this repository already has.
inactivity_budget_ms(Cfg) ->
    %% positive_env/2 yields its Default when the var is absent or
    %% malformed, so passing the row-resolved value as that default gives
    %% the whole precedence chain in one call.
    Hot = setting_ms(Cfg, <<"stream_inactivity_timeout_ms">>, ?DEFAULT_IDLE_MS),
    case positive_env("JANUS_STREAM_INACTIVITY_TIMEOUT_MS", undefined) of
        undefined when Hot >= ?MIN_IDLE_MS ->
            %% The row is the ordinary path and is honoured as written.
            Hot;
        undefined ->
            %% A SUB-FLOOR row value is a unit typo (180 meant as seconds),
            %% not a usable ceiling. Flooring it to ?MIN_IDLE_MS would
            %% silently hand the fleet a one-second silence ceiling — every
            %% stream killed after a second of quiet, before the first byte
            %% included — which is the incident class the garbage-pair
            %% branch exists to prevent, reachable here without a garbage
            %% total. Fall back to the shipped default instead.
            ?DEFAULT_IDLE_MS;
        Env ->
            %% An explicit override ARGUABLY wants a short window (the live
            %% drivers shrink it on purpose), so floor it to the minimum
            %% rather than discarding the operator's intent.
            max(?MIN_IDLE_MS, Env)
    end.

%% Same shape as janus_protocol_translate:tool_cap/1: absent or malformed
%% falls back to the shipped default, so an unconfigured gateway behaves
%% exactly as before. Zero, negatives and non-integers are malformed —
%% none of them may mean "no ceiling".
setting_ms(Cfg, Key, Default) when is_map(Cfg) ->
    case maps:get(Key, Cfg, undefined) of
        N when is_integer(N), N > 0 -> N;
        _ -> Default
    end;
setting_ms(_Cfg, _Key, Default) ->
    Default.

%% Mid-stream INACTIVITY ceiling (2026-10-29): stream_timeout_ms/0 is a
%% TOTAL budget for the whole stream; producers that never die but
%% never produce let a request sit for the full 10 minutes while the
%% client gave up long before. That asymmetry is what made a 300s
%% client idle timeout look like an unexplained "terminated" with no
%% gateway-side counterpart (live 2026-10-29: 15 aborted turns,
%% upstreams "completing" at latency_ms=294473). A stream that goes
%% this long WITHOUT A SINGLE BYTE is a stalled upstream, and the
%% gateway must say so in its own words instead of letting the client
%% die blind. Restarts on every forwarded chunk (progress), so only
%% true silence trips it. Deliberately BELOW stream_timeout_ms/0.

%% Overridable so the live verification driver can shrink the window
%% instead of idling out the real ceiling, and so an operator can tune it
%% per fleet — through the hot `translate` settings row (2026-11-09), with
%% the env var still outranking it for the driver (see the precedence note
%% on inactivity_budget_ms/1). Floored at MIN_IDLE_MS: a
%% tiny ceiling is not a useful config (it would tear down healthy streams
%% instantly) and it breaks the keepalive invariant, which needs strictly
%% ceiling > keepalive to give the keepalive any chance to fire. Flooring
%% at the SOURCE is the only way to guarantee that for every input;
%% clamping on the keepalive side cannot, since ceiling-1 == ceiling when
%% ceiling == 1.
-spec stream_inactivity_timeout_ms() -> pos_integer().
stream_inactivity_timeout_ms() ->
    element(2, resolve_stream_budgets()).

%% Client-facing SSE comment cadence. Lives here (not in janus_http) so
%% janus_providers can use it without depending on the HTTP app — the
%% dependency runs janus_http -> janus_providers, never the reverse.
%% Kept below the inactivity ceiling so a silent stream is always
%% reassured at least once before it is torn down.
-spec stream_keepalive_ms() -> pos_integer().
stream_keepalive_ms() ->
    keepalive_for(stream_inactivity_timeout_ms()).

%% The cadence for a ceiling the caller ALREADY resolved. Callers that also
%% report or anchor the ceilings use this so the derived cadence belongs to
%% the same resolution: recomputing the ceiling here could straddle a config
%% generation and yield a cadence that does not correspond to the reported
%% inactivity_ms (possibly even keepalive >= inactivity, which the invariant
%% forbids).
-spec keepalive_for(pos_integer()) -> pos_integer().
keepalive_for(Ceiling) ->
    case keepalive_setting() of
        V when is_integer(V), V > 0, V < Ceiling ->
            %% The floor applies to EXPLICIT values too: a 1ms cadence is
            %% a ~1 kHz wakeup flood on the drain loop and on the client,
            %% which is the failure mode the floor exists to prevent.
            max(?MIN_KEEPALIVE_MS, V);
        _ ->
            default_keepalive_ms(Ceiling)
    end.

%% application env first (tests set it in-process), then the OS
%% environment (deploys set it via -e), then the built-in default.
keepalive_setting() ->
    case application:get_env(janus_core, stream_keepalive_ms) of
        {ok, V} ->
            V;
        undefined ->
            case os:getenv("JANUS_STREAM_KEEPALIVE_MS") of
                false ->
                    undefined;
                Raw ->
                    case string:to_integer(string:trim(Raw)) of
                        {N, ""} when is_integer(N) -> N;
                        _ -> undefined
                    end
            end
    end.

%% Always strictly BELOW the ceiling, so the client is reassured at
%% least once before the stream is torn down. The ceiling is floored at
%% MIN_IDLE_MS, so Ceiling - 1 > 0 always holds and this cannot collapse
%% onto the ceiling.
default_keepalive_ms(Ceiling) ->
    max(?MIN_KEEPALIVE_MS, min(15_000, Ceiling - 1)).

%% A malformed or non-positive override falls back to the default
%% rather than disarming a timeout: a 0 there would make the ceiling
%% inert, which is the failure mode this whole change removes.
positive_env(Name, Default) ->
    case os:getenv(Name) of
        false ->
            Default;
        V ->
            case string:to_integer(string:trim(V)) of
                {N, ""} when is_integer(N), N > 0 -> N;
                _ -> Default
            end
    end.

-spec ack_deadline_ms() -> pos_integer().
ack_deadline_ms() -> 5_000.

-spec initial_chunk_seq() -> 0.
initial_chunk_seq() -> 0.

-spec hello(pid(), node(), map()) -> {janus_worker_hello, pid(), node(), map()}.
hello(From, Node, Opts) when is_pid(From), is_atom(Node), is_map(Opts) ->
    Region = maps:get(region, Opts, undefined),
    %% Scheduler v2 ADDITIVE hello keys (spec Part 0.10): capacity /
    %% sched_v / git_sha (v2.1 A.3/C.3 build provenance) ride the meta
    %% ONLY when well-formed — an old master's admit path builds its
    %% record from known keys and ignores them; the validator below
    %% tolerates the extra keys (verified: it matches on role/vsn/
    %% region only). Geo-affinity (2026-10-11 spec D4/D18): the worker's
    %% layered egress discovery rides egress_ip / egress_region /
    %% egress_source / egress_fetched_at plus the gw-echo health
    %% counters echo_ok_total / echo_fail_total — all omitted when
    %% absent (knob-off / no usable layer), same additive contract.
    Additive = maps:filter(
        fun
            (capacity, C) when is_integer(C), C >= 1 -> true;
            (sched_v, V) when is_integer(V), V >= 1 -> true;
            (git_sha, S) when is_binary(S), S =/= <<>> -> true;
            (egress_ip, S) when is_binary(S), S =/= <<>> -> true;
            (egress_region, S) when is_binary(S), S =/= <<>> -> true;
            (egress_source, S) when is_binary(S), S =/= <<>> -> true;
            (egress_fetched_at, T) when is_integer(T), T >= 0 -> true;
            (echo_ok_total, N) when is_integer(N), N >= 0 -> true;
            (echo_fail_total, N) when is_integer(N), N >= 0 -> true;
            (_K, _V) -> false
        end,
        Opts
    ),
    Meta = maps:merge(#{role => worker, vsn => ?VSN, region => Region}, Additive),
    Msg = {janus_worker_hello, From, Node, Meta},
    ok = validate(Msg),
    Msg.

-spec hello_ack(node()) -> {janus_worker_hello_ack, node(), map()}.
hello_ack(Node) when is_atom(Node) ->
    hello_ack(Node, #{}).

%% Wire compression (spec 2026-10-12 D2/F1): the master advertises
%% the compression capability as an ADDITIVE ack-map key. The option
%% carries the master's supported-codec LIST; we advertise the
%% DECODABLE SUBSET, normalized to `[zlib]' — `lists:member(zlib,
%% ...)' so a future multi-codec master (e.g. `[zlib, br]') still
%% advertises the zlib it can decode instead of silently dropping
%% compression end-to-end (ocr review); anything else is omitted (the
%% constructor never puts a capability on the wire the codec cannot
%% decode). The ack validator tolerates the extra key either way
%% (partial-map pattern), so an old worker still decodes.
%% SEQUENCING (PR1 task A): the master pool's gated call site (D10 —
%% `JANUS_WIRE_ENC` role-aware) is wired in the LATER PR1 task; until
%% then only the /1 form is on the wire (capability never advertised,
%% workers stay identity — the codec is unreachable end-to-end by
%% construction).
-spec hello_ack(node(), map()) -> {janus_worker_hello_ack, node(), map()}.
hello_ack(Node, Opts) when is_atom(Node), is_map(Opts) ->
    Codecs = maps:get(wire_enc, Opts, undefined),
    HasZlib = is_list(Codecs) andalso zlib_member(Codecs),
    Meta =
        case HasZlib of
            true -> #{vsn => ?VSN, wire_enc => [zlib]};
            false -> #{vsn => ?VSN}
        end,
    Msg = {janus_worker_hello_ack, Node, Meta},
    ok = validate(Msg),
    Msg.

%% is_list/1 accepts IMPROPER lists and lists:member/2 would then
%% raise function_clause — a malformed capability value must be
%% dropped, never crash the constructor (ocr review).
zlib_member(Codecs) ->
    try
        lists:member(zlib, Codecs)
    catch
        _:_ -> false
    end.

-spec hello_nack(node(), drained | vsn | role | node) ->
    {ok, {janus_worker_hello_nack, node(), map()}} | {error, term()}.
hello_nack(Node, Reason) when is_atom(Node) ->
    case valid_nack_reason(Reason) of
        ok ->
            Msg = {janus_worker_hello_nack, Node, #{reason => Reason}},
            ok = validate(Msg),
            {ok, Msg};
        {error, _} = Err ->
            Err
    end.

-spec drain(node()) -> {janus_worker_drain, node()}.
drain(Node) when is_atom(Node) ->
    Msg = {janus_worker_drain, Node},
    ok = validate(Msg),
    Msg.

-spec job(binary(), pid(), map()) ->
    {ok, {janus_job, binary(), pid(), map()}} | {error, term()}.
job(JobRef, MasterSessionPid, Fields) when is_binary(JobRef), is_pid(MasterSessionPid), is_map(Fields) ->
    case validate_job_fields(Fields) of
        ok ->
            Msg = {janus_job, JobRef, MasterSessionPid, Fields},
            ok = validate(Msg),
            {ok, Msg};
        {error, _} = Err ->
            Err
    end.

-spec job_ack(binary(), pid()) -> {janus_job_ack, binary(), pid()}.
job_ack(JobRef, WorkerSessionPid) when is_binary(JobRef), is_pid(WorkerSessionPid) ->
    Msg = {janus_job_ack, JobRef, WorkerSessionPid},
    ok = validate(Msg),
    Msg.

-spec chunk(binary(), non_neg_integer(), binary()) ->
    {janus_chunk, binary(), non_neg_integer(), binary()}.
chunk(JobRef, Seq, Bin) when is_binary(JobRef), is_integer(Seq), Seq >= 0, is_binary(Bin) ->
    Msg = {janus_chunk, JobRef, Seq, Bin},
    ok = validate(Msg),
    Msg.

%% Wire compression (spec 2026-10-12 D2/F1): the 5-tuple form carries
%% zlib bytes in Bin plus the Meta map. `#{enc => zlib}` when
%% compressed; `#{}` is the normalization target for the master-side
%% FIRST-receive clause (4-tuple => 5-tuple before seq/credit/log
%% handling); the identity fallback NEVER emits an enc key. Assert
%% style matches chunk/3: a malformed enc tag crashes the sender (a
%% worker-side bug — loud, never silent).
-spec chunk(binary(), non_neg_integer(), binary(), map()) ->
    {janus_chunk, binary(), non_neg_integer(), binary(), map()}.
chunk(JobRef, Seq, Bin, Meta) when
    is_binary(JobRef), is_integer(Seq), Seq >= 0, is_binary(Bin), is_map(Meta)
->
    Msg = {janus_chunk, JobRef, Seq, Bin, Meta},
    ok = validate(Msg),
    Msg.

%% Wire compression (spec 2026-10-12 D2): the done map MAY carry the
%% top-level `enc => zlib` key — ONLY the `body` field value is
%% compressed; usage/status/trailers stay plaintext (readable
%% outline). The validator below enforces the enc tag. SEQUENCING
%% (PR1 task A): the validator accepts the tagged shape BEFORE any
%% sender ships it (the repo's validators-before-senders rule) — the
%% master-side done-body decode lands in the later PR1 task together
%% with the compressing senders, so no tagged done exists on the wire
%% until its decoder does.
-spec done(binary(), map()) -> {janus_done, binary(), map()}.
done(JobRef, Fields) when is_binary(JobRef), is_map(Fields) ->
    Msg = {janus_done, JobRef, Fields},
    ok = validate(Msg),
    Msg.

%% Wire compression (spec 2026-10-12 D2): error payloads are NEVER
%% compressed — the message is a short string (nothing to compress)
%% and the error outline stays fully readable on the master; there is
%% no enc tag on janus_error by construction, so an error can never
%% fail inflate on the abort path (F2).
-spec error(binary(), atom(), binary()) ->
    {ok, {janus_error, binary(), map()}} | {error, term()}.
error(JobRef, Code, Message) when is_binary(JobRef), is_binary(Message) ->
    error(JobRef, Code, Message, #{}).

%% Scheduler v2 additive-key form (spec A.3): ExtraFields merges into
%% the base #{code, message} map — the shipped error validator matches
%% on code/message only, so extra keys (`rtt_ms`) pass validation and
%% an old master still decodes the message (spec Part 0.10).
-spec error(binary(), atom(), binary(), map()) ->
    {ok, {janus_error, binary(), map()}} | {error, term()}.
error(JobRef, Code, Message, ExtraFields) when
    is_binary(JobRef), is_binary(Message), is_map(ExtraFields)
->
    case valid_error_code(Code) of
        ok ->
            %% Base keys WIN: an ExtraFields collision with the
            %% reserved code/message must never override the wire
            %% contract (ocr review). `enc` is reserved-ABSENT here:
            %% error payloads are NEVER compressed (spec
            %% 2026-10-12-wire-compression D2 — the outline stays
            %% readable and can never fail inflate), so a smuggled
            %% enc key is stripped before the wire (ocr review).
            %% INTENTIONAL asymmetry with the boundary (ocr review):
            %% the constructor STRIPS (a Janus error must always be
            %% deliverable — stripping never blocks an error), while
            %% validate/1 REJECTS a raw enc-carrying tuple
            %% (valid_error_no_enc) — defense in depth in both
            %% directions.
            Fields = maps:merge(maps:remove(enc, ExtraFields), #{code => Code, message => Message}),
            Msg = {janus_error, JobRef, Fields},
            ok = validate(Msg),
            {ok, Msg};
        {error, _} = Err ->
            Err
    end.

-spec cancel(binary()) -> {janus_cancel, binary()}.
cancel(JobRef) when is_binary(JobRef) ->
    Msg = {janus_cancel, JobRef},
    ok = validate(Msg),
    Msg.

-spec credit(binary(), pos_integer()) -> {janus_credit, binary(), pos_integer()}.
credit(JobRef, N) when is_binary(JobRef), is_integer(N), N > 0 ->
    Msg = {janus_credit, JobRef, N},
    ok = validate(Msg),
    Msg.

-spec redact_job({janus_job, binary(), pid(), map()}) ->
    {ok, {janus_job, binary(), pid(), map()}} | {error, term()}.
redact_job({janus_job, JobRef, MasterSessionPid, Fields}) ->
    case validate({janus_job, JobRef, MasterSessionPid, Fields}) of
        ok ->
            #{headers := Hdr} = Fields,
            RedHdr = [{K, <<>>} || {K, _V} <- Hdr],
            RedFields = Fields#{headers => RedHdr, body => <<>>},
            {ok, {janus_job, JobRef, MasterSessionPid, RedFields}};
        {error, Reason} ->
            {error, {bad_job, Reason}}
    end.

-spec validate(term()) -> ok | {error, term()}.
validate({janus_worker_hello, From, Node, Meta}) ->
    with_ok([
        valid_pid(From),
        valid_node(Node),
        validate_hello_meta(Meta)
    ]);
validate({janus_worker_hello_ack, Node, #{vsn := ?VSN} = Meta}) ->
    with_ok([
        valid_node(Node),
        %% Wire compression (ocr review): the capability key, IF
        %% present, must be a proper list of atoms (tolerant of
        %% future multi-codec lists) — the planned worker-dispatch
        %% consumer reads it; a malformed value is a boundary
        %% rejection, never a consumer crash. Absent = old master.
        valid_ack_wire_enc(maps:find(wire_enc, Meta))
    ]);
validate({janus_worker_hello_nack, Node, #{reason := Reason}}) ->
    with_ok([valid_node(Node), valid_nack_reason(Reason)]);
validate({janus_worker_drain, Node}) ->
    with_ok([valid_node(Node)]);
validate({janus_job, JobRef, MasterSessionPid, Fields}) ->
    with_ok([
        valid_job_ref(JobRef),
        valid_pid(MasterSessionPid),
        validate_job_fields(Fields)
    ]);
validate({janus_job_ack, JobRef, WorkerSessionPid}) ->
    with_ok([valid_job_ref(JobRef), valid_pid(WorkerSessionPid)]);
validate({janus_chunk, JobRef, Seq, Bin}) ->
    with_ok([
        valid_job_ref(JobRef),
        validate_chunk_seq(Seq),
        valid_binary(Bin)
    ]);
%% 5-tuple (spec 2026-10-12 D2): BOTH arities validate — decode is
%% tag-driven (F1), the master normalizes 4 => 5 before handling.
validate({janus_chunk, JobRef, Seq, Bin, Meta}) ->
    with_ok([
        valid_job_ref(JobRef),
        validate_chunk_seq(Seq),
        valid_binary(Bin),
        valid_chunk_meta(Meta)
    ]);
validate({janus_done, JobRef, Fields}) ->
    with_ok([valid_job_ref(JobRef), validate_done_fields(Fields)]);
validate({janus_error, JobRef, #{code := Code, message := Message} = Fields}) ->
    with_ok([
        valid_job_ref(JobRef),
        valid_error_code(Code),
        valid_binary(Message),
        %% Error payloads are NEVER compressed (spec 2026-10-12 D2):
        %% an `enc` key on janus_error is a contract violation AT THE
        %% BOUNDARY (ocr review — defense-in-depth with the error/4
        %% constructor strip); other additive keys stay tolerated.
        valid_error_no_enc(Fields)
    ]);
validate({janus_cancel, JobRef}) ->
    with_ok([valid_job_ref(JobRef)]);
validate({janus_credit, JobRef, N}) ->
    with_ok([valid_job_ref(JobRef), valid_pos_integer(N)]);
validate(_) ->
    {error, bad_shape}.

with_ok([]) ->
    ok;
with_ok([ok | Rest]) ->
    with_ok(Rest);
with_ok([{error, _} = Err | _]) ->
    Err.

%%--------------------------------------------------------------------
%% Internal validation
%%--------------------------------------------------------------------

validate_hello_meta(#{role := Role, vsn := Vsn} = Meta) ->
    with_ok([
        case Role of
            worker -> ok;
            _ -> {error, {bad_role, Role}}
        end,
        case Vsn of
            ?VSN -> ok;
            _ -> {error, {bad_vsn, Vsn}}
        end,
        case maps:get(region, Meta, undefined) of
            undefined -> ok;
            R when is_binary(R) -> ok;
            _ -> {error, bad_region}
        end
    ]);
validate_hello_meta(_) ->
    {error, bad_hello_meta}.

-define(JOB_REQUIRED, [url, method, headers, body, stream, timeout_ms, protocol_meta]).

validate_job_fields(Fields) when is_map(Fields) ->
    case lists:all(fun(K) -> maps:is_key(K, Fields) end, ?JOB_REQUIRED) of
        false ->
            {error, bad_job_fields};
        true ->
            with_ok([
                maps_find(url, Fields, fun valid_binary/1),
                maps_find(method, Fields, fun valid_method/1),
                maps_find(headers, Fields, fun valid_headers/1),
                maps_find(body, Fields, fun valid_body/1),
                maps_find(stream, Fields, fun valid_boolean/1),
                maps_find(timeout_ms, Fields, fun valid_timeout_ms/1),
                maps_find(protocol_meta, Fields, fun valid_protocol_meta/1)
            ])
    end;
validate_job_fields(_) ->
    {error, bad_job_fields}.

maps_find(Key, Map, Fun) ->
    case maps:find(Key, Map) of
        {ok, Val} -> Fun(Val);
        error -> {error, bad_job_fields}
    end.

%% Done fields with the OPTIONAL top-level `enc => zlib` key
%% (spec 2026-10-12 D2 — body-only compression; extra additive keys
%% like rtt_ms keep passing, the partial-map match tolerates them).
validate_done_fields(#{usage := Usage, status := Status, trailers := Trailers, body := Body} = Fields) ->
    with_ok([
        valid_usage(Usage),
        valid_status(Status),
        valid_map(Trailers),
        valid_done_body(Body),
        %% enc => zlib compresses ONLY the body value (D2): the tag
        %% implies a BINARY body — `enc => zlib` + undefined/non-binary
        %% body is an inconsistent message rejected here (ocr review),
        %% so the decode side can never funnel a non-binary into
        %% janus_wire_enc:inflate/2. maps:find (not maps:get) so an
        %% EXPLICIT `enc => undefined` is a violation, not absence.
        valid_done_enc(maps:find(enc, Fields), Body)
    ]);
validate_done_fields(_) ->
    {error, bad_done_fields}.

%% Chunk meta (spec 2026-10-12 D2/F1): any map; an `enc` key, IF
%% present, must be exactly the atom `zlib` — anything else (future
%% or corrupt tag, a binary "zlib", an explicit `enc => undefined`)
%% is a contract violation => {error, bad_enc}, never passed to
%% parsers. Presence is detected with maps:find (ocr review):
%% maps:get/3 would conflate an explicit undefined with absence.
valid_chunk_meta(Meta) when is_map(Meta) ->
    case maps:find(enc, Meta) of
        error -> ok;
        {ok, Tag} -> valid_enc_tag(Tag)
    end;
valid_chunk_meta(_) ->
    {error, bad_chunk_meta}.

%% Shared enc-tag rule for chunk meta (F1): called ONLY for a PRESENT
%% enc key (the find/get callers own absence) — the value must be
%% exactly the atom zlib.
valid_enc_tag(zlib) ->
    ok;
valid_enc_tag(_Other) ->
    {error, bad_enc}.

%% Done-specific enc rule: NOT a delegation to valid_enc_tag/1 (ocr
%% review suggestion declined): valid_done_body/1 tolerates
%% `undefined`, so the binary-body requirement for a zlib tag is LIVE
%% here exactly for the `enc => zlib` + `body => undefined` case; a
%% defined non-binary body already fails valid_done_body first.
valid_done_enc(error, _Body) ->
    ok;
valid_done_enc({ok, zlib}, Body) when is_binary(Body) ->
    ok;
valid_done_enc(_Other, _Body) ->
    {error, bad_enc}.

validate_chunk_seq(Seq) when is_integer(Seq), Seq >= 0 ->
    ok;
validate_chunk_seq(_) ->
    {error, bad_seq}.

valid_job_ref(Ref) when is_binary(Ref), byte_size(Ref) > 0 ->
    ok;
valid_job_ref(_) ->
    {error, bad_job_ref}.

valid_pid(P) when is_pid(P) ->
    ok;
valid_pid(_) ->
    {error, bad_pid}.

valid_node(N) when is_atom(N) ->
    ok;
valid_node(_) ->
    {error, bad_node}.

valid_binary(B) when is_binary(B) ->
    ok;
valid_binary(_) ->
    {error, bad_binary}.

valid_map(M) when is_map(M) ->
    ok;
valid_map(_) ->
    {error, bad_map}.

valid_boolean(B) when is_boolean(B) ->
    ok;
valid_boolean(_) ->
    {error, bad_stream}.

valid_method(M) ->
    case lists:member(M, ?METHODS) of
        true -> ok;
        false -> {error, bad_method}
    end.

valid_headers(Hdr) when is_list(Hdr) ->
    case lists:all(
        fun
            ({K, V}) when is_binary(K), is_binary(V) -> true;
            (_) -> false
        end,
        Hdr
    ) of
        true -> ok;
        false -> {error, bad_headers}
    end;
valid_headers(_) ->
    {error, bad_headers}.

valid_body(B) when is_binary(B) ->
    ok;
valid_body(B) when is_list(B) ->
    ok;
valid_body(_) ->
    {error, bad_body}.

valid_timeout_ms(T) when is_integer(T), T > 0 ->
    ok;
valid_timeout_ms(_) ->
    {error, bad_timeout_ms}.

valid_protocol_meta(M) when is_map(M) ->
    ok;
valid_protocol_meta(_) ->
    {error, bad_protocol_meta}.

valid_pos_integer(N) when is_integer(N), N > 0 ->
    ok;
valid_pos_integer(_) ->
    {error, bad_credit_n}.

valid_nack_reason(R) ->
    case lists:member(R, ?NACK_REASONS) of
        true -> ok;
        false -> {error, bad_nack_reason}
    end.

valid_error_code(C) ->
    case lists:member(C, ?ERROR_CODES) of
        true -> ok;
        false -> {error, bad_error_code}
    end.

%% janus_error carries no enc tag ever (D2 — never compressed).
valid_error_no_enc(Fields) when is_map(Fields) ->
    case maps:is_key(enc, Fields) of
        true -> {error, bad_enc};
        false -> ok
    end.

%% Ack capability key (spec 2026-10-12 D2): absent = old master (ok);
%% present = proper list of atoms (ocr review — the worker-dispatch
%% consumer must never see a value that crashes list handling).
valid_ack_wire_enc(error) ->
    ok;
valid_ack_wire_enc({ok, Codecs}) when is_list(Codecs) ->
    try
        case lists:all(fun is_atom/1, Codecs) of
            true -> ok;
            false -> {error, bad_ack_wire_enc}
        end
    catch
        %% Improper list: lists:all would raise — boundary rejects.
        _:_ -> {error, bad_ack_wire_enc}
    end;
valid_ack_wire_enc({ok, _NotAList}) ->
    {error, bad_ack_wire_enc}.

valid_usage(undefined) ->
    ok;
valid_usage(U) when is_map(U) ->
    ok;
valid_usage(_) ->
    {error, bad_usage}.

valid_status(S) when is_integer(S), S >= 100, S =< 599 ->
    ok;
valid_status(_) ->
    {error, bad_status}.

valid_done_body(undefined) ->
    ok;
valid_done_body(B) when is_binary(B) ->
    ok;
valid_done_body(_) ->
    {error, bad_done_body}.
