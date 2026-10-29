%% stream_compatible/2 must judge EVERY candidate route of a name, not
%% just the first one in the priority-sorted list (review 06d M4). The
%% fixtures publish a REAL production-shaped bundle (atom-keyed rows,
%% SMALLINT 0/1 enabled, integer ids); no gen_server is needed because
%% the predicate is a read-only catalog probe.
-module(janus_auto_stream_compat_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GEN, 999_989).

setup() ->
    janus_catalog:publish(?GEN, janus_catalog:build(rows())),
    ok.

cleanup(_) ->
    janus_catalog:publish(?GEN, janus_catalog:build(#{})),
    ok.

stream_compat_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {inorder, [
            fun mixed_binding_is_compatible_with_every_route/0,
            fun native_only_binding_rejects_other_protocol/0,
            fun listing_only_name_uses_listing_protocol/0,
            fun unknown_name_defers_to_the_proxy/0
        ]}}.

row(ModelId, ProviderId) ->
    #{
        model_id => ModelId,
        provider_id => ProviderId,
        upstream_model_id => null,
        weight => 1,
        priority => 0,
        enabled => 1
    }.

provider(Id, Proto) ->
    #{
        id => Id,
        name => iolist_to_binary(["prov-", integer_to_list(Id)]),
        base_url => <<"https://provider.test/v1">>,
        protocol => Proto,
        enabled => 1
    }.

%% Model 1 is bound to an anthropic provider FIRST in row order and a
%% chat provider second — a chat client can still be served natively by
%% the second route (the old first-route-only probe answered false).
%% Model 2 is anthropic-only. <<"chat-listing">> exists only as a chat
%% provider listing (no models row).
rows() ->
    #{
        models => [
            #{id => 1, name => <<"mixed">>, enabled => 1},
            #{id => 2, name => <<"anthropic-only">>, enabled => 1}
        ],
        model_routes => [row(1, 1), row(1, 2), row(2, 1)],
        providers => [
            provider(1, <<"anthropic_messages">>),
            provider(2, <<"openai_chat">>)
        ],
        provider_keys => [
            #{
                id => 11,
                provider_id => 1,
                secret_ciphertext => <<"ciphertext">>,
                key_id => <<"kid-1">>,
                weight => 1,
                enabled => 1
            },
            #{
                id => 21,
                provider_id => 2,
                secret_ciphertext => <<"ciphertext">>,
                key_id => <<"kid-2">>,
                weight => 1,
                enabled => 1
            }
        ],
        api_keys => [],
        api_key_models => [],
        provider_models => [
            #{id => 1, provider_id => 2, name => <<"chat-listing">>, enabled => 1, meta => null}
        ]
    }.

constraint(ClientProto) ->
    #{stream => true, client_proto => ClientProto}.

compat(Name, ClientProto) ->
    janus_auto:stream_compatible(Name, constraint(ClientProto)).

mixed_binding_is_compatible_with_every_route() ->
    ?assertEqual(true, compat(<<"mixed">>, openai_chat)),
    ?assertEqual(true, compat(<<"mixed">>, anthropic_messages)),
    %% No route on the responses protocol, so that client is not
    %% compatible (it would end in dispatch's terminal 400).
    ?assertEqual(false, compat(<<"mixed">>, openai_responses)).

native_only_binding_rejects_other_protocol() ->
    ?assertEqual(true, compat(<<"anthropic-only">>, anthropic_messages)),
    ?assertEqual(false, compat(<<"anthropic-only">>, openai_chat)).

listing_only_name_uses_listing_protocol() ->
    ?assertEqual(true, compat(<<"chat-listing">>, openai_chat)),
    ?assertEqual(false, compat(<<"chat-listing">>, anthropic_messages)).

unknown_name_defers_to_the_proxy() ->
    ?assertEqual(true, compat(<<"not-in-the-catalog">>, openai_chat)).
