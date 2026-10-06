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
    erase(janus_req_counted),
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    case janus_http_auth:require_agent(Req1, #{allow_x_api_key => true}) of
        {ok, Agent, Req2} ->
            case cowboy_req:read_body(Req2, #{length => ?MAX_BODY}) of
                {ok, Body, Req3} ->
                    janus_http_proxy:handle(anthropic_messages, Agent, Body, Req3, State);
                {more, _, Req3} ->
                    Body = thoas:encode(#{
                        type => <<"error">>,
                        error => #{
                            type => <<"invalid_request_error">>,
                            message => <<"body exceeds limit">>,
                            code => <<"request_too_large">>
                        }
                    }),
                    Req4 = cowboy_req:reply(
                        413, #{<<"content-type">> => <<"application/json">>}, Body, Req3
                    ),
                    {ok, Req4, State}
            end;
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.
