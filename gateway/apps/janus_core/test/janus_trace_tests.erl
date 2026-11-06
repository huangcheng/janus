%%%-------------------------------------------------------------------
%%% @doc Characterization tests for `janus_trace' — the W3C Trace
%%% Context contract (extraction, injection, sampling, tracestate).
%%%
%%% These pin the behaviours the telemetry design depends on. Each test
%%% name states an invariant; a failure means a real contract broke, not
%%% that a shape changed cosmetically.
%%%
%%% The sampling tests are the load-bearing ones: the previous
%%% implementation wrote flag `01' unconditionally, so "flags reflect
%%% the decision" is the regression this suite exists for.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_trace_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TID, <<"4bf92f3577b34da6a3ce929d0e0e4736">>).
-define(PID, <<"00f067aa0ba902b7">>).

%%--------------------------------------------------------------------
%% Extraction: valid headers
%%--------------------------------------------------------------------

ensure_honours_valid_traceparent_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    ?assertEqual(?TID, janus_trace:trace_id(T)).

ensure_continues_parent_sampled_decision_test() ->
    %% A parent that decided NOT to sample must stay unsampled. The old
    %% code dropped this and emitted `01' regardless.
    T = janus_trace:ensure(tp(?TID, ?PID, <<"00">>)),
    ?assertEqual(?TID, janus_trace:trace_id(T)),
    ?assertEqual(false, janus_trace:sampled(T)).

ensure_continues_parent_sampled_decision_true_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    ?assertEqual(true, janus_trace:sampled(T)).

%%--------------------------------------------------------------------
%% Extraction: forward-compatible versions (W3C §3.2.2)
%%--------------------------------------------------------------------

higher_version_continues_trace_test() ->
    %% A conformant peer that bumped its version must not have its trace
    %% silently restarted. Read the `00' layout, ignore the unknown tail.
    In = <<"01-", ?TID/binary, "-", ?PID/binary, "-01-extra-fields-here">>,
    T = janus_trace:ensure(In),
    ?assertEqual(?TID, janus_trace:trace_id(T)).

reserved_version_ff_restarts_trace_test() ->
    %% `ff' is explicitly reserved and invalid.
    In = <<"ff-", ?TID/binary, "-", ?PID/binary, "-01">>,
    T = janus_trace:ensure(In),
    ?assertNotEqual(?TID, janus_trace:trace_id(T)).

%%--------------------------------------------------------------------
%% Extraction: malformed headers restart the trace, never crash
%%--------------------------------------------------------------------

malformed_traceparent_test_() ->
    Bad = [
        undefined,
        <<>>,
        <<"garbage">>,
        <<"00-", ?TID/binary, "-", ?PID/binary>>,
        <<"00-", ?TID/binary, "-", ?PID/binary, "-01-too-long">>,
        tp(binary:copy(<<"0">>, 32), ?PID, <<"01">>),
        tp(?TID, binary:copy(<<"0">>, 16), <<"01">>),
        tp(string:uppercase(?TID), ?PID, <<"01">>),
        tp(binary:copy(<<"z">>, 32), ?PID, <<"01">>)
    ],
    [
        ?_assertNotEqual(?TID, janus_trace:trace_id(janus_trace:ensure(B)))
     || B <- Bad
    ].

fresh_trace_shape_test() ->
    T = janus_trace:ensure(undefined),
    Tid = janus_trace:trace_id(T),
    ?assertEqual(32, byte_size(Tid)),
    ?assertEqual(true, is_lc_hex(Tid)).

%%--------------------------------------------------------------------
%% Injection: flags reflect the real decision
%%--------------------------------------------------------------------

upstream_header_flag_follows_decision_test() ->
    Sampled = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    Unsampled = janus_trace:ensure(tp(?TID, ?PID, <<"00">>)),
    {_, H1} = janus_trace:upstream_header(Sampled),
    {_, H2} = janus_trace:upstream_header(Unsampled),
    ?assertEqual(<<"-01">>, trailing_flag(H1)),
    ?assertEqual(<<"-00">>, trailing_flag(H2)).

upstream_header_mints_distinct_span_per_attempt_test() ->
    %% Retry/failover legs are distinct spans and must not share an id.
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    {_, H1} = janus_trace:upstream_header(T),
    {_, H2} = janus_trace:upstream_header(T),
    ?assertNotEqual(H1, H2),
    ?assertEqual(?TID, span_trace_id(H1)),
    ?assertEqual(?TID, span_trace_id(H2)).

upstream_header_keeps_trace_id_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    {<<"traceparent">>, H} = janus_trace:upstream_header(T),
    ?assertEqual(?TID, span_trace_id(H)).

%%--------------------------------------------------------------------
%% tracestate (W3C §3.3)
%%--------------------------------------------------------------------

tracestate_retained_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), <<"foo=bar,baz=qux">>),
    ?assertEqual([{<<"foo">>, <<"bar">>}, {<<"baz">>, <<"qux">>}], janus_trace:tracestate(T)).

tracestate_propagated_on_injection_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), <<"foo=bar">>),
    Hs = janus_trace:upstream_headers(T),
    ?assertEqual(<<"foo=bar">>, proplists:get_value(<<"tracestate">>, Hs)).

tracestate_absent_when_empty_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    ?assertEqual(undefined, proplists:get_value(<<"tracestate">>, janus_trace:upstream_headers(T))).

tracestate_discarded_without_valid_traceparent_test() ->
    %% W3C §4.2: tracestate without a valid traceparent is invalid.
    T = janus_trace:ensure(<<"garbage">>, <<"foo=bar">>),
    ?assertEqual([], janus_trace:tracestate(T)).

tracestate_entry_order_preserved_test() ->
    %% W3C mutation rule: unmodified entries keep their order.
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), <<"a=1,b=2,c=3">>),
    Hs = janus_trace:upstream_headers(T),
    ?assertEqual(<<"a=1,b=2,c=3">>, proplists:get_value(<<"tracestate">>, Hs)).

tracestate_caps_entries_test() ->
    %% 40 members in, at most 32 carried out — capped, never rejected.
    Members = [<<"k", (integer_to_binary(I))/binary, "=v">> || I <- lists:seq(1, 40)],
    In = iolist_to_binary(lists:join(<<",">>, Members)),
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), In),
    ?assertEqual(32, length(janus_trace:tracestate(T))).

tracestate_drops_malformed_members_test() ->
    %% No `=', control bytes, and empty values are dropped; good ones stay.
    In = <<"good=1,noequals,nul=\x01,empty=,alsogood=2,UP=3">>,
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), In),
    ?assertEqual([{<<"good">>, <<"1">>}, {<<"alsogood">>, <<"2">>}], janus_trace:tracestate(T)).

