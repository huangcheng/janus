%%%-------------------------------------------------------------------
%%% @doc Static EPMD replacement (spec Part A, `-epmd_module
%%% janus_fleet_epmd -start_epmd false`): no daemon, port 4369 is
%%% never bound; every node listens on the single pinned
%%% `$JANUS_FLEET_DIST_PORT`, and name resolution is a static map over
%%% the configured peer set. This module runs before any janus process
%%% (the kernel loads it at dist start), so it reads env directly via
%%% os:getenv/1. Callback signatures mirror erl_epmd (OTP 27).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_fleet_epmd).

-export([
    start/0,
    stop/0,
    register_node/2,
    register_node/3,
    port_please/2,
    port_please/3,
    names/0,
    names/1,
    address_please/2,
    address_please/3,
    listen_port_please/2
]).

-define(DEFAULT_DIST_PORT, 25672).
-define(PORT_PLEASE_TIMEOUT, 5000).

%% No-op process: the kernel only needs start/stop to succeed.
start() ->
    {ok, spawn(fun idle/0)}.

idle() ->
    receive
        stop -> ok
    end.

stop() ->
    ok.

%% Creation is static 1 (accepted residual, spec Part A): a restart
%% incarnation is indistinguishable via Creation — harmless because
%% connections are (re)built by the janus_fleet connector loop and no
%% EPMD registrations exist to go stale.
register_node(_Name, _Port) ->
    {ok, 1}.

register_node(_Name, _Port, _Driver) ->
    {ok, 1}.

%% The third element of port_please's reply is the DISTRIBUTION
%% PROTOCOL VERSION (OTP 27 = 6), not the EPMD creation.
port_please(Name, Host) ->
    port_please(Name, Host, ?PORT_PLEASE_TIMEOUT).

port_please(Name, Host, _Timeout) ->
    case configured_peer(Name, Host) of
        true -> {port, dist_port(), 6};
        false -> {error, noport}
    end.

names() ->
    {ok, []}.

names(_Host) ->
    {ok, []}.

address_please(Name, Host) ->
    address_please(Name, Host, inet).

address_please(_Name, Host, Family) when Family =:= inet; Family =:= inet6 ->
    inet:getaddr(Host, Family);
address_please(_Name, _Host, _Family) ->
    {error, address}.

listen_port_please(_Name, _Host) ->
    {ok, dist_port()}.

%%%===================================================================
%%% Internal
%%%===================================================================

dist_port() ->
    case os:getenv("JANUS_FLEET_DIST_PORT") of
        Val when is_list(Val), Val =/= [] ->
            try
                case list_to_integer(Val) of
                    N when is_integer(N), N > 0, N < 65536 -> N;
                    _ -> ?DEFAULT_DIST_PORT
                end
            catch
                _:_ -> ?DEFAULT_DIST_PORT
            end;
        _ ->
            ?DEFAULT_DIST_PORT
    end.

%% Is the dialed node one of the configured static peers? Accept the
%% full node name in atom or list form; the entrypoint-rendered peer
%% list is the single source (exact-string host matching).
configured_peer(Name, Host) ->
    NodeStr = to_list(Name),
    HostStr = to_list(Host),
    Candidate =
        case string:split(NodeStr, "@") of
            [_Alive, _Host] -> NodeStr;
            [Alive] when Alive =/= [] -> Alive ++ "@" ++ HostStr;
            _ -> ""
        end,
    Candidate =/= "" andalso lists:member(Candidate, peer_strings()).

peer_strings() ->
    case os:getenv("JANUS_FLEET_PEERS") of
        Val when is_list(Val), Val =/= [] ->
            [string:trim(P) || P <- string:split(Val, ",", all)];
        _ ->
            []
    end.

to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(L) when is_list(L) -> L;
to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(_) -> "".
