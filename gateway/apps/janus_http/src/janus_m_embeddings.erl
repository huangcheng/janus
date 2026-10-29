%%%-------------------------------------------------------------------
%%% @doc Embeddings plugin: canonical `POST /v1/embeddings` — a pure
%%% passthrough to the provider's OpenAI-shaped /embeddings endpoint
%%% (dashscope compatible-mode, volcengine ark, zhipu, ...). No
%%% protocol translation, no streaming: JSON in, the upstream JSON
%%% relayed back byte-for-byte on 2xx.
%%%
%%% Model resolution mirrors the chat face: a BOUND model (Router
%%% page) resolves through its model_routes and the body's `model` is
%%% rewritten to the route's upstream name; otherwise the name rides
%%% verbatim as a direct provider listing (upstream names callable
%%% as-is). The agent surface stays the union of listings + bindings.
%%%
%%% Knob `modality.embedding` (settings key `modality`, default OFF).
%%% Spend discipline: COMMIT = upstream ACCEPT (2xx); usage row carries
%%% modality=embedding and units = the reply's total_tokens (NULL for
%%% pre-accept rejects). Single upstream attempt, like the other
%%% modality plugins — no failover in v1.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_embeddings).

-export([
    modality/0,
    max_body/0,
    process/5,
    validate/1,
    resolve_route/1,
    upstream_model/2,
    usage_of/1
]).

%% Embedding requests carry document text (often several chunks per
%% call); 2 MiB is a generous parse guard far above every provider's
%% token cap — the upstream rejects over-limit input with its own
%% error, relayed as upstream_error (honest passthrough).
-define(EMBED_BODY_CAP, 2 * 1024 * 1024).

modality() ->
    <<"embedding">>.

max_body() ->
    ?EMBED_BODY_CAP.

%%%===================================================================
%%% Entry (janus_modality:run/3 has authed + read the capped body)
%%%===================================================================

