%%%-------------------------------------------------------------------
%%% @doc Closed-enum fleet command registry (spec Part F.1): the admin
%%% plane's POST /stats/fleet/command maps each name to ONE exported,
%%% audited, idempotent MFA — never arbitrary module:function:args.
%%% Growing the enum requires a spec revision (auditable drift, F.3).
%%%
%%% Mechanics: local arg validation BEFORE any fan-out; a
%%% `function_exported` precheck (version-skew defense); parallel
%%% erpc fan-out with per-command timeouts; the LOCAL node executes
%%% via direct call (never erpc-to-self); partial success is success
%%% (advisory cluster — no quorum, ever); every command is audited
%%% (actor = the origin node, command, per-node results, ring + metric).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_fleet_commands).

-export([
    execute/2,
    safe_call/5,
    command_names/0,
    command/1,
    mfa/1,
    timeout/1,
    valid_target/1,
    outcome/1
]).

%%%===================================================================
%%% Registry (closed enum — MFAs pinned by spec rev 11)
%%%===================================================================

-spec command_names() -> [atom()].
command_names() ->
    [fleet_status, config_reload_nudge, catalog_cache_flush, lb_cool_clear,
     worker_geo_refresh, pool_ping, runtime_snapshot].

-spec command(binary() | atom()) -> {ok, atom()} | error.
command(<<"fleet_status">>) -> {ok, fleet_status};
command(<<"config_reload_nudge">>) -> {ok, config_reload_nudge};
command(<<"catalog_cache_flush">>) -> {ok, catalog_cache_flush};
command(<<"lb_cool_clear">>) -> {ok, lb_cool_clear};
command(<<"worker_geo_refresh">>) -> {ok, worker_geo_refresh};
command(<<"pool_ping">>) -> {ok, pool_ping};
command(<<"runtime_snapshot">>) -> {ok, runtime_snapshot};
command(fleet_status) -> {ok, fleet_status};
command(config_reload_nudge) -> {ok, config_reload_nudge};
command(catalog_cache_flush) -> {ok, catalog_cache_flush};
command(lb_cool_clear) -> {ok, lb_cool_clear};
command(worker_geo_refresh) -> {ok, worker_geo_refresh};
command(pool_ping) -> {ok, pool_ping};
command(runtime_snapshot) -> {ok, runtime_snapshot};
command(_) -> error.

-spec mfa(atom()) -> {module(), atom(), arity()} | error.
mfa(fleet_status) -> {janus_fleet, status, 0};
mfa(config_reload_nudge) -> {janus_config, reload, 0};
mfa(catalog_cache_flush) -> {janus_catalog, flush, 0};
mfa(lb_cool_clear) -> {janus_lb, cool_clear, 1};
%% LOCAL-ONLY (single-node): the master-side sender validates pool
%% membership and dist-sends geo_refresh_now to the target worker's
%% janus_worker_dispatch — no peer fan-out.
mfa(worker_geo_refresh) -> {janus_worker_pool, geo_refresh, 1};
%% LOCAL-ONLY: active net_adm:ping over the EXISTING dist links — the
%% dashboard's direct TCP probe is carrier-filtered between some
%% datacenters (non-standard ports), but the master's dist mesh always
%% reaches its workers.
mfa(pool_ping) -> {janus_worker_pool, pool_ping, 0};
%% Read-only observer snapshot (sup tree + VM + flow counters). Runs on
%% EVERY node via the normal fan-out — workers have no :8090 listener,
%% so the master collects their results over erpc.
mfa(runtime_snapshot) -> {janus_runtime, snapshot, 0};
mfa(_) -> error.

%% Per-command timeouts (F.1): fleet_status 1 s/peer; the mutations
%% 10 s (config reload waits on the DB fetch).
-spec timeout(atom()) -> pos_integer().
timeout(fleet_status) -> 1000;
timeout(_) -> 10000.

%%%===================================================================
%%% Execution
%%%===================================================================

