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
%% Pure ingest-guard seam (reorder spec Hard sequencing — eunit).
-export([reorder_ingest/2]).
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
    %% If boot never published (DB+snapshot miss), still resolve fleet
    %% once from env so JANUS_FLEET_ENABLED keeps working offline.
    case State1#state.ready of
        true -> ok;
        false -> _ = maybe_start_fleet_once()
    end,
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
    %% F9: fleet children start once after the first settings distribute
    %% (not from a cold PT miss / env-only supervisor init).
    _ = maybe_start_fleet_once(),
    ok.

%% Hand dashboard-managed settings (settings table) to their consumers.
%% Soft dependencies — the consumer app may not be running (or loaded)
%% on this node; a missing consumer is not an error.
distribute_settings(Rows) ->
    Settings = maps:get(settings, Rows, []),
    %% Clear raw PT for keys absent from this snapshot so a deleted
    %% row returns to env-only resolve (v1 has no delete API; still
    %% correct if rows are empty on a fresh DB).
    Present = [K || #{key := K} <- Settings],
    maybe_clear_absent(Present, <<"sched">>, fun janus_sched_knobs:put_sched_raw/1),
    maybe_clear_absent(Present, <<"model_sync">>, fun janus_sched_knobs:put_model_sync_raw/1),
    maybe_clear_absent(Present, <<"fleet">>, fun janus_sched_knobs:put_fleet_raw/1),
    lists:foreach(
        fun
            (#{key := <<"failover">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        %% Same direct-PT convention as auto_router:
                        %% consumers read persistent_term, never casts.
                        persistent_term:put({janus, failover_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => failover
                        })
                end;
            (#{key := <<"sched">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        %% put_sched_raw → publish_resolved writes unary PT.
                        ok = janus_sched_knobs:put_sched_raw(Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => sched
                        })
                end;
            (#{key := <<"model_sync">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        ok = janus_sched_knobs:put_model_sync_raw(Map),
                        {Sec, _} = janus_sched_knobs:resolve_model_sync_interval(),
                        _ = (catch janus_model_sync:set_interval(Sec));
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => model_sync
                        })
                end;
            (#{key := <<"fleet">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        %% Desired only — never start/stop fleet_sup here (F5/F9).
                        ok = janus_sched_knobs:put_fleet_raw(Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => fleet
                        })
                end;
            %% Translation unblock knobs (translation spec 1.9): map
            %% {"tools": boolean} — default OFF preserves the legacy
            %% translate-blocked 400 until the operator flips it.
            (#{key := <<"translate">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        persistent_term:put({janus, translate_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => translate
                        })
                end;
            %% Modality enable knobs (spec M1.0c): map of modality
            %% name -> boolean. Missing key/all-false = all OFF (the
            %% shipped default); plugins read persistent_term.
            (#{key := <<"modality">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        persistent_term:put({janus, modality_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => modality
                        })
                end;
            %% Files API knob (2026-10-26): {"enabled": true} turns on
            %% /v1/files + file-janus-* materialization in the chat
            %% pipeline. Missing = OFF (shipped default).
            (#{key := <<"files">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        persistent_term:put({janus, files_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => files
                        })
                end;
            %% Curated per-model capability overrides (spec: janus-auto
            %% image routing). Map of public model name -> #{vision =>
            %% bool, ...}. janus_catalog:vision_capable/1 reads the PT.
            (#{key := <<"model_capabilities">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        persistent_term:put({janus, model_capabilities_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => model_capabilities
                        })
                end;
            %% Curated per-model token limits (Anthropic Models API
            %% parity). Map of public model name -> #{context_length =>
            %% int, max_output_tokens => int}. janus_catalog merges it
            %% over provider metadata and the models.dev snapshot.
            (#{key := <<"model_limits">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        persistent_term:put({janus, model_limits_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => model_limits
                        })
                end;
            %% models.dev snapshot (dashboard sync writes it): per-model
            %% community-maintained limits, joined by provider base_url.
            %% Lowest precedence in janus_catalog:listings_summary/0.
            (#{key := <<"models_dev">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        persistent_term:put({janus, models_dev_cfg}, Map);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => models_dev
                        })
                end;
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
            %% Reorder-loop knobs (reorder spec D7 / Hard sequencing).
            %% GATEWAY-SIDE INGEST GUARD: `enabled=true` is REFUSED while
            %% migration 018_usage_attempt_rows is not applied (the
            %% TF-A.0b per-attempt rows must be flowing BEFORE the loop
            %% can reorder tiers — a mixed cluster's legacy rows would
            %% bias terminal_count). Knob-only rejection (r10): log +
            %% alert + /stats counter; the REST of this payload (and
            %% every unrelated settings key) still distributes.
            (#{key := <<"auto_router_reorder">>, value := V}) ->
                case decode_json(V) of
                    {ok, Map} when is_map(Map) ->
                        {Verdict, Map1} = reorder_ingest(Map, reorder_attempt_rows()),
                        case Verdict of
                            refused ->
                                logger:error(#{
                                    what => janus_auto_reorder_enabled_refused,
                                    alert => true,
                                    reason => migration_018_not_applied
                                }),
                                bump_reorder_refused();
                            ok ->
                                ok
                        end,
                        %% NOTE (ocr medium): this PT key's consumer is
                        %% the DASHBOARD-side reorder loop (Task 2) —
                        %% it polls this flag as a pre-write mirror.
                        %% On the gateway side the refusal above IS the
                        %% enforcement; the PT write is observability
                        %% for /stats + the future loop reader.
                        persistent_term:put({janus, auto_reorder_cfg}, Map1);
                    _ ->
                        logger:warning(#{
                            what => janus_settings_bad_value, key => auto_router_reorder
                        })
                end;
            (_) ->
                ok
        end,
        Settings
    ),
    %% Even with no model_sync row, apply env/default interval once so
    %% the clamp (§9) is live without a dashboard write.
    maybe_apply_model_sync_interval(Present),
    %% Refresh cached sched resolve + unary PT (env-only boots included).
    _ = (catch janus_sched_knobs:publish_resolved()),
    ok.

