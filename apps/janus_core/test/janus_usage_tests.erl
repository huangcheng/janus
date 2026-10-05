-module(janus_usage_tests).

%% Boots the REAL gen_server (not just pure helpers). maybe_flush/1 once
%% returned a bare #state{} instead of {noreply, ...} — every cast
%% crashed the writer and silently dropped all usage events while pure
%% helper tests stayed green. This test fails on that whole bug class.

-include_lib("eunit/include/eunit.hrl").

server_survives_traffic_test() ->
    {ok, Pid} = janus_usage:start_link(),
    %% well-formed, malformed, and boundary events through the real API
    janus_usage:record(#{status => 200, prompt => 1, completion => 1, latency_ms => 5}),
    janus_usage:record(#{}),
    janus_usage:record(#{status => 500}),
    timer:sleep(1500),
    ?assert(is_process_alive(Pid)),
    Stats = janus_usage:stats(),
    ?assert(maps:get(alive, Stats)),
    ?assert(maps:get(dropped, Stats) >= 1),
    gen_server:stop(Pid),
    ok.