%% Arg shapes: fleet_status/nudge/flush take #{}; lb_cool_clear takes
%% #{target => LBTargetTuple} (decoded from JSON by the HTTP layer).
-spec execute(binary(), map()) ->
    {ok, #{results := #{node() => term()}, outcome := atom()}} | {error, term()}.
execute(NameBin, Arg) when is_binary(NameBin), is_map(Arg) ->
    case command(NameBin) of
        {ok, Name} ->
            case validate_arg(Name, Arg) of
                ok -> do_execute(Name, Arg);
                {error, Reason} -> {error, Reason}
            end;
        error ->
            %% Unknown name: local 400, no fan-out, counter-asserted.
            {error, unknown_command}
    end;
execute(_, _) ->
    {error, bad_request}.

validate_arg(lb_cool_clear, #{target := Target}) ->
    case valid_target(Target) of
        true -> ok;
        false -> {error, {bad_arg, target}}
    end;
validate_arg(lb_cool_clear, _) ->
    {error, {bad_arg, target}};
validate_arg(pool_ping, #{}) -> ok;
validate_arg(pool_ping, _) -> ok;
validate_arg(worker_geo_refresh, #{target := {worker, NodeBin}}) when is_binary(NodeBin) ->
    %% Existing-atom check: a connected worker's node name is already
    %% an atom on the master — typos/garbage reject here, before any
    %% send.
    try binary_to_existing_atom(NodeBin, utf8) of
        _ -> ok
    catch
        _:_ -> {error, {bad_arg, target}}
    end;
validate_arg(worker_geo_refresh, _) ->
    {error, {bad_arg, target}};
validate_arg(_, _) ->
    ok.

%% Strict local target validation: exactly the normalized LB target
%% shapes (spec rev 10 — checked before ANY fan-out).
%% Commands whose semantics are single-node: executed ONLY on the
%% originator (no fan-out — worker_geo_refresh targets ONE worker via
%% dist-send from here).
-spec local_only(atom()) -> boolean().
local_only(worker_geo_refresh) -> true;
local_only(pool_ping) -> true;
local_only(_) -> false.

-spec valid_target(term()) -> boolean().
valid_target({route, M, P}) -> M =/= undefined andalso P =/= undefined;
valid_target({route, P}) -> P =/= undefined;
valid_target({provider, P}) -> P =/= undefined;
valid_target({provider_key, K}) -> K =/= undefined;
valid_target({listing, B}) -> is_binary(B) andalso B =/= <<>>;
valid_target({worker, B}) -> is_binary(B) andalso B =/= <<>>;
valid_target(_) -> false.

do_execute(Name, Arg) ->
    {M, F, A} = mfa(Name),
    %% Ensure-loaded precheck: function_exported/3 answers false for a
    %% merely-not-yet-loaded module (eunit and cross-app callers).
    _ = code:ensure_loaded(M),
    case erlang:function_exported(M, F, A) of
        false ->
            %% Version skew on the local node: report, never crash.
            {error, not_exported};
        true ->
            Args = build_args(Name, Arg),
            Timeout = timeout(Name),
            Peers = case local_only(Name) of
                true -> [];
                false -> [P || P <- catch_peers(), P =/= node()]
            end,
            %% LOCAL node via direct call — no erpc to self (rev 11).
            Local = local_call(M, F, Args),
            Remote = fan_out(Peers, M, F, Args, Timeout),
            Results = maps:from_list([{node(), Local} | Remote]),
            Out = outcome(maps:to_list(Results)),
            ok = audit(Name, Out, Results),
            ok = originator_side_effects(Name, Arg, Out),
            {ok, #{results => Results, outcome => Out}}
    end.

build_args(lb_cool_clear, #{target := Target}) -> [Target];
build_args(worker_geo_refresh, #{target := {worker, NodeBin}}) when is_binary(NodeBin) ->
    [binary_to_existing_atom(NodeBin, utf8)];
build_args(_, _) -> [].

local_call(M, F, Args) ->
    try
        {ok, apply(M, F, Args)}
    catch
        Class:Reason -> {error, Class, Reason}
    end.

%% Parallel erpc fan-out, bounded by the per-command timeout (+1 s
%% gather slack); a straggler past the deadline reads as timeout.
%% Children send {Ref, self(), Result}; gather tracks PENDING as a
%% pid->peer map and GUARDS on it, so a stray {Ref, Pid, X} from any
%% other subsystem sharing the (request-process) mailbox can never
%% poison the results map with a pid key again.
fan_out(Peers, M, F, Args, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    Pending = maps:from_list([
        begin
            ParentRef = Ref,
            Pid = spawn(fun() -> Parent ! {ParentRef, self(), safe_call(Peer, M, F, Args, Timeout)} end),
            {Pid, Peer}
        end
     || Peer <- Peers
    ]),
    gather(Ref, Pending, erlang:monotonic_time(millisecond) + Timeout + 1000).

gather(_Ref, Pending, _Deadline) when map_size(Pending) =:= 0 ->
    [];
gather(Ref, Pending, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    Left = erlang:max(0, Deadline - Now),
    receive
        {Ref, ChildPid, Result} when is_map_key(ChildPid, Pending) ->
            Peer = maps:get(ChildPid, Pending),
            [{Peer, Result} | gather(Ref, maps:remove(ChildPid, Pending), Deadline)]
    after Left ->
        [{maps:get(P, Pending), {error, timeout}} || P <- maps:keys(Pending)]
    end.

%% erpc raises error:{erpc, Reason} — normalized FIRST; other classes
%% pass through as {error, Class, Reason}. Common classes (F.1/F.7):
%% undef (version skew), noconnection (peer down), timeout (peer
%% PAUSED — TCP alive, no answer).
-spec safe_call(node(), module(), atom(), [term()], pos_integer()) ->
    {ok, term()} | {error, term()} | {error, term(), term()}.
safe_call(Peer, M, F, A, Timeout) ->
    try
        {ok, erpc:call(Peer, M, F, A, Timeout)}
    catch
        error:{erpc, Reason} -> {error, Reason};
        Class:Reason -> {error, Class, Reason}
    end.

-spec outcome([{node(), term()}]) -> ok | partial | error.
outcome(Results) when is_list(Results) ->
    Oks = [R || {R, {ok, _}} <- Results],
    case {Oks, Results} of
        {[], []} -> ok;
        {[], _} -> error;
        {_, _} when length(Oks) =:= length(Results) -> ok;
        {_, _} -> partial
    end.

audit(Name, Outcome, Results) ->
    NameBin = name_bin(Name),
    ok = catch_ok(fun() -> janus_fleet:record_command(NameBin, Results) end),
    ok = catch_ok(fun() -> janus_fleet:bump({cmd_outcome, NameBin, Outcome}) end),
    logger:info(#{
        what => janus_fleet_command,
        command => NameBin,
        outcome => Outcome,
        results => Results
    }),
    ok.

%% lb_cool_purge is published ONCE by the command originator only
%% (rev 11); the originator also purges its own mirror directly (the
%% broadcast is self-excluded by construction).
originator_side_effects(lb_cool_clear, #{target := Target}, _) ->
    catch_ok(fun() -> janus_fleet:local_cool_purge(Target) end),
    catch_ok(fun() -> janus_fleet:publish({lb_cool_purge, Target}) end),
    ok;
originator_side_effects(_, _, _) ->
    ok.

catch_ok(Fun) ->
    _ = (catch Fun()),
    ok.

catch_peers() ->
    case catch janus_fleet:peers() of
        L when is_list(L), L =/= [] ->
            L;
        _ ->
            %% Fleet ring disabled (or empty): the dist mesh itself still
            %% knows who is connected — without this fallback every
            %% fan-out command silently degrades to master-only on a
            %% ring-less deployment.
            nodes()
    end.

name_bin(Name) when is_atom(Name) -> atom_to_binary(Name, utf8);
name_bin(Name) when is_binary(Name) -> Name.
