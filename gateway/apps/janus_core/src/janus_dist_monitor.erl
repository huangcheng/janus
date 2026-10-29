%%%-------------------------------------------------------------------
%%% @doc busy_dist_port telemetry (scheduler v2.1 spec Part C.2,
%%% `2026-10-11-scheduler-v2.1-hardening.md`).
%%%
%%% A dedicated gen_server owns the node-global `erlang:system_monitor/2`
%%% slot armed for `[busy_dist_port]` and does NOTHING but count: a
%%% saturated dist port can transition busy/unbusy rapidly and monitor
%%% messages must never pile into a mailbox that does real work (spec
%%% failure mode F3).
%%%
%%% OTP 27 VERIFICATION OUTCOME (spec C.2 — "verify whether an unbusy
%%% transition message exists"): there is NO unbusy notification. The
%%% monitor fires `{monitor, SusPid, busy_dist_port, Port}` only at the
%%% moment a sending process is SUSPENDED on the busy distribution
%%% port; the runtime sends nothing when the port becomes unbusy again
%%% (documented in erts erlang:system_monitor/2; corroborated by the
%%% RabbitMQ/EMQX tuning pages, which layer their own alarm-clear
%%% logic for exactly this reason). Per the spec's pre-stated fallback
%%% the deliverable is therefore the events counter + the last-busy
%%% monotonically-increasing stamp (surfaced as an age); there is
%%% deliberately NO `dist_busy_ms` accumulation.
%%%
%%% EXCLUSIVITY: `system_monitor/2` is node-global single-slot. No
%%% other caller exists in this repo (verified by grep; the monitor
%%% slot was `undefined` on a freshly booted OTP 27 container from the
%%% build image). This module is the sole owner; any future consumer
%%% must take it over here, not arm a second monitor.
%%%
%%% ROLE: started by `janus_core_sup` on master AND worker (dist is
%%% symmetric) — every node renders its OWN counters via {@link stats/0}
%%% (a per-node LOCAL read merged into /stats/sched and /metrics by
%%% janus_http; no new dist messages, no cross-node aggregation — a
%%% dist storm is exactly when the worker-side counters matter).
%%%
%%% LOGGING (F3): never per event — one rate-limited WARNING per hour
%%% (first event per window), everything else is counters only.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_dist_monitor).

-behaviour(gen_server).

-export([start_link/0, stats/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% First-warning rate window: at most one WARNING per hour (F3).
-define(WARN_INTERVAL_MS, 3_600_000).

-record(state, {
    busy_events = 0 :: non_neg_integer(),
    last_busy_at_mono = undefined :: undefined | integer(),
    %% The suspended sender + port of the most recent event (display
    %% only; ports/pids are NOT stable identifiers across restarts).
    last_busy_pid = undefined :: undefined | pid(),
    last_busy_port = undefined :: undefined | port(),
    last_warned_at_mono = undefined :: undefined | integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Per-node local counters for /stats/sched + /metrics:
%% `busy_events_total` (int), `last_busy_age_ms` (float ms since the
%% last busy event; `null` when none has fired — never a fabricated 0),
%% `last_busy_at_mono` (the raw stamp) and `last_busy_port` (display).
%% A dead/stuck monitor degrades to a zeroed map — telemetry must never
%% take the admin plane down (dist storms are exactly when it matters).
-spec stats() -> map().
stats() ->
    try
        gen_server:call(?MODULE, stats, 1000)
    catch
        _:_ ->
            #{busy_events_total => 0, last_busy_age_ms => null, last_busy_at_mono => undefined}
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    %% Arm the node-global slot. Re-armed after every event below (the
    %% call is idempotent-cheap and guards a slot cleared by a restart).
    erlang:system_monitor(self(), [busy_dist_port]),
    {ok, #state{}}.

handle_call(stats, _From, State) ->
    Now = erlang:monotonic_time(millisecond),
    Age =
        case State#state.last_busy_at_mono of
            undefined -> null;
            T when is_integer(T) -> (Now - T) * 1.0
        end,
    Reply = #{
        busy_events_total => State#state.busy_events,
        last_busy_age_ms => Age,
        last_busy_at_mono => State#state.last_busy_at_mono,
        last_busy_port => State#state.last_busy_port,
        last_busy_pid => State#state.last_busy_pid
    },
    {reply, Reply, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({monitor, Pid, busy_dist_port, Port}, State) when is_pid(Pid), is_port(Port) ->
    %% Count, stamp, re-arm. NO per-event logging (F3): the first event
    %% per WARN_INTERVAL window warns, the rest are counters only.
    erlang:system_monitor(self(), [busy_dist_port]),
    Now = erlang:monotonic_time(millisecond),
    State1 =
        State#state{
            busy_events = State#state.busy_events + 1,
            last_busy_at_mono = Now,
            last_busy_pid = Pid,
            last_busy_port = Port
        },
    Warned = maybe_warn(Pid, Port, Now, State1),
    {noreply, State1#state{last_warned_at_mono = warned_stamp(Warned, Now, State#state.last_warned_at_mono)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    %% Deliberately NOT clearing the slot: the owning process dying
    %% clears the system_monitor setting by itself, and init/0 re-arms
    %% on supervisor restart. Clearing here could race a future owner.
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

%% One WARNING per WARN_INTERVAL window at most; returns whether this
%% event warned (the caller advances the warned-at stamp only then).
maybe_warn(Pid, Port, Now, #state{busy_events = Events, last_warned_at_mono = LastWarned}) ->
    Due =
        case LastWarned of
            undefined -> true;
            T when is_integer(T) -> Now - T >= ?WARN_INTERVAL_MS
        end,
    case Due of
        true ->
            logger:warning(#{
                what => janus_sched_dist_busy,
                note =>
                    <<"distribution port busy (a sender was suspended); "
                      "consider +zdbbl (JANUS_ZDBBL, v2.1 Part D). Further "
                      "events within the hour are counted, not logged.">>,
                suspended_pid => pid_to_list(Pid),
                port => port_to_list(Port),
                events_so_far => Events
            }),
            true;
        false ->
            false
    end,
    Due.

warned_stamp(true, Now, _Prev) ->
    Now;
warned_stamp(false, _Now, Prev) ->
    Prev.
