%% Decisions forward shape (spec 2026-10-07 §4.3) + D11 gate-excerpt
%% replay. Pure helpers only — no network, no keys: path-join parity
%% with the probe, model rewrite to the upstream listing id, unknown
%% JSON fields forwarded verbatim, NO stream field injected, D17
%% header strip, and the guide-excerpt answers fed through reply
%% validation (answers_shape/1, the §4.3 probe "OK" rule).
-module(janus_decisions_forward_tests).

-include_lib("eunit/include/eunit.hrl").

%%% Path-join: {base}/decisions, probe parity

path_join_test() ->
    Join = fun(Base) -> janus_providers_http:join_path(Base, <<"/decisions">>) end,
    ?assertEqual(<<"/decisions">>, Join(<<>>)),
    ?assertEqual(<<"/decisions">>, Join(<<"/">>)),
    ?assertEqual(<<"/v1/decisions">>, Join(<<"/v1">>)),
    ?assertEqual(<<"/v1/decisions">>, Join(<<"/v1/">>)),
    ?assertEqual(<<"/openai/v1/decisions">>, Join(<<"/openai/v1">>)).

%%% Model rewrite + unknown-field passthrough + no stream injection

out_map_rewrites_model_test() ->
    Route = #{upstream_model_id => <<"gpt-6-luna-2026-10-01">>},
    ReqMap = #{
        <<"model">> => <<"luna-d">>,
        <<"input">> => <<"smoke detector chirping">>,
        <<"questions">> => [#{<<"type">> => <<"predicate">>, <<"name">> => <<"q">>}]
    },
    Out = janus_providers_openai:decisions_out_map(Route, ReqMap),
    ?assertEqual(<<"gpt-6-luna-2026-10-01">>, maps:get(<<"model">>, Out)),
    %% Everything else rides verbatim — known or unknown to Janus.
    ?assertEqual(<<"smoke detector chirping">>, maps:get(<<"input">>, Out)),
    ?assertMatch([_], maps:get(<<"questions">>, Out)).

out_map_forwards_unknown_fields_test() ->
    Out = janus_providers_openai:decisions_out_map(#{}, #{
        <<"model">> => <<"m">>, <<"future_knob">> => #{<<"a">> => [1, 2, 3]}}
    ),
    ?assertEqual(#{<<"a">> => [1, 2, 3]}, maps:get(<<"future_knob">>, Out)).

out_map_injects_no_stream_test() ->
    %% §4.6: native non-stream — a body without "stream" stays without
    %% (chat/responses inject one; decisions must not), and a client's
    %% explicit stream:false is preserved untouched.
    ?assertNot(maps:is_key(<<"stream">>, janus_providers_openai:decisions_out_map(
        #{}, #{<<"model">> => <<"m">>}
    ))),
    ?assertEqual(
        false,
        maps:get(
            <<"stream">>,
            janus_providers_openai:decisions_out_map(
                #{}, #{<<"model">> => <<"m">>, <<"stream">> => false}
            )
        )
    ).

out_map_fallback_without_upstream_id_test() ->
    %% No upstream_model_id -> the client's own name is the listing id
    %% (same rule as chat/responses upstream_model/2).
    ?assertEqual(
        <<"luna-d">>,
        maps:get(
            <<"model">>,
            janus_providers_openai:decisions_out_map(#{}, #{<<"model">> => <<"luna-d">>})
        )
    ).

%%% D17: outbound header list never carries org/project Spoof headers

decisions_headers_test() ->
    Headers = janus_providers_openai:decisions_headers(<<"sk-secret">>),
    ?assertEqual({<<"authorization">>, <<"Bearer sk-secret">>}, lists:keyfind(<<"authorization">>, 1, Headers)),
    ?assertEqual(false, lists:keyfind(<<"openai-organization">>, 1, Headers)),
    ?assertEqual(false, lists:keyfind(<<"openai-project">>, 1, Headers)),
    ?assertNot(lists:member(<<"x-api-key">>, [K || {K, _} <- Headers])).

%%% D11 replay: the three guide-excerpt answers through reply
%%% validation (merge/CI gate). Fixture is read from disk so the gate
%%% exercises the shipped artifact, not a hand-copy.

d11_replay_test() ->
    {ok, Bin} = read_fixture("openai_decisions.guide-excerpts.json"),
    {ok, Fixture} = thoas:decode(Bin),
    #{<<"excerpts">> := Excerpts} = Fixture,
    %% JSON-decoded keys are binaries — the binary-vs-atom bug class.
    Names = [<<"predicate_answer">>, <<"choice_answer">>, <<"score_answer">>],
    lists:foreach(
        fun(Name) ->
            Body = maps:get(Name, Excerpts),
            %% Each excerpt reply replays clean through the §4.3 rule:
            %% HTTP 200 + non-empty `answers` array -> ok.
            ?assertEqual(ok, janus_http_decisions:answers_shape(Body)),
            %% And each individual answer entry is shaped (type/name).
            [#{<<"type">> := T, <<"name">> := N}] = maps:get(<<"answers">>, Body),
            ?assert(lists:member(T, [<<"predicate">>, <<"choice">>, <<"score">>])),
            ?assert(is_binary(N))
        end,
        Names
    ),
    %% Refusal-only replies are OK (§4.3: may contain only refusal
    %% entries).
    ?assertEqual(
        ok,
        janus_http_decisions:answers_shape(#{
            <<"answers">> => [#{<<"type">> => <<"refusal">>, <<"name">> => <<"visible_damage">>}]
        })
    ).

answers_shape_inconclusive_test() ->
    %% Empty or missing answers -> inconclusive (probe rule); the
    %% passthrough face still forwards the body verbatim.
    ?assertEqual(inconclusive, janus_http_decisions:answers_shape(#{<<"answers">> => []})),
    ?assertEqual(inconclusive, janus_http_decisions:answers_shape(#{})),
    ?assertEqual(inconclusive, janus_http_decisions:answers_shape(#{<<"answers">> => <<"no">>})),
    ?assertEqual(inconclusive, janus_http_decisions:answers_shape(not_a_map)).

%%% internal

read_fixture(Name) ->
    Paths = fixture_paths(Name),
    case first_readable(Paths) of
        {ok, Bin} -> {ok, Bin};
        error -> erlang:error({fixture_not_found, Paths})
    end.

fixture_paths(Name) ->
    [
        filename:join(["apps", "janus_http", "test", "fixtures", "probes", Name]),
        filename:join(["test", "fixtures", "probes", Name]),
        filename:absname(
            filename:join(["apps", "janus_http", "test", "fixtures", "probes", Name])
        )
    ].

first_readable([P | Rest]) ->
    case file:read_file(P) of
        {ok, Bin} -> {ok, Bin};
        _ -> first_readable(Rest)
    end;
first_readable([]) ->
    error.
