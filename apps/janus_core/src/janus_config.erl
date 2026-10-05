%%%-------------------------------------------------------------------
%%% @doc Catalog config publisher.
%%%
%%% Boot: try load from DB via `janus_db_conn` when available; otherwise
%%% leave unloaded (`ready = false`) and log. Snapshot cold-start is
%%% owned by another agent — this module does not invent it.
%%%
%%% Reload: Postgres NOTIFY-style messages + poll (default 2000 ms,
%%% `JANUS_CONFIG_POLL_MS`). Compare `config_generation`, rebuild
%%% catalog ETS, swap `persistent_term`. Never wipes LB runtime ETS.
%%%-------------------------------------------------------------------
-module(janus_config).
-behaviour(gen_server).

-export([start_link/0]).
-export([generation/0, get_catalog/0, ready/0, reload/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DEFAULT_POLL_MS, 2000).

-record(state, {
    ready = false :: boolean(),
    generation = 0 :: non_neg_integer(),
    poll_ms = ?DEFAULT_POLL_MS :: pos_integer(),
    poll_ref :: reference() | undefined,
    db_available = false :: boolean(),
    snapshot_only = false :: boolean()
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec generation() -> non_neg_integer().
generation() ->
    case janus_catalog:generation() of
        0 ->
            try
                gen_server:call(?SERVER, generation, 5000)
            catch
                exit:{noproc, _} -> 0;
                exit:{timeout, _} -> 0
            end;
        Gen ->
            Gen
    end.

-spec get_catalog() -> janus_catalog:published() | undefined.
get_catalog() ->
    janus_catalog:get().

-spec ready() -> boolean().
ready() ->
    try
        gen_server:call(?SERVER, ready, 5000)
    catch
        exit:{noproc, _} -> false;
        exit:{timeout, _} -> false
    end.

-spec reload() -> ok | {error, term()}.
reload() ->
    gen_server:call(?SERVER, reload, 30000).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([]) ->
    PollMs = poll_ms(),
    State0 = #state{poll_ms = PollMs},
    State1 = boot_load(State0),
    State = schedule_poll(State1),
    logger:info(#{
        what => janus_config_started,
        ready => State#state.ready,
        generation => State#state.generation,
        poll_ms => PollMs,
        db_available => State#state.db_available
    }),
    {ok, State}.

handle_call(generation, _From, State) ->
    {reply, State#state.generation, State};
handle_call(ready, _From, State) ->
    {reply, State#state.ready, State};
handle_call(reload, _From, State) ->
    {Reply, NewState} = do_reload(State, force),
    {reply, Reply, NewState};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll_config, State) ->
    {_Reply, State1} = do_reload(State, poll),
    {noreply, schedule_poll(State1#state{poll_ref = undefined})};
%% Postgres NOTIFY forwarded by db listener (several common shapes).
handle_info({notification, _Conn, _Pid, _Channel, <<"janus_config">>}, State) ->
    {_Reply, NewState} = do_reload(State, notify),
    {noreply, NewState};
handle_info({notification, _Conn, _Pid, <<"janus_config">>, _Payload}, State) ->
    {_Reply, NewState} = do_reload(State, notify),
    {noreply, NewState};
handle_info({epgsql, _Conn, {notification, Channel, _Payload}}, State) when
    Channel =:= <<"janus_config">>; Channel =:= janus_config
->
    {_Reply, NewState} = do_reload(State, notify),
    {noreply, NewState};
handle_info({epgsql, _Conn, {notification, _Pid, Channel, _Payload}}, State) when
    Channel =:= <<"janus_config">>; Channel =:= janus_config
->
    {_Reply, NewState} = do_reload(State, notify),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{poll_ref = Ref}) ->
    cancel_poll(Ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

boot_load(State) ->
    case try_fetch_catalog() of
        {ok, Gen, Rows} ->
            publish_catalog(Gen, Rows),
            State#state{ready = true, generation = Gen, db_available = true};
        {error, DbReason} ->
            case try_snapshot_boot() of
                {ok, Gen, Rows} ->
                    publish_catalog(Gen, Rows),
                    logger:warning(#{
                        what => janus_config_boot_from_snapshot,
                        generation => Gen,
                        db_reason => DbReason
                    }),
                    State#state{
                        ready = true,
                        generation = Gen,
                        db_available = false,
                        snapshot_only = true
                    };
                {error, SnapReason} ->
                    logger:warning(#{
                        what => janus_config_boot_not_ready,
                        db_reason => DbReason,
                        snapshot_reason => SnapReason
                    }),
                    State#state{ready = false, generation = 0, db_available = false}
            end
    end.

do_reload(State, Mode) ->
    case try_fetch_generation() of
        {ok, Gen} when Mode =:= poll, Gen =:= State#state.generation, State#state.ready ->
            {ok, State#state{db_available = true}};
        {ok, Gen} ->
            case try_fetch_rows() of
                {ok, Rows} ->
                    publish_catalog(Gen, Rows),
                    logger:info(#{
                        what => janus_config_reloaded,
                        mode => Mode,
                        generation => Gen,
                        previous => State#state.generation
                    }),
                    {ok, State#state{
                        ready = true,
                        generation = Gen,
                        db_available = true,
                        snapshot_only = false
                    }};
                {error, Reason} ->
                    logger:warning(#{
                        what => janus_config_reload_failed,
                        mode => Mode,
                        reason => Reason,
                        serving_generation => State#state.generation,
                        ready => State#state.ready
                    }),
                    {{error, Reason}, State#state{db_available = false}}
            end;
        {error, Reason} when State#state.ready ->
            %% Keep last good catalog; do not wipe.
            logger:warning(#{
                what => janus_config_db_unreachable,
                mode => Mode,
                reason => Reason,
                serving_generation => State#state.generation
            }),
            {{error, Reason}, State#state{db_available = false}};
        {error, Reason} ->
            logger:warning(#{
                what => janus_config_still_not_ready,
                mode => Mode,
                reason => Reason
            }),
            {{error, Reason}, State#state{ready = false, db_available = false}}
    end.

try_fetch_generation() ->
    call_db(get_generation, []).

try_fetch_rows() ->
    case call_db(fetch_catalog, []) of
        {ok, Rows} when is_map(Rows) ->
            {ok, Rows};
        {ok, Rows} ->
            {error, {bad_catalog, Rows}};
        {error, _} = Err ->
            Err;
        Other ->
            {error, {unexpected_fetch_catalog, Other}}
    end.

try_fetch_catalog() ->
    case try_fetch_generation() of
        {ok, Gen} ->
            case try_fetch_rows() of
                {ok, Rows} -> {ok, Gen, Rows};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

%% Soft dependency on janus_db_conn — may be wired by the DB agent later.
call_db(Fun, Args) ->
    case code:ensure_loaded(janus_db_conn) of
        {module, janus_db_conn} ->
            case erlang:function_exported(janus_db_conn, Fun, length(Args)) of
                true ->
                    try
                        apply(janus_db_conn, Fun, Args)
                    catch
                        error:undef ->
                            {error, db_api_missing};
                        Class:Reason:Stack ->
                            {error, {Class, Reason, Stack}}
                    end;
                false ->
                    {error, db_api_missing}
            end;
        {error, _} ->
            {error, db_unavailable}
    end.

poll_ms() ->
    case os:getenv("JANUS_CONFIG_POLL_MS") of
        false ->
            ?DEFAULT_POLL_MS;
        "" ->
            ?DEFAULT_POLL_MS;
        Val ->
            try
                case list_to_integer(Val) of
                    N when N > 0 -> N;
                    _ -> ?DEFAULT_POLL_MS
                end
            catch
                _:_ -> ?DEFAULT_POLL_MS
            end
    end.

schedule_poll(#state{poll_ms = Ms, poll_ref = Old} = State) ->
    cancel_poll(Old),
    Ref = erlang:send_after(Ms, self(), poll_config),
    State#state{poll_ref = Ref}.

cancel_poll(undefined) ->
    ok;
cancel_poll(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

publish_catalog(Gen, Rows) when is_integer(Gen), is_map(Rows) ->
    ok = janus_catalog:publish(Gen, janus_catalog:build(Rows)),
    _ = maybe_write_snapshot(Gen, Rows),
    _ = distribute_settings(Rows),
    ok.

%% Hand dashboard-managed settings (settings table) to their consumers.
%% Soft dependencies — the consumer app may not be running (or loaded)
%% on this node; a missing consumer is not an error.
distribute_settings(Rows) ->
    Settings = maps:get(settings, Rows, []),
    lists:foreach(
        fun
            (#{key := <<"auto_router">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        %% Write the shared persistent_term key janus_auto's
                        %% normalized/0 merges over sys.config. A direct PT
                        %% write (not a gen_server cast) is immune to start
                        %% order: janus_core boots before janus_http, and a
                        %% cast to the then-unregistered janus_auto name
                        %% would be silently dropped.
                        persistent_term:put({janus, auto_cfg_db}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => auto_router
                        })
                end;
            (_) ->
                ok
        end,
        Settings
    ).

decode_json(Bin) when is_binary(Bin) ->
    try
        thoas:decode(Bin)
    catch
        _:_ -> {error, bad_json}
    end;
decode_json(Term) when is_map(Term) ->
    {ok, Term};
decode_json(_) ->
    {error, bad_json}.

maybe_write_snapshot(Gen, Rows) ->
    case code:ensure_loaded(janus_snapshot) of
        {module, janus_snapshot} ->
            Term = snapshot_term(Gen, Rows),
            case janus_snapshot:write_snapshot(Term) of
                ok ->
                    ok;
                {error, Reason} ->
                    logger:debug(#{what => janus_snapshot_write_skipped, reason => Reason}),
                    ok
            end;
        {error, _} ->
            ok
    end.

snapshot_term(Gen, Rows) ->
    maps:merge(Rows, #{generation => Gen}).

try_snapshot_boot() ->
    case code:ensure_loaded(janus_snapshot) of
        {module, janus_snapshot} ->
            case janus_snapshot:load_latest() of
                {ok, Catalog, Meta} ->
                    {Gen, Rows} = catalog_from_snapshot(Catalog, Meta),
                    {ok, Gen, Rows};
                {error, _} = Err ->
                    Err
            end;
        {error, _} ->
            {error, snapshot_unavailable}
    end.

catalog_from_snapshot(Catalog, Meta) when is_map(Catalog) ->
    Gen =
        case maps:get(generation, Catalog, undefined) of
            G when is_integer(G) -> G;
            _ ->
                case Meta of
                    #{generation := G} when is_integer(G) -> G;
                    _ -> 0
                end
        end,
    Rows = maps:without([generation], Catalog),
    {Gen, Rows};
catalog_from_snapshot(Catalog, Meta) ->
    Gen = maps:get(generation, Meta, 0),
    {Gen, Catalog}.
