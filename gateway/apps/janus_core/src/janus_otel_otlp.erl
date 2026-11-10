%%%-------------------------------------------------------------------
%%% @doc Encode finished spans as an OTLP/HTTP JSON `ExportTraceServiceRequest'.
%%%
%%% ## Why hand-built JSON over the official Erlang SDK
%%%
%%% The reference exporter (`opentelemetry_exporter') pulls in `grpcbox',
%%% `chatterbox' and `hpack' for the gRPC transport this gateway does not
%%% use, and adds three applications to a release that ships ten. This
%%% gateway speaks OTLP/HTTP with a JSON body: a POST to `/v1/traces',
%%% which is a shape `thoas' already encodes elsewhere in this tree. No
%%% new dependency, no protobuf compile step, and the wire format is
%%% inspectable in a log when an export is rejected.
%%%
%%% ## The OTLP JSON encoding rules that are easy to get wrong
%%%
%%% * `traceId'/`spanId' are lowercase HEX STRINGS, not byte arrays.
%%% * `startTimeUnixNano'/`endTimeUnixNano' are DECIMAL STRINGS, because
%%%   JavaScript cannot represent a nanosecond epoch as a JSON number.
%%%   Emitting integers appears to work and then silently corrupts every
%%%   timestamp a JS backend parses.
%%% * `kind' is an INTEGER enum (SPAN_KIND_SERVER = 2, CLIENT = 3), not a
%%%   name.
%%% * `status.code' is an integer (UNSET=0, OK=1, ERROR=2) and its
%%%   `message' field is omitted when empty.
%%% * Attribute values are wrapped in a typed `value' object
%%%   (`{"stringValue": "..."}'), never emitted bare.
%%%
%%% ## What this module does NOT do
%%%
%%% It does not perform HTTP. Encoding is pure, so the wire shape is
%%% testable and a failed export cannot corrupt a span record.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_otlp).

-export([
    encode/2,
    encode_metrics/4,
    encode_logs/2,
    encode_attrs/1,
    encode_span/1,
    span_kind/1,
    status_code/1
]).

-define(SPAN_KIND_INTERNAL, 1).
-define(SPAN_KIND_SERVER, 2).
-define(SPAN_KIND_CLIENT, 3).
-define(SPAN_KIND_PRODUCER, 4).
-define(SPAN_KIND_CONSUMER, 5).

%% @doc Encode a batch of finished spans.
%%
%% `Resource' is a flat map of resource attributes (service.name,
%% service.version, ...). Emitted once per request, not per span, because
%% OTLP carries resource attributes at the ResourceSpans level and
%% repeating them per span bloats the payload by an order of magnitude.
-spec encode([map()], map()) -> map().
encode(Spans, Resource) when is_list(Spans), is_map(Resource) ->
    #{
        <<"resourceSpans">> => [
            #{
                <<"resource">> => #{
                    <<"attributes">> => encode_attrs(Resource)
                },
                <<"scopeSpans">> => [
                    #{
                        <<"scope">> => #{
                            <<"name">> => <<"janus">>,
                            <<"version">> => scope_version()
                        },
                        <<"spans">> => [encode_span(S) || S <- Spans]
                    }
                ]
            }
        ]
    }.

%%%-------------------------------------------------------------------
%%% Metrics (design §8.1: a second VIEW over the same ETS rows)
%%%
%%% OTLP metrics are structurally different from spans: each instrument
%%% carries its data points, and a SUM additionally carries `aggregation
%%% Temporality' and `isMonotonic'. Getting that metadata wrong makes a
%%% backend either double-count on restart (delta temporality where the
%%% counter is cumulative) or refuse to compute a rate (missing
%%% monotonicity).
%%%
%%% We emit CUMULATIVE temporality for every counter: the ETS registry holds
%%% process-lifetime totals and NEVER resets, which is exactly the
%%% definition of a cumulative sum. Delta would require the exporter to
%%% track a previous sample per series and subtract — bookkeeping that can
%%% only lose accuracy here.
%%%
%%% `startTimeUnixNano' is the process start, not the first observation:
%%% for a cumulative counter it must be the instant the measurement period
%%% began, and every reset of that timestamp reads as a restart.
%%% @end
%%%-------------------------------------------------------------------
%%% Logs (design §10.2)
%%%
%%% One resourceLogs entry carrying every record in the batch. The record's
%%% `body' is the rendered text and its `attributes' are the flattened
%%% report fields, which is the split the OTLP model asks for: a backend can
%%% group by `what' without parsing the human-readable line.
%%%
%%% `traceId'/'spanId' are TOP-LEVEL proto fields, not attributes. They are
%%% omitted entirely when absent — a line emitted outside any span has no
%%% trace, and back-filling a fabricated id would attach unrelated log lines
%%% to a real trace.
%%% @end
-spec encode_logs([map()], map()) -> map().
encode_logs(Records, Resource) when is_list(Records), is_map(Resource) ->
    #{
        <<"resourceLogs">> => [
            #{
                <<"resource">> => #{<<"attributes">> => encode_attrs(Resource)},
                <<"scopeLogs">> => [
                    #{
                        <<"scope">> => #{
                            <<"name">> => <<"janus">>,
                            <<"version">> => scope_version()
                        },
                        <<"logRecords">> => Records
                    }
                ]
            }
        ]
    }.

