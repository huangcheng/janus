%% Face eligibility + §4.5 precedence (spec 2026-10-07): the gate is
%% ordered BEFORE wrong_modality (TF-D.13) and disjoint from the
%% pick-owned rows 6-8; the LB-side hard filter is pure mechanism
%% (policy lives in janus_http_proxy). Catalog fixtures are
%% production-shaped: epgsql rows with SMALLINT 0/1 booleans and
%% binary protocol strings.
-module(janus_decisions_eligibility_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GEN, 999_997).

publish(Rows) ->
    janus_catalog:publish(?GEN, janus_catalog:build(Rows)).

restore() ->
    publish(#{}).

%% Providers: 1 = openai_decisions, 2 = openai_chat,
%% 3 = anthropic_messages, 4 = an unknown future protocol.
base_rows() ->
    #{
        models => [
            #{id => 10, name => <<"bound-dual">>, enabled => 1}
        ],
        model_routes => [
            #{model_id => 10, provider_id => 1, upstream_model_id => null, weight => 1,
                priority => 0, enabled => 1},
            #{model_id => 10, provider_id => 2, upstream_model_id => null, weight => 1,
                priority => 0, enabled => 1}
        ],
        providers => [
            #{id => 1, name => <<"decisions-prov">>, base_url => <<"https://api.openai.com/v1">>,
                protocol => <<"openai_decisions">>, enabled => 1},
            #{id => 2, name => <<"chat-prov">>, base_url => <<"https://api.openai.com/v1">>,
                protocol => <<"openai_chat">>, enabled => 1},
            #{id => 3, name => <<"anthropic-prov">>, base_url => <<"https://api.anthropic.com">>,
                protocol => <<"anthropic_messages">>, enabled => 1},
            #{id => 4, name => <<"future-prov">>, base_url => <<"https://example.com">>,
                protocol => <<"future_proto">>, enabled => 1}
        ],
        provider_keys => [],
        api_keys => [],
        api_key_models => [],
        provider_models => [
            #{id => 1, provider_id => 1, name => <<"luna-d">>, enabled => 1, meta => null},
            #{id => 2, provider_id => 2, name => <<"gpt-chat">>, enabled => 1, meta => null},
            #{id => 3, provider_id => 3, name => <<"claude-chat">>, enabled => 1, meta => null},
            #{id => 4, provider_id => 1, name => <<"dual-name">>, enabled => 1, meta => null},
            #{id => 5, provider_id => 2, name => <<"dual-name">>, enabled => 1, meta => null},
            #{id => 6, provider_id => 4, name => <<"unknown-p">>, enabled => 1, meta => null},
            #{id => 7, provider_id => 1, name => <<"luna-d-off">>, enabled => 0, meta => null}
        ]
    }.

with_catalog(TestFun) ->
    publish(base_rows()),
    try
        TestFun()
    after
        restore()
    end.

%%% Row 5: name exists, no eligible route -> protocol_requires_native
%%% (TF-D.2 / TF-D.3 / D9 — never wrong_modality, eligibility first)

chat_naming_decisions_only_test() ->
    with_catalog(fun() ->
        ?assertEqual(
            {error, protocol_requires_native},
            janus_http_proxy:proto_gate(openai_chat, <<"luna-d">>)
        ),
        ?assertEqual(
            {error, protocol_requires_native},
            janus_http_proxy:proto_gate(openai_responses, <<"luna-d">>)
        ),
        ?assertEqual(
            {error, protocol_requires_native},
            janus_http_proxy:proto_gate(anthropic_messages, <<"luna-d">>)
        )
    end).

decisions_naming_chat_only_test() ->
    with_catalog(fun() ->
        ?assertEqual(
            {error, protocol_requires_native},
            janus_http_proxy:proto_gate(openai_decisions, <<"gpt-chat">>)
        ),
        ?assertEqual(
            {error, protocol_requires_native},
            janus_http_proxy:proto_gate(openai_decisions, <<"claude-chat">>)
        )
    end).

