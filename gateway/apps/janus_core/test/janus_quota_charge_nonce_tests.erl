%% Quota charge-idempotency regression (security audit run-1,
%% confirmed gateway:janus_quota.charge_tokens:
%% client-request-id-dedup). charge_tokens/4 deduplicated on the
%% request id every charging call site fed it, and that id came
%% verbatim from the client-supplied x-request-id header — so an
%% agent key that pinned one constant header value suppressed every
%% later TPM/daily charge (about one real charge per 2 h GC window),
%% defeating the operator's per-key token budget entirely.
%%
%% The fix mints a server-side per-request nonce (charge_nonce/0) in
%% the shared preamble/modality entry; these tests pin both halves of
%% the invariant: distinct nonces are always distinct, and a REPLAYED
%% nonce is still idempotent (failover retries within one request
%% must not double-charge). Like the other suites here they run via
%% `rebar3 eunit` (CI compiles/formats only).
-module(janus_quota_charge_nonce_tests).

-include_lib("eunit/include/eunit.hrl").

nonce_uniqueness_test() ->
    %% 10k nonces must all be distinct — the replay-suppression
    %% defect relied on the DEDUP KEY being attacker-chosen, so the
    %% replacement key must be unguessable-by-construction.
    Nonces = [janus_quota:charge_nonce() || _ <- lists:seq(1, 10_000)],
    ?assertEqual(length(Nonces), sets:size(sets:from_list(Nonces))),
    [?assertMatch(<<"q_", _/binary>>, N) || N <- Nonces].

replayed_id_still_idempotent_test() ->
    %% The failover-retry contract survives: the same logical request
    %% (same nonce) charges exactly once across replayed charges.
    Agent = #{id => 91, rpm_limit => null, tpm_limit => 1000, daily_token_limit => 2000},
    Nonce = janus_quota:charge_nonce(),
    try
        ok = janus_quota:admit(Agent),
        %% Simulate the per-request pdict hygiene the preamble does:
        %% fresh request-lifecycle state, SAME pinned nonce.
        erase(janus_quota_admitted),
        erase(janus_quota_charged),
        _ = janus_quota:charge_tokens(Nonce, 91, 800, 100),
        erase(janus_quota_admitted),
        erase(janus_quota_charged),
        _ = janus_quota:charge_tokens(Nonce, 91, 800, 100),
        {_Rpm, Tpm, Daily} = maps:get(91, janus_quota:current_usage(), {0, 0, 0}),
        ?assertEqual(900, Tpm),
        ?assertEqual(900, Daily),
        %% And a DIFFERENT nonce (the next request, even one that
        %% replays the same client x-request-id) charges again — the
        %% exact bypass scenario, now closed.
        N2 = janus_quota:charge_nonce(),
        erase(janus_quota_admitted),
        erase(janus_quota_charged),
        _ = janus_quota:charge_tokens(N2, 91, 800, 100),
        {_Rpm2, Tpm2, _D2} = maps:get(91, janus_quota:current_usage(), {0, 0, 0}),
        ?assertEqual(1800, Tpm2)
    after
        erase(janus_quota_admitted),
        erase(janus_quota_charged),
        %% Hermetic: drop this test's rows from the shared named tables
        %% so nothing leaks into suites that read current_usage/0.
        _ = ets:match_delete(janus_quota_tpm, {{91, '_'}, '_'}),
        _ = ets:match_delete(janus_quota_daily, {{91, '_'}, '_'}),
        _ = ets:match_delete(janus_quota_charged, {'_', '_'})
    end.

mint_charge_id_test() ->
    %% The whole fix hinges on this helper: it must mint a fresh,
    %% well-shaped nonce AND store it under janus_quota_charge_id;
    %% entry points call only this, so drift here fails loud.
    try
        Id1 = janus_quota:mint_charge_id(),
        ?assertMatch(<<"q_", _/binary>>, Id1),
        ?assertEqual(Id1, get(janus_quota_charge_id)),
        Id2 = janus_quota:mint_charge_id(),
        ?assert(Id1 =/= Id2),
        ?assertEqual(Id2, get(janus_quota_charge_id))
    after
        erase(janus_quota_charge_id)
    end.