%%--------------------------------------------------------------------
%% Response headers
%%--------------------------------------------------------------------

response_headers_carry_traceparent_and_legacy_id_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>)),
    Hs = janus_trace:response_headers(T),
    ?assertEqual(?TID, proplists:get_value(<<"x-trace-id">>, Hs)),
    {<<"traceparent">>, TP} = lists:keyfind(<<"traceparent">>, 1, Hs),
    ?assertEqual(?TID, span_trace_id(TP)).

response_headers_respect_unsampled_test() ->
    T = janus_trace:ensure(tp(?TID, ?PID, <<"00">>)),
    {<<"traceparent">>, TP} = lists:keyfind(<<"traceparent">>, 1, janus_trace:response_headers(T)),
    ?assertEqual(<<"-00">>, trailing_flag(TP)).

%%--------------------------------------------------------------------
%% Wire constructors (rolling-deploy shapes)
%%--------------------------------------------------------------------

from_trace_id_valid_test() ->
    T = janus_trace:from_trace_id(?TID),
    ?assertEqual(?TID, janus_trace:trace_id(T)).

from_trace_id_absent_mints_test() ->
    T = janus_trace:from_trace_id(undefined),
    ?assertEqual(32, byte_size(janus_trace:trace_id(T))).

from_wire_reads_additive_keys_test() ->
    T = janus_trace:from_wire(#{
        trace_id => ?TID, sampled => false, tracestate => <<"v=1">>
    }),
    ?assertEqual(?TID, janus_trace:trace_id(T)),
    ?assertEqual(false, janus_trace:sampled(T)),
    ?assertEqual([{<<"v">>, <<"1">>}], janus_trace:tracestate(T)).

