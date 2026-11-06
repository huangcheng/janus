%%%-------------------------------------------------------------------
%%% @doc W3C Trace Context (`traceparent` + `tracestate`) for the
%%% gateway, with a parent-based head sampler.
%%%
%%% Behaviour, in one place so call sites stay honest:
%%%
%%%   * Extraction honours an inbound `traceparent` (version `00`, and
%%%     any future version >= 55 bytes whose prefix parses — W3C §3.2.2
%%%     requires reading those with the `00` layout, not restarting the
%%%     trace) and an inbound `tracestate` (carried opaquely, bounded).
%%%   * The sampled bit is a real decision, not a constant. A root trace
%%%     uses a monotone `TraceIdRatioBased` sampler (default 5%); a
%%%     trace with a valid inbound parent inherits the parent's decision
%%%     (ParentBased). The old hardcoded `01` asserted "recorded" on
%%%     every call while nothing was recorded.
%%%   * Injection emits a fresh parent-id per attempt (a new span) and
%%%     propagates the retained `tracestate`, per the W3C mutation
%%%     rules: the order of unmodified entries is preserved.
%%%
%%% ## Failure-mode posture
%%%
%%% Telemetry must never fail or slow a request. Every parse is
%%% fixed-shape binary matching (no regexes, no exceptions); a malformed
%%% header mints a fresh trace instead of rejecting. `trace_id(undefined)
%%% -> undefined` so pdict readers need no guard.
%%%
%%% ## Tracestate failure modes guarded
%%%
%%%   * Oversized/oversubscribed lists are CAPPED, not rejected: W3C
%%%     allows dropping whole trailing entries, and dropping the whole
%%%     header would lose vendor state for a cosmetic reason.
%%%   * A `tracestate` without a valid `traceparent` is DISCARDED (W3C
%%%     §4.2), and on a malformed `traceparent` the `tracestate` is
%%%     never parsed at all (W3C §3.3).
%%%   * Entry keys/values are validated to printable ASCII; a bad entry
%%%     is dropped rather than forwarded, so we never emit a header an
%%%     upstream would reject.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_trace).

-export([
    ensure/1,
    ensure/2,
    from_trace_id/1,
    from_wire/1,
    header/0,
    headers/0,
    trace_id/1,
    sampled/1,
    tracestate/1,
    upstream_header/1,
    upstream_headers/1,
    response_headers/1,
    encode_tracestate/1,
    strip_trace_headers/1,
    ratio/0,
    %% Exported for eunit: the ratio sampler is pure over
    %% (trace-id, ratio), so its determinism and monotonicity can be
    %% pinned without minting traces.
    should_sample/1
]).

-export_type([t/0]).

-record(trace, {
    tid :: binary(),
    sampled = true :: boolean(),
    ts = [] :: [{binary(), binary()}]
}).

-opaque t() :: #trace{}.

%% Once-per-boot flag for the malformed wire-map trace-id warning.
-define(PT_WARNED, {?MODULE, malformed_wire_trace_id_warned}).
%% Cached sampler ratio (persistent_term: read-mostly, set at most once).
-define(PT_RATIO, {?MODULE, sampler_ratio}).

%% W3C Trace Context §3.3.1.5 limits. 32 list members; Janus keeps a
%% little headroom under the "at least 512 characters" guidance by
%% bounding entries rather than total bytes (a 256-char key plus a
%% 256-char value per entry would blow any byte budget immediately).
-define(TS_MAX_ENTRIES, 32).
%% Hard cap on the bytes we will even look at: a caller cannot make us
%% split an arbitrarily large header on the request path.
-define(TS_MAX_BYTES, 8192).
-define(TS_MAX_KEY, 256).
-define(TS_MAX_VALUE, 256).

%% 2^56 — the randomness space of a TraceIdRatioBased threshold.
-define(TWO_POW_56, 72057594037927936).

-spec ensure(binary() | undefined) -> t().
ensure(In) ->
    ensure(In, undefined).