-spec encode_metrics([{tuple(), integer()}], [term()], map(), integer()) -> map().
encode_metrics(Rows, Gauges, Resource, StartNs) when is_list(Rows), is_map(Resource) ->
    Counters = encode_counter_metrics(Rows, StartNs),
    Histograms = encode_hist_metrics(Rows, StartNs),
    GaugesOut = encode_gauge_metrics(Gauges),
    #{
        <<"resourceMetrics">> => [
            #{
                <<"resource">> => #{<<"attributes">> => encode_attrs(Resource)},
                <<"scopeMetrics">> => [
                    #{
                        <<"scope">> => #{
                            <<"name">> => <<"janus">>,
                            <<"version">> => scope_version()
                        },
                        <<"metrics">> => Counters ++ Histograms ++ GaugesOut
                    }
                ]
            }
        ]
    }.

%% One metric per (family, unit), with one data point per label set.
encode_counter_metrics(Rows, StartNs) ->
    ByName = group_by_name([{N, L, V} || {{counter, N, L}, V} <- Rows]),
    [
        #{
            <<"name">> => metric_name(Name),
            <<"unit">> => unit_of(Name),
            <<"description">> => description_of(Name),
            <<"sum">> => #{
                <<"dataPoints">> => [
                    #{
                        <<"attributes">> => encode_attrs(labels_map(L)),
                        <<"startTimeUnixNano">> => integer_to_binary(StartNs),
                        <<"timeUnixNano">> => integer_to_binary(now_ns()),
                        <<"asInt">> => integer_to_binary(V)
                    }
                 || {L, V} <- Points
                ],
                %% CUMULATIVE, MONOTONIC: the registry never resets during
                %% a process lifetime (see the section comment).
                <<"aggregationTemporality">> => 2,
                <<"isMonotonic">> => true
            }
        }
     || {Name, Points} <- ByName
    ].

