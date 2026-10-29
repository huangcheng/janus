%%%-------------------------------------------------------------------
%%% @doc Shared agent-request preamble (spec 2026-10-07 D16, extracted
%%% from janus_http_responses): request-id + trace-context mint/echo,
%%% agent auth, and the capped full-body read that every agent face
%%% repeats. Local rejects (401 auth, 413 body cap) reply directly with
%%% the caller face's error envelope and return `{error, Req}'; success
%%% returns `{ok, Agent, Body, Req}' for the face's proxy call.
%%%
%%% Behavior-identical to the inlined preamble it replaces: erase the
%%% keep-alive-stale counter flag FIRST, resolve the request id before
%%% auth so even 401s carry x-request-id, read the whole body before
%%% any upstream connect (D12 for Decisions, long-standing for the
%%% other faces).
%%%
%%% Observability-depth Task 3: the W3C trace context resolves beside
%%% the request id — a well-formed inbound `traceparent' is honored,
%%% else a fresh trace-id is minted; the `x-trace-id' echo rides the
%%% same Req chain, so 2xx, pre-flight 4xx rejects, 401/413/429 and
%%% streams all carry it. Requests rejected by cowboy's own HTTP parser
%%% (malformed request-line/headers) return before handler entry and
%%% echo neither x-trace-id nor x-request-id.
%%%
%%% v2.2 Part A (quota admission revival): every agent face now runs
%%% this module — chat/messages dropped their inline preamble copies
%%% (byte-compat pinned by test/fixtures/preamble) so quota admission
%%% runs on them too. ALWAYS-ON: admission has no off switch.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_preamble).

-export([read/2, read_full/2, init_knob/0, max_body_default/0]).

-define(DEFAULT_MAX_BODY, 200 * 1024 * 1024).
-define(PT_MAX_BODY, {janus, max_body_bytes}).
%% Slow-upload bound for read_full: a dribbling client may hold a
%% handler at most this long before the read is refused.
-define(READ_DEADLINE_MS, 300_000).

%% JANUS_MAX_BODY_BYTES at boot (persistent_term; restart to change —
%% no rebuild). Invalid or absent -> 200 MiB default.
init_knob() ->
    Val =
        case os:getenv("JANUS_MAX_BODY_BYTES") of
            false -> ?DEFAULT_MAX_BODY;
            "" -> ?DEFAULT_MAX_BODY;
            S ->
                case string:to_integer(S) of
                    {N, Rest} when is_integer(N), N >= 1048576, Rest =:= [] -> N;
                    _ -> ?DEFAULT_MAX_BODY
                end
        end,
    persistent_term:put(?PT_MAX_BODY, Val),
    ok.

max_body_default() ->
    persistent_term:get(?PT_MAX_BODY, ?DEFAULT_MAX_BODY).

%% Opts:
%%   face          — client proto atom; picks the 413 error envelope
%%                   (anthropic_messages gets the anthropic shape)
%%   max_body      — request byte cap (default: JANUS_MAX_BODY_BYTES)
%%   allow_x_api_key — pass through to janus_http_auth (messages face)
-spec read(cowboy_req:req(), map()) ->
    {ok, map(), binary(), cowboy_req:req()} | {error, cowboy_req:req()}.
read(Req0, Opts) when is_map(Opts) ->
    %% Cowboy reuses the process across HTTP/1.1 keep-alive requests —
    %% a stale counted flag from the previous request must never leak.
    erase(janus_req_counted),
    erase(janus_error_detail),
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    %% Trace context beside the request id (Task 3): resolve ONCE per
    %% request — the unconditional put also overwrites any previous
    %% request's value on this keep-alive-reused process.
    Trace = janus_trace:ensure(cowboy_req:header(<<"traceparent">>, Req0)),
    Req1 = cowboy_req:set_resp_header(
        <<"x-trace-id">>,
        janus_trace:trace_id(Trace),
        cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0)
    ),
    put(janus_request_id, ReqId),
    %% Quota charge idempotency must NOT key on the client-controlled
    %% x-request-id: replaying one fixed id suppressed all later
    %% TPM/daily charges for the key (security-audit run-1). Mint a
    %% per-request server-side nonce; failover retries within this
    %% request reuse it via the pdict, so idempotent charging survives.
    janus_quota:mint_charge_id(),
    put(janus_trace, Trace),
    AuthOpts = #{allow_x_api_key => maps:get(allow_x_api_key, Opts, false)},
    case janus_http_auth:require_agent(Req1, AuthOpts) of
        {ok, Agent, Req2} ->
            erase(janus_quota_admitted),
            erase(janus_quota_charged),
            case janus_quota:admit(Agent) of
                ok ->
                    Max = maps:get(max_body, Opts, max_body_default()),
                    %% read_body returns {more, _} when its PERIOD (default
                    %% 15 s) elapses before the body completes — a slow
                    %% upload, not an oversized one. Looping until {ok,_}
                    %% keeps size and slowness distinct (2026-10-21: a
                    %% 490 KB body uploading at ~17 KB/s was 413'd as
                    %% request_too_large). The length cap still enforces
                    %% the real size limit.
                    case read_full(Req2, Max) of
                        {ok, Body, Req3} ->
                            {ok, Agent, Body, Req3};
                        {too_large, Req3} ->
                            {error, reply_too_large(Req3, Opts)}
                    end;
                {error, {quota, Kind, Sec}} ->
                    {error, reply_quota(Req2, Opts, Kind, Sec)}
            end;
        {error, ReqErr} ->
            {error, ReqErr}
    end.

%% Loop cowboy's read_body until the body completes. {more, _} only
%% means "period elapsed, bytes still pending" — a slow client is NOT
%% an oversized one (2026-10-21: 490 KB at ~17 KB/s was 413'd after
%% cowboy's 15 s period). The accumulated length enforces the real
%% cap; READ_DEADLINE_MS bounds a dribbling client.
-spec read_full(cowboy_req:req(), pos_integer()) ->
    {ok, binary(), cowboy_req:req()} | {too_large, cowboy_req:req()}.
read_full(Req, Max) ->
    read_full(Req, Max, <<>>, erlang:monotonic_time(millisecond) + ?READ_DEADLINE_MS).

read_full(Req, Max, Acc, Deadline) ->
    case byte_size(Acc) >= Max of
        true ->
            {too_large, Req};
        false ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true ->
                    {too_large, Req};
                false ->
                    Remaining = Max - byte_size(Acc),
                    case cowboy_req:read_body(Req, #{length => Remaining, period => 15000}) of
                        {ok, Part, Req2} ->
                            Body = <<Acc/binary, Part/binary>>,
                            case byte_size(Body) > Max of
                                true -> {too_large, Req2};
                                false -> {ok, Body, Req2}
                            end;
                        {more, Part, Req2} ->
                            read_full(Req2, Max, <<Acc/binary, Part/binary>>, Deadline)
                    end
            end
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
    %% v2.2 Part A: the 429 envelope is per protocol family. OpenAI
    %% faces keep the exact shape the responses face has always emitted
    %% (headers incl. retry-after; pinned by fixture). The anthropic
    %% face gets the spec-pinned body-only shape — type rate_limit_error,
    %% no code field, NO retry-after header in v2.2 (header additions
    %% are the v2.2-followup capture task).
    Face = maps:get(face, Opts, openai_chat),
    Body = thoas:encode(quota_envelope(Face, Code, Msg)),
    case Face of
        anthropic_messages ->
            cowboy_req:reply(429, #{<<"content-type">> => <<"application/json">>}, Body, Req);
        _ ->
            cowboy_req:reply(
                429,
                #{
                    <<"content-type">> => <<"application/json">>,
                    <<"retry-after">> => integer_to_binary(Sec)
                },
                Body,
                Req
            )
    end.

%% Quota rejections (NEW branches — no old-inline source on the
%% chat/messages faces): OpenAI family byte-matches the responses
%% face's live output; anthropic carries the messages face's
%% established error wrapper with the rate-limit type.
quota_envelope(anthropic_messages, _Code, Msg) ->
    #{
        type => <<"error">>,
        error => #{
            type => <<"rate_limit_error">>,
            message => Msg
        }
    };
quota_envelope(Face, Code, Msg) ->
    %% Only the anthropic branch differs — delegate the standard
    %% family shape to the shared builder (a future envelope
    %% change must propagate; ocr review).
    error_envelope(Face, Code, Msg).

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
