%%%-------------------------------------------------------------------
%%% @doc Read-only runtime snapshot for the dashboard's observer view
%%% (the `runtime_snapshot` fleet command). Zero arguments on purpose:
%%% the command registry maps the name to ONE pure introspection call —
%%% there is no arbitrary-MFA surface here.
%%%
%%% Nothing about the deployment is hardcoded: supervision roots are
%%% DISCOVERED from the running system (application:which_applications()
%%% -> application:get_key(App, supervisor)), the role comes from
%%% janus_role, peers from nodes(). The result is strictly JSON-safe
%%% (binaries / integers / floats / booleans / null / maps / lists) so
%%% thoas encodes it verbatim and the HTTP layer's is_json_deep gate
%%% passes it through structured instead of formatting it as ~p text.
%%%
%%% Cost bounds: the tree walk is capped (depth and total entries) and
%%% the process scan is two process_info reads per process. This is an
%%% on-demand operator action, not a poller.
%%%
%%% The node-global erlang:system_monitor slot is NEVER touched here —
%%% it belongs to janus_dist_monitor.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_runtime).

-export([snapshot/0]).

-define(MAX_DEPTH, 5).
-define(MAX_ENTRIES, 400).
-define(TOP_N, 10).

%%%===================================================================
%%% API
%%%===================================================================

-spec snapshot() -> map().
snapshot() ->
    #{
        sup_tree => sup_tree(),
        memory => memory_json(),
        process_count => erlang:system_info(process_count),
        port_count => erlang:system_info(port_count),
        ets_count => length(ets:all()),
        uptime_sec => uptime_sec(),
        run_queue_total => erlang:statistics(run_queue),
        schedulers_online => erlang:system_info(schedulers_online),
        dirty_cpu_schedulers_online => dirty_cpu_online(),
        msg_queue_top => top_processes(message_queue_len),
        memory_top => top_processes(memory),
        counters => flow_counters(),
        connected => [node_to_bin(N) || N <- lists:sort(nodes())],
        role => role_bin(),
        captured_at_ms => os:system_time(millisecond)
    }.

%%%===================================================================
%%% Supervision tree — discovered, never hardcoded
%%%===================================================================
%%%
%%% There is no documented "give me app X's supervisor" API, so the tree
%%% is rebuilt the way observer does it: every OTP supervisor process
%%% runs supervisor:sup/1 (visible as its initial_call), and every
%%% proc_lib process carries its $ancestors — the first ancestor of a
%%% supervisor is its parent supervisor, or the application master for
%%% a tree root. Grouping supervisors by that parent yields the
%%% supervision forest with ZERO hardcoded names.

%% Returns #{roots => [tree()], truncated => boolean()}.
sup_tree() ->
    Infos = supervisor_infos(),
    State0 = #{count => 0, truncated => false},
    {Roots, State1} =
        lists:mapfoldl(
            fun(Pid, Acc) -> walk_sup(Pid, Infos, 1, Acc) end,
            State0,
            sup_roots(Infos)
        ),
    #{roots => Roots, truncated => maps:get(truncated, State1, false)}.

