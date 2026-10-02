-module(janus_http_models).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    %% Placeholder until DB-backed model catalog lands.
    Body = thoas:encode(#{
        object => <<"list">>,
        data => []
    }),
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req0),
    {ok, Req, State}.