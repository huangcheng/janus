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
                Model when is_binary(Model), Model =/= <<>> ->
                    case model_allowed(Agent, Model) of
                        false ->
                            reply_json(Req, State, 403, error_body(<<"model_not_allowed">>, <<"model not in allowlist">>));
                        true ->
                            proxy_chat(Model, Body, Map, Req, State)
                    end;
                _ ->
                    reply_json(Req, State, 400, error_body(<<"invalid_request">>, <<"model must be a non-empty string">>))
            end;
        {ok, _} ->
            reply_json(Req, State, 400, error_body(<<"invalid_json">>, <<"request body must be a JSON object">>));
        {error, _} ->
            reply_json(Req, State, 400, error_body(<<"invalid_json">>, <<"request body must be JSON">>))
    end.

proxy_chat(ModelName, Body, Map, Req, State) ->
    case resolve_model(ModelName) of
        {ok, ModelId} ->
            case janus_lb:pick_route(ModelId, #{}) of
                {ok, Route} ->
                    Result =
                        try
                            janus_providers_openai:chat_completions(Route, Body, Map)
                        catch
                            Class:CatchReason:Stack ->
                                logger:error(#{
                                    what => janus_chat_crashed,
                                    class => Class,
                                    reason => janus_seed:sanitize_error(CatchReason),
                                    stack => janus_seed:redact_stack(Stack)
                                }),
                                {error, crashed}
                        end,
                    handle_upstream(Result, Route, Req, State);
                {error, all_cooling} ->
                    reply_json(
                        Req,
                        State,
                        503,
                        error_body(<<"all_cooling">>, <<"all upstream routes are cooling down">>)
                    );
                {error, Reason} ->
                    reply_json(Req, State, 404, error_body(<<"no_route">>, format_reason(Reason)))
            end;
        error ->
            reply_json(Req, State, 404, error_body(<<"model_not_found">>, <<"unknown model">>))
    end.

handle_upstream({ok, Status, Headers, RespBody}, Route, Req, State)
  when Status =:= 401; Status =:= 403; Status =:= 429; Status >= 500 ->
    _ = note_key_failure(Route, Headers, Status),
    _ = note_route_success(Route),
    Req2 = cowboy_req:reply(Status, filter_headers(Headers), RespBody, Req),
    {ok, Req2, State};
handle_upstream({ok, Status, Headers, RespBody}, Route, Req, State) when Status >= 400 ->
    %% Client/request errors: pass through, do not cool the key.
    _ = note_route_success(Route),
    Req2 = cowboy_req:reply(Status, filter_headers(Headers), RespBody, Req),
    {ok, Req2, State};
handle_upstream({ok, Status, Headers, RespBody}, Route, Req, State) ->
    _ = note_key_success(Route),
    _ = note_route_success(Route),
    Req2 = cowboy_req:reply(Status, filter_headers(Headers), RespBody, Req),
    {ok, Req2, State};
handle_upstream({error, crashed}, Route, Req, State) ->
    _ = note_route_success(Route),
    reply_json(Req, State, 500, error_body(<<"internal_error">>, <<"upstream call crashed">>));
handle_upstream({error, Reason}, Route, Req, State) ->
    case is_transient(Reason) of
        true ->
            %% Transport failure: cool the route/provider, not the API key.
            _ = note_route_failure(Route, Reason);
        false ->
            _ = note_route_success(Route)
    end,
    logger:warning(#{
        what => janus_chat_upstream_error,
        reason => janus_seed:sanitize_error(Reason)
    }),
    Status = case Reason of
        provider_disabled -> 503;
        _ -> 502
    end,
    reply_json(Req, State, Status, error_body(<<"upstream_error">>, <<"upstream request failed">>)).

note_key_failure(Route, Headers, Status) when is_integer(Status) ->
    case key_target(Route) of
        undefined -> ok;
        Target -> janus_lb:note_failure(Target, retry_reason(Headers, Status))
    end;
note_key_failure(Route, _Headers, Reason) ->
    case key_target(Route) of
        undefined -> ok;
        Target -> janus_lb:note_failure(Target, Reason)
    end.

note_key_success(Route) ->
    case key_target(Route) of
        undefined -> ok;
        Target -> janus_lb:note_success(Target)
    end.

note_route_failure(Route, Reason) ->
    case route_target(Route) of
        undefined -> ok;
        Target -> janus_lb:note_failure(Target, Reason)
    end.

note_route_success(Route) ->
    case route_target(Route) of
        undefined -> ok;
        Target -> janus_lb:note_success(Target)
    end.

retry_reason(Headers, Status) when Status =:= 429; Status =:= 503 ->
    case maps:get(<<"retry-after">>, Headers, undefined) of
        Bin when is_binary(Bin) ->
            try
                Sec = binary_to_integer(Bin),
                {retry_after, min(max(Sec, 0), 300) * 1000}
            catch
                _:_ -> {http, Status}
            end;
        _ ->
            {http, Status}
    end;
retry_reason(_Headers, Status) when is_integer(Status) ->
    {http, Status};
retry_reason(_Headers, Reason) ->
    Reason.

is_transient({open, _}) -> true;
is_transient({await_up, _}) -> true;
is_transient({await, _}) -> true;
is_transient({body, _}) -> true;
is_transient({unexpected_await, _}) -> true;
is_transient({unexpected_body, _}) -> true;
is_transient(_) -> false.

resolve_model(Name) when is_binary(Name), Name =/= <<>> ->
    case janus_catalog:lookup_model(Name) of
        {ok, #{id := Id}} -> {ok, Id};
        error -> error
    end;
resolve_model(_) ->
    error.

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

key_target(#{provider_key := #{id := Kid}}) ->
    {provider_key, Kid};
key_target(_) ->
    undefined.

route_target(#{provider_id := P, model_id := M}) ->
    {route, M, P};
route_target(#{provider_id := P}) ->
    {route, P};
route_target(_) ->
    undefined.