%% @doc Resolve the trace context for one request from both headers.
%% `Traceparent' is the inbound `traceparent' binary (or `undefined');
%% `Tracestate' is the inbound `tracestate' (or `undefined'). Never
%% raises: anything unparseable yields a fresh, sampled-or-not root
%% trace.
-spec ensure(binary() | undefined, binary() | undefined) -> t().
ensure(Traceparent, Tracestate) when is_binary(Traceparent) ->
    case parse(Traceparent) of
        {ok, Tid, Sampled} ->
            %% W3C §3.3: only consult tracestate when traceparent
            %% parsed. A forwarded higher-version header is rewritten
            %% as `00' on injection, which is a legal downgrade.
            #trace{tid = Tid, sampled = Sampled, ts = parse_ts(Tracestate)};
        error ->
            %% Malformed traceparent: restart the trace AND discard
            %% tracestate (it belongs to a trace we are not continuing).
            new_root()
    end;
ensure(_Bad, _Tracestate) ->
    new_root().

%% @doc Worker-side constructor from the bare 32-hex trace-id carried
%% by the dispatch wire map (rolling-deploy compatible: an old master
%% sends no sampled/tracestate keys). `undefined' generates silently; a
%% malformed value generates + one warning per boot — a divergent
%% trace-id is preferable to a killed request.
-spec from_trace_id(binary() | undefined) -> t().
from_trace_id(undefined) ->
    new_root();
from_trace_id(Tid) when is_binary(Tid) ->
    case is_lc_hex(Tid, 32) andalso Tid =/= zero(32) of
        true -> #trace{tid = Tid, sampled = true};
        false ->
            warn_once(Tid),
            new_root()
    end;
from_trace_id(Other) ->
    warn_once(Other),
    new_root().

%% @doc Worker-side constructor from the whole dispatch wire map. Reads
%% the additive `trace_id' / `sampled' / `tracestate' keys; any absent
%% key degrades to the old behaviour (fresh sampled trace / inherit
%% true) so a mixed-version fleet never loses a request.
-spec from_wire(map()) -> t().
from_wire(Fields) when is_map(Fields) ->
    case maps:get(trace_id, Fields, undefined) of
        Tid when is_binary(Tid) ->
            case is_lc_hex(Tid, 32) andalso Tid =/= zero(32) of
                true ->
                    #trace{
                        tid = Tid,
                        sampled = maps:get(sampled, Fields, true) =:= true,
                        ts = parse_ts(maps:get(tracestate, Fields, undefined))
                    };
                false ->
                    warn_once(Tid),
                    new_root()
            end;
        _ ->
            new_root()
    end;
from_wire(_) ->
    new_root().

%% @doc The outbound `traceparent' header for ONE upstream attempt,
%% reading the pdict trace context (`get(janus_trace)' — module-named
%% key, house convention) stashed by the handler entry / worker
%% session. A missing context (non-request callers: eunit, the spawned
%% janus-auto judge worker) mints a fresh trace on the spot — never
%% crashes. Invoke once per attempt: retry/failover legs get distinct
%% parent-ids (distinct spans).
-spec header() -> {binary(), binary()}.
header() ->
    upstream_header(current()).

%% @doc Both outbound trace headers (traceparent plus tracestate when
%% the caller supplied any). Call sites splice this into their header
%% list; `tracestate' is omitted entirely when empty, per W3C.
-spec headers() -> [{binary(), binary()}].
headers() ->
    upstream_headers(current()).

%% @doc The 32-hex trace-id, or `undefined' when no context is stashed
%% (pdict readers need no guard; the usage writer's bin_or_null maps
%% it to null).
-spec trace_id(t() | undefined) -> binary() | undefined.
trace_id(undefined) ->
    undefined;
