-module(janus_http_models).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    erase(janus_req_counted),
    ReqId = janus_request_id:resolve(cowboy_req:header(<<"x-request-id">>, Req0)),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, ReqId, Req0),
    put(janus_request_id, ReqId),
    %% Task 3: /v1/models is deliberately EXCLUDED from trace
    %% resolution/echo — no upstream call, no usage row.
    case janus_http_auth:require_agent(Req1) of
        {ok, Agent, Req2} ->
            %% Exact-match route yields path_info = undefined; the
            %% [...] route yields a (possibly empty) segment list.
            case cowboy_req:path_info(Req2) of
                undefined ->
                    reply_list(Agent, Req2, State);
                [] ->
                    reply_list(Agent, Req2, State);
                Segments ->
                    reply_one(Agent, Segments, Req2, State)
            end;
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.

reply_list(Agent, Req2, State) ->
    Data =
        try
            list_models(Agent)
        catch
            C:R:S ->
                logger:error(#{what => models_handler_crash, class => C, reason => R, stack => S}),
                exit({models_handler_crash, R})
        end,
    Body = thoas:encode(#{object => <<"list">>, data => Data}),
    %% Unary REST JSON (the union listing can be large) — the
    %% downstream gzip seam (spec F6/D8).
    Req = janus_downstream_enc:reply(
        200,
        #{
            <<"content-type">> => <<"application/json">>
        },
        Body,
        Req2
    ),
    janus_metrics:inc(requests_total, #{
        endpoint => models,
        protocol => none,
        status_class => <<"2xx">>
    }),
    {ok, Req, State}.

%% GET /v1/models/{id} — OpenAI retrieve-model shape. The id is matched
%% against the SAME advertised set as the list (allowlist + disabled
%% filtering), so a name the list hides is a 404 here too.
reply_one(Agent, Segments, Req2, State) ->
    %% cowboy already url-decodes path_info segments — no second decode.
    Name = iolist_to_binary(lists:join(<<"/">>, Segments)),
    Advertised =
        try
            list_models(Agent)
        catch
            _:_ -> []
        end,
    case lists:filter(fun(#{id := Id}) -> Id =:= Name end, Advertised) of
        [Entry] ->
            Req = janus_downstream_enc:reply(
                200, #{<<"content-type">> => <<"application/json">>}, thoas:encode(Entry), Req2
            ),
            janus_metrics:inc(requests_total, #{
                endpoint => models, protocol => none, status_class => <<"2xx">>
            }),
            {ok, Req, State};
        _ ->
            Body = thoas:encode(#{
                error => #{
                    message => <<"The model '", Name/binary, "' does not exist">>,
                    type => <<"invalid_request_error">>,
                    param => null,
                    code => <<"model_not_found">>
                }
            }),
            Req = janus_downstream_enc:reply(
                404, #{<<"content-type">> => <<"application/json">>}, Body, Req2
            ),
            janus_metrics:inc(requests_total, #{
                endpoint => models, protocol => none, status_class => <<"4xx">>
            }),
            {ok, Req, State}
    end.

