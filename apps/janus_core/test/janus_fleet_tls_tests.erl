%% Fleet TLS verify_fun (spec Part A identity model) against REAL
%% generated chain fixtures (apps/janus_core/test/fixtures/fleet/):
%%   ca.pem            — the fleet CA
%%   node-good.pem     — CA-signed, SAN dNSName janus@gw2.test
%%   node-multi.pem    — CA-signed, SANs janus@multi.test + janus@other.test
%%   node-intruder.pem — FOREIGN-CA-signed, carries janus@gw2.test
%% The verify_fun sees the OTP cert shape ssl hands it; fixtures are
%% decoded with public_key:pkix_decode_cert/2 (otp) to match production.
-module(janus_fleet_tls_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE(Name), "apps/janus_core/test/fixtures/fleet/" ++ Name).
-define(PEERS, [<<"janus@gw2.test">>, <<"janus@gw3.test">>]).

otp_cert(File) ->
    {ok, Pem} = file:read_file(?FIXTURE(File)),
    [{'Certificate', Der, _}] = public_key:pem_decode(Pem),
    public_key:pkix_decode_cert(Der, otp).

valid_peer_membership_test() ->
    Cert = otp_cert("node-good.pem"),
    ?assertEqual({valid, ?PEERS}, janus_fleet_tls:verify(Cert, valid_peer, ?PEERS)).

multi_dnsname_exactly_one_match_passes_test() ->
    Cert = otp_cert("node-multi.pem"),
    %% Only the second SAN is in the peer set — one match is enough.
    ?assertEqual({valid, [<<"janus@other.test">>]}, janus_fleet_tls:verify(Cert, valid_peer, [
        <<"janus@other.test">>
    ])),
    %% Zero matches fails with the pinned reason.
    ?assertEqual(
        {fail, san_not_in_peer_set},
        janus_fleet_tls:verify(Cert, valid_peer, [<<"janus@gw2.test">>])
    ).

wrong_san_fails_test() ->
    Cert = otp_cert("node-good.pem"),
    ?assertEqual(
        {fail, san_not_in_peer_set},
        janus_fleet_tls:verify(Cert, valid_peer, [<<"janus@gw3.test">>])
    ).

intruder_is_killed_by_path_validation_not_san_test() ->
    %% The attacker cert carries a configured peer's SAN, so the SAN
    %% membership check alone would pass it — the layered defense is
    %% path validation: with the fleet CA as the only trust anchor the
    %% foreign chain dies at unknown_ca, and the verify_fun never
    %% rescues that event (returns {unknown, _}, see below).
    Intruder = otp_cert("node-intruder.pem"),
    ?assertMatch(
        {valid, _},
        janus_fleet_tls:verify(Intruder, valid_peer, [<<"janus@gw2.test">> | ?PEERS])
    ),
    Ca = otp_cert("ca.pem"),
    %% The exact bad_cert reason depends on which check fires first
    %% (unknown_ca vs invalid_issuer across public_key versions) — the
    %% invariant under test is that path validation KILLS the foreign
    %% chain while the fleet-CA chain validates.
    ?assertMatch(
        {error, {bad_cert, _}},
        public_key:pkix_path_validation(Ca, [Intruder], [])
    ),
    ?assertMatch(
        {ok, _},
        public_key:pkix_path_validation(Ca, [otp_cert("node-good.pem")], [])
    ).

never_rescues_failed_path_validation_test() ->
    Cert = otp_cert("node-intruder.pem"),
    %% Every non-valid_peer event returns {unknown, State} — the fun can
    %% never turn a failed CA validation into a pass.
    ?assertEqual({unknown, ?PEERS}, janus_fleet_tls:verify(Cert, valid, ?PEERS)),
    ?assertEqual({unknown, ?PEERS}, janus_fleet_tls:verify(Cert, {extension, 'BasicConstraints'}, ?PEERS)),
    ?assertEqual({unknown, ?PEERS}, janus_fleet_tls:verify(Cert, {bad_cert, unknown_ca}, ?PEERS)),
    ?assertEqual({unknown, ?PEERS}, janus_fleet_tls:verify(undefined, valid, ?PEERS)).

san_dns_names_extracts_binaries_test() ->
    ?assertEqual([<<"janus@gw2.test">>], janus_fleet_tls:san_dns_names(otp_cert("node-good.pem"))),
    ?assertEqual(
        [<<"janus@multi.test">>, <<"janus@other.test">>],
        lists:sort(janus_fleet_tls:san_dns_names(otp_cert("node-multi.pem")))
    ).

cert_days_remaining_is_int_test() ->
    ?assertMatch(
        {ok, Days} when is_integer(Days), janus_fleet_tls:cert_days_remaining(?FIXTURE("node-good.pem"))
    ),
    {ok, Days} = janus_fleet_tls:cert_days_remaining(?FIXTURE("node-good.pem")),
    %% Fixture validity is 396 days from generation; allow slack.
    ?assert(Days =< 396),
    ?assert(Days > 360).

cert_days_remaining_missing_file_test() ->
    ?assertEqual(error, janus_fleet_tls:cert_days_remaining(?FIXTURE("no-such.pem"))).
