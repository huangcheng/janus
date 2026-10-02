%%%-------------------------------------------------------------------
%%% @doc Admin console supervisor: session store, audit trail, and a
%%% Cowboy listener bound to the admin plane (default
%%% `127.0.0.1:8090` — never on the data-plane listener).
%%%
%%% App env (`janus_admin`): `port` (8090), `bind` ("127.0.0.1"),
%%% `secure_cookies` (false; enable behind Caddy TLS).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_admin_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port =
        case os:getenv("JANUS_ADMIN_PORT") of
            PortVal when is_list(PortVal), PortVal =/= [] ->
                list_to_integer(PortVal);
            _ ->
                application:get_env(janus_admin, port, 8090)
        end,
    Bind =
        case os:getenv("JANUS_ADMIN_BIND") of
            BindVal when is_list(BindVal), BindVal =/= [] ->
                parse_ip(BindVal);
            _ ->
                parse_ip(application:get_env(janus_admin, bind, "0.0.0.0"))
        end,
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/admin/api/[...]", janus_admin_api, []},
            {"/admin", janus_admin_assets, []},
            {"/admin/[...]", janus_admin_assets, []}
        ]}
    ]),
    Session = #{
        id => janus_admin_session,
        start => {janus_admin_session, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_admin_session]
    },
    Audit = #{
        id => janus_admin_audit,
        start => {janus_admin_audit, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [janus_admin_audit]
    },
    Listener = #{
        id => janus_admin_listener,
        start => {cowboy, start_clear, [
            janus_admin_listener,
            [{port, Port}, {ip, Bind}],
            #{env => #{dispatch => Dispatch}}
        ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [cowboy]
    },
    logger:info(#{
        what => janus_admin_listen,
        bind => inet:ntoa(Bind),
        port => Port
    }),
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Session, Audit, Listener]}}.

parse_ip(Bin) when is_binary(Bin) ->
    parse_ip(binary_to_list(Bin));
parse_ip(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Ip} -> Ip;
        {error, _} -> {127, 0, 0, 1}
    end.
