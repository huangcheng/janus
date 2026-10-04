%%%-------------------------------------------------------------------
%%% @doc Anthropic Messages API agent endpoint.
%%% Accepts Bearer or x-api-key (Bearer wins if both present).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_messages).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY, 10 * 1024 * 1024).

init(Req0, State) ->
    case janus_http_auth:require_agent(Req0, #{allow_x_api_key => true}) of
        {ok, Agent, Req1} ->
            case cowboy_req:read_body(Req1, #{length => ?MAX_BODY}) of
                {ok, Body, Req2} ->
                    janus_http_proxy:handle(anthropic_messages, Agent, Body, Req2, State);
                {more, _, Req2} ->
                    Body = thoas:encode(#{
                        type => <<"error">>,
                        error => #{
                            type => <<"invalid_request_error">>,
                            message => <<"body exceeds limit">>,
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