%% A histogram becomes ONE data point per label set carrying every bucket,
%% the count and the sum — not one metric per bucket. That shape is what
%% the OTLP data model requires, and it is also why the Prometheus
%% `_bucket/_count/_sum' split cannot be reused directly here.
encode_hist_metrics(Rows, StartNs) ->
    Buckets =
        lists:foldl(
            fun
                ({{hist, N, L, Le}, V}, Acc) ->
                    maps:update_with(
                        {N, L}, fun(M) -> M#{Le => V} end, #{Le => V}, Acc
                    );
                (_, Acc) ->
                    Acc
            end,
            #{},
            Rows
        ),
    Sums = maps:from_list([{{N, L}, V} || {{hist_sum_us, N, L}, V} <- Rows]),
    Counts = maps:from_list([{{N, L}, V} || {{hist_count, N, L}, V} <- Rows]),
    ByName = group_by_metric([{K, B} || {K, B} <- maps:to_list(Buckets)]),
    [
        #{
            <<"name">> => metric_name(Name),
            <<"unit">> => unit_of(Name),
            <<"description">> => description_of(Name),
            <<"histogram">> => #{
                <<"dataPoints">> => [
                    encode_hist_point(L, B, maps:get({Name, L}, Sums, 0), maps:get({Name, L}, Counts, 0), StartNs)
                 || {L, B} <- Points
                ],
                <<"aggregationTemporality">> => 2
            }
        }
     || {Name, Points} <- ByName
    ].

encode_hist_point(L, BucketMap, SumUs, Count, StartNs) ->
    %% OTLP `bucketCounts' are PER-BUCKET, NOT cumulative: the wire spec
    %% requires "the sum of the bucket_counts must equal the value in the
    %% count field", and its bucket definition is
    %% `(-inf, bounds[0]], (bounds[i-1], bounds[i]], (bounds[N-1], +inf)'.
    %%
    %% The ETS registry stores CUMULATIVE counts (Prometheus `le'
    %% semantics: every bucket counts all observations at or below its
    %% bound), so each value must be DIFFERENCED against its predecessor
    %% before it goes on the wire. Copying the cumulative values across
    %% makes the sum exceed `count` by a growing factor and every consumer
    %% rejects the point.
    %%
    %% Prometheus and OTLP agree that a bucket INCLUDES its upper bound, so
    %% only the aggregation differs — no off-by-one to correct.
    Ordered = sorted_buckets(BucketMap),
    Bounds = [le_num(Le) || {Le, _} <- Ordered, Le =/= <<"+Inf">>],
    CountsOut = per_bucket_counts([V || {_Le, V} <- Ordered]),
    #{
        <<"attributes">> => encode_attrs(labels_map(L)),
        <<"startTimeUnixNano">> => integer_to_binary(StartNs),
        <<"timeUnixNano">> => integer_to_binary(now_ns()),
        <<"count">> => integer_to_binary(Count),
        %% OTLP `sum' is a proto DOUBLE: in OTLP/JSON that is a JSON
        %% NUMBER, not a decimal string — strings are reserved for the
        %% 64-bit INTEGER fields (`count', `bucketCounts', `asInt'), and
        %% a strict protobuf-JSON parser rejects a string where a double
        %% belongs. The registry stores integer microseconds to keep ETS
        %% counters integral; converting here keeps the wire value honest.
        <<"sum">> => SumUs / 1_000_000,
        <<"bucketCounts">> => [integer_to_binary(V) || V <- CountsOut],
        <<"explicitBounds">> => Bounds
    }.

%% Cumulative -> per-bucket. The last entry is the +Inf bucket, which in
%% cumulative form equals the total; differenced it becomes the tail mass.
per_bucket_counts([]) ->
    [];
per_bucket_counts([First | Rest]) ->
    {Out, _Prev} = lists:foldl(
        fun(V, {Acc, Prev}) -> {[V - Prev | Acc], V} end,
        {[First], First},
        Rest
    ),
    lists:reverse(Out).

sorted_buckets(BucketMap) ->
    lists:sort(
        fun({A, _}, {B, _}) ->
            case {A, B} of
                {<<"+Inf">>, <<"+Inf">>} -> true;
                {<<"+Inf">>, _} -> false;
                {_, <<"+Inf">>} -> true;
                _ -> le_num(A) =< le_num(B)
            end
        end,
        maps:to_list(BucketMap)
    ).

encode_gauge_metrics(Gauges) ->
    Pairs = [{{N, L}, gauge_value(G)} || {N, _, L} = G <- Gauges],
    ByName = group_by_metric(Pairs),
    [
        #{
            <<"name">> => metric_name(Name),
            <<"unit">> => unit_of(Name),
            <<"description">> => description_of(Name),
            <<"gauge">> => #{
                <<"dataPoints">> => [
                    #{
                        <<"attributes">> => encode_attrs(labels_map(L)),
                        <<"timeUnixNano">> => integer_to_binary(now_ns()),
                        <<"asInt">> => integer_to_binary(V)
                    }
                 || {L, V} <- Points
                ]
            }
        }
     || {Name, Points} <- ByName
    ].

gauge_value({_N, V, _L}) when is_integer(V) -> V;
gauge_value({_N, V, _L}) when is_float(V) -> trunc(V);
gauge_value(_) -> 0.

group_by_name(Triples) ->
    group_by_metric([{{N, L}, V} || {N, L, V} <- Triples]).

group_by_metric(Pairs) ->
    Folded = lists:foldl(
        fun({{N, L}, V}, Acc) ->
            maps:update_with(N, fun(Ps) -> [{L, V} | Ps] end, [{L, V}], Acc)
        end,
        #{},
        Pairs
    ),
    [{N, lists:reverse(Ps)} || {N, Ps} <- lists:sort(maps:to_list(Folded))].

%% The OTLP name is the semconv name when one exists, else the `janus.'
%% namespace (design §8.4). Never the Prometheus `janus_...' spelling: that
%% is the OTHER view's name and mixing them would make the two
%% indistinguishable in a backend that ingests both.
metric_name(Family) ->
    case janus_metrics:semconv_name(Family) of
        undefined -> janus_name(Family);
        Semconv -> Semconv
    end.

janus_name(Family) ->
    <<"janus.", (atom_to_binary(Family, utf8))/binary>>.

unit_of(Family) ->
    case janus_metrics_render:unit(Family) of
        undefined -> <<"1">>;
        U -> U
    end.

description_of(Family) ->
    janus_metrics_render:help(Family).

labels_map(L) when is_list(L) ->
    maps:from_list(L);
labels_map(L) when is_map(L) ->
    L;
labels_map(_) ->
    #{}.

now_ns() ->
    erlang:system_time(nanosecond).

%% A bucket bound as a number. `+Inf' never reaches here (the caller filters
%% it), and an unparseable bound degrades to 0 rather than crashing the
%% export — the same tolerance the Prometheus renderer applies.
le_num(Le) when is_binary(Le) ->
    try
        binary_to_float(Le)
    catch
        _:_ ->
            try
                float(binary_to_integer(Le))
            catch
                _:_ -> 0.0
            end
    end;