%% Every live supervisor: #{Pid => #{name, parent}}. parent is the pid
%% or registered name of the parent supervisor, or the app-master pid
%% (not itself a supervisor) for roots. proc_lib stores both under the
%% dollar-prefixed dictionary keys '$initial_call' / '$ancestors'.
supervisor_infos() ->
    maps:from_list(
        [begin
             Dict = pinfo(Pid, dictionary, []),
             Name = registered_name_of(Pid),
             Parent = case lists:keyfind('$ancestors', 1, Dict) of
                 {'$ancestors', [First | _]} -> First;
                 _ -> undefined
             end,
             {Pid, #{name => Name, parent => Parent}}
         end
         || Pid <- erlang:processes(),
            begin
                D = pinfo(Pid, dictionary, []),
                case lists:keyfind('$initial_call', 1, D) of
                    {'$initial_call', {supervisor, _Name, 1}} -> true;
                    _ -> false
                end
            end]
    ).

%% Forest roots: supervisors whose parent is NOT itself a supervisor in
%% the map (application masters, init, dead parents). Ancestors may
%% carry the parent's registered NAME instead of its pid — resolve
%% those through whereis before declaring the node a root.
sup_roots(Infos) ->
    maps:keys(
        maps:filter(
            fun(_Pid, #{parent := Parent}) ->
                not is_supervisor_ref(Parent, Infos)
            end,
            Infos
        )
    ).

is_supervisor_ref(Parent, Infos) when is_pid(Parent) ->
    maps:is_key(Parent, Infos);
is_supervisor_ref(Parent, Infos) when is_atom(Parent) ->
    case whereis(Parent) of
        P when is_pid(P) -> maps:is_key(P, Infos);
        undefined -> false
    end;
is_supervisor_ref(_, _Infos) ->
    false.

%% Expand one supervisor's supervisor-children (from the infos map) and
%% worker-children (from supervisor:which_children).
walk_sup(Pid, Infos, Depth, State) ->
    case over_caps(Depth, State) of
        true ->
            {[], mark_truncated(State)};
        false ->
            SupChildren = [
                ChildPid
             || {ChildPid, _} <- maps:to_list(Infos),
                is_parent_of(maps:get(parent, maps:get(ChildPid, Infos)), Pid,
                             maps:get(name, maps:get(Pid, Infos)))
            ],
            WorkerChildren =
                try supervisor:which_children(Pid) of
                    List when is_list(List) ->
                        [C || C = {_Id, ChildPid, worker, _Mods} <- List, not maps:is_key(ChildPid, Infos)];
                    _ ->
                        []
                catch
                    _:_ -> []
                end,
            {SupJson, State1} =
                lists:mapfoldl(
                    fun(ChildPid, Acc) ->
                        walk_sup(ChildPid, Infos, Depth + 1, Acc)
                    end,
                    State,
                    lists:sort(SupChildren)
                ),
            {WorkerJson, State2} =
                lists:mapfoldl(
                    fun(Child, Acc) ->
                        walk_child(Child, Acc)
                    end,
                    State1,
                    WorkerChildren
                ),
            {sup_entry(Pid, Infos, SupJson ++ WorkerJson), State2}
    end.

sup_entry(Pid, Infos, Children) ->
    Info = maps:get(Pid, Infos),
    #{
        id => entry_name(Pid, Info),
        pid => pid_to_bin(Pid),
        type => supervisor,
        queue_len => pinfo(Pid, message_queue_len, 0),
        memory => pinfo(Pid, memory, 0),
        children => Children
    }.

is_parent_of(Parent, Pid, _Name) when is_pid(Parent) -> Parent =:= Pid;
is_parent_of(Parent, _Pid, Name) when is_atom(Parent) ->
    Parent =:= Name orelse whereis(Parent) =:= _Pid;
is_parent_of(_, _, _) -> false.

entry_name(Pid, #{name := undefined}) -> pid_to_bin(Pid);
entry_name(_Pid, #{name := Name}) -> atom_to_binary(Name, utf8).

walk_child({Id, Pid, worker, _Mods}, State) ->
    State0 = bump(State),
    Entry0 = #{
        id => id_to_bin(Id),
        pid => pid_to_bin(Pid),
        type => worker,
        queue_len => pinfo(Pid, message_queue_len, 0),
        memory => pinfo(Pid, memory, 0)
    },
    Entry = case registered_name_of(Pid) of
        undefined -> Entry0#{name => null};
        Name -> Entry0#{name => atom_to_binary(Name, utf8)}
    end,
    {Entry, State0}.

bump(State) -> State#{count => maps:get(count, State, 0) + 1}.

over_caps(Depth, State) ->
    Depth > ?MAX_DEPTH orelse maps:get(count, State) >= ?MAX_ENTRIES.

mark_truncated(State) -> State#{truncated => true}.

%%%===================================================================
%%% VM stats
%%%===================================================================

memory_json() ->
    Keep = [total, processes, processes_used, system, atom, binary, code, ets],
    All = maps:from_list(erlang:memory()),
    #{
        K => maps:get(K, All, 0)
     || K <- Keep
    }.

uptime_sec() ->
    {TotalMs, _} = erlang:statistics(wall_clock),
    TotalMs div 1000.

dirty_cpu_online() ->
    case catch erlang:system_info(dirty_cpu_schedulers_online) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%%%===================================================================
%%% Top processes
%%%===================================================================

%% Top ?TOP_N live processes by Key (message_queue_len | memory).
top_processes(Key) ->
    Rows =
        [begin
             #{
                 pid => pid_to_bin(Pid),
                 name => case registered_name_of(Pid) of
                     undefined -> null;
                     Name -> atom_to_binary(Name, utf8)
                 end,
                 queue_len => pinfo(Pid, message_queue_len, 0),
                 memory => pinfo(Pid, memory, 0)
             }
         end
         || Pid <- erlang:processes()],
    SortKey = case Key of
        message_queue_len -> fun(R) -> maps:get(queue_len, R) end;
        memory -> fun(R) -> maps:get(memory, R) end
    end,
    Ranked = lists:sort(fun(A, B) -> SortKey(A) >= SortKey(B) end, Rows),
    lists:sublist(Ranked, ?TOP_N).

