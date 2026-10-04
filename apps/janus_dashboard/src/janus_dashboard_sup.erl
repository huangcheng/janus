%%%-------------------------------------------------------------------
%%% @doc Dashboard console supervisor: session store, audit trail, and a
%%% Cowboy listener bound to the dashboard plane (default
%%% `127.0.0.1:8090` — separate from the data-plane listener).
%%%
%%% App env (`janus_dashboard`): `port` (8090), `bind` ("127.0.0.1"),
%%% `secure_cookies` (false; enable behind Caddy TLS).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_dashboard_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port =
        case os:getenv("JANUS_DASHBOARD_PORT") of
            PortVal when is_list(PortVal), PortVal =/= [] ->
                list_to_integer(PortVal);
            _ ->
                application:get_env(janus_dashboard, port, 8090)
        end,
    Bind =
        case os:getenv("JANUS_DASHBOARD_BIND") of
            BindVal when is_list(BindVal), BindVal =/= [] ->
                parse_ip(BindVal);
            _ ->
                parse_ip(application:get_env(janus_dashboard, bind, "0.0.0.0"))
        end,
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/[...]", janus_dashboard_api, []},
            {"/dashboard", janus_dashboard_redirect, []},
            {"/", janus_dashboard_assets, []},
            {"/[...]", janus_dashboard_assets, []}
        ]}
    ]),
    LogTail = #{
        id => janus_log_tail,
        start => {janus_log_tail, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_log_tail]
    },
    Session = #{
        id => janus_dashboard_session,
        start => {janus_dashboard_session, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_dashboard_session]
    },
    Audit = #{
        id => janus_dashboard_audit,
        start => {janus_dashboard_audit, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_dashboard_audit]
    },
    Listener = #{
        id => janus_dashboard_listener,
        start =>
            {cowboy, start_clear, [
                janus_dashboard_listener,
                [{port, Port}, {ip, Bind}],
                #{env => #{dispatch => Dispatch}}
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cowboy]
    },
    Children =
        case janus_role:serves_dashboard() of
            true ->
                logger:info(#{
                    what => janus_dashboard_listen,
                    bind => inet:ntoa(Bind),
                    port => Port
                }),
                [LogTail, Session, Audit, Listener];
            false ->
                logger:info(#{
                    what => janus_dashboard_skipped,
                    role => janus_role:role(),
                    bind => inet:ntoa(Bind),
                    port => Port
                }),
                []
        end,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.

parse_ip(Bin) when is_binary(Bin) ->
    parse_ip(binary_to_list(Bin));
parse_ip(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Ip} -> Ip;
        {error, _} -> {127, 0, 0, 1}
    end.
