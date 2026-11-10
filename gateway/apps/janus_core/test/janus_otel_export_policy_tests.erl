%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the OTLP exporter's pure policy
%%% surface: which failures retry, how the backoff is bounded, how a 2xx
%%% body with/without rejections classifies, and the per-signal config
%%% resolution (endpoint, headers, signal selection).
%%%
%%% The retry policy is the load-bearing part: the OTLP spec is exact
%%% about it ("transient errors MUST be retried with exponential back-off
%%% with jitter … all other 4xx/5xx MUST NOT be retried"), and a policy
%%% that retries a 404 turns a wrong endpoint into a self-inflicted
%%% load spike — the exact production failure this suite pins against.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_export_policy_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Retryable classification: exactly the transient set
%%--------------------------------------------------------------------

retryable_test_() ->
    Transient = [
        {http, 429},
        {http, 502},
        {http, 503},
        {http, 504},
        {error, {failed_connect, [{to_address, {"c", 4318}}]}},
        {error, timeout},
        {error, econnrefused},
        {error, closed},
        %% Observed httpc transient shapes (janus_model_sync:
        %% transport_class/1 documents two of them in this codebase).
        {error, connect_timeout},
        {error, socket_closed_remotely},
        {error, unexpected_end_of_input}
    ],
    Permanent = [
        %% Host-level and DNS failures are NOT transient: retrying a
        %% wrong hostname or an exhausted fd table is a self-inflicted
        %% spike at the worst moment.
        {error, nxdomain},
        {error, emfile},
        {error, enomem},
        {http, 400},
        {http, 401},
        {http, 403},
        {http, 404},
        {http, 413},
        {http, 500},
        {http, 501},
        %% The shape a caught exception actually produces in
        %% post_attempt/5: {error, {Class, Reason}} — our own bugs are
        %% permanent, not retried four times.
        {error, {error, badarg}},
        {partial, rejected},
        <<"nonsense">>
    ],
    [
        {"transient: " ++ why(R), ?_assert(janus_otel_export:retryable(R))}
     || R <- Transient
    ] ++ [
        {"permanent: " ++ why(R), ?_assertNot(janus_otel_export:retryable(R))}
     || R <- Permanent
    ].

why(R) -> lists:flatten(io_lib:format("~0p", [R])).

%%--------------------------------------------------------------------
%% Backoff: exponential, jittered, budget-capped
%%--------------------------------------------------------------------

backoff_is_exponential_in_attempt_test() ->
    %% With jitter the delay is random in [50%, 100%) of the doubling
    %% base. Pin the WINDOW, not a value: any sample must land in it.
    Windows = #{
        1 => {100, 200},
        2 => {200, 400},
        3 => {400, 800},
        4 => {800, 1600}
    },
    maps:foreach(
        fun(Attempt, {Lo, Hi}) ->
            [?assert(D >= Lo andalso D < Hi)
             || D <- [janus_otel_export:backoff_delay_ms(Attempt, undefined, 60000) || _ <- lists:seq(1, 50)]]
        end,
        Windows
    ).

backoff_never_exceeds_the_budget_test() ->
    %% The remaining budget is a hard ceiling MINUS a reserved slice for
    %% the attempt itself: a sleep that would eat the last of the budget
    %% ends the episode in budget_exhausted without firing, so it must
    %% return <= 0 ("give up") instead.
    ?assert(janus_otel_export:backoff_delay_ms(4, 60000, 500) =< 0),
    %% A floor that fits under the ceiling is honored verbatim.
    ?assertEqual(700, janus_otel_export:backoff_delay_ms(1, 700, 10000)),
    %% Clamping still applies once the slice is reserved.
    ?assertEqual(500, janus_otel_export:backoff_delay_ms(1, 60000, 1500)).

backoff_retry_after_is_a_floor_test() ->
    %% The server asked for at least N ms; the jitter curve alone would
    %% say less; the floor wins.
    ?assertEqual(5000, janus_otel_export:backoff_delay_ms(1, 5000, 60000)).

backoff_zero_budget_is_zero_test() ->
    ?assert(janus_otel_export:backoff_delay_ms(1, undefined, 0) =< 0).

retry_after_parsing_test() ->
    ?assertEqual(4000, janus_otel_export:retry_after_ms([{"retry-after", "4"}])),
    ?assertEqual(0, janus_otel_export:retry_after_ms([{"retry-after", "0"}])),
    %% HTTP-date form and junk: ignored, never guessed.
    ?assertEqual(undefined, janus_otel_export:retry_after_ms([{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}])),
    ?assertEqual(undefined, janus_otel_export:retry_after_ms([{"retry-after", "soon"}])),
    ?assertEqual(undefined, janus_otel_export:retry_after_ms([])).

%%--------------------------------------------------------------------
%% partialSuccess: empty object is a SUCCESS (production evidence)
%%--------------------------------------------------------------------

partial_success_empty_object_is_ok_test() ->
    %% Tempo answers `{"partialSuccess":{}}` on a clean accept. A variant
    %% that treated this as a rejection reported every healthy POST as
    %% failed while the collector ingested the data all along.
    ?assertEqual(ok, partial(<<"{\"partialSuccess\":{}}">>, <<"rejectedSpans">>)).

