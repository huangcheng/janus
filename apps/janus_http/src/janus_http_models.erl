-module(janus_http_models).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case janus_http_auth:require_agent(Req0) of
        {ok, _Agent, Req1} ->
            Data =
                try
                    list_models()
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
            {ok, Req, State};
        {error, ReqErr} ->
            {ok, ReqErr, State}
    end.

list_models() ->
    case janus_catalog:get() of
        #{catalog := #{models := Tid}} ->
            Rows = ets:tab2list(Tid),
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
                Names = lists:sort(Bound ++ Listings) ++ auto_names(),
                [
                    #{id => Name, object => <<"model">>, owned_by => <<"janus">>}
                 || Name <- Names
                ]
            after
                ets:delete(Seen)
            end;
        _ ->
            []
    end.

%% The janus-auto virtual model appears when any tier is configured.
auto_names() ->
    Env = application:get_env(janus, auto_router, []),
    Tiers = proplists:get_value(tiers, Env, #{}),
    HasMembers = lists:any(
        fun
            ({_, [_ | _]}) -> true;
            (_) -> false
        end,
        maps:to_list(maps:filter(fun(_K, V) -> is_list(V) end, Tiers))
    ),
    case HasMembers of
        true -> [<<"janus-auto">>];
        false -> []
    end.
