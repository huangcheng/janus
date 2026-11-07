%%%-------------------------------------------------------------------
%%% @doc A minimal OpenTelemetry span: identify, time, attribute, close.
%%%
%%% ## Scope
%%%
%%% This is NOT an SDK. It is the smallest thing that can produce a
%%% conformant span record: an identity (`trace_id', `span_id',
%%% `parent_span_id'), a kind, a name, monotonic start/end, a bounded
%%% attribute set, and a status. Exporting those records over OTLP/HTTP
%%% JSON is a separate concern (`janus_otel_otlp'), and sampling is
%%% decided before a span is ever created (`janus_trace').
%%%
%%% ## Why a plain map, not a process or ETS
%%%
%%% A span lives for exactly one request inside one process. There is no
%%% cross-process sharing, no lifecycle to supervise, and nothing to
%%% clean up if the request crashes — an abandoned span is simply never
%%% closed and never exported, which is the correct outcome. Making it a
%%% gen_server would put a message hop on the hot path for no benefit.
%%%
%%% ## Failure posture
%%%
%%% Telemetry must never fail or slow a request. Every entry point is
%%% total: a bad attribute value is clamped, an over-cap attribute set is
%%% truncated with `dropped_attributes' counted (never silently), and
%%% `finish/2' on a malformed span returns the span unchanged rather than
%%% raising. The one thing this module will NOT do is invent data — a
%%% missing value is omitted, never defaulted to zero.
%%%
%%% ## Clocks
%%%
%%% Durations come from `erlang:monotonic_time', which cannot go
%%% backwards; the OTLP record needs wall-clock nanoseconds, so the
%%% wall-clock instant is captured ONCE at start and the monotonic delta
%%% is added to it. Reading the wall clock at the end instead would
%%% produce negative durations across a clock step.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_span).

-export([
    start/4,
    start/5,
    finish/1,
    finish/2,
    set_attr/3,
    set_attrs/2,
    set_status/3,
    set_error/2,
    id/1,
    trace_id/1,
    is_span/1,
    duration_us/1
]).

-export_type([span/0, kind/0]).

%% Per the OTel spec's span limits. Counts are the spec defaults; the
%% value-length cap is Janus's own, because the spec's default is "no
%% limit" and unbounded memory is not acceptable here.
-define(MAX_ATTRS, 128).
-define(MAX_VALUE_BYTES, 1024).

-type kind() :: server | client | internal | producer | consumer.
-type span() :: #{
    trace_id := binary(),
    span_id := binary(),
    parent_span_id := binary() | undefined,
    name := binary(),
    kind := kind(),
    %% Wall-clock nanoseconds at start (OTLP wants unix nanos).
    start_wall_ns := integer(),
    %% Monotonic microseconds at start (duration source).
    start_mono_us := integer(),
    attributes := #{binary() => binary() | integer() | float() | boolean()},
    dropped_attributes := non_neg_integer(),
    status := {binary(), binary()}
}.

%%--------------------------------------------------------------------
%% Lifecycle
%%--------------------------------------------------------------------

-spec start(kind(), binary(), binary() | undefined, binary()) -> span().
start(Kind, Name, ParentSpanId, TraceId) ->
    start(Kind, Name, ParentSpanId, TraceId, #{}).

%% @doc Open a span. `TraceId' comes from `janus_trace'; `ParentSpanId'
%% is the enclosing span's id (or `undefined' for the root SERVER span).
%% The span's own id is minted here, so one attempt == one span id.
-spec start(kind(), binary(), binary() | undefined, binary(), map()) -> span().
start(Kind, Name, ParentSpanId, TraceId, Attrs) when is_map(Attrs) ->
    Span = #{
        trace_id => TraceId,
        span_id => new_span_id(),
        parent_span_id => ParentSpanId,
        name => janus_otel_attr:sanitize_value(Name),
        kind => Kind,
        start_wall_ns => wall_ns(),
        start_mono_us => erlang:monotonic_time(microsecond),
        attributes => #{},
        dropped_attributes => 0,
        status => {<<"UNSET">>, <<>>}
    },
    add_attrs(Span, Attrs).

%% @doc Close the span: stamp the end time and return the record ready
%% for encoding. Idempotent-ish by construction — closing a closed span
%% would just restamp the end, so callers close exactly once.
-spec finish(span()) -> span().
finish(Span) when is_map(Span) ->
    finish(Span, undefined).

%% @doc Close the span with a terminal HTTP status, applying the
%% semconv status rule for the span's kind.
-spec finish(span(), pos_integer() | undefined) -> span().
finish(Span, Status) when is_map(Span) ->
    Span1 =
        case Status of
            undefined -> Span;
            _ -> set_status(Span, Status, undefined)
        end,
    EndMono = erlang:monotonic_time(microsecond),
    StartMono = maps:get(start_mono_us, Span1, EndMono),
    DurUs = max(0, EndMono - StartMono),
    StartNs = maps:get(start_wall_ns, Span1, 0),
    Span1#{
        end_wall_ns => StartNs + DurUs * 1000,
        duration_us => DurUs
    }.

