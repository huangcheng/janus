-module(janus_http_not_implemented).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Api = proplists:get_value(api, State, unknown),
    Body = thoas:encode(#{
        error => #{
            message => iolist_to_binary(io_lib:format("~p not implemented yet", [Api])),
            type => <<"not_implemented">>,
            code => <<"janus_wip">>
        }
    }),
    Req = cowboy_req:reply(501, #{
        <<"content-type">> => <<"application/json">>
    }, Body, Req0),
    {ok, Req, State}.