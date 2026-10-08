%%%-------------------------------------------------------------------
%%% @doc Shared agent-request preamble (spec 2026-10-07 D16, extracted
%%% from janus_http_responses): request-id mint/echo, agent auth, and
%%% the capped full-body read that every agent face repeats. Local
%%% rejects (401 auth, 413 body cap) reply directly with the caller
%%% face's error envelope and return `{error, Req}'; success returns
%%% `{ok, Agent, Body, Req}' for the face's proxy call.
%%%
%%% Behavior-identical to the inlined preamble it replaces: erase the
%%% keep-alive-stale counter flag FIRST, resolve the request id before
%%% auth so even 401s carry x-request-id, read the whole body before
%%% any upstream connect (D12 for Decisions, long-standing for the
%%% other faces).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_preamble).

-export([read/2]).

-define(DEFAULT_MAX_BODY, 10 * 1024 * 1024).

%% Opts:
%%   face          — client proto atom; picks the 413 error envelope
%%                   (anthropic_messages gets the anthropic shape)
%%   max_body      — request byte cap (default 10 MiB)
%%   allow_x_api_key — pass through to janus_http_auth (messages face)
-spec read(cowboy_req:req(), map()) ->
    {ok, map(), binary(), cowboy_req:req()} | {error, cowboy_req:req()}.
read(Req0, Opts) when is_map(Opts) ->
    %% Cowboy reuses the process across HTTP/1.1 keep-alive requests —
    %% a stale counted flag from the previous request must never leak.
    erase(janus_req_counted),
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    AuthOpts = #{allow_x_api_key => maps:get(allow_x_api_key, Opts, false)},
    case janus_http_auth:require_agent(Req1, AuthOpts) of
        {ok, Agent, Req2} ->
            erase(janus_quota_admitted),
            erase(janus_quota_charged),
            case janus_quota:admit(Agent) of
                ok ->
                    Max = maps:get(max_body, Opts, ?DEFAULT_MAX_BODY),
                    case cowboy_req:read_body(Req2, #{length => Max}) of
                        {ok, Body, Req3} ->
                            {ok, Agent, Body, Req3};
                        {more, _, Req3} ->
                            {error, reply_too_large(Req3, Opts)}
                    end;
                {error, {quota, Kind, Sec}} ->
                    {error, reply_quota(Req2, Opts, Kind, Sec)}
            end;
        {error, ReqErr} ->
            {error, ReqErr}
    end.

reply_too_large(Req, Opts) ->
    Body = thoas:encode(
        error_envelope(maps:get(face, Opts, openai_chat), <<"request_too_large">>, <<"body exceeds limit">>)
    ),
    cowboy_req:reply(413, #{<<"content-type">> => <<"application/json">>}, Body, Req).

reply_quota(Req, Opts, Kind, Sec) when is_integer(Sec), Sec > 0 ->
    Code = janus_quota:kind_code(Kind),
    Msg = <<"agent key quota exceeded (", Code/binary, ")">>,
    case get(janus_req_counted) of
        true ->
            ok;
        _ ->
            put(janus_req_counted, true),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
                protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
                status_class => <<"4xx">>
            })
    end,
    logger:warning(#{
        what => janus_agent_reject,
        status => 429,
        code => Code,
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        request_id => get(janus_request_id)
    }),
    Body = thoas:encode(
        error_envelope(maps:get(face, Opts, openai_chat), Code, Msg)
    ),
    SecBin = integer_to_binary(Sec),
    cowboy_req:reply(
        429,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"retry-after">> => SecBin
        },
        Body,
        Req
    ).

%% Same envelopes the faces inlined before the extraction (byte-identical).
error_envelope(anthropic_messages, Code, Msg) ->
    #{
        type => <<"error">>,
        error => #{
            type => <<"invalid_request_error">>,
            message => Msg,
            code => Code
        }
    };
error_envelope(_Face, Code, Msg) ->
    #{
        error => #{
            message => Msg,
            type => <<"janus_error">>,
            code => Code
        }
    }.
