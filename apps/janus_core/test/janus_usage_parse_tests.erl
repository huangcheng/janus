-module(janus_usage_parse_tests).

-include_lib("eunit/include/eunit.hrl").

openai_body_test() ->
    B = <<"{\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":7,\"total_tokens\":18}}">>,
    ?assertEqual(
        #{prompt => 11, completion => 7},
        janus_usage_parse:from_response_body(openai_chat, B)
    ).

anthropic_body_test() ->
    B = <<"{\"usage\":{\"input_tokens\":5,\"output_tokens\":9}}">>,
    ?assertEqual(
        #{prompt => 5, completion => 9},
        janus_usage_parse:from_response_body(anthropic_messages, B)
    ).

anthropic_cache_tokens_test() ->
    B =
        <<"{\"usage\":{\"input_tokens\":5,\"output_tokens\":9,"
          "\"cache_creation_input_tokens\":100,\"cache_read_input_tokens\":50}}">>,
    ?assertEqual(
        #{prompt => 155, completion => 9},
        janus_usage_parse:from_response_body(anthropic_messages, B)
    ).

responses_nested_body_test() ->
    B = <<"{\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}}">>,
    ?assertEqual(
        #{prompt => 3, completion => 4},
        janus_usage_parse:from_response_body(openai_responses, B)
    ).

no_usage_body_test() ->
    ?assertEqual(undefined, janus_usage_parse:from_response_body(openai_chat, <<"{}">>)),
    ?assertEqual(undefined, janus_usage_parse:from_response_body(openai_chat, <<"not json">>)).

openai_sse_tail_test() ->
    Tail =
        <<"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
          "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":21,\"completion_tokens\":13,\"total_tokens\":34}}\n\n"
          "data: [DONE]\n\n">>,
    ?assertEqual(
        #{prompt => 21, completion => 13},
        janus_usage_parse:from_sse(openai_chat, <<>>, Tail)
    ).

anthropic_sse_head_tail_test() ->
    Head =
        <<"event: message_start\n"
          "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":17,\"output_tokens\":1}}}\n\n">>,
    Tail =
        <<"event: message_delta\n"
          "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":42}}\n\n">>,
    ?assertEqual(
        #{prompt => 17, completion => 42},
        janus_usage_parse:from_sse(anthropic_messages, Head, Tail)
    ).

anthropic_message_start_nesting_test() ->
    Head =
        <<"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":17,\"output_tokens\":1}}}\n\n">>,
    ?assertEqual(
        #{prompt => 17, completion => 1},
        janus_usage_parse:from_sse(anthropic_messages, Head, <<>>)
    ).

responses_sse_tail_test() ->
    Tail =
        <<"event: response.completed\n"
          "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":8,\"output_tokens\":6}}}\n\n">>,
    ?assertEqual(
        #{prompt => 8, completion => 6},
        janus_usage_parse:from_sse(openai_responses, <<>>, Tail)
    ).

empty_sse_test() ->
    ?assertEqual(undefined, janus_usage_parse:from_sse(openai_chat, <<>>, <<"data: [DONE]\n\n">>)).

genuine_zero_usage_test() ->
    B = <<"{\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0}}">>,
    ?assertEqual(
        #{prompt => 0, completion => 0},
        janus_usage_parse:from_response_body(openai_chat, B)
    ).

genuine_zero_sse_test() ->
    Tail =
        <<"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0}}\n\n"
          "data: [DONE]\n\n">>,
    ?assertEqual(#{prompt => 0, completion => 0}, janus_usage_parse:from_sse(openai_chat, <<>>, Tail)).

%% response.completed embeds the full response (>16KB); the tail keeps
%% only its end, so the data: line never decodes whole — the regex
%% fallback must still recover the trailing usage object.
responses_oversized_completed_test() ->
    Filler = binary:copy(<<"x">>, 20000),
    Tail =
        <<"...truncated...", Filler/binary,
            "\"usage\": {\"input_tokens\": 8, \"output_tokens\": 6, ",
            "\"output_tokens_details\": {\"reasoning_tokens\": 2}}}">>,
    ?assertEqual(
        #{prompt => 8, completion => 6},
        janus_usage_parse:from_sse(openai_responses, <<>>, Tail)
    ).
