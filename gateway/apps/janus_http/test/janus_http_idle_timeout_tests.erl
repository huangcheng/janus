%% Cowboy connection idle timeout.
%%
%% Why this is worth a test at all: the value was hardcoded at 300_000 and
%% silently truncated any stream older than five minutes. Measured live, a
%% response delivering an event every ~100ms with ZERO idle gaps was cut at
%% exactly 300.0s — no status code, nothing in the log, because the response
%% head was already committed. It reproduced against 127.0.0.1:8080 with no
%% proxy in the path, which is how it was pinned on the listener rather than
%% on Caddy or on the upstream.
%%
%% The invariant that makes the class of bug impossible: the connection
%% timeout must EXCEED the gateway's own total-stream ceiling
%% (janus_worker_wire:stream_timeout_ms/0). Below it, Cowboy always wins the
%% race against the deadline the gateway meant to enforce, and the failure
%% arrives as a silent stop instead of a classified error.
-module(janus_http_idle_timeout_tests).

-include_lib("eunit/include/eunit.hrl").

%% The default must outlive the stream ceiling, with room on both sides for
%% the connect and drain phases.
default_exceeds_stream_ceiling_test() ->
    Ceiling = janus_worker_wire:stream_timeout_ms(),
    Default = janus_http_sup:idle_timeout_default(),
    ?assert(Default > Ceiling),
    %% "Room on both sides" is the actual requirement, not merely "greater".
    ?assert(Default - Ceiling >= Ceiling),
    ?assertEqual(Ceiling * 2, Default).

%% Unset and empty both mean "use the default" — an operator clearing the env
%% var must get the safe value back, not zero and not a crash.
unset_uses_default_test() ->
    ?assertEqual(
        janus_http_sup:idle_timeout_default(),
        janus_http_sup:idle_timeout_ms(false)
    ),
    ?assertEqual(
        janus_http_sup:idle_timeout_default(),
        janus_http_sup:idle_timeout_ms("")
    ).

%% A value above the ceiling is honoured.
explicit_value_test() ->
    Above = janus_worker_wire:stream_timeout_ms() + 1,
    ?assertEqual(
        Above,
        janus_http_sup:idle_timeout_ms(integer_to_list(Above))
    ).

%% A value AT OR BELOW the ceiling is refused, not honoured. This is the whole
%% point: accepting it reintroduces the silent truncation, and the operator who
%% set 300000 would have no way to connect a silent stop to a timeout knob.
at_or_below_ceiling_is_refused_test() ->
    Ceiling = janus_worker_wire:stream_timeout_ms(),
    Default = janus_http_sup:idle_timeout_default(),
    %% The exact value that caused the production failure.
    ?assertEqual(Default, janus_http_sup:idle_timeout_ms("300000")),
    ?assertEqual(Default, janus_http_sup:idle_timeout_ms(integer_to_list(Ceiling))),
    ?assertEqual(Default, janus_http_sup:idle_timeout_ms(integer_to_list(Ceiling - 1))),
    ?assertEqual(Default, janus_http_sup:idle_timeout_ms("1000")).

%% Garbage falls back LOUDLY rather than becoming an unusable listener.
invalid_values_fall_back_test() ->
    Default = janus_http_sup:idle_timeout_default(),
    lists:foreach(
        fun(V) ->
            ?assertEqual(Default, janus_http_sup:idle_timeout_ms(V))
        end,
        ["abc", "0", "-1", "1.5", " 900000 ", ""]
    ).