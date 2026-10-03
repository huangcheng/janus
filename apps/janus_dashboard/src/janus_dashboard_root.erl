%%%-------------------------------------------------------------------
%%% @doc `/` redirects to the dashboard SPA (the only surface on this
%%% listener — the data plane lives on its own port).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_dashboard_root).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(
        302,
        #{
            <<"location">> => <<"/dashboard">>,
            <<"cache-control">> => <<"no-cache">>
        },
        <<>>,
        Req0
    ),
    {ok, Req, State}.
