%%%-------------------------------------------------------------------
%%% @doc OpenAI chat/completions agent endpoint.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_chat).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY, 10 * 1024 * 1024).

init(Req0, State) ->
    erase(janus_req_counted),
    case janus_http_auth:require_agent(Req0) of
        {ok, Agent, Req1} ->
            case cowboy_req:read_body(Req1, #{length => ?MAX_BODY}) of
                {ok, Body, Req2} ->
                    janus_http_proxy:handle(openai_chat, Agent, Body, Req2, State);
                {more, _, Req2} ->
                    Body = thoas:encode(#{
                        error => #{
                            message => <<"body exceeds limit">>,
                            type => <<"janus_error">>,
                            code => <<"request_too_large">>
                        }
                    }),
                    Req3 = cowboy_req:reply(
                        413, #{<<"content-type">> => <<"application/json">>}, Body, Req2
                    ),
                    {ok, Req3, State}
            end;
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.
