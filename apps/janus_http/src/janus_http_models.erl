-module(janus_http_models).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    erase(janus_req_counted),
    case janus_http_auth:require_agent(Req0) of
        {ok, Agent, Req1} ->
            Data =
                try
                    list_models(Agent)
                catch
                    C:R:S ->
                        logger:error(#{what => models_handler_crash, class => C, reason => R, stack => S}),
                        exit({models_handler_crash, R})
                end,
            Body = thoas:encode(#{object => <<"list">>, data => Data}),
            Req = cowboy_req:reply(
                200,
                #{
                    <<"content-type">> => <<"application/json">>
                },
                Body,
                Req1
            ),
            janus_metrics:inc(requests_total, #{
                endpoint => models,
                protocol => none,
                status_class => <<"2xx">>
            }),
            {ok, Req, State};
        {error, ReqErr} ->
            {ok, ReqErr, State}
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
                %% Union with the provider listings — the agent-visible
                %% surface is every model every provider offers.
                Listings = [
                    Name
                 || Name <- janus_catalog:listing_names(),
                    ets:insert_new(Seen, {Name, true})
                ],
                Names = filter_allowed(Agent, lists:sort(Bound ++ Listings) ++ auto_names()),
                Meta = janus_catalog:listings_summary(),
                [model_entry(Name, maps:get(Name, Meta, #{})) || Name <- Names]
            after
                ets:delete(Seen)
            end;
        _ ->
            []
    end.

filter_allowed(#{model_ids := all}, Names) ->
    Names;
filter_allowed(#{model_ids := Ids}, Names) when is_list(Ids) ->
    Allowed = sets:from_list(allowed_names(Ids), [{version, 2}]),
    [N || N <- Names, sets:is_element(N, Allowed)];
filter_allowed(_, Names) ->
    Names.

allowed_names(Ids) ->
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
%% (integers) and reasoning / vision (true).
model_entry(Name, Meta) when map_size(Meta) =:= 0 ->
    #{id => Name, object => <<"model">>, owned_by => <<"janus">>};
model_entry(Name, Meta) ->
    maps:merge(#{id => Name, object => <<"model">>, owned_by => <<"janus">>}, Meta).

%% The janus-auto virtual model appears when any tier has members —
%% from the LIVE config (sys.config overlaid by dashboard settings).
auto_names() ->
    try
        case janus_auto:snapshot() of
            #{configured := true, model := M} when is_binary(M) -> [M];
            _ -> []
        end
    catch
        _:_ -> []
    end.