trace_id(#trace{tid = Tid}) ->
    Tid.

%% @doc The sampling decision for this trace. Used by the span layer to
%% decide whether to build a span at all, and by `headers/0' to write
%% the flag byte.
-spec sampled(t() | undefined) -> boolean().
sampled(undefined) ->
    true;
sampled(#trace{sampled = S}) ->
    S.

%% @doc Retained tracestate entries as `[{Key, Value}]' (may be empty).
-spec tracestate(t() | undefined) -> [{binary(), binary()}].
tracestate(undefined) ->
    [];
tracestate(#trace{ts = Ts}) ->
    Ts.

%% @doc The outbound `traceparent' header for ONE upstream attempt:
%% stable trace-id, freshly minted parent-id, flag byte reflecting the
%% REAL sampling decision. Invoke once per attempt — retry/failover
%% legs get distinct spans.
-spec upstream_header(t()) -> {binary(), binary()}.
upstream_header(#trace{tid = Tid, sampled = Sampled}) ->
    Pid = new_parent_id(),
    {<<"traceparent">>, <<"00-", Tid/binary, "-", Pid/binary, "-", (flags(Sampled))/binary>>}.

%% @doc Both outbound trace headers for one attempt.
-spec upstream_headers(t()) -> [{binary(), binary()}].
upstream_headers(#trace{ts = Ts} = Trace) ->
    case Ts of
        [] -> [upstream_header(Trace)];
        _ -> [upstream_header(Trace), {<<"tracestate">>, encode_ts(Ts)}]
    end.

%% @doc Downstream response headers: a W3C `traceparent' so a
%% conformant client can continue the trace, ADDED alongside the
%% existing non-standard `x-trace-id' (which is preserved so current
%% clients keep working). The span-id here is a fresh one: the gateway
%% is answering the request, so this is its own span.
-spec response_headers(t() | undefined) -> [{binary(), binary()}].
response_headers(undefined) ->
    %% No context (non-handler caller): answer with nothing rather than
    %% minting a trace the caller never used.
    [];
response_headers(#trace{tid = Tid, sampled = Sampled, ts = Ts}) ->
    Base = [
        {<<"traceparent">>,
            <<"00-", Tid/binary, "-", (new_parent_id())/binary, "-", (flags(Sampled))/binary>>},
        {<<"x-trace-id">>, Tid}
    ],
    case Ts of
        [] -> Base;
        _ -> Base ++ [{<<"tracestate">>, encode_ts(Ts)}]
    end.

%% @doc Serialize tracestate entries back to a header value (`[]' when
%% empty). Exported so the master→worker wire codec and the injector
%% cannot drift into two encodings.
-spec encode_tracestate([{binary(), binary()}]) -> binary().
encode_tracestate([]) -> <<>>;
encode_tracestate(Ts) -> encode_ts(Ts).

%% @doc Remove BOTH trace headers from a header list, so a downstream
%% request never carries a STALE trace header from an earlier attempt
%% while the fresh ones are prepended.
-spec strip_trace_headers([{binary(), binary()}]) -> [{binary(), binary()}].
strip_trace_headers(Headers) ->
    lists:filter(
        fun({K, _}) -> K =/= <<"traceparent">> andalso K =/= <<"tracestate">> end,
        Headers
    ).

%% @doc The effective root sampling ratio (0.0–1.0). Read once from
%% `OTEL_TRACES_SAMPLER_ARG' and cached in persistent_term; an
%% unparseable value falls back to the default rather than crashing a
%% request (the OTel spec says log-and-ignore).
-spec ratio() -> float().
ratio() ->
    case persistent_term:get(?PT_RATIO, undefined) of
        undefined ->
            R = resolve_ratio(),
            persistent_term:put(?PT_RATIO, R),
            R;
        R ->
            R
    end.

%% `OTEL_TRACES_SAMPLER' wins over the arg: the two names an operator
%% actually reaches for are `always_on' and `always_off', and silently
%% ignoring them would make the documented knob a lie. Unknown values
%% fall back to the ratio (spec: log-and-ignore would be loud; we stay
%% quiet on the hot path and fall back).
resolve_ratio() ->
    case os:getenv("OTEL_TRACES_SAMPLER") of
        "always_on" -> 1.0;
        "always_off" -> 0.0;
        _ -> parse_ratio(os:getenv("OTEL_TRACES_SAMPLER_ARG"))
    end.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

current() ->
    case get(?MODULE) of
        undefined -> new_root();
        #trace{} = Trace -> Trace
    end.

%% Fresh root trace: mint the id, then let the sampler decide.
new_root() ->
    Tid = new_trace_id(),
    #trace{tid = Tid, sampled = should_sample(Tid)}.

%%--------------------------------------------------------------------
%% Sampling
%%
%% TraceIdRatioBased, implemented as the spec requires: deterministic
%% on the trace-id and MONOTONE — a lower ratio's sampled set is a
%% subset of a higher ratio's. That property is what makes raising the
%% ratio during an incident safe; a `rand:uniform()' comparison, the
%% obvious shortcut, has neither determinism nor monotonicity and would
%% resample the same trace differently on every node.
%%
%% The 56 low bits of the trace-id are the randomness; the threshold is
%% ratio * 2^56. Sampling iff R < T gives the monotone property.
%%--------------------------------------------------------------------

should_sample(Tid) when is_binary(Tid), byte_size(Tid) =:= 32 ->
    R = low56(Tid),
    T = trunc(ratio() * ?TWO_POW_56),
    R < T;
should_sample(_) ->
    false.

%% Low 56 bits of the 128-bit trace id, read as the last 14 hex chars.
%% 56 bits is the randomness width OTel uses for consistent probability
%% sampling, and reading it from the id (rather than from a PRNG) is what
%% makes the decision deterministic across nodes.
low56(Tid) ->
    <<_:18/binary, Tail:14/binary>> = Tid,
    case catch binary:decode_hex(Tail) of
        Hex when is_binary(Hex) -> binary:decode_unsigned(Hex, big);
        %% Non-hex id (only reachable from a caller that skipped the
        %% charset validation): treat as "not sampled" rather than
        %% raising inside a telemetry decision.
        _ -> ?TWO_POW_56
    end.

%% `os:getenv/1' returns `false' (not `undefined') for an unset variable —
%% missing that clause crashed every root span. Both are "unset".
parse_ratio(undefined) ->
    0.05;
parse_ratio(false) ->
    0.05;
parse_ratio("") ->
    0.05;
parse_ratio(Val) when is_list(Val) ->
    case string:to_float(Val) of
        {F, ""} when F >= 0.0, F =< 1.0 ->
            F;
        _ ->
            case string:to_integer(Val) of
                {I, ""} when I >= 0, I =< 1 -> float(I);
                _ -> 0.05
            end
    end.

flags(true) -> <<"01">>;
flags(false) -> <<"00">>.

%%--------------------------------------------------------------------
%% traceparent parsing
%%--------------------------------------------------------------------

%% W3C Trace Context §3.2.2. Three accepted shapes:
%%
%%   * version `00': exactly the 55-byte layout. A longer header is
%%     invalid for this version.
%%   * version `ff': reserved, always invalid.
%%   * any other version: at least 55 bytes; read the same first four
%%     fields and IGNORE the remainder (vendors MUST NOT assume
%%     anything about unknown fields). Previously Janus rejected these
%%     and restarted the trace, which silently severed a conformant
%%     peer's trace the moment it bumped its version.
parse(<<"ff", _/binary>>) ->
    error;
parse(<<"00-", Rest/binary>>) when byte_size(Rest) =:= 52 ->
    four_fields(Rest);
%% Version `00' is EXACTLY 55 bytes: a longer `00' header is invalid and
%% must restart the trace. Without this clause the generic
%% forward-compatible clause below would accept it by prefix, which is
%% the opposite of what W3C says about version 00.
parse(<<"00-", _/binary>>) ->
    error;
parse(<<V:2/binary, "-", Rest/binary>>) when byte_size(Rest) >= 52 ->
    case is_lc_hex(V, 2) of
        true -> four_fields_prefix(Rest);
        false -> error
    end;
parse(_) ->
    error.

four_fields(Rest) ->
    case Rest of
        <<Tid:32/binary, "-", Pid:16/binary, "-", F:2/binary>> -> validate(Tid, Pid, F);
        _ -> error
    end.

four_fields_prefix(Rest) ->
    case Rest of
        <<Tid:32/binary, "-", Pid:16/binary, "-", F:2/binary, _/binary>> -> validate(Tid, Pid, F);
        _ -> error
    end.

validate(Tid, Pid, F) ->
    case
        is_lc_hex(Tid, 32) andalso is_lc_hex(Pid, 16) andalso is_lc_hex(F, 2) andalso
            Tid =/= zero(32) andalso Pid =/= zero(16)
    of
        true -> {ok, Tid, sampled_flag(F)};
        false -> error
    end.

%% The sampled bit is bit 0 of the flag byte. `00' means the caller
%% decided not to record; honouring that is the whole point.
sampled_flag(F) ->
    <<N>> = binary:decode_hex(F),
    N band 1 =:= 1.

%%--------------------------------------------------------------------
%% tracestate parsing / encoding
%%
%% Carried opaquely: Janus does not interpret vendor entries, it
%% preserves them. Bounded per W3C (32 members) with per-entry key and
%% value length caps; over-long or unprintable entries are DROPPED
%% rather than forwarded, because emitting a header an upstream rejects
%% is worse than losing one vendor's hint.
%%--------------------------------------------------------------------

parse_ts(undefined) ->
    [];
parse_ts(Bin) when is_binary(Bin) ->
    %% An oversized header is CAPPED, not discarded: the parse below is
    %% bounded by ?TS_MAX_ENTRIES anyway, so a huge value costs one split
    %% of already-received bytes and never changes the outcome. The cap
    %% below bounds the split itself for pathological input.
    Head = case byte_size(Bin) > ?TS_MAX_BYTES of
        true -> binary:part(Bin, 0, ?TS_MAX_BYTES);
        false -> Bin
    end,
    Members = binary:split(Head, <<",">>, [global]),
    lists:sublist(dedupe_ts(lists:filtermap(fun parse_ts_member/1, Members)), ?TS_MAX_ENTRIES);
parse_ts(_) ->
    [].

%% W3C requires member keys to be unique. Keep the FIRST occurrence —
%% that is the one closest to the caller, matching the left-to-right
%% precedence the header uses.
dedupe_ts(Pairs) ->
    dedupe_ts(Pairs, #{}, []).

dedupe_ts([], _Seen, Acc) ->
    lists:reverse(Acc);
dedupe_ts([{K, _} = P | Rest], Seen, Acc) ->
    case maps:is_key(K, Seen) of
        true -> dedupe_ts(Rest, Seen, Acc);
        false -> dedupe_ts(Rest, Seen#{K => true}, [P | Acc])
    end.

parse_ts_member(Member0) ->
    Member = trim(Member0),
    case binary:split(Member, <<"=">>) of
        [Key, Value] ->
            case valid_ts_token(Key, ?TS_MAX_KEY) andalso valid_ts_value(Value) of
                true -> {true, {Key, Value}};
                false -> false
            end;
        _ ->
            false
    end.

%% W3C key grammar. Two shapes are legal:
%%
%%   simple-key      = lcalpha 0*255( lcalpha / DIGIT / "_" / "-"/ "*" / "/" )
%%   multi-tenant-key= tenant-id "@" system-id
%%
%% The multi-tenant form MUST be supported: it is how a vendor isolates
%% per-customer state, and silently dropping those entries would break
%% exactly the tenants the header exists to serve. Every segment is
%% validated; a malformed segment drops the whole entry (never forwarded
%% half-formed).
valid_ts_token(K, Max) ->
    byte_size(K) >= 1 andalso byte_size(K) =< Max andalso
        case binary:split(K, <<"@">>, [global]) of
            [One] -> valid_ts_segment(One);
            [Tenant, System] -> valid_ts_segment(Tenant) andalso valid_ts_segment(System);
            _ -> false
        end.

valid_ts_segment(<<>>) ->
    false;
valid_ts_segment(Seg) ->
    <<First, Rest/binary>> = Seg,
    (First >= $a andalso First =< $z) andalso
        lists:all(
            fun(C) ->
                (C >= $a andalso C =< $z) orelse
                    (C >= $0 andalso C =< $9) orelse
                    C =:= $_ orelse C =:= $- orelse C =:= $* orelse C =:= $/
            end,
            binary_to_list(Rest)
        ).

%% Value: printable ASCII excluding comma and `='.
valid_ts_value(V) ->
    byte_size(V) >= 1 andalso byte_size(V) =< ?TS_MAX_VALUE andalso
        lists:all(
            fun(C) -> C >= 16#20 andalso C =< 16#7E andalso C =/= $, andalso C =/= $= end,
            binary_to_list(V)
        ).

encode_ts(Ts) ->
    iolist_to_binary(lists:join(<<",">>, [[K, <<"=">>, V] || {K, V} <- Ts])).

%% Trim ASCII spaces/tabs only. `string:trim/3' is Unicode-aware and
%% decodes client-controlled bytes as codepoints — on a malformed
%% sequence it raises, which would turn a bad `tracestate' header into a
%% 500. Byte-level trimming cannot fail.
trim(B) ->
    trim_right(trim_left(B)).

trim_left(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> trim_left(Rest);
trim_left(B) -> B.

trim_right(B) ->
    case byte_size(B) of
        0 ->
            B;
        Sz ->
            case binary:at(B, Sz - 1) of
                C when C =:= $\s; C =:= $\t -> trim_right(binary:part(B, 0, Sz - 1));
                _ -> B
            end
    end.

%%--------------------------------------------------------------------
%% Ids
%%--------------------------------------------------------------------

%% Exact version-`00' wire shape is 55 bytes, but parse/1 above owns
%% that decision; these helpers only answer "is this field the right
%% hex and not all zero".
is_lc_hex(Bin, N) ->
    byte_size(Bin) =:= N andalso
        lists:all(
            fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
            binary_to_list(Bin)
        ).

zero(N) -> binary:copy(<<"0">>, N).

%% Fresh 32-hex trace-id; redraw on the (2^-128) all-zero draw — W3C
%% forbids all-zero ids.
new_trace_id() ->
    Tid = rand_hex(16),
    case Tid =:= zero(32) of
        true -> new_trace_id();
        false -> Tid
    end.

%% Fresh 16-hex parent-id; redraw on the (2^-64) all-zero draw.
new_parent_id() ->
    Pid = rand_hex(8),
    case Pid =:= zero(16) of
        true -> new_parent_id();
        false -> Pid
    end.

%% encode_hex is uppercase; lowercase for the W3C all-lowercase shape.
%% crypto:strong_rand_bytes is guarded (janus_request_id:generate/0
%% precedent): trace ids must never 500 a request — fall back to a
%% unique_integer draw PADDED to the full width (the N-hex shape holds
%% either way; binary:encode_unsigned/2's second arg is the
%% ENDIANNESS, not a pad size — pad via a binary pattern).
rand_hex(N) ->
    try
        string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(N)))
    catch
        _:_ ->
            I = erlang:unique_integer([positive]),
            string:lowercase(binary:encode_hex(<<I:(N * 8)/big>>))
    end.

%% One warning per boot for malformed wire-map trace-ids (a bad value
%% here means a peer bug, not a client fault — loud once, then silent
%% divergence). Concurrent first hits may log a handful of lines; the
%% flag bounds it per boot.
warn_once(Value) ->
    case persistent_term:get(?PT_WARNED, false) of
        true ->
            ok;
        false ->
            persistent_term:put(?PT_WARNED, true),
            logger:warning(#{
                what => janus_trace_malformed_wire_trace_id,
                value => Value
            })
    end.