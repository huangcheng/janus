%%%-------------------------------------------------------------------
%%% @doc Path → closed-enum label values for metrics. Single source
%%% used by the proxy, auth rejects, and the models handler.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_classify).

-export([endpoint/1, protocol/1, status_class/1]).

endpoint(<<"/v1/chat/completions">>) -> chat;
endpoint(<<"/v1/responses">>) -> responses;
endpoint(<<"/v1/messages">>) -> messages;
endpoint(<<"/v1/models">>) -> models;
endpoint(<<"/v1/decisions">>) -> decisions;
endpoint(_) -> other.

protocol(<<"/v1/chat/completions">>) -> openai_chat;
protocol(<<"/v1/responses">>) -> openai_responses;
protocol(<<"/v1/messages">>) -> anthropic_messages;
protocol(<<"/v1/models">>) -> none;
protocol(<<"/v1/decisions">>) -> openai_decisions;
protocol(_) -> other.

status_class(S) when is_integer(S), S >= 200, S < 300 -> <<"2xx">>;
status_class(S) when is_integer(S), S >= 400, S < 500 -> <<"4xx">>;
status_class(S) when is_integer(S), S >= 500 -> <<"5xx">>;
status_class(_) -> <<"unknown">>.
