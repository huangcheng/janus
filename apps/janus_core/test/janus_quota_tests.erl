%%%-------------------------------------------------------------------
%%% @doc eunit-first tests for janus_quota (Phase 2 Slice Q).
%%% Run inorder — shared named ETS is process-global.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_quota_tests).

-include_lib("eunit/include/eunit.hrl").

janus_quota_test_() ->
    {setup, fun() -> ok = janus_quota:ensure() end, fun(_) -> ok end,
        {inorder, [
            fun unlimited_short_circuit/0,
            fun rpm_second_admit_rejected/0,
            fun admit_once_per_request/0,
            fun charge_idempotent/0,
            fun tpm_lagging_admit/0,
            fun null_usage_charges_zero/0
        ]}}.

reset() ->
    janus_quota:reset_for_test().

unlimited_short_circuit() ->
    reset(),
    Agent = #{id => 1, rpm_limit => null, tpm_limit => null, daily_token_limit => null},
    ?assertEqual(ok, janus_quota:admit(Agent)),
    ?assertEqual([], ets:lookup(janus_quota_rpm, {1, janus_quota:tpm_bucket_now()})).

rpm_second_admit_rejected() ->
    reset(),
    Agent = #{id => 42, rpm_limit => 1, tpm_limit => null, daily_token_limit => null},
    put(janus_request_id, <<"req_aaaaaaaaaaaaaaaa">>),
    ?assertEqual(ok, janus_quota:admit(Agent)),
    erase(janus_quota_admitted),
    put(janus_request_id, <<"req_bbbbbbbbbbbbbbbb">>),
    case janus_quota:admit(Agent) of
        {error, {quota, rpm, Sec}} when is_integer(Sec), Sec >= 1, Sec =< 60 ->
            ok;
        Other ->
            ?assertEqual(quota_rpm_error, Other)
    end.

admit_once_per_request() ->
    reset(),
    Agent = #{id => 7, rpm_limit => 1, tpm_limit => null, daily_token_limit => null},
    put(janus_request_id, <<"req_cccccccccccccccc">>),
    ?assertEqual(ok, janus_quota:admit(Agent)),
    ?assertEqual(ok, janus_quota:admit(Agent)).

charge_idempotent() ->
    reset(),
    AgentId = 9,
    Rid = <<"req_dddddddddddddddd">>,
    ok = janus_quota:charge_tokens(Rid, AgentId, 10, 20),
    ok = janus_quota:charge_tokens(Rid, AgentId, 10, 20),
    Bucket = janus_quota:tpm_bucket_now(),
    [{_, N}] = ets:lookup(janus_quota_tpm, {AgentId, Bucket}),
    ?assertEqual(30, N).

tpm_lagging_admit() ->
    reset(),
    Agent = #{id => 11, rpm_limit => null, tpm_limit => 50, daily_token_limit => null},
    Rid1 = <<"req_eeeeeeeeeeeeeeee">>,
    ok = janus_quota:charge_tokens(Rid1, 11, 40, 20),
    put(janus_request_id, <<"req_ffffffffffffffff">>),
    erase(janus_quota_admitted),
    ?assertMatch({error, {quota, tpm, _}}, janus_quota:admit(Agent)).

null_usage_charges_zero() ->
    reset(),
    Rid = <<"req_1111111111111111">>,
    ok = janus_quota:charge_tokens(Rid, 3, null, null),
    ?assertEqual([], ets:lookup(janus_quota_tpm, {3, janus_quota:tpm_bucket_now()})).
