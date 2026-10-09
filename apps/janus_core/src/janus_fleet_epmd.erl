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
    start_link/0,
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
%% OTP 27 net_sup calls start_link/0 on -epmd_module; older docs said start/0.
start() ->
    {ok, spawn(fun idle/0)}.

start_link() ->
    {ok, Pid} = start(),
    true = link(Pid),
    {ok, Pid}.

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

%% Is the dialed node one of the configured static peers?
%%
%% OTP may call port_please/2 with:
%%   - full long name as Name (`'janus@host.example'`, Host ignored), or
%%   - alive name + hostname string, or
%%   - alive name + **IP tuple** after DNS (inet_tls_dist setup path).
%% Peers are stored as full long names; IP hosts cannot rebuild the
%% DNS host part, so fall back to matching the alive name prefix.
configured_peer(Name, Host) ->
    NodeStr = to_list(Name),
    case string:split(NodeStr, "@") of
        [Alive, HostPart] when Alive =/= [], HostPart =/= [] ->
            lists:member(NodeStr, peer_strings());
        [Alive] when Alive =/= [] ->
            case host_to_list(Host) of
                "" ->
                    peer_has_alive(Alive);
                HostStr ->
                    Candidate = Alive ++ "@" ++ HostStr,
                    lists:member(Candidate, peer_strings()) orelse peer_has_alive(Alive)
            end;
        _ ->
            false
    end.

peer_has_alive(Alive) ->
    Prefix = Alive ++ "@",
    lists:any(fun(P) -> lists:prefix(Prefix, P) end, peer_strings()).

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

%% Hostname forms for candidate rebuild. IP tuples return "" so the
%% caller matches on alive-name prefix instead of inventing IP long names.
host_to_list(Host) when is_list(Host) -> Host;
host_to_list(Host) when is_atom(Host) -> atom_to_list(Host);
host_to_list(Host) when is_binary(Host) -> binary_to_list(Host);
host_to_list({A, B, C, D}) when is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    "";
host_to_list(T) when is_tuple(T), tuple_size(T) =:= 8 ->
    "";
host_to_list(_) ->
    "".
