%%%-------------------------------------------------------------------
%%% @doc Anthropic Messages API agent endpoint.
%%% Accepts Bearer or x-api-key (Bearer wins if both present).
%%%
%%% v2.2 Part A: the inline auth+body preamble was replaced by the
%%% shared {@link janus_http_preamble} so quota admission runs on this
%%% face (ALWAYS-ON). allow_x_api_key => true is the VERIFIED-passthrough
%%% of the old inline handler (no new auth surface); byte-compat with
%%% the old inline replies (401/413/400/happy/x-api-key) is pinned by
%%% test/fixtures/preamble goldens; the face's 429 is the spec-pinned
%%% anthropic body-only envelope (rate_limit_error, no retry-after).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_messages).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    %% No max_body: the preamble 10 MiB default governs — verified
    %% identical to the old inline cap.
    case janus_http_preamble:read(Req0, #{face => anthropic_messages, allow_x_api_key => true}) of
        {ok, Agent, Body, Req1} ->
            janus_http_proxy:handle(anthropic_messages, Agent, Body, Req1, State);
        {error, Req1} ->
            {ok, Req1, State}
    end.
