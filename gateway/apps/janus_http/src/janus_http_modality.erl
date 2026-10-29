%%%-------------------------------------------------------------------
%%% @doc Cowboy front door for modality plugins (spec M1.0). The
%%% plugin module arrives in the route's Opts — static dispatch, no
%%% hot registration.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_modality).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req, [Plugin]) ->
    janus_modality:run(Plugin, Req, []);
init(Req, Plugin) when is_atom(Plugin) ->
    janus_modality:run(Plugin, Req, []).