process(Req, State, Agent, Body, _Meta) ->
    Started = erlang:monotonic_time(millisecond),
    case janus_modality:parse_json(Body) of
        {ok, Map} ->
            case validate(Map) of
                {ok, Model} ->
                    put(janus_req_model, Model),
                    case janus_modality:check_modality(<<"embedding">>, Model) of
                        ok ->
                            route(Req, State, Agent, Model, Map, Body, Started);
                        {error, Why} ->
                            reject(Req, State, Agent, #{}, 400, wrong_modality, Why, Started)
                    end;
                {error, Code} ->
                    reject(Req, State, Agent, #{}, 400, Code, message_for(Code), Started)
            end;
        {error, bad_json} ->
            reject(
                Req, State, Agent, #{}, 400, bad_json, <<"request body is not valid JSON">>, Started
            )
    end.

route(Req, State, Agent, Model, Map, RawBody, Started) ->
    case resolve_route(Model) of
        {ok, Route} ->
            embed(Req, State, Agent, Route, Model, Map, RawBody, Started);
        {error, no_route} ->
            reject(Req, State, Agent, #{}, 404, no_route, <<"no route for model">>, Started);
        {error, Reason} ->
            logger:warning(#{what => janus_embedding_no_route, reason => Reason}),
            reject(
                Req,
                State,
                Agent,
                #{},
                503,
                service_unavailable,
                <<"no usable upstream for model">>,
                Started
            )
    end.

%% Bound model first (Router page curation + aliasing), then the
%% direct listing surface — the same order the chat face uses.
-spec resolve_route(binary()) -> {ok, map()} | {error, term()}.
resolve_route(Model) ->
    case janus_catalog:lookup_model(Model) of
        {ok, #{id := ModelId}} -> janus_lb:pick_route(ModelId, #{});
        _ -> janus_lb:pick_listing_route(Model, #{})
    end.

%%%===================================================================
%%% Upstream call (single attempt — same discipline as the other
%%% modality plugins; retrying after accept would double-bill)
%%%===================================================================

embed(Req, State, Agent, Route, Model, Map, RawBody, Started) ->
    Upstream = upstream_model(Route, Model),
    %% Byte fidelity when no rewrite is needed; re-encoded body only
    %% for a bound alias (key order/duplicates are not preserved —
    %% the same trade every other plugin makes).
    UpBody =
        case Upstream =:= Model of
            true -> RawBody;
            false -> thoas:encode(Map#{<<"model">> => Upstream})
        end,
    case janus_modality:upstream_post(Route, <<"/embeddings">>, UpBody) of
        {ok, Status, _Headers, RespBody} when Status >= 200, Status < 300 ->
            accepted(Req, State, Agent, Route, Status, RespBody, Started);
        {ok, Status, _Headers, RespBody} ->
            Msg = upstream_message(RespBody),
            reject(Req, State, Agent, Route, Status, upstream_error, Msg, Started);
        {error, Reason} ->
            logger:warning(#{what => janus_embedding_upstream_error, reason => Reason}),
            reject(
                Req,
                State,
                Agent,
                Route,
                502,
                upstream_unreachable,
                <<"upstream request failed">>,
                Started
            )
    end.

%% Upstream ACCEPTED (2xx): tokens were spent; units come from the
%% reply's usage object, the JSON relays byte-for-byte.
accepted(Req, State, Agent, Route, Status, RespBody, Started) ->
    Units = usage_of(janus_modality:parse_json(RespBody)),
    record(Agent, Route, Status, Units, completed, Started),
    janus_modality:reply_bytes(Req, State, Status, <<"application/json">>, RespBody).

%% The upstream name for the picked route: a bound route's explicit
%% upstream_model_id, else the bound public name, else the listing
%% name the client itself sent (listing picks carry no rewrite).
-spec upstream_model(map(), binary()) -> binary().
upstream_model(Route, ClientModel) ->
    case maps:get(upstream_model_id, Route, undefined) of
        Bin when is_binary(Bin), Bin =/= <<>> ->
            Bin;
        _ ->
            case maps:get(model_id, Route, null) of
                null ->
                    ClientModel;
                ModelId ->
                    case janus_catalog:lookup_model(ModelId) of
                        {ok, #{name := N}} when is_binary(N) -> N;
                        _ -> ClientModel
                    end
            end
    end.

%% units = total_tokens (fallback prompt_tokens); NULL when the
%% dialect reports no usage — never invent a count.
usage_of({ok, Map}) when is_map(Map) ->
    case maps:get(<<"usage">>, Map, undefined) of
        #{<<"total_tokens">> := T} when is_integer(T) -> T;
        #{<<"prompt_tokens">> := T} when is_integer(T) -> T;
        _ -> null
    end;
usage_of(_) ->
    null.

%% Request validation, all BEFORE any upstream spend. `input` shape
%% (string | string array | token array) is the provider's to judge —
%% presence is all the gateway asserts.
-spec validate(map()) -> {ok, binary()} | {error, atom()}.
validate(Map) when is_map(Map) ->
    Model = janus_modality:model_of(Map),
    Input = maps:get(<<"input">>, Map, undefined),
    case {Model, Input} of
        {undefined, _} -> {error, missing_model};
        {_, undefined} -> {error, missing_input};
        {_, I} when not is_binary(I), not is_list(I) -> {error, invalid_input};
        {M, _} -> {ok, M}
    end;
validate(_) ->
    {error, bad_json}.

%%%===================================================================
%%% Errors + usage
%%%===================================================================

reject(Req, State, Agent, Route, Status, Code, Msg, Started) ->
    stash_error_detail(Msg),
    reject(Req, State, Agent, Route, Status, Code, Msg, Started, null).

reject(Req, State, Agent, Route, Status, Code, Msg, Started, Units) ->
    stash_error_detail(Msg),
    record(Agent, Route, Status, Units, failed, Started),
    reply_error(Req, State, Status, Code, Msg).

%% Terminal usage row detail (merged by janus_modality:record_usage).
stash_error_detail(Msg) when is_binary(Msg) ->
    put(janus_error_detail, Msg);
stash_error_detail(_) ->
    ok.

reply_error(Req, State, Status, Code, Msg) ->
    janus_modality:reply_json(Req, State, Status, #{
        error => #{message => Msg, type => <<"janus_error">>, code => code_bin(Code)}
    }).

code_bin(Code) when is_binary(Code) -> Code;
code_bin(Code) when is_atom(Code) -> atom_to_binary(Code, utf8).

message_for(missing_model) -> <<"you must provide a model parameter">>;
message_for(missing_input) -> <<"you must provide an input parameter">>;
message_for(invalid_input) -> <<"input must be a string or an array">>.

%% Usage row: modality embedding, units = reply total_tokens from
%% accept, NULL for pre-spend rejects.
record(Agent, Route, Status, Units, Outcome, Started) ->
    janus_modality:record_usage(
        #{
            ts => erlang:system_time(second),
            agent_key_id => maps:get(id, Agent, null),
            model_id => maps:get(model_id, Route, null),
            protocol => openai_chat,
            stream => false,
            status => Status,
            latency_ms => erlang:monotonic_time(millisecond) - Started,
            modality => <<"embedding">>,
            units => Units,
            outcome => Outcome
        },
        Route
    ).

%% Best-effort upstream error message (never relayed raw HTML bodies).
upstream_message(Body) ->
    case janus_modality:parse_json(Body) of
        {ok, #{<<"error">> := #{<<"message">> := M}}} when is_binary(M) -> M;
        {ok, #{<<"error">> := M}} when is_binary(M) -> M;
        _ -> <<"upstream request failed">>
    end.
