%%%-------------------------------------------------------------------
%%% @doc `/dashboard` redirects to `/` — the SPA moved to the root;
%%% kept so existing bookmarks keep working.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_dashboard_redirect).

-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(
        302,
        #{
            <<"location">> => <<"/">>,
            <<"cache-control">> => <<"no-cache">>
        },
        <<>>,
        Req0
    ),
    {ok, Req, State}.
