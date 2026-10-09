%%% @doc Master-side worker pool (spec §3.4 / §6).
%%%
%%% Tracks hello'd workers, drain → sticky transitions, and selection
%%% (affinity then least-in-flight / name-order). Pure state helpers are
%%% exported for eunit; the gen_server owns timers, `monitor_nodes`, and
%%% sticky persistence in `worker_sticky_drained`.
-module(janus_worker_pool).
-behaviour(gen_server).

-export([
    start_link/0,
    pick/1,
    available/0,
    undrain/1,
    note_inflight/2,
    drain_idle_ms/0
]).

%% Pure state machine (eunit — no net/DB).
-export([
    new_pool/1,
    apply_hello/3,
    apply_drain/2,
    apply_nodedown/2,
    apply_undrain/2,
    apply_inflight/3,
    apply_drain_idle/2,
    select/2,
    available/1,
    is_sticky/2,
    is_draining/2,
    is_member/2,
    inflight/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DRAIN_IDLE_MS, 30_000).
-define(VSN, 1).

-record(state, {
    pool :: map(),
    timers = #{} :: #{node() => reference()}
}).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec pick(map()) -> {ok, node()} | empty.
pick(Opts) when is_map(Opts) ->
    gen_server:call(?SERVER, {pick, Opts}).

-spec available() -> non_neg_integer().
available() ->
    gen_server:call(?SERVER, available).

-spec undrain(node()) -> ok.
undrain(Node) when is_atom(Node) ->
    gen_server:call(?SERVER, {undrain, Node}).

-spec note_inflight(node(), 1 | -1) -> ok.
note_inflight(Node, Delta) when is_atom(Node), (Delta =:= 1 orelse Delta =:= -1) ->
    gen_server:cast(?SERVER, {note_inflight, Node, Delta}).

-spec drain_idle_ms() -> pos_integer().
drain_idle_ms() ->
    ?DRAIN_IDLE_MS.

%%%===================================================================
%%% Pure pool (BINDING interfaces for eunit)
%%%===================================================================

-spec new_pool([node()]) -> map().
new_pool(StickyNodes) when is_list(StickyNodes) ->
    Sticky = maps:from_list([{N, true} || N <- StickyNodes, is_atom(N)]),
    #{members => #{}, sticky => Sticky}.

-spec apply_hello(map(), node(), map()) ->
    {ack | {nack, drained | vsn}, map()}.
apply_hello(Pool, Node, Meta) when is_map(Pool), is_atom(Node), is_map(Meta) ->
    case maps:get(vsn, Meta, undefined) of
        ?VSN ->
            case maps:is_key(Node, maps:get(sticky, Pool)) of
                true ->
                    {{nack, drained}, Pool};
                false ->
                    Region = maps:get(region, Meta, undefined),
                    Members0 = maps:get(members, Pool),
                    case maps:find(Node, Members0) of
                        {ok, #{draining := true} = M} ->
                            %% Ack but stay draining (not re-activated).
                            Members1 = Members0#{Node => M#{region => Region}},
                            {ack, Pool#{members => Members1}};
                        {ok, M} ->
                            Members1 = Members0#{Node => M#{region => Region}},
                            {ack, Pool#{members => Members1}};
                        error ->
                            Member = #{
                                region => Region,
                                inflight => 0,
                                draining => false
                            },
                            {ack, Pool#{members => Members0#{Node => Member}}}
                    end
            end;
        _ ->
            {{nack, vsn}, Pool}
    end.

-spec apply_drain(map(), node()) -> {map(), boolean()}.
apply_drain(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{draining := true}} ->
            {Pool, false};
        {ok, #{inflight := In} = M} ->
            Members1 = Members0#{Node => M#{draining => true}},
            {Pool#{members => Members1}, In =:= 0};
        error ->
            {Pool, false}
    end.

-spec apply_nodedown(map(), node()) -> map().
apply_nodedown(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    %% Draining nodedown is NOT sticky (spec §3.4).
    Pool#{members => maps:remove(Node, Members0)}.

-spec apply_undrain(map(), node()) -> map().
apply_undrain(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Sticky0 = maps:get(sticky, Pool),
    Pool#{sticky => maps:remove(Node, Sticky0)}.

-spec apply_inflight(map(), node(), 1 | -1) -> {map(), boolean()}.
apply_inflight(Pool, Node, Delta) when
    is_map(Pool), is_atom(Node), (Delta =:= 1 orelse Delta =:= -1)
->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{inflight := In0, draining := Draining} = M} ->
            In1 = max(0, In0 + Delta),
            Members1 = Members0#{Node => M#{inflight => In1}},
            StartIdle = Draining andalso In1 =:= 0 andalso In0 =/= 0,
            {Pool#{members => Members1}, StartIdle};
        error ->
            {Pool, false}
    end.

-spec apply_drain_idle(map(), node()) -> {map(), boolean()}.
apply_drain_idle(Pool, Node) when is_map(Pool), is_atom(Node) ->
    Members0 = maps:get(members, Pool),
    case maps:find(Node, Members0) of
        {ok, #{draining := true, inflight := 0}} ->
            Sticky1 = maps:put(Node, true, maps:get(sticky, Pool)),
            {
                Pool#{
                    members => maps:remove(Node, Members0),
                    sticky => Sticky1
                },
                true
            };
        _ ->
            {Pool, false}
    end.

-spec select(map(), map()) -> {ok, node()} | empty.
select(Pool, Opts) when is_map(Pool), is_map(Opts) ->
    Candidates = dispatchable(Pool),
    case Candidates of
        [] ->
            empty;
        _ ->
            AffinityNode = maps:get(affinity_node, Opts, undefined),
            RegionTag = maps:get(region_tag, Opts, undefined),
            Matched =
                case AffinityNode of
                    N when is_atom(N) ->
                        case lists:keyfind(N, 1, Candidates) of
                            {N, _} = Hit -> [Hit];
                            false -> []
                        end;
                    _ ->
                        []
                end,
            Chosen =
                case Matched of
                    [_ | _] ->
                        Matched;
                    [] when RegionTag =/= undefined, RegionTag =/= <<>> ->
                        case
                            [
                                {N, M}
                             || {N, M} <- Candidates,
                                maps:get(region, M, undefined) =:= RegionTag
                            ]
                        of
                            [] -> Candidates;
                            RegionHits -> RegionHits
                        end;
                    [] ->
                        Candidates
                end,
            least_inflight(Chosen)
    end.

-spec available(map()) -> non_neg_integer().
available(Pool) when is_map(Pool) ->
    length(dispatchable(Pool)).

-spec is_sticky(map(), node()) -> boolean().
is_sticky(Pool, Node) ->
    maps:is_key(Node, maps:get(sticky, Pool)).

-spec is_draining(map(), node()) -> boolean().
is_draining(Pool, Node) ->
    case maps:find(Node, maps:get(members, Pool)) of
        {ok, #{draining := D}} -> D;
        error -> false
    end.

-spec is_member(map(), node()) -> boolean().
is_member(Pool, Node) ->
    maps:is_key(Node, maps:get(members, Pool)).

-spec inflight(map(), node()) -> non_neg_integer().
inflight(Pool, Node) ->
    case maps:find(Node, maps:get(members, Pool)) of
        {ok, #{inflight := N}} -> N;
        error -> 0
    end.

dispatchable(#{members := Members}) ->
    [
        {N, M}
     || {N, #{draining := false} = M} <- maps:to_list(Members)
    ].

least_inflight(Candidates) ->
    Sorted = lists:sort(
        fun({N1, #{inflight := I1}}, {N2, #{inflight := I2}}) ->
            {I1, N1} =< {I2, N2}
        end,
        Candidates
    ),
    case Sorted of
        [{N, _} | _] -> {ok, N};
        [] -> empty
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    Sticky = load_sticky(),
    _ = maybe_monitor_nodes(),
    logger:info(#{what => janus_worker_pool_started, sticky_count => length(Sticky)}),
    {ok, #state{pool = new_pool(Sticky)}}.

handle_call({pick, Opts}, _From, #state{pool = Pool} = State) ->
    {reply, select(Pool, Opts), State};
handle_call(available, _From, #state{pool = Pool} = State) ->
    {reply, available(Pool), State};
handle_call({undrain, Node}, _From, #state{pool = Pool} = State) ->
    ok = sticky_delete(Node),
    Pool1 = apply_undrain(Pool, Node),
    State1 = cancel_timer(Node, State#state{pool = Pool1}),
    {reply, ok, State1};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({note_inflight, Node, Delta}, State) ->
    {noreply, do_inflight(Node, Delta, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({janus_worker_hello, From, Node, Meta}, State) when is_pid(From), is_atom(Node) ->
    {noreply, do_hello(From, Node, Meta, State)};
handle_info({janus_worker_drain, Node}, State) when is_atom(Node) ->
    {noreply, do_drain(Node, State)};
handle_info({drain_idle, Node}, State) when is_atom(Node) ->
    {noreply, do_drain_idle(Node, State)};
handle_info({nodedown, Node}, State) ->
    {noreply, do_nodedown(Node, State)};
handle_info({nodedown, Node, _Info}, State) ->
    {noreply, do_nodedown(Node, State)};
handle_info({nodeup, _Node}, State) ->
    {noreply, State};
handle_info({nodeup, _Node, _Info}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal — gen_server actions
%%%===================================================================

do_hello(From, Node, Meta, #state{pool = Pool} = State) ->
    {Verdict, Pool1} = apply_hello(Pool, Node, normalize_hello_meta(Meta)),
    case Verdict of
        ack ->
            From ! janus_worker_wire:hello_ack(Node);
        {nack, Reason} ->
            {ok, Nack} = janus_worker_wire:hello_nack(Node, Reason),
            From ! Nack
    end,
    State#state{pool = Pool1}.

do_drain(Node, #state{pool = Pool} = State) ->
    {Pool1, StartIdle} = apply_drain(Pool, Node),
    State1 = State#state{pool = Pool1},
    maybe_arm_idle(Node, StartIdle, State1).

do_inflight(Node, Delta, #state{pool = Pool} = State) ->
    {Pool1, StartIdle} = apply_inflight(Pool, Node, Delta),
    State1 = State#state{pool = Pool1},
    case StartIdle of
        true ->
            maybe_arm_idle(Node, true, State1);
        false ->
            %% Inflight rose while draining — cancel pending idle clock.
            case inflight(Pool1, Node) > 0 of
                true -> cancel_timer(Node, State1);
                false -> State1
            end
    end.

do_drain_idle(Node, #state{pool = Pool} = State0) ->
    State = forget_timer(Node, State0),
    {Pool1, BecameSticky} = apply_drain_idle(Pool, Node),
    case BecameSticky of
        true ->
            ok = sticky_insert(Node),
            logger:info(#{what => janus_worker_pool_sticky, node => Node}),
            State#state{pool = Pool1};
        false ->
            State#state{pool = Pool1}
    end.

do_nodedown(Node, #state{pool = Pool} = State) ->
    Pool1 = apply_nodedown(Pool, Node),
    State1 = cancel_timer(Node, State#state{pool = Pool1}),
    logger:info(#{what => janus_worker_pool_nodedown, node => Node}),
    State1.

normalize_hello_meta(Meta) when is_map(Meta) ->
    #{
        role => maps:get(role, Meta, undefined),
        vsn => maps:get(vsn, Meta, undefined),
        region => maps:get(region, Meta, undefined)
    };
normalize_hello_meta(_) ->
    #{role => undefined, vsn => undefined, region => undefined}.

maybe_arm_idle(_Node, false, State) ->
    State;
maybe_arm_idle(Node, true, State) ->
    State1 = cancel_timer(Node, State),
    TRef = erlang:send_after(drain_idle_ms(), self(), {drain_idle, Node}),
    State1#state{timers = maps:put(Node, TRef, State1#state.timers)}.

cancel_timer(Node, #state{timers = Timers} = State) ->
    case maps:take(Node, Timers) of
        {TRef, Timers1} ->
            _ = erlang:cancel_timer(TRef),
            %% Drain any already-delivered message.
            receive
                {drain_idle, Node} -> ok
            after 0 ->
                ok
            end,
            State#state{timers = Timers1};
        error ->
            State
    end.

forget_timer(Node, #state{timers = Timers} = State) ->
    State#state{timers = maps:remove(Node, Timers)}.

maybe_monitor_nodes() ->
    case net_kernel:monitor_nodes(true) of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning(#{what => janus_worker_pool_monitor_nodes, reason => Reason}),
            ok
    end.

%%%===================================================================
%%% Sticky persistence (worker_sticky_drained)
%%%===================================================================

load_sticky() ->
    case q(<<"SELECT node_name FROM worker_sticky_drained">>, []) of
        {ok, Rows} ->
            [row_node(R) || R <- Rows];
        {error, Reason} ->
            logger:warning(#{what => janus_worker_pool_sticky_load_failed, reason => Reason}),
            []
    end.

sticky_insert(Node) ->
    Name = node_name_bin(Node),
    case
        q(
            <<
                "INSERT INTO worker_sticky_drained (node_name) VALUES (?) "
                "ON CONFLICT (node_name) DO NOTHING"
            >>,
            [Name]
        )
    of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{
                what => janus_worker_pool_sticky_insert_failed,
                node => Node,
                reason => Reason
            }),
            ok
    end.

sticky_delete(Node) ->
    Name = node_name_bin(Node),
    case q(<<"DELETE FROM worker_sticky_drained WHERE node_name = ?">>, [Name]) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{
                what => janus_worker_pool_sticky_delete_failed,
                node => Node,
                reason => Reason
            }),
            ok
    end.

node_name_bin(Node) when is_atom(Node) ->
    atom_to_binary(Node, utf8).

row_node([Name]) ->
    row_node(Name);
row_node({Name}) ->
    row_node(Name);
row_node(Name) when is_binary(Name) ->
    binary_to_atom(Name, utf8);
row_node(Name) when is_list(Name) ->
    list_to_atom(Name);
row_node(Name) when is_atom(Name) ->
    Name.

q(Sql, Params) ->
    try
        case janus_db_conn:backend() of
            postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
            _ -> janus_db_conn:query(Sql, Params)
        end
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

rewrite_pg(Sql) ->
    rewrite_pg(Sql, 1).

rewrite_pg(<<"?", Rest/binary>>, N) ->
    <<"$", (integer_to_binary(N))/binary, (rewrite_pg(Rest, N + 1))/binary>>;
rewrite_pg(<<C, Rest/binary>>, N) ->
    <<C, (rewrite_pg(Rest, N))/binary>>;
rewrite_pg(<<>>, _N) ->
    <<>>.
