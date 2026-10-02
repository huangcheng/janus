-module(janus_http_ready).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Ready = janus_config:ready(),
    Status = case Ready of
        true -> 200;
        false -> 503
    end,
    Body = thoas:encode(#{
        ready => Ready,
        generation => janus_config:generation(),
        backend => janus_db:select_backend()
    }),
    Req = cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req0),
    {ok, Req, State}.
