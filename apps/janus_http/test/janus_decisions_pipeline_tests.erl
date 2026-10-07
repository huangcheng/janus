%% Decisions handler pipeline ORDER (spec 2026-10-07 §4.2, D18):
%% decisions_pre_pick/2 encodes steps 3-5 (model extract -> grant ->
%% stream guard) as ONE ordered function — these tests pin the order,
%% not just the outcomes: precedence rows 2/3 are disjoint BY order.
%% Fixtures are JSON-decoded shapes (binary keys) exactly as
%% thoas hands them to the proxy.
-module(janus_decisions_pipeline_tests).

-include_lib("eunit/include/eunit.hrl").

all_models_agent() ->
    #{model_ids => all}.

%%% Step 3: model extract

missing_model_test() ->
    ?assertMatch(
        {error, {400, <<"invalid_request">>, <<"model required">>}},
        janus_http_proxy:decisions_pre_pick(all_models_agent(), #{<<"input">> => <<"hi">>})
    ).

empty_model_test() ->
    ?assertMatch(
        {error, {400, <<"invalid_request">>, _}},
        janus_http_proxy:decisions_pre_pick(all_models_agent(), #{<<"model">> => <<>>})
    ).

%%% Step 4 (grant) outranks step 5 (stream): row 2 before row 3

grant_deny_outranks_stream_test() ->
    Agent = #{model_ids => [999]},
    Map = #{
        <<"model">> => <<"gpt-6-luna">>,
        <<"stream">> => true,
        <<"input">> => <<"damage photo">>
    },
    ?assertMatch(
        {error, {403, <<"model_not_allowed">>, _}},
        janus_http_proxy:decisions_pre_pick(Agent, Map)
    ).

%%% Step 5: stream guard — body field only (D18)

stream_true_rejected_test() ->
    Map = #{
        <<"model">> => <<"gpt-6-luna">>,
        <<"stream">> => true,
        <<"questions">> => []
    },
    ?assertMatch(
        {error, {400, <<"stream_not_supported">>, <<"decisions does not support streaming">>}},
        janus_http_proxy:decisions_pre_pick(all_models_agent(), Map)
    ).

stream_string_true_rejected_test() ->
    %% wants_stream treats the JSON string "true" as streaming on every
    %% face — same rule here; still a BODY field, never a header.
    Map = #{<<"model">> => <<"gpt-6-luna">>, <<"stream">> => <<"true">>},
    ?assertMatch(
        {error, {400, <<"stream_not_supported">>, _}},
        janus_http_proxy:decisions_pre_pick(all_models_agent(), Map)
    ).

stream_false_and_absent_pass_test() ->
    ?assertMatch(
        {ok, <<"gpt-6-luna">>},
        janus_http_proxy:decisions_pre_pick(
            all_models_agent(), #{<<"model">> => <<"gpt-6-luna">>, <<"stream">> => false}
        )
    ),
    ?assertMatch(
        {ok, <<"gpt-6-luna">>},
        janus_http_proxy:decisions_pre_pick(
            all_models_agent(),
            #{
                <<"model">> => <<"gpt-6-luna">>,
                <<"input">> => [
                    #{
                        <<"role">> => <<"user">>,
                        <<"content">> => [#{<<"type">> => <<"input_text">>, <<"text">> => <<"hi">>}]
                    }
                ],
                <<"questions">> => [#{<<"type">> => <<"predicate">>, <<"name">> => <<"q">>}]
            }
        )
    ).

%%% §4.5 last row: janus-auto on the decisions face

auto_model_gate_test() ->
    ?assert(janus_http_proxy:decisions_auto_model(<<"janus-auto">>)),
    ?assertNot(janus_http_proxy:decisions_auto_model(<<"gpt-6-luna">>)),
    ?assertNot(janus_http_proxy:decisions_auto_model(not_a_binary)).

%%% Pinned local error codes (§4.2 table) stay verbatim

local_error_messages_test() ->
    ?assertEqual(
        {<<"upstream_timeout">>, <<"upstream decisions response timed out">>},
        janus_http_proxy:decisions_local_error(upstream_timeout)
    ),
    ?assertEqual(
        {<<"upstream_response_too_large">>, <<"upstream decisions response exceeds size limit">>},
        janus_http_proxy:decisions_local_error(response_too_large)
    ),
    ?assertEqual(
        {<<"upstream_error">>, <<"upstream request failed">>},
        janus_http_proxy:decisions_local_error(other)
    ).

%%% Local reject envelopes: the Decisions face speaks the OpenAI
%%% janus_error shape (shared default clause); the anthropic face keeps
%%% its own shape (regression anchor).

decisions_error_envelope_test() ->
    ?assertEqual(
        #{
            error => #{
                message => <<"decisions does not support streaming">>,
                type => <<"janus_error">>,
                code => <<"stream_not_supported">>
            }
        },
        janus_http_proxy:error_map(
            openai_decisions, <<"stream_not_supported">>, <<"decisions does not support streaming">>
        )
    ),
    ?assertEqual(
        #{
            error => #{
                message => <<"nope">>,
                type => <<"janus_error">>,
                code => <<"no_route">>
            }
        },
        janus_http_proxy:error_map(openai_decisions, <<"no_route">>, <<"nope">>)
    ),
    %% Anthropic face unchanged (byte-identical regression).
    ?assertEqual(
        #{
            type => <<"error">>,
            error => #{
                type => <<"invalid_request_error">>,
                message => <<"m">>,
                code => <<"c">>
            }
        },
        janus_http_proxy:error_map(anthropic_messages, <<"c">>, <<"m">>)
    ).

%%% D15 pre-send predicate

presend_failure_tags_test() ->
    %% Only gun setup errors are provably pre-send (no request byte
    %% written); everything else — HTTP statuses, first-byte timeout,
    %% mid-body errors, the response cap — is terminal.
    ?assert(janus_http_proxy:decisions_presend_failure({error, {open, econnrefused}})),
    ?assert(janus_http_proxy:decisions_presend_failure({error, {await_up, timeout}})),
    ?assertNot(janus_http_proxy:decisions_presend_failure({error, {await, timeout}})),
    ?assertNot(janus_http_proxy:decisions_presend_failure({error, {body, closed}})),
    ?assertNot(janus_http_proxy:decisions_presend_failure({error, response_too_large})),
    ?assertNot(janus_http_proxy:decisions_presend_failure({ok, 500, #{}, <<>>})),
    ?assertNot(janus_http_proxy:decisions_presend_failure({ok, 200, #{}, <<"{\"answers\":[]}">>})).
