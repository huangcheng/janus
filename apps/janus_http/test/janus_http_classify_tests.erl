-module(janus_http_classify_tests).
-include_lib("eunit/include/eunit.hrl").

paths_test() ->
    ?assertEqual(chat, janus_http_classify:endpoint(<<"/v1/chat/completions">>)),
    ?assertEqual(responses, janus_http_classify:endpoint(<<"/v1/responses">>)),
    ?assertEqual(messages, janus_http_classify:endpoint(<<"/v1/messages">>)),
    ?assertEqual(models, janus_http_classify:endpoint(<<"/v1/models">>)),
    ?assertEqual(other, janus_http_classify:endpoint(<<"/healthz">>)),
    ?assertEqual(other, janus_http_classify:endpoint(<<"bogus">>)),
    ?assertEqual(openai_chat, janus_http_classify:protocol(<<"/v1/chat/completions">>)),
    ?assertEqual(anthropic_messages, janus_http_classify:protocol(<<"/v1/messages">>)),
    ?assertEqual(openai_responses, janus_http_classify:protocol(<<"/v1/responses">>)),
    ?assertEqual(none, janus_http_classify:protocol(<<"/v1/models">>)).

status_boundaries_test() ->
    ?assertEqual(<<"2xx">>, janus_http_classify:status_class(200)),
    ?assertEqual(<<"2xx">>, janus_http_classify:status_class(299)),
    ?assertEqual(<<"unknown">>, janus_http_classify:status_class(301)),
    ?assertEqual(<<"4xx">>, janus_http_classify:status_class(400)),
    ?assertEqual(<<"4xx">>, janus_http_classify:status_class(499)),
    ?assertEqual(<<"5xx">>, janus_http_classify:status_class(500)),
    ?assertEqual(<<"5xx">>, janus_http_classify:status_class(599)),
    ?assertEqual(<<"unknown">>, janus_http_classify:status_class(undefined)).