le_num(Le) when is_float(Le) ->
    Le;
le_num(Le) when is_integer(Le) ->
    float(Le);
le_num(_) ->
    0.0.

%% @doc One span in OTLP JSON shape. Assumes the span was finished;
%% an unfinished span has no `end_wall_ns' and is skipped by the caller.
-spec encode_span(map()) -> map().
encode_span(Span) ->
    Base = #{
        <<"traceId">> => maps:get(trace_id, Span),
        <<"spanId">> => maps:get(span_id, Span),
        <<"name">> => maps:get(name, Span, <<>>),
        <<"kind">> => span_kind(maps:get(kind, Span, internal)),
        <<"startTimeUnixNano">> => int_str(maps:get(start_wall_ns, Span, 0)),
        <<"endTimeUnixNano">> => int_str(end_ns(Span)),
        <<"attributes">> => encode_attrs(maps:get(attributes, Span, #{})),
        <<"status">> => encode_status(maps:get(status, Span, {<<"UNSET">>, <<>>}))
    },
    WithParent =
        case maps:get(parent_span_id, Span, undefined) of
            undefined -> Base;
            P when is_binary(P), byte_size(P) =:= 16 -> Base#{<<"parentSpanId">> => P};
            _ -> Base
        end,
    WithDropped =
        case maps:get(dropped_attributes, Span, 0) of
            0 -> WithParent;
            N when is_integer(N), N > 0 -> WithParent#{<<"droppedAttributesCount">> => N};
            _ -> WithParent
        end,
    WithDropped.

end_ns(Span) ->
    case maps:get(end_wall_ns, Span, undefined) of
        undefined ->
            %% An unfinished span should never be exported; timestamp it at
            %% its start rather than emitting a null, which some collectors
            %% reject outright and others read as the epoch.
            maps:get(start_wall_ns, Span, 0);
        Ns ->
            Ns
    end.

%% OTLP/JSON: 64-bit integers are STRINGS. A JS consumer rounds a numeric
%% nanosecond epoch and every span lands in the wrong minute.
int_str(N) when is_integer(N) -> integer_to_binary(N).

-spec span_kind(atom()) -> pos_integer().
span_kind(server) -> ?SPAN_KIND_SERVER;
span_kind(client) -> ?SPAN_KIND_CLIENT;
span_kind(producer) -> ?SPAN_KIND_PRODUCER;
span_kind(consumer) -> ?SPAN_KIND_CONSUMER;
span_kind(_) -> ?SPAN_KIND_INTERNAL.

%% OTLP status code enum. NOT the HTTP status: `OK' (1) means the
%% operation succeeded and is normally left UNSET; `ERROR' (2) is the
%% only code that carries a message.
-spec status_code(binary()) -> non_neg_integer().
status_code(<<"OK">>) -> 1;
status_code(<<"ERROR">>) -> 2;
status_code(_) -> 0.

encode_status({Code, Message}) ->
    Base = #{<<"code">> => status_code(Code)},
    case Message of
        M when is_binary(M), byte_size(M) > 0 -> Base#{<<"message">> => M};
        _ -> Base
    end;
encode_status(_) ->
    #{<<"code">> => 0}.

%% OTLP attributes are a repeated {key, value-AnyValue} list, NOT a map:
%% the wire format is an array of {key, value} objects precisely so that
%% duplicate keys and ordering can round-trip.
encode_attrs(Attrs) when is_map(Attrs) ->
    [encode_attr(K, V) || {K, V} <- lists:sort(maps:to_list(Attrs))];
encode_attrs(_) ->
    [].

encode_attr(K, V) when is_binary(V) ->
    #{<<"key">> => K, <<"value">> => #{<<"stringValue">> => V}};
encode_attr(K, V) when is_boolean(V) ->
    #{<<"key">> => K, <<"value">> => #{<<"boolValue">> => V}};
encode_attr(K, V) when is_integer(V) ->
    #{<<"key">> => K, <<"value">> => #{<<"intValue">> => integer_to_binary(V)}};
encode_attr(K, V) when is_float(V) ->
    #{<<"key">> => K, <<"value">> => #{<<"doubleValue">> => V}};
encode_attr(K, V) ->
    %% Nothing else should reach here (the span layer normalizes), but an
    %% unexpected shape becomes a string rather than crashing an export.
    #{<<"key">> => K, <<"value">> => #{<<"stringValue">> => iolist_to_binary(io_lib:format("~0p", [V]))}}.

scope_version() ->
    case application:get_key(janus_core, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> <<"0.0.0">>
    end.