from_wire_old_master_shape_test() ->
    %% An old master sends only `trace_id'; that must not break.
    T = janus_trace:from_wire(#{trace_id => ?TID}),
    ?assertEqual(?TID, janus_trace:trace_id(T)),
    ?assertEqual(true, janus_trace:sampled(T)).

from_wire_no_trace_id_mints_test() ->
    T = janus_trace:from_wire(#{url => <<"http://x">>}),
    ?assertEqual(32, byte_size(janus_trace:trace_id(T))).

%%--------------------------------------------------------------------
%% Sampling: determinism and monotonicity
%%--------------------------------------------------------------------

ratio_zero_never_samples_test() ->
    with_ratio(0.0, fun() ->
        ?assertEqual(false, janus_trace:sampled(janus_trace:ensure(undefined)))
    end).

ratio_one_always_samples_test() ->
    with_ratio(1.0, fun() ->
        ?assertEqual(true, janus_trace:sampled(janus_trace:ensure(undefined)))
    end).

sampling_is_deterministic_test() ->
    %% Same trace id, same decision — across calls and nodes. A PRNG
    %% comparison would fail this.
    with_ratio(0.5, fun() ->
        D1 = janus_trace:sampled(janus_trace:ensure(tp(?TID, ?PID, <<"01">>))),
        D2 = janus_trace:sampled(janus_trace:ensure(tp(?TID, ?PID, <<"01">>))),
        ?assertEqual(D1, D2)
    end).

sampling_is_monotone_test() ->
    %% Raising the ratio must not un-sample a trace that was sampled at a
    %% lower ratio: the sampled set at 0.1 is a subset of the set at 0.5.
    Tids = [tid(N) || N <- lists:seq(1, 200)],
    Lo = sampled_set(0.1, Tids),
    Hi = sampled_set(0.5, Tids),
    ?assertEqual([], Lo -- Hi).

sampling_ratio_is_approximate_test() ->
    %% Drive the pure sampler directly: `ensure/1' on a valid parent
    %% inherits the parent's decision by design (ParentBased), so it
    %% cannot exercise the ratio. 2000 uniform ids at 25% should land
    %% near 25%; generous bounds assert the threshold direction, not
    %% statistical purity.
    with_ratio(0.25, fun() ->
        Tids = [random_tid() || _ <- lists:seq(1, 2000)],
        N = length([T || T <- Tids, janus_trace:should_sample(T)]),
        ?assert(N > 350),
        ?assert(N < 650)
    end).

sampling_ratio_monotone_on_random_ids_test() ->
    %% Strict growth: raising the ratio must sample MORE, and the lower
    %% ratio's set must be a subset. Asserting only the subset would pass
    %% on two equal sets (or two empty ones), which is how this test was
    %% vacuous before.
    Tids = [random_tid() || _ <- lists:seq(1, 500)],
    Lo = with_ratio(0.10, fun() -> [T || T <- Tids, janus_trace:should_sample(T)] end),
    Hi = with_ratio(0.60, fun() -> [T || T <- Tids, janus_trace:should_sample(T)] end),
    ?assert(length(Lo) > 0),
    ?assert(length(Hi) > length(Lo)),
    ?assertEqual([], Lo -- Hi).

sampling_reads_low_56_bits_only_test() ->
    %% Pin WHICH bits decide. The high 72 bits must not affect the
    %% decision, and the threshold must be strict (`R < T', not `=<').
    with_ratio(0.5, fun() ->
        %% Low 56 bits all ones -> R = 2^56-1, far above the 2^55
        %% threshold -> NOT sampled. High bits are zero, which proves
        %% the decision ignores them.
        ?assertNot(janus_trace:should_sample(<<"000000000000000000ffffffffffffff">>)),
        %% Same low bits, high bits all ones -> identical decision.
        ?assertNot(janus_trace:should_sample(<<"ffffffffffffffffff" "ffffffffffffff">>)),
        %% Low 56 bits all zero -> R = 0 < 2^55 -> sampled.
        ?assert(janus_trace:should_sample(<<"ffffffffffffffffff00000000000000">>)),
        %% R == 2^55 exactly is NOT sampled under a strict threshold.
        ?assertNot(janus_trace:should_sample(<<"ffffffffffffffffff80000000000000">>)),
        %% R == 2^55 - 1 is sampled.
        ?assert(janus_trace:should_sample(<<"ffffffffffffffffff7fffffffffffff">>))
    end).

sampled_set(Ratio, Tids) ->
    with_ratio(Ratio, fun() ->
        [T || T <- Tids, janus_trace:should_sample(T)]
    end).


%%--------------------------------------------------------------------
%% strip_trace_headers/1 — the stale-header guard for downstream hops
%%--------------------------------------------------------------------

strip_trace_headers_removes_both_test() ->
    %% A downstream attempt must never inherit an earlier attempt's trace
    %% headers. Both names go, every other header survives in order.
    In = [
        {<<"authorization">>, <<"Bearer x">>},
        {<<"traceparent">>, <<"00-", ?TID/binary, "-", ?PID/binary, "-01">>},
        {<<"tracestate">>, <<"a=1">>},
        {<<"accept">>, <<"application/json">>}
    ],
    ?assertEqual(
        [{<<"authorization">>, <<"Bearer x">>}, {<<"accept">>, <<"application/json">>}],
        janus_trace:strip_trace_headers(In)
    ).

strip_trace_headers_idempotent_test() ->
    In = [{<<"x">>, <<"1">>}],
    ?assertEqual(In, janus_trace:strip_trace_headers(janus_trace:strip_trace_headers(In))).

encode_tracestate_roundtrip_test() ->
    Ts = [{<<"a">>, <<"1">>}, {<<"b">>, <<"2">>}],
    Enc = janus_trace:encode_tracestate(Ts),
    ?assertEqual(<<"a=1,b=2">>, Enc),
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), Enc),
    ?assertEqual(Ts, janus_trace:tracestate(T)).

