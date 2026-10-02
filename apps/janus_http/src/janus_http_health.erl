-module(janus_http_health).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Body = thoas:encode(#{
        status => <<"ok">>,
        service => <<"janus">>,
        generation => janus_config:generation(),
        backend => janus_db:select_backend()
    }),
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req0),
    {ok, Req, State}.