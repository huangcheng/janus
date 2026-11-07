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