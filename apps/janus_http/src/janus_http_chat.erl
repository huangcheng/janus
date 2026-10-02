%%%-------------------------------------------------------------------
%%% @doc Minimal OpenAI chat/completions passthrough (non-stream first).
%%% Auth: Bearer agent key. Upstream UA: opencode/2.0.15 (global).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_chat).
-behaviour(cowboy_handler).

-export([init/2]).

-define(MAX_BODY, 10 * 1024 * 1024).

init(Req0, State) ->
    case janus_http_auth:require_agent(Req0) of
        {ok, Agent, Req1} ->
            case cowboy_req:read_body(Req1, #{length => ?MAX_BODY}) of
                {ok, Body, Req2} ->
                    handle_body(Body, Agent, Req2, State);
                {more, _, Req2} ->
                    reply_json(Req2, State, 413, error_body(<<"request_too_large">>, <<"body exceeds limit">>))
            end;
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.

handle_body(Body, Agent, Req, State) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            Model = maps:get(<<"model">>, Map, undefined),
            case Model of
                undefined ->
                    reply_json(Req, State, 400, error_body(<<"invalid_request">>, <<"model required">>));
                _ ->
                    case model_allowed(Agent, Model) of
                        false ->
                            reply_json(Req, State, 403, error_body(<<"model_not_allowed">>, <<"model not in allowlist">>));
                        true ->
                            proxy_chat(Model, Body, Map, Req, State)
                    end
            end;
        {error, _} ->
            reply_json(Req, State, 400, error_body(<<"invalid_json">>, <<"request body must be JSON">>))
    end.

proxy_chat(ModelName, Body, Map, Req, State) ->
    case resolve_model(ModelName) of
        {ok, ModelId} ->
            case janus_lb:pick_route(ModelId, #{}) of
                {ok, Route} ->
                    case janus_providers_openai:chat_completions(Route, Body, Map) of
                        {ok, Status, Headers, RespBody} ->
                            _ = janus_lb:note_success(lb_target(Route)),
                            Req2 = cowboy_req:reply(Status, filter_headers(Headers), RespBody, Req),
                            {ok, Req2, State};
                        {error, {upstream, Status, RespBody}} ->
                            _ = janus_lb:note_failure(lb_target(Route), {http, Status}),
                            reply_json(Req, State, Status, RespBody);
                        {error, Reason} ->
                            _ = janus_lb:note_failure(lb_target(Route), Reason),
                            logger:warning(#{what => janus_chat_upstream_error, reason => Reason}),
                            reply_json(Req, State, 502, error_body(<<"upstream_error">>, format_reason(Reason)))
                    end;
                {error, Reason} ->
                    reply_json(Req, State, 404, error_body(<<"no_route">>, format_reason(Reason)))
            end;
        error ->
            reply_json(Req, State, 404, error_body(<<"model_not_found">>, <<"unknown model">>))
    end.

resolve_model(Name) when is_binary(Name) ->
    case janus_catalog:lookup_model(Name) of
        {ok, #{id := Id}} -> {ok, Id};
        error -> error
    end.

model_allowed(#{model_ids := all}, _) -> true;
model_allowed(#{model_ids := Ids}, ModelName) when is_list(Ids) ->
    case janus_catalog:lookup_model(ModelName) of
        {ok, #{id := Id}} -> lists:member(Id, Ids);
        error -> false
    end;
model_allowed(_, _) -> true.

filter_headers(Headers) when is_map(Headers) ->
    maps:with([<<"content-type">>], Headers);
filter_headers(_) ->
    #{<<"content-type">> => <<"application/json">>}.

reply_json(Req, State, Status, Body) when is_binary(Body) ->
    Req2 = cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, Req2, State};
reply_json(Req, State, Status, Map) when is_map(Map) ->
    reply_json(Req, State, Status, thoas:encode(Map)).

error_body(Code, Msg) ->
    #{
        error => #{
            message => Msg,
            type => <<"janus_error">>,
            code => Code
        }
    }.

format_reason(R) when is_atom(R) -> atom_to_binary(R, utf8);
format_reason(R) when is_binary(R) -> R;
format_reason(R) -> iolist_to_binary(io_lib:format("~p", [R])).

lb_target(#{provider_id := P, provider_key := #{id := K}}) ->
    #{provider_id => P, key_id => K};
lb_target(#{provider_id := P}) ->
    #{provider_id => P};
lb_target(Other) ->
    Other.
