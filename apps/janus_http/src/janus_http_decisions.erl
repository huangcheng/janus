%%%-------------------------------------------------------------------
%%% @doc OpenAI Decisions API agent endpoint (spec 2026-10-07).
%%%
%%% Native passthrough POST /v1/decisions: no translate clauses
%%% anywhere (D4), no streaming (§4.6 — body "stream": true answers
%%% stream_not_supported, D18: the Accept header alone is never a
%%% trigger), no face enable knob (D8 — always available while a
%%% provider + routes exist). Pipeline order is contractual (§4.2):
%%% auth -> 10 MiB body cap (413) -> JSON parse -> grant by body model
%%% -> stream guard -> eligibility/pick. Non-POST -> 405.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_decisions).
-behaviour(cowboy_handler).

-export([init/2]).
%% Exported for eunit (pure reply-shape classifier; the dashboard's
%% server-side probe reuses the same rule, §4.3 "OK" classification).
-export([answers_shape/1]).

-define(MAX_BODY, 10 * 1024 * 1024).

init(Req0, State) ->
    %% Non-POST -> 405 (checked before auth: method dispatch is not an
    %% authenticated question, matching the admin-plane 405 shape).
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            run(Req0, State);
        _ ->
            {ok, method_not_allowed(Req0), State}
    end.

run(Req0, State) ->
    %% Steps 1-2 (auth + capped body, D12: fully buffered BEFORE any
    %% upstream connect) live in the shared preamble (D16).
    case janus_http_preamble:read(Req0, #{face => openai_decisions, max_body => ?MAX_BODY}) of
        {ok, Agent, Body, Req1} ->
            %% Steps 3-6 (parse -> grant -> stream guard -> pick) are
            %% owned by the proxy so usage/metrics/logging stay shared.
            janus_http_proxy:handle(openai_decisions, Agent, Body, Req1, State);
        {error, Req1} ->
            {ok, Req1, State}
    end.

method_not_allowed(Req0) ->
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    logger:warning(#{
        what => janus_agent_reject,
        status => 405,
        code => method_not_allowed,
        method => cowboy_req:method(Req1),
        path => cowboy_req:path(Req1),
        request_id => ReqId
    }),
    janus_metrics:inc(requests_total, #{
        endpoint => janus_http_classify:endpoint(cowboy_req:path(Req1)),
        protocol => janus_http_classify:protocol(cowboy_req:path(Req1)),
        status_class => <<"4xx">>
    }),
    put(janus_req_counted, true),
    Body = thoas:encode(#{
        error => #{
            message => <<"decisions accepts POST only">>,
            type => <<"janus_error">>,
            code => <<"method_not_allowed">>
        }
    }),
    cowboy_req:reply(
        405,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"allow">> => <<"POST">>
        },
        Body,
        Req1
    ).

%% Reply validation (§4.3 probe "OK" rule; D11 gate-excerpt replay):
%% a Decisions reply is well-formed when `answers` is a JSON array —
%% it may contain ONLY refusal entries. Missing/empty/non-array
%% answers are inconclusive. Pure + total; used by eunit to replay the
%% guide-excerpt fixture and by the dashboard probe mirror.
-spec answers_shape(term()) -> ok | inconclusive.
answers_shape(#{<<"answers">> := Answers}) when is_list(Answers), Answers =/= [] ->
    ok;
answers_shape(_) ->
    inconclusive.
