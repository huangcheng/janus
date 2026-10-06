-module(janus_request_id_tests).
-include_lib("eunit/include/eunit.hrl").

generate_when_absent_test() ->
    Id = janus_request_id:resolve(undefined),
    ?assertMatch({0, _}, binary:match(Id, <<"req_">>)),
    ?assertEqual(20, byte_size(Id)),
    ?assertEqual(match, re:run(Id, <<"^req_[0-9a-f]{16}$">>, [{capture, none}])).

accept_valid_test() ->
    ?assertEqual(<<"abc-DEF_0123">>, janus_request_id:resolve(<<"abc-DEF_0123">>)).

reject_bad_chars_test() ->
    ?assertMatch(<<"req_", _/binary>>, janus_request_id:resolve(<<"has spaces">>)),
    ?assertMatch(<<"req_", _/binary>>, janus_request_id:resolve(<<"emoji-", 16#F0, 16#9F, 16#98, 16#80>>)).

reject_too_long_test() ->
    ?assertMatch(<<"req_", _/binary>>, janus_request_id:resolve(binary:copy(<<"a">>, 129))).

accept_max_len_test() ->
    ?assertEqual(128, byte_size(janus_request_id:resolve(binary:copy(<<"a">>, 128)))).

unique_test() ->
    ?assertNotEqual(janus_request_id:resolve(undefined), janus_request_id:resolve(undefined)).
