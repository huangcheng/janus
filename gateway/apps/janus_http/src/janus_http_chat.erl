%%%-------------------------------------------------------------------
%%% @doc OpenAI chat/completions agent endpoint.
%%%
%%% v2.2 Part A: the inline auth+body preamble was replaced by the
%%% shared {@link janus_http_preamble} so quota admission runs on this
%%% face (ALWAYS-ON). Byte-compat with the old inline replies (401/
%%% 413/400/happy) is pinned by test/fixtures/preamble goldens; the
%%% face's 429 inherits the responses face's OpenAI-family envelope.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_chat).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    %% No max_body: the preamble 10 MiB default governs — verified
    %% identical to the old inline cap.
    case janus_http_preamble:read(Req0, #{face => openai_chat}) of
        {ok, Agent, Body, Req1} ->
            janus_http_proxy:handle(openai_chat, Agent, Body, Req1, State);
        {error, Req1} ->
            {ok, Req1, State}
    end.
