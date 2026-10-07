%% /readyz protocols advertisement (spec 2026-10-07 §4.3 write gate):
%% the agent-face registry is the single source for the cowboy dispatch
%% AND the advertised protocol list; the dashboard write gate blocks
%% Decisions provider writes unless EVERY ready node advertises
%% openai_decisions here (fail closed on missing advertisement).
-module(janus_decisions_readyz_tests).

-include_lib("eunit/include/eunit.hrl").

registry_has_four_faces_test() ->
    Routes = janus_http_sup:agent_routes(),
    ?assertEqual(4, length(Routes)),
    ?assertEqual(
        {"/v1/decisions", janus_http_decisions, openai_decisions},
        lists:keyfind("/v1/decisions", 1, Routes)
    ),
    %% The three existing faces keep their exact routes/handlers
    %% (D16 regression anchor: routes byte-identical).
    ?assert(lists:member({"/v1/chat/completions", janus_http_chat, openai_chat}, Routes)),
    ?assert(lists:member({"/v1/responses", janus_http_responses, openai_responses}, Routes)),
    ?assert(lists:member({"/v1/messages", janus_http_messages, anthropic_messages}, Routes)).

protocols_advertised_from_registry_test() ->
    %% publish (what listener start does) -> sorted unique binaries;
    %% openai_decisions present. persistent_term restored after.
    janus_http_sup:publish_agent_protocols(),
    try
        Protocols = janus_http_sup:agent_protocols(),
        ?assertEqual(
            [
                <<"anthropic_messages">>,
                <<"openai_chat">>,
                <<"openai_decisions">>,
                <<"openai_responses">>
            ],
            Protocols
        ),
        ?assert(lists:member(<<"openai_decisions">>, Protocols))
    after
        persistent_term:erase({janus, agent_protocols})
    end.

unpublished_defaults_closed_test() ->
    %% Before the supervisor runs (or on a node where the listener
    %% never started), the advertisement is empty — the write gate
    %% treats that as NOT serving the protocol (fail closed, §4.3).
    persistent_term:erase({janus, agent_protocols}),
    ?assertEqual([], janus_http_sup:agent_protocols()).
