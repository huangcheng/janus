%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the OTLP/HTTP-JSON encoder.
%%%
%%% These pin the wire-shape rules the spec states and a JSON encoder
%%% gets wrong silently: 64-bit integers as decimal STRINGS, doubles as
%%% JSON NUMBERS, enums as integers, histogram bucket counts differenced
%%% to per-bucket. The `sum'-as-string bug is the regression this suite
%%% exists for: it parses as OTLP-ish JSON and a lenient collector may
%%% even accept it, while a strict protobuf-JSON parser rejects the
%%% whole data point.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_otlp_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Histogram data points
%%--------------------------------------------------------------------

histogram_sum_is_a_json_number_test() ->
    %% `sum' is a proto double: OTLP/JSON encodes doubles as numbers.
    %% Strings are for the 64-bit INTEGER fields only. The exact value
    %% also pins the us->s conversion (750000 us = 0.75 s): an is_float
    %% check alone would pass a wrong divisor.
    Point = hist_point(),
    ?assertEqual(0.75, maps:get(<<"sum">>, Point)).

histogram_count_is_a_decimal_string_test() ->
    %% `count' is fixed64: decimal string, not a JSON number.
    ?assertEqual(<<"4">>, maps:get(<<"count">>, hist_point())).

histogram_bucket_counts_are_per_bucket_test() ->
    %% The registry stores cumulative `le' counts; the wire wants
    %% per-bucket, whose sum must equal `count'. Cumulative values copied
    %% across would sum to ~2x count and every consumer rejects the point.
    %% OTLP shape: N bounds => N+1 bucketCounts, the last being the
    %% (+Inf] tail bucket.
    Point = hist_point(),
    Buckets = [binary_to_integer(B) || B <- maps:get(<<"bucketCounts">>, Point)],
    ?assertEqual([1, 1, 1, 1, 0, 0], Buckets),
    ?assertEqual(4, lists:sum(Buckets)).

histogram_bounds_are_sorted_numbers_test() ->
    %% Includes 10.0 with 2.0: lexicographic order ("10.0" < "2.0")
    %% differs from numeric order there, so this actually pins the
    %% NUMERIC comparator, not an accidental string sort.
    Point = hist_point(),
    ?assertEqual([0.1, 0.25, 0.5, 2.0, 10.0], maps:get(<<"explicitBounds">>, Point)).

hist_point() ->
    %% One histogram family with cumulative le-buckets in registry shape.
    Rows = [
        {{hist, probe_hist, [], <<"0.1">>}, 1},
        {{hist, probe_hist, [], <<"0.25">>}, 2},
        {{hist, probe_hist, [], <<"0.5">>}, 3},
        {{hist, probe_hist, [], <<"2.0">>}, 4},
        {{hist, probe_hist, [], <<"10.0">>}, 4},
        {{hist, probe_hist, [], <<"+Inf">>}, 4},
        {{hist_sum_us, probe_hist, []}, 750_000},
        {{hist_count, probe_hist, []}, 4}
    ],
    #{<<"resourceMetrics">> := [#{<<"scopeMetrics">> := [#{<<"metrics">> := Ms}]}]} =
        janus_otel_otlp:encode_metrics(Rows, [], #{}, 1_000_000),
    [#{<<"histogram">> := #{<<"dataPoints">> := [P]}}] = Ms,
    P.

%%--------------------------------------------------------------------
%% Span encoding rules
%%--------------------------------------------------------------------

span_ids_are_hex_and_enums_integers_test() ->
    Span = janus_otel_span:finish(
        janus_otel_span:start(server, <<"probe">>, undefined, <<"4bf92f3577b34da6a3ce929d0e0e4736">>),
        200
    ),
    Enc = janus_otel_otlp:encode_span(Span),
    ?assertEqual(32, byte_size(maps:get(<<"traceId">>, Enc))),
    %% SPAN_KIND_SERVER = 2, an INTEGER — enum name strings are invalid.
    ?assertEqual(2, maps:get(<<"kind">>, Enc)),
    %% UNSET status is code 0; 64-bit timestamps are decimal strings.
    ?assertEqual(#{<<"code">> => 0}, maps:get(<<"status">>, Enc)),
    ?assert(is_binary(maps:get(<<"startTimeUnixNano">>, Enc))),
    ?assert(is_binary(maps:get(<<"endTimeUnixNano">>, Enc))).

attribute_values_are_typed_wrappers_test() ->
    Attrs = janus_otel_otlp:encode_attrs(#{
        <<"s">> => <<"text">>,
        <<"i">> => 42,
        <<"d">> => 1.5,
        <<"b">> => true
    }),
    ?assertEqual(
        [
            #{<<"key">> => <<"b">>, <<"value">> => #{<<"boolValue">> => true}},
            #{<<"key">> => <<"d">>, <<"value">> => #{<<"doubleValue">> => 1.5}},
            %% int64 → decimal string on the wire.
            #{<<"key">> => <<"i">>, <<"value">> => #{<<"intValue">> => <<"42">>}},
            #{<<"key">> => <<"s">>, <<"value">> => #{<<"stringValue">> => <<"text">>}}
        ],
        Attrs
    ).
