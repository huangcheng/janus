%%%-------------------------------------------------------------------
%%% @doc Audit-R2 regression tests (2026-10-07, written BEFORE the fix):
%%%
%%% 1. Translated NON-STREAM replies carry the spec-required timestamp
%%%    fields on every face: `created` on chat faces (incl. responses
%%%    providers, which name it `created_at`), `created_at` on responses
%%%    faces. Null/garbage upstream values fall back, never crash.
%%% 2. Responses tool-loop items: `reasoning` history items are skipped
%%%    (not rejected as "vision"); unknown item types get the honest
%%%    `unsupported responses input item` error; real multimodal parts
%%%    keep the vision reject; non-string `function_call_output.output`
%%%    is flattened to text on the chat path.
%%% 3. stream_pair_untranslatable/2: a stream toward a responses-protocol
%%%    provider is only servable natively (drives dispatch + repick).
%%%
%%% Fixtures are thoas:decode'd JSON (binary keys, nulls) — the exact
%%% shapes the drivers hand the translator, never hand-idiomatic maps.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_translate_audit_r2_tests).

-include_lib("eunit/include/eunit.hrl").

dec(Bin) ->
    {ok, Map} = thoas:decode(Bin),
    Map.

%%%-------------------------------------------------------------------
%%% 1. Timestamp fields on translated non-stream faces
%%%-------------------------------------------------------------------

%% Responses-provider reply -> chat client: `created` from `created_at`.
responses_face_created_from_created_at_test() ->
    Resp = dec(
        <<"{\"id\":\"resp_abc\",\"object\":\"response\",\"created_at\":1730000123,"
          "\"model\":\"gpt-x\",\"status\":\"completed\","
          "\"output\":[{\"type\":\"message\",\"role\":\"assistant\","
          "\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}],"
          "\"usage\":{\"input_tokens\":5,\"output_tokens\":2,\"total_tokens\":7}}">>
    ),
    {ok, Chat} = janus_protocol_translate:translate_response(openai_chat, openai_responses, Resp),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Chat)),
    ?assertEqual(1730000123, maps:get(<<"created">>, Chat)).

%% Missing created_at -> integer fallback (and never a crash).
responses_face_created_fallback_test() ->
    Resp = dec(
        <<"{\"id\":\"resp_abc\",\"object\":\"response\","
          "\"output\":[{\"type\":\"message\",\"role\":\"assistant\","
          "\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}]}">>
    ),
    {ok, Chat} = janus_protocol_translate:translate_response(openai_chat, openai_responses, Resp),
    ?assert(is_integer(maps:get(<<"created">>, Chat))).

%% Anthropic-provider reply with created: null -> fallback, no case_clause.
anthropic_face_created_null_test() ->
    Msg = dec(
        <<"{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"created\":null,"
          "\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],"
          "\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}">>
    ),
    {ok, Chat} = janus_protocol_translate:translate_response(openai_chat, anthropic_messages, Msg),
    ?assert(is_integer(maps:get(<<"created">>, Chat))).

%% Chat reply -> responses client: `created_at` mirrors chat `created`.
chat_face_created_at_mapped_test() ->
    Chat = dec(
        <<"{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"created\":1730000456,"
          "\"model\":\"qwen\",\"choices\":[{\"index\":0,"
          "\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":\"stop\"}],"
          "\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":1,\"total_tokens\":5}}">>
    ),
    {ok, Resp} = janus_protocol_translate:translate_response(openai_responses, openai_chat, Chat),
    ?assertEqual(<<"response">>, maps:get(<<"object">>, Resp)),
    ?assertEqual(1730000456, maps:get(<<"created_at">>, Resp)).

chat_face_created_at_fallback_test() ->
    Chat = dec(
        <<"{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\","
          "\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hi\"},"
          "\"finish_reason\":\"stop\"}]}">>
    ),
    {ok, Resp} = janus_protocol_translate:translate_response(openai_responses, openai_chat, Chat),
    ?assert(is_integer(maps:get(<<"created_at">>, Resp))).

%%%-------------------------------------------------------------------
%%% 2. Responses input items: reasoning rides, honest errors, flatten
%%%-------------------------------------------------------------------

reasoning_item_skipped_not_vision_test() ->
    Req = dec(
        <<"{\"model\":\"m\",\"input\":["
          "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q\"}]},"
          "{\"type\":\"reasoning\",\"summary\":[]},"
          "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"a\"}]}"
          "]}">>
    ),
    {ok, Chat} = janus_protocol_translate:translate_request(openai_responses, openai_chat, Req),
    Msgs = maps:get(<<"messages">>, Chat),
    ?assertEqual(2, length(Msgs)).

unknown_item_type_honest_error_test() ->
    Req = dec(
        <<"{\"model\":\"m\",\"input\":["
          "{\"type\":\"computer_call\",\"call_id\":\"c1\",\"action\":{\"type\":\"screenshot\"}}"
          "]}">>
    ),
    {error, {translate_unsupported, Why}} =
        janus_protocol_translate:translate_request(openai_responses, openai_chat, Req),
    ?assertEqual(<<"unsupported responses input item">>, Why).

real_multimodal_still_vision_rejected_test() ->
    Req = dec(
        <<"{\"model\":\"m\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":["
          "{\"type\":\"input_image\",\"image_url\":\"https://x/y.png\"}"
          "]}]}">>
    ),
    {error, {translate_unsupported, Why}} =
        janus_protocol_translate:translate_request(openai_responses, openai_chat, Req),
    ?assertEqual(<<"vision/multimodal content not supported">>, Why).

function_call_output_parts_flattened_test() ->
    Req = dec(
        <<"{\"model\":\"m\",\"input\":["
          "{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"get_weather\",\"arguments\":\"{}\"},"
          "{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":["
          "{\"type\":\"input_text\",\"text\":\"sunny, 25C\"}]}"
          "]}">>
    ),
    {ok, Chat} = janus_protocol_translate:translate_request(openai_responses, openai_chat, Req),
    [Tool] = [M || M <- maps:get(<<"messages">>, Chat), maps:get(<<"role">>, M) =:= <<"tool">>],
    ?assertEqual(<<"sunny, 25C">>, maps:get(<<"content">>, Tool)),
    ?assertEqual(<<"c1">>, maps:get(<<"tool_call_id">>, Tool)).

%%%-------------------------------------------------------------------
%%% 3. stream_pair_untranslatable/2
%%%-------------------------------------------------------------------

stream_pair_untranslatable_truth_table_test() ->
    ?assertEqual(true, janus_protocol_translate:stream_pair_untranslatable(openai_chat, openai_responses)),
    ?assertEqual(true, janus_protocol_translate:stream_pair_untranslatable(anthropic_messages, openai_responses)),
    ?assertEqual(false, janus_protocol_translate:stream_pair_untranslatable(openai_responses, openai_responses)),
    ?assertEqual(false, janus_protocol_translate:stream_pair_untranslatable(openai_responses, openai_chat)),
    ?assertEqual(false, janus_protocol_translate:stream_pair_untranslatable(openai_chat, anthropic_messages)),
    ?assertEqual(false, janus_protocol_translate:stream_pair_untranslatable(openai_chat, openai_chat)).
