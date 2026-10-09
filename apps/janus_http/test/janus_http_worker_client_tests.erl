%%% @doc Pure helpers for master→worker proxy dispatch (W2.1).
-module(janus_http_worker_client_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_want_stream_test() ->
    ?assertEqual(true, janus_http_worker_client:normalize_want_stream(true)),
    ?assertEqual(false, janus_http_worker_client:normalize_want_stream(false)),
    ?assertEqual(false, janus_http_worker_client:normalize_want_stream(#{stream => false})),
    ?assertEqual(true, janus_http_worker_client:normalize_want_stream(#{stream => true})).

outcome_bin_test() ->
    ?assertEqual(<<"completed">>, janus_http_worker_client:outcome_bin(ok)),
    ?assertEqual(<<"failed">>, janus_http_worker_client:outcome_bin(error)),
    ?assertEqual(<<"cancelled">>, janus_http_worker_client:outcome_bin(cancelled)).

map_worker_error_test() ->
    ?assertEqual({error, {await, timeout}}, janus_http_worker_client:map_worker_error(timeout, <<"x">>)),
    ?assertEqual({error, {worker_error, connect}}, janus_http_worker_client:map_worker_error(connect, <<"x">>)),
    ?assertEqual({error, worker_lost}, janus_http_worker_client:map_worker_error(worker_lost, <<"x">>)).

affinity_node_parse_test() ->
    ?assertEqual(undefined, janus_http_worker_client:parse_affinity_node(undefined)),
    ?assertEqual(undefined, janus_http_worker_client:parse_affinity_node(null)),
    ?assertEqual(undefined, janus_http_worker_client:parse_affinity_node(<<>>)),
    %% Unknown node name must not create atoms.
    ?assertEqual(
        undefined,
        janus_http_worker_client:parse_affinity_node(<<"no_such_node@nowhere.example">>)
    ),
    Node = node(),
    Bin = atom_to_binary(Node, utf8),
    ?assertEqual(Node, janus_http_worker_client:parse_affinity_node(Bin)).

affinity_opts_test() ->
    Opts = janus_http_worker_client:affinity_opts_from_provider(#{
        region_tag => <<"cn-hz">>,
        affinity_node => atom_to_binary(node(), utf8)
    }),
    ?assertEqual(<<"cn-hz">>, maps:get(region_tag, Opts)),
    ?assertEqual(node(), maps:get(affinity_node, Opts)).
