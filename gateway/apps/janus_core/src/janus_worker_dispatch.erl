%%% @doc Worker-side job intake (spec §3.2 / §3.4 / §4).
%%%
%%% Registers as `janus_worker_dispatch`. Hellos the master pool until
%%% ack/nack, then spawns per-job `janus_worker_session` processes.
%%% Control for unknown JobRefs is dropped; cancel for a known job is
%%% forwarded to its session (covers the pre-ack orphan cancel path).
%%%
%%% Scheduler v2 (Task C, spec rev 10 Part 0.5 / A.3): hello carries
%%% the ADDITIVE `capacity` (`JANUS_WORKER_CAPACITY`; unset => key
%%% omitted => master defaults infinity) and `sched_v => 2` markers.
%%% After ack the dispatcher runs a 60 s KEEPALIVE re-hello (plain
%%% hello, idempotent admit — an adopted-pool master must be
%%% re-hello'd by every worker) and monitors the master pool process
%%% by its registered name — owner death (dist still up) triggers an
%%% IMMEDIATE re-hello. The dispatcher also owns the worker's
%%% per-provider passive EWMA (sessions report successful non-internal
%%% durations via `{job_duration, ProviderId, Ms}` — the EWMA must
%%% survive across per-job sessions) and emits the 30 s COALESCED
%%% load cast, sent when the aggregate EWMA moved > 20 % since the
%%% last report (storm-bounded, spec A.3) OR — D9 (Task C, spec
%%% 2026-10-12-wire-compression) — while the worker's own wire-enc env
%%% gate is on and the codec counters are non-empty: workers run no
%%% `:8090`, so the load cast is their ONLY telemetry path (additive
%%% `wire_enc` key; old masters drop it via the `{sched, 2, _}`
%%% tolerance). The env gate — NOT table emptiness — is the switch:
%%% the identity out-legs bump the table even with compression off
%%% (D9 partition symmetry), and knob-off behavior must stay
%%% byte-identical (`wire_enc_relay_due/1`).
%%%
%%% Wire compression (spec 2026-10-12-wire-compression F1/D10-D12):
%%% the dispatcher owns the worker's ENCODE capability — per-dist-
%%% session state set from each hello ack (`wire_enc => [zlib]` AND
%%% the worker env gate), reset on master/pool loss, threaded into
%%% spawned sessions. Boot wiring (env snapshot, D11 self-check,
%%% counters-table ownership) rides `boot_wire_enc/0`.
-module(janus_worker_dispatch).
-behaviour(gen_server).

-export([start_link/0, hello_retry_ms/0, keepalive_ms/0, load_report_ms/0]).

%% Pure helpers (eunit).
-export([
    capacity_opt/1,
    hello_opts/1,
    hello_opts/3,
    should_report_load/2,
    should_send_load/3,
    wire_enc_relay_due/1,
    aggregate_ewma/1,
    %% Wire compression capability cell (spec 2026-10-12-wire-
    %% compression F1/D12): ack meta x env gate => identity | zlib.
    ack_wire_enc/2
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
%% BINDING: fixed 1s hello retry (spec pinned numerics; no backoff).
-define(HELLO_RETRY_MS, 1000).
%% Flap backoff (2026-10-25 incident): a SECOND master/pool loss
%% before any keepalive re-ack escalates the reconnect delay
%% exponentially with +-20% jitter; a single transient drop keeps the
%% immediate re-hello (the spec's fast reconnect is unchanged for the
%% normal case). Two processes claiming one node name (duplicate
%% bare/docker deployment on a host) otherwise wage a takeover war at
%% ~100 Hz; with backoff the combined rate settles under ~2/s.
-define(FLAP_BACKOFF_CAP_MS, 30_000).
%% BINDING (spec Part 0.5 / A.3): 60 s keepalive hello; 30 s coalesced
%% load cast. Overridable via env for tests only.
-define(KEEPALIVE_MS, 60_000).
-define(LOAD_REPORT_MS, 30_000).
%% Load-cast suppression: report only when the aggregate EWMA moved
%% more than 20 % since the last report (spec A.3).
-define(LOAD_MOVE_RATIO, 0.20).

-record(state, {
    master_node :: node(),
    region :: binary() | undefined,
    hello = connecting :: connecting | helloing | acked | nacked,
    hello_timer :: reference() | undefined,
    %% Scheduler v2 timers/monitors (Task C).
    keepalive_timer = undefined :: reference() | undefined,
    load_timer = undefined :: reference() | undefined,
    pool_mon = undefined :: reference() | undefined,
    %% ProviderId => EwmaMs — the per-provider passive upstream EWMA.
    ewma = #{} :: map(),
    %% Aggregate EWMA at the last load cast (undefined = never sent).
    last_report = undefined :: number() | undefined,
    %% Capacity observability: one load cast at boot so the
    %% master sees mem_self even before this worker serves its
    %% first job (an idle since-restart worker otherwise never
    %% reports — EWMA suppression has no baseline to move).
    load_boot_sent = false :: boolean(),
    %% JobRef => session pid
    jobs = #{} :: #{binary() => pid()},
    %% MonitorRef => JobRef
    mons = #{} :: #{reference() => binary()},
    %% Geo-affinity (spec 2026-10-11 D4/D18): the last winning egress
    %% discovery entry `#{source, ip|region, fetched_at}` (undefined =
    %% never discovered / knob off). Stale-entry aging happens at
    %% hello-build time (hello_opts/3 checks the retain window), so a
    %% failed chain keeps riding the last-known result until it ages
    %% out — exactly the D18 retain rule.
    geo = undefined :: map() | undefined,
    %% gw-echo health counters (echo_ok/echo_fail — observability ONLY,
    %% never eviction): updated by the discovery runner's reply.
    echo = #{} :: map(),
    %% true while a spawned discovery run is in flight (spawn guard).
    geo_inflight = false :: boolean(),
    %% true after an operator-initiated geo_refresh_now: the next
    %% geo_discovered reply re-hellos IMMEDIATELY (the keepalive hello
    %% would otherwise carry the fresh entry up to 60 s later).
    geo_manual = false :: boolean(),
    %% Wire compression capability (spec 2026-10-12-wire-compression
    %% F1): zlib ONLY while the ack for the CURRENT dist session
    %% advertised it AND this worker's env gate is on. Re-read from
    %% every ack (keepalive re-acks refresh it), reset to identity on
    %% master/pool loss — per-master-session state, NEVER cached across
    %% sessions and never persistent_term (F1 pin). Appended last so
    %% the eunit state_field positions stay valid.
    wire_enc = identity :: identity | zlib,
    %% Consecutive master/pool losses since the last keepalive re-ack
    %% (the stability proof — a mid-war ack dies long before 60 s).
    %% 1 => immediate reconnect (legacy path); >=2 => flap backoff.
    flaps = 0 :: non_neg_integer()
}).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec hello_retry_ms() -> pos_integer().
hello_retry_ms() ->
    ?HELLO_RETRY_MS.

%% 60 s keepalive re-hello after ack (spec Part 0.5). Test seam only.
-spec keepalive_ms() -> pos_integer().
keepalive_ms() ->
    env_pos_int("JANUS_WORKER_KEEPALIVE_MS", ?KEEPALIVE_MS).

%% 30 s coalesced load-cast interval (spec A.3). Test seam only.
-spec load_report_ms() -> pos_integer().
load_report_ms() ->
    env_pos_int("JANUS_WORKER_LOAD_REPORT_MS", ?LOAD_REPORT_MS).

%%%===================================================================
%%% Pure helpers (eunit)
%%%===================================================================

%% `JANUS_WORKER_CAPACITY` parse (spec A.5): unset => undefined (the
%% hello key is OMITTED — the master defaults to infinity); integer
%% clamped >= 1; garbage => 1. Takes the os:getenv/1 return value.
-spec capacity_opt(false | string()) -> pos_integer() | undefined.
capacity_opt(false) ->
    undefined;
capacity_opt("") ->
    undefined;
capacity_opt(Val) when is_list(Val) ->
    try
        max(1, list_to_integer(Val))
    catch
        _:_ -> 1
    end.

%% Hello opts for the wire constructor: region from
%% `JANUS_WORKER_REGION` as today + the additive scheduler v2 markers
%% (`sched_v => 2` always; `capacity` only when the env is set) + the
%% v2.1 A.3/C.3 build-provenance `git_sha` (env `JANUS_GIT_SHA` read at
%% boot; a missing build-arg stamps the literal `<<"unknown">>` — never
%% empty — so mixed-image fleets are visible in the workers array).
-spec hello_opts(binary() | undefined) -> map().
hello_opts(Region) ->
    hello_opts(Region, undefined, #{}).

%% Geo-affinity form (spec 2026-10-11 D4/D18): merges the ADDITIVE
%% egress keys (`egress_ip`/`egress_region`/`egress_source`/
%% `egress_fetched_at` — the entry is dropped wholesale when older than
%% the retain window; a stale IP never sticks) and the gw-echo health
%% counters (`echo_ok_total`/`echo_fail_total`). All keys omitted when
%% Geo is undefined (knob off / never discovered / stale) — a knob-off
%% worker's hello stays byte-identical to v2.1.
-spec hello_opts(binary() | undefined, map() | undefined, map()) -> map().
hello_opts(Region, Geo, Echo) ->
    Opts0 = #{region => Region, sched_v => 2, git_sha => git_sha_opt(os:getenv("JANUS_GIT_SHA"))},
    Opts1 = maps:merge(Opts0, geo_hello_keys(Geo)),
    Opts2 = maps:merge(Opts1, echo_hello_keys(Echo)),
    case capacity_opt(os:getenv("JANUS_WORKER_CAPACITY")) of
        undefined -> Opts2;
        Capacity -> Opts2#{capacity => Capacity}
    end.

%% Egress entry -> additive hello keys. Retain-window check is
%% time-parameterized via janus_worker_geo:fresh/3 (wall-clock unix
%% seconds — egress_fetched_at crosses nodes).
geo_hello_keys(undefined) ->
    #{};
geo_hello_keys(#{source := Source, fetched_at := At} = Entry) ->
    case janus_worker_geo:fresh(At, erlang:system_time(second), janus_worker_geo:retain_sec()) of
        false ->
            %% Stale: omit every egress key (the master reads unknown).
            #{};
        true ->
            Base = #{egress_source => atom_to_binary(Source, utf8), egress_fetched_at => At},
            maps:merge(Base, geo_value_key(Entry))
    end;
geo_hello_keys(_) ->
    #{}.

geo_value_key(#{ip := Ip}) when is_binary(Ip), Ip =/= <<>> ->
    #{egress_ip => Ip};
geo_value_key(#{region := Region}) when is_binary(Region), Region =/= <<>> ->
    #{egress_region => Region};
geo_value_key(_) ->
    #{}.

echo_hello_keys(Echo) when is_map(Echo) ->
    Opts =
        case Echo of
            #{echo_ok := Ok} when is_integer(Ok), Ok >= 0 -> #{echo_ok_total => Ok};
            _ -> #{}
        end,
    case Echo of
        #{echo_fail := Fail} when is_integer(Fail), Fail >= 0 ->
            Opts#{echo_fail_total => Fail};
        _ ->
            Opts
    end;
echo_hello_keys(_) ->
    #{}.

%% `JANUS_GIT_SHA` parse (v2.1 C.3): unset/empty => <<"unknown">>;
%% string => binary (wire validation requires a non-empty binary).
-spec git_sha_opt(false | string()) -> binary().
git_sha_opt(false) ->
    <<"unknown">>;
git_sha_opt("") ->
    <<"unknown">>;
git_sha_opt(Val) when is_list(Val) ->
    list_to_binary(Val);
git_sha_opt(_) ->
    <<"unknown">>.

%% Load-cast suppression rule (spec A.3): first report once anything
%% is measured (Last = undefined); afterwards only when the aggregate
%% EWMA moved more than 20 %. `Old = 0` cannot move by ratio — false
%% (EWMA seeds at the first positive sample, so unreachable in
%% practice).
-spec should_report_load(undefined | number(), number()) -> boolean().
should_report_load(undefined, _New) ->
    true;
should_report_load(Old, New) when is_number(Old), is_number(New), Old > 0 ->
    abs(New - Old) > ?LOAD_MOVE_RATIO * Old;
should_report_load(_Old, _New) ->
    false.

%% Send decision for the 30 s coalesced load cast (spec A.3 + the D9
%% Task C extension): {Send, ResetEwmaBaseline}. Send = the EWMA moved
%% > 20 % since the last EWMA-driven report OR the relay is due (see
%% `wire_enc_relay_due/1` — workers run no `:8090`, this cast is their
%% only counter path). ResetEwmaBaseline is true ONLY for EWMA-driven
%% sends: a counter-driven cadence must not keep resetting the > 20 %
%% baseline, or slow genuine moves would be starved by the relay (ocr
%% review pin).
-spec should_send_load(undefined | number(), undefined | number(), boolean()) ->
    {boolean(), boolean()}.
should_send_load(Last, Aggregate, RelayDue) ->
    EwmaDue = Aggregate =/= undefined andalso should_report_load(Last, Aggregate),
    {EwmaDue orelse RelayDue =:= true, EwmaDue}.

%% D9 Task C relay predicate: the counter-driven override applies ONLY
%% while THIS worker's own env gate is on AND the table is non-empty.
%% The identity out-legs bump the table even with compression OFF (D9
%% partition symmetry — janus_worker_session counts every plaintext
%% chunk/done so out matches in; the table is non-empty after ONE job,
%% forever), so non-empty ALONE would fire the load cast every tick on
%% a busy compression-off worker and void the >20 % suppression
%% fleet-wide (ocr review, medium): the env gate is the switch, table
%% emptiness is not. Reads the boot-snapshotted config (persistent_
%% term first, live env until wired).
-spec wire_enc_relay_due(map()) -> boolean().
wire_enc_relay_due(WireEnc) ->
    %% PR2 disjunct (ocr review r2): gate on SNAPSHOT CONTENT, not the
    %% env — the identity out-legs bump the table unconditionally, so
    %% an env-keyed upstream disjunct would relay every tick fleet-wide
    %% (the exact EWMA suppression wire_enc_relay_due_test pins). The
    %% only PR2 counter a worker bumps is the unsolicited-gzip signal:
    %% relay when IT is present; otherwise the internal-hop knob rules.
    UpstreamKeys = [
        {upstream_enc_unsolicited_total, {in, gzip}}
    ],
    HasUpstream = is_map(WireEnc) andalso lists:any(fun(K) -> maps:is_key(K, WireEnc) end, UpstreamKeys),
    (maps:get(enabled, janus_wire_enc:env_config(), false) orelse HasUpstream) =:= true
        andalso is_map(WireEnc) andalso map_size(WireEnc) > 0.

%% Aggregate the per-provider EWMA map into the single advisory
%% `ewma_upstream_ms` value (mean; undefined when nothing is measured
%% — no cast is sent, spec A.3).
-spec aggregate_ewma(map()) -> float() | undefined.
now_mono() ->
    erlang:monotonic_time(millisecond).

aggregate_ewma(Ewma) when is_map(Ewma) ->
    Values = [V || {_, {V, _At}} <- maps:to_list(Ewma), is_number(V)],
    case Values of
        [] -> undefined;
        _ -> lists:sum(Values) / length(Values)
    end.

%% Wire compression capability from a hello ack (spec
%% 2026-10-12-wire-compression F1): `zlib` ONLY when the ack for THIS
%% dist session advertised the codec AND the worker's own env gate is
%% on (encode is capability-gated — the two-gate spelling). A missing
%% key (old master / master env off) => identity. Malformed values
%% degrade to identity without crashing (the boundary already rejects
%% them via valid_ack_wire_enc; the consumer stays tolerant — the
%% janus_worker_wire zlib_member idiom).
-spec ack_wire_enc(map(), boolean()) -> identity | zlib.
ack_wire_enc(Meta, Enabled) when is_map(Meta), is_boolean(Enabled) ->
    case Enabled andalso advertises_zlib(maps:get(wire_enc, Meta, undefined)) of
        true -> zlib;
        false -> identity
    end;
ack_wire_enc(_NotAMap, _Enabled) ->
    identity.

%% Live form (handle_info consumer): the worker's own env gate comes
%% from the boot-snapshotted config — the two-gate spelling.
ack_wire_enc(Meta) ->
    ack_wire_enc(Meta, maps:get(enabled, janus_wire_enc:env_config(), false)).

%% No is_list guard (ocr review): the try/catch stays LIVE for
%% improper/malformed capability tails — the janus_worker_wire
%% zlib_member idiom — instead of a dead catch behind a guard that
%% already filtered every raisable input.
advertises_zlib(Codecs) ->
    try
        lists:member(zlib, Codecs)
    catch
        _:_ -> false
    end.

env_pos_int(Name, Default) ->
    case os:getenv(Name) of
        Val when is_list(Val), Val =/= "" ->
            try
                max(1, list_to_integer(Val))
            catch
                _:_ -> Default
            end;
        _ ->
            Default
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    case boot_wire_enc() of
        {stop, _} = Stop ->
            Stop;
        ok ->
            case master_node_from_env() of
                {ok, MasterNode} ->
                    Region = region_from_env(),
                    ok = maybe_monitor_nodes(),
                    State0 = #state{
                        master_node = MasterNode,
                        region = Region,
                        hello = connecting
                    },
                    %% First hello immediately; retries every hello_retry_ms.
                    State1 = do_hello_tick(State0),
                    logger:info(#{
                        what => janus_worker_dispatch_started,
                        master_node => MasterNode
                    }),
                    {ok, State1};
                {error, Reason} ->
                    {stop, Reason}
            end
    end.

%% Wire compression boot wiring (spec 2026-10-12-wire-compression
%% D10/D11, worker side): delegates to the SHARED `janus_wire_enc:boot/1`
%% (ocr review dedup — master and worker stay in lockstep) with the
%% worker's role gate: JANUS_WIRE_ENC. A default-OFF node never refuses
%% boot over an unused feature (D11); the enabled path snapshots the
%% env, runs the self-check ({stop, wire_enc_self_check_failed} — the
%% permanent-restart supervisor then exhausts and stops the node, the
%% janus_geo refuse-boot precedent), and owns the long-lived counters
%% table (per-job session processes must NOT own it — Task A's
%% ownership design).
-spec boot_wire_enc() -> ok | {stop, term()}.
boot_wire_enc() ->
    ok = warn_corrupt_test_seam(),
    %% PR2 disjunct (D11): workers run ALL provider I/O — upstream gzip
    %% decode needs the same boot-time zlib proof.
    Upstream = janus_wire_enc:upstream_enc_enabled(),
    janus_wire_enc:boot(
        maps:get(enabled, janus_wire_enc:env_config(), false) orelse Upstream
    ).

%% W.1b seam loud-boot guard (spec 2026-10-12-wire-compression §4):
%% JANUS_WIRE_ENC_CORRUPT_AFTER is TEST-ONLY — a worker booted with it
%% DELIBERATELY corrupts compressed wire traffic. Warn at every
%% dispatch boot while it is set so a prod node carrying it is visible
%% in the first log lines (the corruption itself also logs per fire on
%% the session side).
warn_corrupt_test_seam() ->
    case janus_wire_enc:corrupt_after_from_env() of
        N when is_integer(N) ->
            logger:warning(#{
                what => janus_wire_enc_corrupt_test_seam,
                env => "JANUS_WIRE_ENC_CORRUPT_AFTER",
                corrupt_after => N,
                note => "TEST-ONLY fault injection active; never set this in production"
            }),
            ok;
        undefined ->
            ok
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(hello_tick, State) ->
    {noreply, do_hello_tick(State#state{hello_timer = undefined})};
handle_info(geo_refresh_now, State) ->
    %% Fleet command worker_geo_refresh (dashboard button). Explicit
    %% operator consent: unlike the keepalive-cadence run this BYPASSES
    %% the JANUS_SCHED_WORKER_GEO knob (v1 default is zero probes; a
    %% manual ask is exactly that). One-in-flight guard still applies.
    logger:info(#{what => janus_worker_geo_refresh_now}),
    {noreply, spawn_geo_run(State#state{geo_manual = true})};
handle_info(keepalive_tick, #state{hello = acked} = State) ->
    %% Plain periodic re-hello after ack (spec Part 0.5): idempotent
    %% admit, NO load payload (the load cast keeps its own suppression
    %% rule). Any nack lands in hello_nacked (sticky, as today).
    %% Geo discovery (2026-10-11 spec D18) PIGGYBACKS this cadence but
    %% NEVER gates the hello: the hello below carries the CURRENT
    %% cached entry and a fresh discovery result rides the NEXT
    %% keepalive (a hung probe must not stall the liveness signal).
    {noreply, arm_keepalive(send_hello(maybe_spawn_geo(State)))};
handle_info(keepalive_tick, State) ->
    %% Not acked (stray tick after leaving acked): the 1 s retry loop
    %% owns reconnection; the timer re-arms at the next ack.
    {noreply, State};
handle_info({geo_discovered, {Result, Counters}}, State) ->
    %% Discovery runner reply (spawned by maybe_spawn_geo/1): refresh
    %% the egress entry (a no_layer run keeps the last-known entry —
    %% retention/aging happens at hello-build time) + the echo health
    %% counters. One info line per keepalive cadence (60 s in prod) —
    %% the chain is otherwise unobservable from the worker.
    Geo =
        case Result of
            {ok, #{source := _} = Entry} when is_map(Entry) -> Entry;
            _ -> State#state.geo
        end,
    logger:info(#{
        what => janus_worker_geo_discovered,
        result => Result,
        echo => Counters
    }),
    State1 = State#state{geo = Geo, echo = Counters, geo_inflight = false},
    case State#state.geo_manual of
        true ->
            %% Manual refresh: report NOW. send_hello is the keepalive
            %% message shape (safe while acked; the pool re-acks and
            %% re-arms its keepalive).
            {noreply, send_hello(State1#state{geo_manual = false})};
        false ->
            {noreply, State1}
    end;
handle_info(load_report_tick, #state{hello = acked} = State) ->
    {noreply, arm_load_report(maybe_send_load(State))};
handle_info(load_report_tick, State) ->
    %% Not acked (stray tick after nack / master loss): do NOT
    %% re-arm — the 1 s retry loop owns reconnection and the next
    %% ack re-arms the cadence (ocr review: an in-flight tick after
    %% cancel_sched_timers must not spin forever).
    {noreply, State#state{load_timer = undefined}};
handle_info({job_duration, ProviderId, ElapsedMs}, State) when
    is_number(ElapsedMs), ElapsedMs >= 0
->
    %% Session completion report (successful non-internal upstream
    %% duration — the session filters; internal jobs never report).
    {noreply, State#state{ewma = ewma_update(ProviderId, ElapsedMs, State#state.ewma)}};
%% Wire hello_ack/nack identify the MASTER (pool's node()). Match that
%% against master_node — the worker's own node() never appears here
%% after the 2026-10-11 pool flip (geo-affinity G.14).
handle_info({janus_worker_hello_ack, Node, Meta}, #state{master_node = Node} = State) ->
    %% Capability re-read from EVERY ack (F1): the first ack AND every
    %% keepalive re-ack refresh it; an ack without the key (old master
    %% / master restarted env-off) drops back to identity. The worker's
    %% own env gate is part of the two-gate spelling (boot-snapshotted
    %% into persistent_term by boot_wire_enc/0). ack_wire_enc/2 degrades
    %% ANY malformed Meta to identity (no guard needed here — ocr
    %% review: a guard would silently swallow the ack into the
    %% catch-all and stall the reconnect loop).
    {noreply, hello_acked(State#state{wire_enc = ack_wire_enc(Meta)})};
handle_info({janus_worker_hello_nack, Node, _Meta}, #state{master_node = Node} = State) ->
    {noreply, hello_nacked(State)};
handle_info({janus_job, JobRef, MasterSessionPid, Fields}, State) ->
    {noreply, do_job(JobRef, MasterSessionPid, Fields, State)};
handle_info({janus_cancel, JobRef}, State) when is_binary(JobRef) ->
    {noreply, do_cancel(JobRef, State)};
handle_info({'DOWN', Mon, process, _Pid, Reason}, State) ->
    case State#state.pool_mon of
        Mon ->
            %% Master pool owner death (spec Part 0.5): dist survives
            %% but the adopted pool has NO member records — immediate
            %% re-hello. The name-based monitor also fires on nodedown
            %% (noconnection), where the reconnect path below resumes.
            State1 = State#state{pool_mon = undefined},
            {noreply, master_pool_lost(State1)};
        _ ->
            case Reason of
                normal ->
                    ok;
                shutdown ->
                    ok;
                _ ->
                    JobRef = maps:get(Mon, State#state.mons, undefined),
                    logger:warning(#{
                        what => janus_worker_session_down,
                        reason => Reason,
                        monitor => Mon,
                        job_ref => JobRef
                    })
            end,
            {noreply, do_session_down(Mon, State)}
    end;
handle_info({nodedown, Node}, #state{master_node = Node} = State) ->
    {noreply, master_lost(State)};
handle_info({nodedown, Node, _Info}, #state{master_node = Node} = State) ->
    {noreply, master_lost(State)};
handle_info({nodeup, Node}, #state{master_node = Node} = State) ->
    {noreply, master_up(State)};
handle_info({nodeup, Node, _Info}, #state{master_node = Node} = State) ->
    {noreply, master_up(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{jobs = Jobs} = State) ->
    cancel_hello_timer(State),
    cancel_keepalive(State),
    cancel_load_report(State),
    _ = demonitor_pool(State),
    maps:foreach(
        fun(_JobRef, Pid) ->
            exit(Pid, shutdown)
        end,
        Jobs
    ),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Hello loop
%%%===================================================================

do_hello_tick(#state{hello = Hello} = State) when Hello =:= acked; Hello =:= nacked ->
    State;
do_hello_tick(#state{master_node = MasterNode} = State) ->
    case catch net_kernel:connect_node(MasterNode) of
        true ->
            arm_hello(send_hello(State#state{hello = helloing}));
        _Other ->
            %% Not connected yet — retry without wasting a hello send.
            arm_hello(State#state{hello = connecting})
    end.

send_hello(#state{master_node = MasterNode, region = Region, geo = Geo, echo = Echo} = State) ->
    Msg = janus_worker_wire:hello(self(), node(), hello_opts(Region, Geo, Echo)),
    try
        {janus_worker_pool, MasterNode} ! Msg
    catch
        _:_ -> ok
    end,
    State.

%% Geo discovery spawn (spec 2026-10-11 D4/D18): runs the layered
%% chain in a SEPARATE process — the probes are blocking I/O (gun GETs
%% with up to ~3 s budgets) and this gen_server also owns job intake.
%% The reply `{geo_discovered, {Result, Counters}}` refreshes the
%% cached entry; one in-flight run at a time. Knob-off (default) never
%% spawns — v1 behavior, zero probes.
maybe_spawn_geo(#state{geo_inflight = true} = State) ->
    State;
maybe_spawn_geo(#state{master_node = MasterNode, echo = Echo} = State) ->
    case janus_worker_geo:enabled() of
        true -> spawn_geo_run(State#state{master_node = MasterNode, echo = Echo});
        false -> State
    end.

%% Shared discovery spawner (keepalive-cadence + manual nudge): runs
%% the layered chain in a separate process, one in flight at a time.
spawn_geo_run(#state{geo_inflight = true} = State) ->
    State;
spawn_geo_run(#state{master_node = MasterNode, echo = Echo} = State) ->
    Parent = self(),
    _ = erlang:spawn(fun() ->
        {Result, Counters} =
            try
                janus_worker_geo:discover(MasterNode, Echo)
            catch
                Class:Reason ->
                    logger:warning(#{
                        what => janus_worker_geo_discover_crashed,
                        class => Class,
                        reason => Reason
                    }),
                    {no_layer, Echo}
            end,
        Parent ! {geo_discovered, {Result, Counters}}
    end),
    State#state{geo_inflight = true}.

hello_acked(#state{hello = acked, load_timer = TRef} = State) when
    is_reference(TRef)
->
    %% Keepalive re-ack: refresh the pool monitor + keepalive, but
    %% leave the 30 s load cadence ALONE — restarting it here would
    %% delay/skip scheduled casts around every keepalive (ocr review).
    %% A survived keepalive period is the flap-stability proof.
    State1 = cancel_hello_timer(State),
    State2 = demonitor_pool(State1),
    Mon = monitor_pool(State2#state.master_node),
    logger:debug(#{what => janus_worker_keepalive_acked, master_node => State#state.master_node}),
    arm_keepalive(State2#state{hello = acked, pool_mon = Mon, flaps = 0});
hello_acked(State) ->
    State1 = cancel_hello_timer(State),
    State2 = demonitor_pool(State1),
    Mon = monitor_pool(State2#state.master_node),
    logger:info(#{what => janus_worker_hello_acked, master_node => State#state.master_node}),
    %% First ack: keepalive re-hello + the coalesced load-cast cadence
    %% (nack / master loss cancels them).
    arm_load_report(arm_keepalive(State2#state{hello = acked, pool_mon = Mon})).

hello_nacked(State) ->
    State1 = cancel_hello_timer(cancel_sched_timers(State)),
    logger:warning(#{what => janus_worker_hello_nacked, master_node => State#state.master_node}),
    State1#state{hello = nacked}.

%% Pool owner death WITHOUT nodedown: immediate re-hello attempt (the
%% new owner admits; a not-yet-restarted owner leaves the retry loop
%% running — same shape as the nodedown path). The wire-compression
%% capability resets (F1: per-dist-session, and the pool that
%% advertised it is GONE — a new owner re-advertises or not on the
%% next ack).
master_pool_lost(#state{hello = nacked} = State) ->
    %% Sticky/vsn nack is sticky until ops undrain.
    State;
master_pool_lost(State) ->
    logger:info(#{
        what => janus_worker_master_pool_down, master_node => State#state.master_node
    }),
    reconnect_after_flap(
        reset_wire_enc(cancel_sched_timers(State#state{hello = connecting}))
    ).

master_lost(#state{hello = nacked} = State) ->
    %% Sticky/vsn nack is sticky until ops undrain; do not auto-rehello.
    State;
master_lost(State) ->
    logger:info(#{what => janus_worker_master_nodedown, master_node => State#state.master_node}),
    reconnect_after_flap(
        reset_wire_enc(cancel_sched_timers(State#state{hello = connecting}))
    ).

%% First loss since the last stable keepalive reconnects immediately
%% (the legacy fast path). Sustained flapping arms a jittered
%% exponential backoff instead — a duplicate-name takeover war then
%% converges to <= ~2 attempts/s combined instead of ~200/s, and the
%% log flood it caused (23 MB / 20 min, 2026-10-25) becomes impossible.
reconnect_after_flap(#state{flaps = Flaps} = State) ->
    Flaps1 = Flaps + 1,
    case flap_backoff_ms(Flaps1) of
        immediate ->
            do_hello_tick(State#state{flaps = Flaps1});
        DelayMs ->
            %% hello_tick runs do_hello_tick later: connect, then send
            %% (the same not-connected retry shape, on a longer fuse).
            arm_hello_after(DelayMs, State#state{flaps = Flaps1})
    end.

%% Pure: reconnect delay after Flaps losses without a keepalive
%% re-ack between them. 1 = immediate (single transient drop); >=2 =
%% 1s, 2s, 4s ... capped at ?FLAP_BACKOFF_CAP_MS, +-20% jitter so two
%% flapping twins de-synchronize instead of locking step.
-spec flap_backoff_ms(pos_integer()) -> immediate | pos_integer().
flap_backoff_ms(1) ->
    immediate;
flap_backoff_ms(Flaps) when Flaps >= 2 ->
    Base = min(1000 * (1 bsl (Flaps - 2)), ?FLAP_BACKOFF_CAP_MS),
    Jitter = 0.8 + rand:uniform() * 0.4,
    max(1, round(Base * Jitter)).

master_up(#state{hello = nacked} = State) ->
    State;
master_up(#state{hello = acked} = State) ->
    %% Dist reconnect: re-advertise (spec §3.4). hello_acked re-arms
    %% the keepalive/load cadence and the pool monitor.
    do_hello_tick(cancel_sched_timers(State#state{hello = connecting}));
master_up(State) ->
    arm_hello(State).

arm_hello(State) ->
    State1 = cancel_hello_timer(State),
    TRef = erlang:send_after(?HELLO_RETRY_MS, self(), hello_tick),
    State1#state{hello_timer = TRef}.

%% Backoff-armed hello tick (flap path): same message, longer fuse.
arm_hello_after(Ms, State) ->
    State1 = cancel_hello_timer(State),
    TRef = erlang:send_after(max(1, Ms), self(), hello_tick),
    State1#state{hello_timer = TRef}.

cancel_hello_timer(#state{hello_timer = undefined} = State) ->
    State;
cancel_hello_timer(#state{hello_timer = TRef} = State) ->
    _ = erlang:cancel_timer(TRef),
    State#state{hello_timer = undefined}.

arm_keepalive(State) ->
    State1 = cancel_keepalive(State),
    TRef = erlang:send_after(keepalive_ms(), self(), keepalive_tick),
    State1#state{keepalive_timer = TRef}.

cancel_keepalive(#state{keepalive_timer = undefined} = State) ->
    State;
cancel_keepalive(#state{keepalive_timer = TRef} = State) ->
    _ = erlang:cancel_timer(TRef),
    State#state{keepalive_timer = undefined}.

arm_load_report(State) ->
    State1 = cancel_load_report(State),
    TRef = erlang:send_after(load_report_ms(), self(), load_report_tick),
    State1#state{load_timer = TRef}.

cancel_load_report(#state{load_timer = undefined} = State) ->
    State;
cancel_load_report(#state{load_timer = TRef} = State) ->
    _ = erlang:cancel_timer(TRef),
    State#state{load_timer = undefined}.

cancel_sched_timers(State) ->
    cancel_load_report(cancel_keepalive(demonitor_pool(State))).

%% Capability reset on master/pool loss (F1): never cached across
%% sessions — no chunk is compressed pre-ack on the reconnect.
reset_wire_enc(State) ->
    State#state{wire_enc = identity}.

%%%===================================================================
%%% Master pool monitor + load cast (Task C, spec Part 0.5 / A.3)
%%%===================================================================

%% Monitor the master pool by its registered name (the ack handshake
%% is a plain send — the sender pid is not on the wire). A name-based
%% monitor fires on owner death AND on nodedown (noconnection); both
%% routes converge on the re-hello paths above.
monitor_pool(MasterNode) ->
    try
        erlang:monitor(process, {janus_worker_pool, MasterNode})
    catch
        _:_ -> undefined
    end.

demonitor_pool(#state{pool_mon = undefined} = State) ->
    State;
demonitor_pool(#state{pool_mon = Mon} = State) ->
    _ = demonitor(Mon, [flush]),
    State#state{pool_mon = undefined}.

%% Cast destination: the plain atom on the local node (the {Name,
%% Node} tuple form is silently dropped by an UNDISTRIBUTED runtime —
%% single-node dev/eunit; production always runs distributed).
pool_dest(MasterNode) when MasterNode =:= node() ->
    janus_worker_pool;
pool_dest(MasterNode) ->
    {janus_worker_pool, MasterNode}.

%% 30 s coalesced load cast (spec A.3): sent to the master pool via
%% gen_server:cast (the `{sched, 2, _}` delivery class — an old master
%% drops+counts it in the catch-all, spec Part 0.10) when acked and
%% EITHER the aggregate passive EWMA moved > 20 % since the last report
%% OR the wire-enc relay is due (D9 Task C — env gate on + non-empty
%% counters, `wire_enc_relay_due/1`; workers run no `:8090`). Nothing
%% measured and relay not due => no cast. Advisory-only on the master
%% side; the additive `wire_enc` snapshot is monotonic counters,
%% relayed latest-wins.
maybe_send_load(#state{hello = acked, master_node = MasterNode, jobs = Jobs, ewma = Ewma, last_report = Last} = State) ->
    Aggregate = aggregate_ewma(Ewma),
    WireEnc = janus_wire_enc:counters(),
    {Send0, EwmaDue} = should_send_load(Last, Aggregate, wire_enc_relay_due(WireEnc)),
    Send = Send0 orelse not State#state.load_boot_sent,
    case Send of
        true ->
            ok =
                try
                    gen_server:cast(
                        pool_dest(MasterNode),
                        {sched, 2, {load, node(), #{
                            inflight_self => maps:size(Jobs),
                            ewma_upstream_ms => Aggregate,
                            wire_enc => WireEnc,
                            %% Capacity observability (2026-10-28): beam
                            %% memory split rides the existing load
                            %% cadence — the binary/process split tells
                            %% refc-binary high-water from a live leak
                            %% (live: 2G workers bloated ~8x baseline).
                            mem_self => mem_summary()
                        }}}
                    )
                catch
                    _:_ -> ok
                end,
            case EwmaDue of
                true -> State#state{last_report = Aggregate, load_boot_sent = true};
                false -> State#state{load_boot_sent = true}
            end;
        false ->
            State
    end;
maybe_send_load(State) ->
    State.

%% MB-rounded erlang:memory split for the load report. Keys stay
%% single-letter: the report crosses the wire on every load change.
mem_summary() ->
    M = erlang:memory([total, processes, binary, ets]),
    #{
        t => mem_mb(proplists:get_value(total, M, 0)),
        p => mem_mb(proplists:get_value(processes, M, 0)),
        b => mem_mb(proplists:get_value(binary, M, 0)),
        e => mem_mb(proplists:get_value(ets, M, 0))
    }.

mem_mb(B) when is_integer(B) ->
    B div 1048576.

%% Per-provider passive EWMA (spec A.3): alpha 0.25, seeds at the
%% FIRST sample — the pure step function is shared with the master
%% pool (`janus_worker_pool:ewma_step/2`).
%% Entries carry their last-update stamp so a stray/dynamic
%% provider_id cannot grow the map without bound: past EWMA_CAP the
%% oldest entry is evicted (ocr review).
-define(EWMA_CAP, 128).

ewma_update(ProviderId, X, Ewma) when is_map(Ewma) ->
    Now = now_mono(),
    Prev =
        case maps:find(ProviderId, Ewma) of
            {ok, {E, _At}} when is_number(E) -> {E, 0};
            _ -> none
        end,
    {E1, _Count} = janus_worker_pool:ewma_step(Prev, X),
    Bounded =
        case map_size(Ewma) >= ?EWMA_CAP andalso not maps:is_key(ProviderId, Ewma) of
            true ->
                [{K, _} | _] = lists:keysort(2, maps:to_list(Ewma)),
                maps:remove(K, Ewma);
            false ->
                Ewma
        end,
    Bounded#{ProviderId => {E1, Now}}.

%%%===================================================================
%%% Jobs
%%%===================================================================

do_job(JobRef, MasterSessionPid, Fields, #state{hello = Hello} = State) when
    Hello =/= acked, is_binary(JobRef), is_pid(MasterSessionPid)
->
    logger:warning(#{
        what => janus_worker_job_rejected_not_acked,
        hello => Hello,
        job_ref => JobRef
    }),
    maybe_reject(JobRef, MasterSessionPid, not_acked),
    State;
do_job(JobRef, MasterSessionPid, Fields, #state{jobs = Jobs} = State) when
    is_binary(JobRef), is_pid(MasterSessionPid), is_map(Fields)
->
    case maps:is_key(JobRef, Jobs) of
        true ->
            logger:debug(#{
                what => janus_worker_dispatch_duplicate_job,
                job_ref => JobRef
            }),
            State;
        false ->
            case janus_worker_wire:validate({janus_job, JobRef, MasterSessionPid, Fields}) of
                ok ->
                    %% The CURRENT dist session's capability rides the
                    %% job spawn (F1): pre-ack or master-lost jobs run
                    %% identity; sessions never re-read the capability
                    %% mid-job (a mid-job ack drop must not change
                    %% already-sent framing).
                    WireEnc = State#state.wire_enc,
                    {Pid, Mon} = spawn_monitor(fun() ->
                        janus_worker_session:run(JobRef, MasterSessionPid, Fields, WireEnc)
                    end),
                    State#state{
                        jobs = Jobs#{JobRef => Pid},
                        mons = (State#state.mons)#{Mon => JobRef}
                    };
                {error, Reason} ->
                    logger:warning(#{
                        what => janus_worker_job_rejected,
                        reason => Reason
                    }),
                    maybe_reject(JobRef, MasterSessionPid, Reason),
                    State
            end
    end;
do_job(_JobRef, _MasterSessionPid, _Fields, State) ->
    State.

do_cancel(JobRef, #state{jobs = Jobs} = State) ->
    case maps:find(JobRef, Jobs) of
        {ok, Pid} ->
            Pid ! janus_worker_wire:cancel(JobRef),
            State;
        error ->
            State
    end.

do_session_down(Mon, #state{mons = Mons, jobs = Jobs} = State) ->
    case maps:take(Mon, Mons) of
        {JobRef, Mons1} ->
            State#state{
                mons = Mons1,
                jobs = maps:remove(JobRef, Jobs)
            };
        error ->
            State
    end.

maybe_reject(JobRef, MasterSessionPid, Reason) ->
    Msg = iolist_to_binary(io_lib:format("~p", [Reason])),
    case janus_worker_wire:error(JobRef, internal, Msg) of
        {ok, Err} ->
            MasterSessionPid ! Err;
        {error, _} ->
            ok
    end.

%%%===================================================================
%%% Env / nodes
%%%===================================================================

master_node_from_env() ->
    case os:getenv("JANUS_MASTER_NODE") of
        false ->
            {error, missing_master_node};
        "" ->
            {error, missing_master_node};
        NodeStr when is_list(NodeStr) ->
            {ok, list_to_atom(NodeStr)}
    end.

region_from_env() ->
    case os:getenv("JANUS_WORKER_REGION") of
        false -> undefined;
        "" -> undefined;
        Val when is_list(Val) -> list_to_binary(Val)
    end.

maybe_monitor_nodes() ->
    case net_kernel:monitor_nodes(true) of
        ok ->
            ok;
        {error, Reason} ->
            logger:warning(#{what => janus_worker_dispatch_monitor_nodes, reason => Reason}),
            ok
    end.