registered_name_of(Pid) ->
    %% pinfo unwraps the {registered_name, Name} tuple, so a named
    %% process yields the bare atom here (default = undefined).
    case pinfo(Pid, registered_name, undefined) of
        undefined -> undefined;
        Name when is_atom(Name) -> Name
    end.

pinfo(Pid, Item, Default) when is_pid(Pid) ->
    case catch erlang:process_info(Pid, Item) of
        {Item, Value} -> Value;
        _ -> Default
    end;
pinfo(_, _, Default) ->
    Default.

%%%===================================================================
%%% Flow counters (monotone — the dashboard computes rates from deltas)
%%%===================================================================

flow_counters() ->
    Http = safe(fun janus_http_stats:snapshot/0, #{}),
    Fleet = safe(fun janus_fleet:counters/0, #{}),
    Dist = safe(fun janus_dist_monitor:stats/0, #{}),
    #{
        requests_total => int_or(maps:get(requests_total, Http, 0), 0),
        requests_failed => int_or(maps:get(requests_failed, Http, 0), 0),
        signals_tx => int_or(maps:get(signals_tx, Fleet, 0), 0),
        signals_rx => int_or(maps:get(signals_rx, Fleet, 0), 0),
        dist_busy_events_total => int_or(maps:get(busy_events_total, Dist, 0), 0)
    }.

safe(Fun, Default) ->
    case catch Fun() of
        V when is_map(V) -> V;
        _ -> Default
    end.

int_or(V, _Default) when is_integer(V) -> V;
int_or(_, Default) -> Default.

%%%===================================================================
%%% JSON-safe coercions (thoas / is_json_deep never see raw terms)
%%%===================================================================

node_to_bin(N) when is_atom(N) -> atom_to_binary(N, utf8).

role_bin() ->
    case catch janus_role:get() of
        master -> <<"master">>;
        worker -> <<"worker">>;
        _ -> <<"unknown">>
    end.

id_to_bin(Id) when is_atom(Id) -> atom_to_binary(Id, utf8);
id_to_bin(Id) when is_binary(Id) -> Id;
id_to_bin(Id) -> unicode:characters_to_binary(io_lib:format("~0p", [Id])).

pid_to_bin(Pid) when is_pid(Pid) ->
    list_to_binary(pid_to_list(Pid));
pid_to_bin(Pid) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Pid])).