encode_tracestate_empty_test() ->
    ?assertEqual(<<>>, janus_trace:encode_tracestate([])).

%%--------------------------------------------------------------------
%% tracestate grammar details
%%--------------------------------------------------------------------

tracestate_multi_tenant_keys_test() ->
    %% `tenant@system' is legal W3C and must be preserved: it is how a
    %% vendor isolates per-customer state.
    In = <<"tenant1@vendor=abc,tenant2@vendor=def">>,
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), In),
    ?assertEqual(
        [{<<"tenant1@vendor">>, <<"abc">>}, {<<"tenant2@vendor">>, <<"def">>}],
        janus_trace:tracestate(T)
    ).

tracestate_rejects_bad_segments_test() ->
    %% Uppercase first char, empty segment, and a double `@' are invalid.
    In = <<"Up=1,@vendor=x,tenant@=y,a@b@c=z,good=ok">>,
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), In),
    ?assertEqual([{<<"good">>, <<"ok">>}], janus_trace:tracestate(T)).

tracestate_duplicate_keys_keep_first_test() ->
    %% W3C requires unique keys; leftmost wins (closest to the caller).
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), <<"k=first,k=second">>),
    ?assertEqual([{<<"k">>, <<"first">>}], janus_trace:tracestate(T)).

parse_ts_non_utf8_does_not_crash_test() ->
    %% Client bytes are not guaranteed UTF-8. Byte-level trimming means a
    %% malformed sequence is just a bad entry, never a 500.
    T = janus_trace:ensure(tp(?TID, ?PID, <<"01">>), <<"a=1,", 16#FF, 16#FE, "=2,b=3">>),
    ?assertEqual([{<<"a">>, <<"1">>}, {<<"b">>, <<"3">>}], janus_trace:tracestate(T)).

response_headers_undefined_context_test() ->
    %% No context must yield no headers, not a fabricated trace.
    ?assertEqual([], janus_trace:response_headers(undefined)).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

tp(Tid, Pid, F) ->
    <<"00-", Tid/binary, "-", Pid/binary, "-", F/binary>>.

%% Pull the trace-id out of a traceparent binary.
span_trace_id(<<"00-", Tid:32/binary, "-", _/binary>>) -> Tid.

%% The "-FF" flag suffix of a traceparent.
trailing_flag(TP) ->
    Sz = byte_size(TP),
    binary:part(TP, Sz - 3, 3).

with_ratio(R, Fun) ->
    Old = persistent_term:get({janus_trace, sampler_ratio}, undefined),
    persistent_term:put({janus_trace, sampler_ratio}, R),
    try
        Fun()
    after
        case Old of
            undefined -> persistent_term:erase({janus_trace, sampler_ratio});
            _ -> persistent_term:put({janus_trace, sampler_ratio}, Old)
        end
    end.

%% Uniformly random 32-hex id (distribution tests only — hashed
%% integers are not uniform enough in the low 56 bits).
random_tid() ->
    string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(16))).

%% Deterministic 32-hex ids for monotonicity tests. The low 56 bits must be
%% well spread — encoding N directly leaves them tiny, so every id would
%% fall under any threshold and the distribution test would prove nothing.
tid(N) ->
    A = erlang:phash2({N, 1}, 4294967296),
    B = erlang:phash2({N, 2}, 4294967296),
    C = erlang:phash2({N, 3}, 4294967296),
    D = erlang:phash2({N, 4}, 4294967296),
    string:lowercase(binary:encode_hex(<<A:32, B:32, C:32, D:32>>)).

is_lc_hex(Bin) ->
    lists:all(
        fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
        binary_to_list(Bin)
    ).