partial_success_absent_is_ok_test() ->
    ?assertEqual(ok, partial(<<"{}">>, <<"rejectedSpans">>)).

partial_success_zero_rejected_is_ok_test() ->
    ?assertEqual(
        ok, partial(<<"{\"partialSuccess\":{\"rejectedSpans\":0}}">>, <<"rejectedSpans">>)
    ).

partial_success_positive_rejected_is_loss_test() ->
    ?assertMatch(
        {error, {partial, rejected}},
        partial(<<"{\"partialSuccess\":{\"rejectedSpans\":3}}">>, <<"rejectedSpans">>)
    ).

partial_success_rejected_as_string_is_loss_test() ->
    %% int64 fields are decimal STRINGS in proto3-JSON — a compliant
    %% collector answers `"rejectedSpans":"3"', and an integer-only read
    %% would report the loss as a clean accept.
    ?assertMatch(
        {error, {partial, rejected}},
        partial(<<"{\"partialSuccess\":{\"rejectedSpans\":\"3\"}}">>, <<"rejectedSpans">>)
    ),
    %% And the zero-string form is a clean accept, not a parse error.
    ?assertEqual(
        ok, partial(<<"{\"partialSuccess\":{\"rejectedSpans\":\"0\"}}">>, <<"rejectedSpans">>)
    ).

partial_success_log_key_test() ->
    ?assertMatch(
        {error, {partial, rejected}},
        partial(<<"{\"partialSuccess\":{\"rejectedLogRecords\":1}}">>, <<"rejectedLogRecords">>)
    ).

partial_success_metric_keys_test() ->
    %% Current field name and the pre-1.1 alias both parse.
    ?assertMatch(
        {error, {partial, rejected}},
        partial(<<"{\"partialSuccess\":{\"rejectedMetricPoints\":2}}">>, <<"rejectedMetricPoints">>)
    ),
    ?assertMatch(
        {error, {partial, rejected}},
        partial(<<"{\"partialSuccess\":{\"rejectedDataPoints\":2}}">>, <<"rejectedDataPoints">>)
    ).

partial_success_garbage_body_is_ok_test() ->
    %% An unparseable body is a decode error on our side, not a
    %% collector rejection: treat as accepted (the 2xx already said so).
    ?assertEqual(ok, partial(<<"not json">>, <<"rejectedSpans">>)).

partial(Body, Key) ->
    janus_otel_export:partial_success(Body, Key).

%%--------------------------------------------------------------------
%% Log record encoding: event time, not enqueue time
%%--------------------------------------------------------------------

log_record_uses_event_time_test() ->
    Event = #{
        level => info,
        msg => {report, #{what => janus_probe}},
        meta => #{time => 1794281442000000, what => janus_probe}
    },
    case janus_otel_export:encode_log_for_test(Event) of
        #{<<"timeUnixNano">> := Ts, <<"observedTimeUnixNano">> := Obs} ->
            ?assertEqual(<<"1794281442000000000">>, Ts),
            %% observed is "now", strictly after the fixed past event.
            ?assert(binary_to_integer(Obs) > 1794281442000000000);
        skip ->
            ?assert(false)
    end.

log_record_without_time_falls_back_to_now_test() ->
    Event = #{level => info, msg => {report, #{what => janus_probe}}, meta => #{}},
    case janus_otel_export:encode_log_for_test(Event) of
        #{<<"timeUnixNano">> := Ts} ->
            ?assert(binary_to_integer(Ts) > 1794281442000000000);
        skip ->
            ?assert(false)
    end.

%%--------------------------------------------------------------------
%% Stats contract: the metrics-failure counter exists from boot
%%--------------------------------------------------------------------

stats_expose_metrics_failure_counter_test() ->
    %% The /metrics face renders `otel_export_metrics_batches_total' from
    %% this exact stats key via maps:get/3 — a rename on either side would
    %% silently render a permanent 0. Pin the key at its source (the
    %% exporter), which is the side the face reads.
    Vars = [
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
        "OTEL_METRICS_EXPORTER",
        "OTEL_SDK_DISABLED"
    ],
    Saved = [{V, os:getenv(V)} || V <- Vars],
    [os:unsetenv(V) || V <- Vars],
    case whereis(janus_otel_export) of
        undefined ->
            try
                {ok, Pid} = janus_otel_export:start_link(),
        Stats = janus_otel_export:stats(),
        ?assert(maps:is_key(metrics_batches_failed_total, Stats)),
        ?assertEqual(0, maps:get(metrics_batches_failed_total, Stats)),
                %% Synchronous stop, not exit(kill): a killed linked
                %% process makes eunit CANCEL neighbouring tests
                %% ("related process exited"), and the queue is empty so
                %% terminate's single-shot flush is a no-op against a
                %% disabled export.
                ok = gen_server:stop(Pid)
            after
                lists:foreach(
                    fun
                        ({V, false}) -> os:unsetenv(V);
                        ({V, Val}) -> os:putenv(V, Val)
                    end,
                    Saved
                )
            end;
        _AlreadyRunning ->
            %% A supervision tree owns the exporter (another suite or the
            %% app fixture started it): read the live stats instead.
            Stats = janus_otel_export:stats(),
            ?assert(maps:is_key(metrics_batches_failed_total, Stats))
    end.
