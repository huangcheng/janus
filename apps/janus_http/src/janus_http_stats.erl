%%%-------------------------------------------------------------------
%%% @doc Node request counters for /stats (Slice B).
%%% Count unit: one CLIENT LLM call — the entry into
%%% janus_http_proxy:do_proxy after auth + JSON object parse. Not
%%% /v1/models, not /healthz, not per LB retry, not per janus-auto
%%% inner judge/target call (janus-auto = 1). Invariant:
%%% requests_failed <= requests_total.
%%%
%%% Atomics are created ONCE per application start (janus_http_app,
%%% before the Cowboy listeners) and kept in persistent_term — the
%%% boot-order-safe distribution convention (never gen_server casts).
%%% A VM or app restart resets counters; hot code reload without app
%%% re-init keeps them. Missing refs (app not started) make every
%%% call a no-op and snapshot report zeros.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_stats).

-export([init/0, inc_total/0, inc_failed/0, snapshot/0]).

-define(PT_KEY, {janus_http_stats, refs}).

-spec init() -> ok.
init() ->
    Refs = #{
        total => atomics:new(1, [{signed, false}]),
        failed => atomics:new(1, [{signed, false}]),
        started_at => erlang:system_time(second)
    },
    persistent_term:put(?PT_KEY, Refs),
    ok.

-spec inc_total() -> ok.
inc_total() ->
    bump(total).

-spec inc_failed() -> ok.
inc_failed() ->
    bump(failed).

-spec snapshot() -> #{
    requests_total := non_neg_integer(),
    requests_failed := non_neg_integer(),
    started_at := pos_integer() | undefined
}.
snapshot() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            #{requests_total => 0, requests_failed => 0, started_at => undefined};
        #{total := T, failed := F, started_at := S} ->
            #{
                requests_total => atomics:get(T, 1),
                requests_failed => atomics:get(F, 1),
                started_at => S
            }
    end.

%%% internal

bump(Key) ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            ok;
        #{Key := Ref} ->
            _ = atomics:add(Ref, 1, 1),
            ok
    end.