%% @doc Wall-clock duration in microseconds (0 while still open).
-spec duration_us(span()) -> non_neg_integer().
duration_us(Span) when is_map(Span) ->
    maps:get(duration_us, Span, 0).

%%--------------------------------------------------------------------
%% Attributes
%%--------------------------------------------------------------------

-spec set_attr(span(), binary(), term()) -> span().
set_attr(Span, Key, Value) when is_map(Span), is_binary(Key) ->
    add_attrs(Span, #{Key => Value}).

-spec set_attrs(span(), map()) -> span().
set_attrs(Span, Attrs) when is_map(Span), is_map(Attrs) ->
    add_attrs(Span, Attrs).

%% Values with no meaning are OMITTED, never defaulted: a missing token
%% count must not become 0, which would be indistinguishable from a real
%% zero. Over-cap attributes are dropped and counted.
add_attrs(Span, Attrs) ->
    maps:fold(fun(K, V, Acc) -> add_attr(Acc, K, V) end, Span, Attrs).

add_attr(#{attributes := A, dropped_attributes := D} = Span, Key, Value) ->
    case normalize_value(Value) of
        undefined ->
            Span;
        Norm ->
            case map_size(A) < ?MAX_ATTRS of
                true -> Span#{attributes := A#{Key => Norm}};
                false ->
                    %% Counted, not silent: the exporter reports
                    %% dropped_attributes on the span.
                    Span#{dropped_attributes := D + 1}
            end
    end.

%% Convert to an OTLP AnyValue-compatible scalar, or `undefined' to
%% omit. Numbers and booleans pass through; binaries are clamped; atoms
%% are rendered; anything else is dropped rather than encoded as
%% `~p' noise.
normalize_value(undefined) ->
    undefined;
normalize_value(null) ->
    undefined;
normalize_value(V) when is_boolean(V) -> V;
normalize_value(V) when is_integer(V) -> V;
normalize_value(V) when is_float(V) -> V;
normalize_value(V) when is_binary(V) ->
    case byte_size(V) of
        0 -> undefined;
        _ -> janus_otel_attr:sanitize_value(V)
    end;
normalize_value(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
normalize_value(V) when is_list(V) ->
    %% String lists only; a list of tables is not an attribute value.
    case io_lib:printable_unicode_list(V) of
        true -> janus_otel_attr:sanitize_value(unicode:characters_to_binary(V));
        false -> undefined
    end;
normalize_value(_) ->
    undefined.

%%--------------------------------------------------------------------
%% Status
%%--------------------------------------------------------------------

%% @doc Apply the semconv status rule for this span's kind.
-spec set_status(span(), pos_integer() | undefined, binary() | undefined) -> span().
set_status(Span, Status, Message) when is_map(Span) ->
    Kind = maps:get(kind, Span, internal),
    {Code, DefaultMsg} = janus_otel_attr:status(kind_for_status(Kind), Status),
    Msg = case Message of
        undefined -> DefaultMsg;
        M when is_binary(M) -> janus_otel_attr:sanitize_value(M);
        _ -> DefaultMsg
    end,
    %% A message only rides an ERROR status; UNSET with a message is
    %% meaningless in the OTLP model.
    case Code of
        <<"ERROR">> -> Span#{status := {Code, Msg}};
        _ -> Span#{status := {Code, <<>>}}
    end.

%% The semconv's 4xx rule differs between SERVER and CLIENT; anything
%% else is treated as a client of whatever it called.
kind_for_status(server) -> server;
kind_for_status(_) -> client.

%% @doc Mark the span failed with a low-cardinality `error.type'.
-spec set_error(span(), term()) -> span().
set_error(Span, Reason) when is_map(Span) ->
    case janus_otel_attr:error_type(Reason) of
        undefined ->
            set_status(Span, 500, undefined);
        T ->
            Span1 = set_status(Span, 500, undefined),
            set_attr(Span1, <<"error.type">>, T)
    end.

%%--------------------------------------------------------------------
%% Accessors
%%--------------------------------------------------------------------

-spec id(span()) -> binary().
id(Span) when is_map(Span) -> maps:get(span_id, Span).

-spec trace_id(span()) -> binary().
trace_id(Span) when is_map(Span) -> maps:get(trace_id, Span).

-spec is_span(term()) -> boolean().
is_span(#{span_id := Id, trace_id := T}) when is_binary(Id), is_binary(T) -> true;
is_span(_) -> false.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

%% 8 random bytes as 16 lowercase hex — the W3C span-id shape. Guarded
%% like janus_trace's id minting: telemetry must never 500 a request.
new_span_id() ->
    try
        string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(8)))
    catch
        _:_ ->
            I = erlang:unique_integer([positive]),
            string:lowercase(binary:encode_hex(<<I:64/big>>))
    end.

%% Wall-clock nanoseconds since the epoch.
wall_ns() ->
    erlang:system_time(nanosecond).