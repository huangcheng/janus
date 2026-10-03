-module(janus_http_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port = application:get_env(janus, http_port, 8080),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/healthz", janus_http_health, []},
            {"/readyz", janus_http_ready, []},
            {"/v1/models", janus_http_models, []},
            {"/v1/chat/completions", janus_http_chat, []},
            {"/v1/responses", janus_http_not_implemented, [{api, responses}]},
            {"/v1/messages", janus_http_not_implemented, [{api, messages}]}
        ]}
    ]),
    TransportOpts = [{port, Port}],
    ProtocolOpts = #{env => #{dispatch => Dispatch}},
    AutoRouter = #{
        id => janus_auto,
        start => {janus_auto, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_auto]
    },
    Listener = #{
        id => janus_http_listener,
        start => {cowboy, start_clear, [janus_http_listener, TransportOpts, ProtocolOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cowboy]
    },
    logger:info(#{what => janus_http_listen, port => Port}),
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [AutoRouter, Listener]}}.