list_models(Agent) ->
    case janus_catalog:get() of
        #{catalog := #{models := Tid}} ->
            Rows =
                try
                    ets:tab2list(Tid)
                catch
                    error:badarg -> []
                end,
            %% Table stores both id and name keys — keep name entries only once.
            Seen = ets:new(janus_models_seen, [set]),
            try
                Bound =
                    lists:filtermap(
                        fun
                            ({Key, #{name := Name, enabled := true}}) when
                                is_binary(Name), Key =:= Name
                            ->
                                case ets:insert_new(Seen, {Name, true}) of
                                    true -> {true, Name};
                                    false -> false
                                end;
                            (_) ->
                                false
                        end,
                        Rows
                    ),
                %% A disabled `models` row is the operator's kill switch
                %% for that name: no component of the agent surface
                %% (listing union, bound models, janus-auto) may
                %% re-advertise it (review 06d H1). Both the id-keyed
                %% and name-keyed entry carry the same name, so either
                %% match is the same set.
                Disabled = maps:from_list([
                    {Name, true}
                 || {_Key, #{name := Name, enabled := false}} <- Rows,
                    is_binary(Name)
                ]),
                %% Union with the provider listings — the agent-visible
                %% surface is every model every provider offers.
                Listings = [
                    Name
                 || Name <- janus_catalog:listing_names(),
                    ets:insert_new(Seen, {Name, true})
                ],
                Names0 = filter_allowed(Agent, lists:sort(Bound ++ Listings) ++ auto_names()),
                Names = [Name || Name <- Names0, not maps:is_key(Name, Disabled)],
                Meta = janus_catalog:listings_summary(),
                [model_entry(Name, maps:get(Name, Meta, #{})) || Name <- Names]
            after
                ets:delete(Seen)
            end;
        _ ->
            []
    end.

filter_allowed(#{model_names := all}, Names) ->
    Names;
filter_allowed(#{model_names := Allowed}, Names) when is_list(Allowed) ->
    Set = sets:from_list(Allowed, [{version, 2}]),
    [N || N <- Names, sets:is_element(N, Set)];
%% Legacy catalog field (pre-022 beams).
filter_allowed(#{model_ids := all}, Names) ->
    Names;
filter_allowed(#{model_ids := Ids}, Names) when is_list(Ids) ->
    Allowed = sets:from_list(allowed_names_by_id(Ids), [{version, 2}]),
    [N || N <- Names, sets:is_element(N, Allowed)];
filter_allowed(_, Names) ->
    Names.

allowed_names_by_id(Ids) ->
    lists:filtermap(
        fun(Id) ->
            case janus_catalog:lookup_model(Id) of
                {ok, #{name := Name}} when is_binary(Name) -> {true, Name};
                _ -> false
            end
        end,
        Ids
    ).

%% Capability fields captured from provider catalogs appear only when
%% at least one provider reports them: context_length / max_output_tokens
%% (integers) and reasoning / vision (true). Anthropic Models API parity:
%% the same integers are also emitted under Anthropic's names
%% (max_input_tokens / max_tokens); OpenAI-shape clients ignore the
%% unknown keys, Anthropic-shape clients read their own spelling.
%%
%% `created` (unix int) is REQUIRED by the OpenAI Model object and the
%% openai-python SDK (Model.created: int, no default) — provider
%% catalogs variously emit `created_at` (string), `created`, or
%% nothing, so the upstream spellings are STRIPPED and a spec-valid
%% int is always emitted (upstream int when present, else 0). The list
%% and single-model paths share these entries, so both faces are
%% compliant by construction.
model_entry(Name, Meta) when map_size(Meta) =:= 0 ->
    base_entry(Name);
model_entry(Name, Meta) ->
    %% Meta carries the upstream's own binary keys; the base map uses
    %% atom keys, so maps:merge would keep BOTH spellings of id/object/
    %% owned_by and thoas would emit duplicate JSON keys (parsers then
    %% pick arbitrarily). Drop the identity keys — and the timestamp
    %% spellings, replaced by our own spec-valid `created` — from Meta
    %% first.
    Base = maps:merge(
        base_entry(Name),
        maps:without(
            [<<"id">>, <<"object">>, <<"owned_by">>, <<"created">>, <<"created_at">>],
            Meta
        )
    ),
    anthropic_aliases(Base#{created => created_int(Meta)}).

base_entry(Name) ->
    #{id => Name, object => <<"model">>, owned_by => <<"janus">>, created => 0}.

created_int(#{<<"created">> := I}) when is_integer(I) -> I;
created_int(#{<<"created_at">> := I}) when is_integer(I) -> I;
created_int(_) -> 0.

anthropic_aliases(#{<<"context_length">> := C} = M) when is_integer(C) ->
    anthropic_aliases_out(M#{<<"max_input_tokens">> => C});
anthropic_aliases(M) ->
    anthropic_aliases_out(M).

anthropic_aliases_out(#{<<"max_output_tokens">> := O} = M) when is_integer(O) ->
    M#{<<"max_tokens">> => O};
anthropic_aliases_out(M) ->
    M.

%% The janus-auto virtual model appears when at least one tier member
%% resolves to a routable listing — from the LIVE config (sys.config
%% overlaid by dashboard settings). A configured tier list whose members
%% are all gone must not advertise a model every call would 404 on.
auto_names() ->
    try
        case janus_auto:snapshot() of
            #{routable := true, model := M} when is_binary(M) -> [M];
            _ -> []
        end
    catch
        _:_ -> []
    end.
