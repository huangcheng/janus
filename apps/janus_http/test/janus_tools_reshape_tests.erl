%%%-------------------------------------------------------------------
%%% @doc Tools/tool_choice shape translation between the responses flat
%%% dialect and the chat wrapped dialect (audit Q4; production find
%%% 2026-10-07: verbatim passthrough got flat tools rejected by chat
%%% providers with "missing tools.function parameter").
%%% @end
%%%-------------------------------------------------------------------
-module(janus_tools_reshape_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FLAT_TOOL, #{
    <<"type">> => <<"function">>,
    <<"name">> => <<"get_weather">>,
    <<"description">> => <<"Get weather">>,
    <<"parameters">> => #{<<"type">> => <<"object">>, <<"properties">> => #{}}
}).
-define(WRAPPED_TOOL, #{
    <<"type">> => <<"function">>,
    <<"function">> => #{
        <<"type">> => <<"function">>,
        <<"name">> => <<"get_weather">>,
        <<"description">> => <<"Get weather">>,
        <<"parameters">> => #{<<"type">> => <<"object">>, <<"properties">> => #{}}
    }
}).

responses_to_chat_reshapes_flat_tools_test() ->
    {ok, Out} = janus_protocol_translate:translate_request(
        openai_responses, openai_chat,
        #{<<"model">> => <<"m">>,
          <<"input">> => <<"hi">>,
          <<"tools">> => [?FLAT_TOOL]}
    ),
    ?assertEqual([?WRAPPED_TOOL], maps:get(<<"tools">>, Out)).

chat_to_responses_unwraps_tools_test() ->
    {ok, Out} = janus_protocol_translate:translate_request(
        openai_chat, openai_responses,
        #{<<"model">> => <<"m">>,
          <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
          <<"tools">> => [?WRAPPED_TOOL]}
    ),
    ?assertEqual([?FLAT_TOOL], maps:get(<<"tools">>, Out)).

tool_choice_maps_both_ways_test() ->
    {ok, Out1} = janus_protocol_translate:translate_request(
        openai_responses, openai_chat,
        #{<<"model">> => <<"m">>, <<"input">> => <<"hi">>,
          <<"tools">> => [?FLAT_TOOL],
          <<"tool_choice">> => #{<<"type">> => <<"function">>, <<"name">> => <<"get_weather">>}}
    ),
    ?assertEqual(
        #{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => <<"get_weather">>}},
        maps:get(<<"tool_choice">>, Out1)
    ),
    {ok, Out2} = janus_protocol_translate:translate_request(
        openai_chat, openai_responses,
        #{<<"model">> => <<"m">>,
          <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
          <<"tools">> => [?WRAPPED_TOOL],
          <<"tool_choice">> => #{<<"type">> => <<"function">>, <<"function">> => #{<<"name">> => <<"get_weather">>}}}
    ),
    ?assertEqual(
        #{<<"type">> => <<"function">>, <<"name">> => <<"get_weather">>},
        maps:get(<<"tool_choice">>, Out2)
    ).

tool_choice_string_passthrough_test() ->
    ?assertEqual(
        <<"auto">>,
        janus_protocol_translate:responses_tool_choice_to_chat(<<"auto">>)
    ).

already_correct_shapes_pass_test() ->
    {ok, W} = janus_protocol_translate:chat_tool_to_responses(?WRAPPED_TOOL),
    %% wrapped goes flat
    ?assertMatch(#{<<"name">> := <<"get_weather">>}, W),
    {ok, F} = janus_protocol_translate:responses_tool_to_chat(?FLAT_TOOL),
    ?assertMatch(#{<<"function">> := _}, F),
    %% wrapped input to the chat-side shaper passes untouched
    ?assertEqual({ok, ?WRAPPED_TOOL}, janus_protocol_translate:responses_tool_to_chat(?WRAPPED_TOOL)).

nameless_tool_rejected_test() ->
    ?assertMatch(
        {error, {translate_unsupported, _}},
        janus_protocol_translate:responses_tools_to_chat([#{<<"type">> => <<"function">>, <<"parameters">> => #{}}])
    ).