maybe_clear_absent(Present, Key, PutFun) ->
    case lists:member(Key, Present) of
        true -> ok;
        false -> PutFun(undefined)
    end.

maybe_apply_model_sync_interval(Present) ->
    case lists:member(<<"model_sync">>, Present) of
        true ->
            ok;
        false ->
            {Sec, _} = janus_sched_knobs:resolve_model_sync_interval(),
            _ = (catch janus_model_sync:set_interval(Sec)),
            ok
    end.

%% Start janus_fleet_sup at most once per boot after first distribute.
maybe_start_fleet_once() ->
    case janus_role:get() of
        worker ->
            ok;
        master ->
            case persistent_term:get({janus, fleet_boot_done}, false) of
                true ->
                    ok;
                false ->
                    Enabled = janus_sched_knobs:fleet_boot_enabled(),
                    ok = janus_sched_knobs:put_fleet_effective(Enabled),
                    case Enabled of
                        true ->
                            case start_fleet_child() of
                                ok ->
                                    persistent_term:put({janus, fleet_boot_done}, true),
                                    ok;
                                {error, _} ->
                                    %% Leave boot_done false so the next
                                    %% publish can retry (ocr High).
                                    ok
                            end;
                        false ->
                            persistent_term:put({janus, fleet_boot_done}, true),
                            ok
                    end
            end
    end.

start_fleet_child() ->
    Child = #{
        id => janus_fleet_sup,
        start => {janus_fleet_sup, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => supervisor,
        modules => [janus_fleet_sup]
    },
    case supervisor:start_child(janus_core_sup, Child) of
        {ok, _} ->
            logger:info(#{what => janus_fleet_started_after_settings}),
            ok;
        {ok, _, _} ->
            logger:info(#{what => janus_fleet_started_after_settings}),
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, already_present} ->
            ok;
        {error, Reason} ->
            logger:error(#{what => janus_fleet_start_failed, reason => Reason}),
            {error, Reason}
    end.

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

%%--------------------------------------------------------------------
%% auto_router_reorder ingest guard (reorder spec Hard sequencing)
%%--------------------------------------------------------------------

%% Tolerant TF-A.0b capability read (janus_usage memoizes once true;
%% a DB hiccup reads false = refuse — fail-closed on the KNOB only).
reorder_attempt_rows() ->
    try
        janus_usage:usage_attempt_rows()
    catch
        _:_ -> false
    end.

%% PURE knob-only rejection (eunit seam): `enabled=true` with the
%% TF-A.0b marker absent -> the payload ships with `enabled => false`
%% (THE KNOB is rejected; intervals/thresholds in the same map and
%% every unrelated settings key still distribute). Anything else
%% passes through verbatim.
-spec reorder_ingest(map(), boolean()) -> {ok | refused, map()}.
reorder_ingest(#{<<"enabled">> := true} = Map, false) when is_map(Map) ->
    {refused, Map#{<<"enabled">> => false}};
reorder_ingest(Map, _AttemptRows) when is_map(Map) ->
    {ok, Map}.

%% Refusal counter (persistent_term, single writer = this gen_server —
%% serialized by the mailbox, so a plain read-modify-write is safe).
%% Surfaced as `reorder_enabled_refused_total` in /stats.
bump_reorder_refused() ->
    N =
        try
            persistent_term:get({janus, reorder_refused_total}, 0)
        catch
            _:_ -> 0
        end,
    persistent_term:put({janus, reorder_refused_total}, N + 1),
    ok.

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
