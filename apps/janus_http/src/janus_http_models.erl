-module(janus_http_models).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case janus_http_auth:require_agent(Req0) of
        {ok, _Agent, Req1} ->
            Data = list_models(),
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
                lists:filtermap(
                    fun
                        ({Key, #{id := Id, name := Name, enabled := true}}) when
                            is_binary(Name), Key =:= Name
                        ->
                            case ets:insert_new(Seen, {Id, true}) of
                                true ->
                                    {true, #{
                                        id => Name,
                                        object => <<"model">>,
                                        owned_by => <<"janus">>
                                    }};
                                false ->
                                    false
                            end;
                        (_) ->
                            false
                    end,
                    Rows
                )
            after
                ets:delete(Seen)
            end;
        _ ->
            []
    end.