%%% Row 4: unknown name defers to the pick (ok here; the pick answers
%%% no_route with its usage row — behavior identical to before)

unknown_name_defers_test() ->
    with_catalog(fun() ->
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_decisions, <<"no-such-model">>)),
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_chat, <<"no-such-model">>))
    end).

disabled_everywhere_listing_defers_test() ->
    %% A listing disabled on every provider is OFF the agent surface:
    %% listings_for/1 returns [] exactly like an unknown name — the
    %% pick answers no_route (row 4), not row 5/6.
    with_catalog(fun() ->
        ?assertEqual([], janus_catalog:listings_for(<<"luna-d-off">>)),
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_decisions, <<"luna-d-off">>))
    end).

%%% TF-D.9: same name on two protocol rows splits by face

dual_protocol_name_ok_for_both_faces_test() ->
    with_catalog(fun() ->
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_chat, <<"dual-name">>)),
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_decisions, <<"dual-name">>)),
        %% Bound models with mixed routes gate the same way.
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_chat, <<"bound-dual">>)),
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_decisions, <<"bound-dual">>))
    end).

%%% TF-D.13: eligibility outranks modality — the decisions-only name
%%% is modality <<"chat">> (provider_models default), so the old
%%% wrong_modality guard could never fire for it anyway; the gate
%%% answers first for ANY future non-chat Decisions tag.

