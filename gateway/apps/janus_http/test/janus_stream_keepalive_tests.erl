%% SSE keepalive cadence (2026-10-29).
%%
%% The drain wakes at most every stream_keepalive_ms/0 to write a
%% client-facing comment while an upstream is silent. The cadence is
%% env-overridable so a test can observe a tick without idling for the
%% real interval; the default must survive both an unset and a garbage
%% value, because a zero or negative cadence would either spin the
%% receive loop or disable the keepalive that keeps clients alive.
-module(janus_stream_keepalive_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_MS, 15_000).

default_when_unset_test() ->
    ok = application:unset_env(janus_core, stream_keepalive_ms),
    ?assertEqual(?DEFAULT_MS, janus_http_worker_client:stream_keepalive_ms()).

override_applies_test() ->
    ok = application:set_env(janus_core, stream_keepalive_ms, 25),
    try
        ?assertEqual(25, janus_http_worker_client:stream_keepalive_ms())
    after
        application:unset_env(janus_core, stream_keepalive_ms)
    end.

%% A non-positive cadence would busy-loop the drain's `after 0`.
non_positive_falls_back_test() ->
    lists:foreach(
        fun(Bad) ->
            ok = application:set_env(janus_core, stream_keepalive_ms, Bad),
            try
                ?assertEqual(?DEFAULT_MS, janus_http_worker_client:stream_keepalive_ms())
            after
                application:unset_env(janus_core, stream_keepalive_ms)
            end
        end,
        [0, -1, -60_000]
    ).

%% Non-integer junk must not crash the drain on every wait.
non_integer_falls_back_test() ->
    ok = application:set_env(janus_core, stream_keepalive_ms, <<"nope">>),
    try
        ?assertEqual(?DEFAULT_MS, janus_http_worker_client:stream_keepalive_ms())
    after
        application:unset_env(janus_core, stream_keepalive_ms)
    end.

%% An override at or above the inactivity ceiling is refused: the drain
%% would tear the stream down before the client heard a keepalive.
override_at_or_above_ceiling_refused_test() ->
    Ceiling = janus_worker_wire:stream_inactivity_timeout_ms(),
    lists:foreach(
        fun(Bad) ->
            ok = application:set_env(janus_core, stream_keepalive_ms, Bad),
            try
                ?assertEqual(?DEFAULT_MS, janus_http_worker_client:stream_keepalive_ms())
            after
                application:unset_env(janus_core, stream_keepalive_ms)
            end
        end,
        [Ceiling, Ceiling + 1, Ceiling * 10]
    ).

%% A valid override below the ceiling is still honoured.
override_below_ceiling_applies_test() ->
    ok = application:set_env(janus_core, stream_keepalive_ms, 5_000),
    try
        ?assertEqual(5_000, janus_http_worker_client:stream_keepalive_ms())
    after
        application:unset_env(janus_core, stream_keepalive_ms)
    end.

%% The cadence must be shorter than the inactivity ceiling, or a stalled
%% stream would be torn down before the client ever hears a keepalive.
cadence_under_inactivity_ceiling_test() ->
    ok = application:unset_env(janus_core, stream_keepalive_ms),
    ?assert(
        janus_http_worker_client:stream_keepalive_ms() <
            janus_worker_wire:stream_inactivity_timeout_ms()
    ).