-module(janus_http_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Counters BEFORE the listeners: handlers may bump the moment
    %% Cowboy accepts (persistent_term — consumers can't lose the race).
    ok = janus_http_stats:init(),
    ok = janus_metrics:init(),
    %% v2.1 Part E: the unary worker_lost fallback knob (default OFF)
    %% reads env ONCE at boot into persistent_term — restart to change.
    ok = janus_http_worker_client:init_knob(),
    %% Request body cap (JANUS_MAX_BODY_BYTES, default 200 MiB) reads env
    %% ONCE at boot into persistent_term — restart to change, no rebuild.
    ok = janus_http_preamble:init_knob(),
    %% Gw-echo knobs + the per-peer bucket table (geo-affinity §5):
    %% proxy-header list into persistent_term, ETS before listeners.
    ok = janus_http_echo:init_knob(),
    janus_http_sup:start_link().

stop(_State) ->
    ok.
