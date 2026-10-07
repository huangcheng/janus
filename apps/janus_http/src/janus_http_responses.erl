%%%-------------------------------------------------------------------
%%% @doc OpenAI Responses API agent endpoint.
%%%
%%% Shared preamble (request-id, auth, capped body read) lives in
%%% janus_http_preamble since spec 2026-10-07 D16 — this module is the
%%% D16 regression anchor: behavior identical to the inlined version.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_responses).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY, 10 * 1024 * 1024).

init(Req0, State) ->
    case janus_http_preamble:read(Req0, #{face => openai_responses, max_body => ?MAX_BODY}) of
        {ok, Agent, Body, Req1} ->
            janus_http_proxy:handle(openai_responses, Agent, Body, Req1, State);
        {error, Req1} ->
            {ok, Req1, State}
    end.