route_eligibility_matrix_test() ->
    with_catalog(fun() ->
        Rd = #{provider_id => 1},
        Rc = #{provider_id => 2},
        Ra = #{provider_id => 3},
        Ru = #{provider_id => 4},
        %% Decisions client rides ONLY openai_decisions routes.
        ?assert(janus_http_proxy:route_eligible(openai_decisions, Rd)),
        ?assertNot(janus_http_proxy:route_eligible(openai_decisions, Rc)),
        ?assertNot(janus_http_proxy:route_eligible(openai_decisions, Ra)),
        %% Every other face excludes openai_decisions routes.
        ?assertNot(janus_http_proxy:route_eligible(openai_chat, Rd)),
        ?assertNot(janus_http_proxy:route_eligible(openai_responses, Rd)),
        ?assertNot(janus_http_proxy:route_eligible(anthropic_messages, Rd)),
        ?assert(janus_http_proxy:route_eligible(openai_chat, Rc)),
        ?assert(janus_http_proxy:route_eligible(anthropic_messages, Ra)),
        %% Unknown protocol: defer (old beams skip; dispatch fails
        %% closed with unknown_protocol — TF-D.12/D2).
        ?assert(janus_http_proxy:route_eligible(openai_chat, Ru)),
        ?assert(janus_http_proxy:route_eligible(openai_decisions, Ru)),
        %% Malformed routes never crash the gate.
        ?assert(janus_http_proxy:route_eligible(openai_chat, #{})),
        ?assertEqual(ok, janus_http_proxy:proto_gate(openai_chat, <<"unknown-p">>))
    end).

%%% §4.2 pinned message shape: F/P filled, faces present

protocol_requires_native_message_has_faces_test() ->
    with_catalog(fun() ->
        M1 = janus_http_proxy:protocol_requires_native_msg(openai_chat, <<"luna-d">>),
        ?assertEqual(
            <<"client face openai_chat cannot call model that requires openai_decisions">>, M1
        ),
        M2 = janus_http_proxy:protocol_requires_native_msg(openai_decisions, <<"gpt-chat">>),
        ?assertEqual(
            <<"client face openai_decisions cannot call model that requires openai_chat">>, M2
        ),
        %% Anthropic-only name from the decisions face names the
        %% anthropic protocol.
        M3 = janus_http_proxy:protocol_requires_native_msg(openai_decisions, <<"claude-chat">>),
        ?assertEqual(
            <<"client face openai_decisions cannot call model that requires anthropic_messages">>,
            M3
        )
    end).

%%% Face -> pick-opt policy reaches the LB as a hard filter

face_pick_opts_test() ->
    ?assertEqual(
        #{require_proto => <<"openai_decisions">>},
        janus_http_proxy:face_eligibility_opts(openai_decisions)
    ),
    ?assertEqual(
        #{exclude_protos => [<<"openai_decisions">>]},
        janus_http_proxy:face_eligibility_opts(openai_chat)
    ),
    ?assertEqual(
        #{exclude_protos => [<<"openai_decisions">>]},
        janus_http_proxy:face_eligibility_opts(anthropic_messages)
    ),
    %% Non-stream and stream both carry the policy; streams add the
    %% same-protocol bias on top (auto-router repicks share this).
    ?assertEqual(
        #{require_proto => <<"openai_decisions">>},
        janus_http_proxy:stream_pick_opts(openai_decisions, #{<<"model">> => <<"m">>})
    ),
    ?assertEqual(
        #{exclude_protos => [<<"openai_decisions">>]},
        janus_http_proxy:stream_pick_opts(openai_chat, #{<<"model">> => <<"m">>})
    ),
    ?assertEqual(
        #{
            exclude_protos => [<<"openai_decisions">>],
            prefer_proto => <<"openai_chat">>
        },
        janus_http_proxy:stream_pick_opts(
            openai_chat, #{<<"model">> => <<"m">>, <<"stream">> => true}
        )
    ).

%%% LB mechanism: janus_lb:protocol_filter/3 (pure, injected lookup)

lb_protocol_filter_test() ->
    Proto = fun(#{p := P}) -> P end,
    Routes = [#{p => <<"openai_decisions">>}, #{p => <<"openai_chat">>}, #{p => undefined}],
    ?assertEqual(
        [#{p => <<"openai_decisions">>}],
        janus_lb:protocol_filter(Routes, #{require_proto => <<"openai_decisions">>}, Proto)
    ),
    ?assertEqual(
        [#{p => <<"openai_chat">>}, #{p => undefined}],
        janus_lb:protocol_filter(
            Routes, #{exclude_protos => [<<"openai_decisions">>]}, Proto
        )
    ),
    %% No policy opts -> unchanged (modality/legacy callers).
    ?assertEqual(Routes, janus_lb:protocol_filter(Routes, #{}, Proto)),
    %% require mode is EXACT (D2 fail closed on the Decisions face):
    %% unknown protocols do not satisfy require_proto — the pick
    %% answers no_route; exclude mode KEEPS unknowns (they defer to
    %% the dispatch-time unknown_protocol guard like today).
    ?assertEqual(
        [],
        janus_lb:protocol_filter(
            [#{p => undefined}, #{p => <<"openai_chat">>}],
            #{require_proto => <<"openai_decisions">>},
            Proto
        )
    ),
    ?assertEqual(
        [#{p => undefined}],
        janus_lb:protocol_filter(
            [#{p => undefined}, #{p => <<"openai_decisions">>}],
            #{exclude_protos => [<<"openai_decisions">>]},
            Proto
        )
    ),
    %% Total on garbage.
    ?assertEqual(Routes, janus_lb:protocol_filter(Routes, not_a_map, Proto)).

%%% TF-D.12: normalize_protocol catch-all — the clause OLD beams fall
%%% into for <<"openai_decisions">> rows (they lack the new clause) is
%%% the trailing catch-all: unknown -> {error, unknown_protocol},
%%% never a crash. Rows are skipped (fail closed), never written.

old_normalize_skip_test() ->
    ?assertEqual({ok, openai_decisions}, janus_protocol_translate:normalize_protocol(
        <<"openai_decisions">>
    )),
    ?assertEqual({ok, openai_decisions}, janus_protocol_translate:normalize_protocol(
        openai_decisions
    )),
    %% An unseen protocol binary (what an old beam sees) hits the
    %% catch-all — no function_clause, no crash.
    ?assertEqual(
        {error, unknown_protocol},
        janus_protocol_translate:normalize_protocol(<<"future_proto">>)
    ),
    ?assertEqual(
        {error, unknown_protocol},
        janus_protocol_translate:normalize_protocol(#{<<"weird">> => 1})
    ).
