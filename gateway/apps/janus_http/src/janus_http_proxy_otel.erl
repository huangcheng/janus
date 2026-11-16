%%%-------------------------------------------------------------------
%%% @doc OTel spans and GenAI/HTTP duration/token producers for the
%%% data-plane proxy. Extracted from `janus_http_proxy` so OCR can
%%% scan the orchestrator under the line budget. Telemetry never fails
%%% a request: every entry point is total.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy_otel).

-export([
    open_server_span/2,
    close_server_span/1,
    export_request_spans/0,
    open_attempt_span/4,
    close_attempt_span/2,
    attach_usage_to_span/1,
    observe_genai_tokens/5,
    observe_http_server_duration/3,
    method_label/0,
    scheme_label/0,
    maybe_observe_genai_duration/1,
    row_span_ids/0,
    attempt_spans/0,
    ttfc_seconds/0
]).

-define(SPAN_KEEP, 8).

%% The TTFC attribute value in SECONDS (the semconv's unit), or
%% `undefined' when no content chunk ever arrived.
ttfc_seconds() ->
    case {get(janus_req_started), get(janus_first_content_chunk_us)} of
        {Start, First} when is_integer(Start), is_integer(First) ->
            case First >= Start of
                true -> (First - Start) / 1000000;
                false -> undefined
            end;
        _ ->
            undefined
    end.

%% `http.server.request.duration' (semconv, unit `s').
%%
%% Required attributes only: `http.request.method' and `url.scheme',
%% written with their OTel spelling. The registry transliterates label
%% names for the Prometheus view (dots are not legal there), so the same
%% key serves both encodings.
%%
%% The route is deliberately NOT an attribute -- `http.route' would be the
%% semconv name and the gateway's route set is catalog-bounded, but adding
%% a label here that the legacy series does not have would make the two
%% views incomparable for no benefit.
observe_http_server_duration(Status, _Stream, LatencyMs) ->
    janus_metrics:observe(
        http_server_request_duration,
        #{
            <<"http.request.method">> => method_label(),
            <<"url.scheme">> => scheme_label(),
            <<"http.response.status_code">> => Status
        },
        LatencyMs / 1000
    ).

%% The request method as cowboy received it (already the uppercase
%% original the semconv wants).
%%
%% An absent value reports `_OTHER', the semconv convention for an unknown
%% method. Guessing `POST' would turn a missing value into a
%% plausible-looking lie: a GET would be reported as a POST with no way to
%% tell them apart downstream.
method_label() ->
    case method_class(get(janus_req_method)) of
        unknown -> <<"_OTHER">>;
        M -> M
    end.

%% The method comes from the CLIENT, and cowboy's parser accepts ANY HTTP
%% token, so a caller can put an arbitrary string in this label and create
%% a new time series per request. Collapse to the registered method set:
%% it is what a dashboard actually filters on, and it is the semconv
%% `_OTHER' convention for anything else.
method_class(M) when is_binary(M) ->
    case lists:member(M, [
        <<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"DELETE">>,
        <<"CONNECT">>, <<"OPTIONS">>, <<"TRACE">>, <<"PATCH">>
    ]) of
        true -> M;
        false -> unknown
    end;
method_class(_) ->
    unknown.

%% The scheme of the connection the gateway ITSELF accepted.
%%
%% That is `http': the cowboy listener is `start_clear', and TLS is
%% terminated upstream (the proxy in front of the fleet). Reporting
%% `https' would describe the client's leg, which the gateway cannot see —
%% it never reads `x-forwarded-proto', and honouring that header would mean
%% trusting any client that can reach the listener to rewrite it. This
%% instrument measures the gateway's own server work, so it reports the
%% scheme the gateway actually served.
scheme_label() ->
    <<"http">>.

%% `gen_ai.client.inference.duration' (semconv, unit `s').
%%
%% Measured from the upstream attempt's own wall time, not the request
%% total: this instrument is about the PROVIDER call. Fed from the same
%% `janus_upstream_ms' value the LB EWMA uses, so the two cannot disagree
%% about how long the upstream took.
maybe_observe_genai_duration(Route) ->
    case {get(janus_upstream_ms), janus_telemetry:export_enabled()} of
        {Ms, true} when is_integer(Ms), Ms >= 0 ->
            janus_metrics:observe(
                gen_ai_client_inference_duration,
                #{
                    <<"gen_ai.operation.name">> => gen_ai_operation(Route),
                    <<"gen_ai.provider.name">> => gen_ai_provider(Route)
                },
                Ms / 1000
            );
        _ ->
            ok
    end.

%% The operation comes from the provider PROTOCOL published by
%% upstream_call/5. Hardcoding `chat' mislabelled every non-chat face
%% (image, TTS, ASR, decisions) in a way no dashboard could detect,
%% because the label was always `chat'.
gen_ai_operation(_Route) ->
    case get(janus_upstream_proto) of
        undefined -> <<"chat">>;
        Proto -> janus_otel_attr:operation_name(Proto)
    end.

gen_ai_provider(Route) ->
    janus_otel_attr:provider_name(janus_http_proxy:route_provider_name(Route)).

%% Feed the LB latency EWMA from the last upstream_call's wall time
%% (pdict). Absent on paths that never reached upstream_call — those
%% must not invent a sample.

%%%===================================================================
%%% OTel spans (P1)
%%%
%%% Telemetry never fails a request: every entry point here is total and
%%% returns `undefined' when there is nothing to record. A span is only
%%% opened when the trace is sampled, so an unsampled request pays one
%%% sampler read and no allocation.
%%%
%%% The CLIENT span is stored in the process dictionary under
%%% `janus_otel_spans' (a bounded list, newest first) so the terminal
%%% usage row can carry its span id without threading a handle through
%%% the whole dispatch chain.
%%%===================================================================


%% @doc Open the request's SERVER span. Called from the HTTP preamble at
%% the earliest point that has the trace context, and closed on the
%% terminal reply. Returns `undefined' when the trace is unsampled or the
%% trace context is absent, in which case every downstream span helper
%% becomes a no-op.
%%
%% SpanKind SERVER with `http.*' attributes: the `http.route' is the
%% matched route TEMPLATE, never the concrete path, because a path
%% contains ids and would be unbounded cardinality.
open_server_span(Method, Path) ->
    try
        Trace = get(janus_trace),
        case janus_trace:sampled(Trace) of
            false ->
                undefined;
            true ->
                Span0 = janus_otel_span:start(
                    server, server_span_name(Method, Path), undefined, janus_trace:trace_id(Trace)
                ),
                Span1 = janus_otel_span:set_attrs(Span0, #{
                    <<"http.request.method">> => iolist_to_binary(Method),
                    <<"url.path">> => janus_otel_attr:sanitize_value(iolist_to_binary(Path))
                }),
                put(janus_otel_server_span, Span1),
                %% Correlate log lines with the span they belong to, not
                %% just with the trace.
                _ = janus_trace:set_log_span(janus_otel_span:id(Span1)),
                Span1
        end
    catch
        _:_ -> undefined
    end.

%% The semconv's HTTP span name is `{method} {route}'. The route template
%% is not available at preamble time (routing has not run yet), so the
%% method plus the path is used and the path is capped by the attribute
%% sanitizer. Named for the method first so a backend can group by verb.
server_span_name(Method, Path) ->
    M = iolist_to_binary(Method),
    P = janus_otel_attr:sanitize_value(iolist_to_binary(Path)),
    <<M/binary, " ", P/binary>>.

%% @doc Close the SERVER span with the terminal status. Called once from
%% the terminal reply path; safe to call when no span was opened.
close_server_span(Status) ->
    try
        case get(janus_otel_server_span) of
            undefined ->
                ok;
            Span ->
                %% `http.response.status_code' is Cond. Required on an HTTP
                %% SERVER span and was never stamped anywhere (only the
                %% metric label carried it) — a backend could not tell a
                %% 401 reject span from a 413 without this.
                Span1 =
                    case is_integer(Status) of
                        true ->
                            janus_otel_span:set_attr(
                                Span, <<"http.response.status_code">>, Status
                            );
                        false ->
                            Span
                    end,
                Finished = janus_otel_span:finish(Span1, Status),
                put(janus_otel_server_span, Finished),
                _ = janus_trace:set_log_span(undefined),
                ok
        end
    catch
        _:_ -> ok
    end.

%% @doc Open one CLIENT span for this upstream attempt, or `undefined'
%% when the trace is not sampled. Returns the span record (closed later).
open_attempt_span(ProviderProto, Route, Map, WantStream) ->
    try
        Trace = get(janus_trace),
        case janus_trace:sampled(Trace) of
            false ->
                undefined;
            true ->
                Op = janus_otel_attr:operation_name(ProviderProto),
                Model = requested_model_for_span(Map),
                Parent = current_parent_span_id(),
                Span0 = janus_otel_span:start(
                    client,
                    janus_otel_attr:span_name(Op, Model),
                    Parent,
                    janus_trace:trace_id(Trace)
                ),
                Span1 = janus_otel_span:set_attrs(Span0, #{
                    <<"gen_ai.operation.name">> => Op,
                    <<"gen_ai.provider.name">> => janus_otel_attr:provider_name(
                        janus_http_proxy:route_provider_name(Route)
                    ),
                    <<"gen_ai.request.model">> => Model,
                    <<"gen_ai.request.stream">> => WantStream =:= true
                }),
                Span2 = add_server_address(Span1, Route),
                _ = push_span(Span2),
                Span2
        end
    catch
        _:_ -> undefined
    end.

%% The model the CLIENT actually asked the provider for. `janus_req_model'
%% is the resolved name; the requested name is the client's original.
requested_model_for_span(Map) ->
    case get(janus_req_model) of
        M when is_binary(M), M =/= <<>> ->
            M;
        _ ->
            case Map of
                #{<<"model">> := M} when is_binary(M) -> M;
                _ -> undefined
            end
    end.

%% `server.address'/`server.port' are Recommended/Required on the CLIENT
%% span; both come from the provider's base URL. Omitted when the
%% provider row is unavailable rather than guessed.
add_server_address(Span, Route) ->
    case route_provider_base(Route) of
        {ok, Host, Port} ->
            janus_otel_span:set_attrs(Span, #{
                <<"server.address">> => Host,
                <<"server.port">> => Port
            });
        _ ->
            Span
    end.

route_provider_base(Route) ->
    try
        case janus_catalog:lookup_provider(maps:get(provider_id, Route, undefined)) of
            {ok, #{base_url := Base0}} ->
                case janus_providers_http:parse_base(iolist_to_binary(Base0)) of
                    {ok, Host, Port, _Path, _Tls} -> {ok, Host, Port};
                    _ -> error
                end;
            _ ->
                error
        end
    catch
        _:_ -> error
    end.

%% Close the attempt span with its outcome. Transport failures are the
%% error class; an HTTP status uses the semconv rule via set_status.
close_attempt_span(undefined, _Result) ->
    ok;
close_attempt_span(Span, Result) ->
    try
        Status =
            case Result of
                {ok, S, _H, _B} when is_integer(S) -> S;
                {ok, stream, S, _H, _D} when is_integer(S) -> S;
                _ -> undefined
            end,
        Span1 = janus_otel_span:finish(Span, Status),
        Span2 = maybe_record_transport_error(Span1, Result),
        _ = replace_span(Span2),
        ok
    catch
        _:_ -> ok
    end.

maybe_record_transport_error(Span, {error, Reason}) ->
    janus_otel_span:set_error(Span, span_error_class(Reason));
maybe_record_transport_error(Span, _) ->
    Span.

%% Map a transport failure to the small closed set of error classes. The
%% raw reason is not used directly: it can embed provider text.
span_error_class(worker_lost) -> worker_lost;
span_error_class(crashed) -> transport;
span_error_class(timeout) -> timeout;
span_error_class(cancelled) -> cancelled;
span_error_class(R) when is_atom(R) -> transport;
span_error_class(_) -> transport.

%% Replace an OPEN span with its closed version, keeping its position.
%%
%% Matching is by span_id, not by value: the span has changed (end time,
%% status, and possibly usage attributes), so it can only be identified by
%% identity. If the open copy is already gone (a caller closed twice) the
%% closed copy is appended — never duplicated.
replace_span(Closed) ->
    Id = janus_otel_span:id(Closed),
    Prev = case get(janus_otel_spans) of
        L when is_list(L) -> L;
        _ -> []
    end,
    case lists:any(fun(S) -> janus_otel_span:id(S) =:= Id end, Prev) of
        true ->
            put(janus_otel_spans, [case janus_otel_span:id(S) =:= Id of
                true -> Closed;
                false -> S
            end || S <- Prev]),
            ok;
        false ->
            push_span(Closed)
    end.

%% The span stack: newest first, bounded so a pathological retry cascade
%% cannot grow the pdict without limit.
push_span(Span) ->
    Prev = case get(janus_otel_spans) of
        L when is_list(L) -> L;
        _ -> []
    end,
    put(janus_otel_spans, lists:sublist([Span | Prev], ?SPAN_KEEP)),
    ok.

%% The SERVER span id is the parent of every attempt span in this
%% request; `undefined' when the SERVER span was never opened (see
%% `server_span/0').
current_parent_span_id() ->
    case get(janus_otel_server_span) of
        undefined -> undefined;
        S -> janus_otel_span:id(S)
    end.

%% @doc Put the parsed token usage on this request's most recent CLIENT
%% span.
%%
%% `prompt' already includes the cached tokens (billing parity with the
%% provider's own input count), which is exactly what the semconv wants
%% for `gen_ai.usage.input_tokens': "includes cached tokens, report the
%% billed count". The cache dimensions ride as their own attributes and
%% are SUBSETS of input_tokens — never additive.
attach_usage_to_span(Usage) when is_map(Usage) ->
    try
        case attempt_spans() of
            [Latest | _] ->
                Attrs = #{
                    <<"gen_ai.usage.input_tokens">> => maps:get(prompt, Usage, undefined),
                    <<"gen_ai.usage.output_tokens">> => maps:get(completion, Usage, undefined),
                    <<"gen_ai.usage.cache_read.input_tokens">> => nonzero(maps:get(cache_read, Usage, undefined)),
                    <<"gen_ai.usage.cache_write.input_tokens">> => nonzero(maps:get(cache_write, Usage, undefined)),
                    %% Streaming only, and only when a content chunk
                    %% actually arrived: the semconv says MUST NOT set
                    %% this if no chunk was received, so `undefined'
                    %% omits the attribute rather than reporting 0.
                    <<"gen_ai.response.time_to_first_chunk">> => ttfc_seconds()
                },
                Updated = janus_otel_span:set_attrs(Latest, Attrs),
                _ = replace_span(Updated),
                ok;
            [] ->
                ok
        end
    catch
        _:_ -> ok
    end;
attach_usage_to_span(_) ->
    ok.

%% `gen_ai.client.inference.usage.*' token counters (semconv, unit
%% `{token}').
%%
%% One counter per dimension, each carrying `gen_ai.token.modality'.
%%
%% That attribute is mandated `unknown', not inferred as `text'. Providers
%% fold image and audio input into `prompt_tokens`, so after the cache
%% split we know the token COUNT but not its modality mix; the semconv
%% permits `unknown' for precisely this case. Inferring `text' would
%% fabricate a dimension and silently report image/audio traffic as text.
%%
%% `reasoning.output_tokens' is NOT emitted, and it is the one counter that
%% would not carry the modality attribute: it was removed from that
%% instrument on 2026-11-05 because reasoning counts are not split by
%% modality. The gateway does not account for reasoning tokens separately
%% today, so there is nothing to emit — recorded here so a later reader
%% does not add it with the attribute attached.
observe_genai_tokens(Route, Prompt, Completion, CacheRead, CacheWrite) ->
    %% export_enabled, not signal_enabled(metrics): same §13.4 reasoning
    %% as maybe_observe_genai_duration — the Prometheus families are a
    %% superset when export is on, regardless of signal selection.
    case janus_telemetry:export_enabled() of
        false ->
            ok;
        true ->
            %% Built ONCE, not per counter: the label map is identical for
            %% all four and rebuilding it four times per request is pure
            %% allocation on the hot path.
            Labels = #{
                <<"gen_ai.operation.name">> => gen_ai_operation(Route),
                <<"gen_ai.provider.name">> => gen_ai_provider(Route),
                %% The model is the discriminator that makes a token series
                %% answerable ("which model costs us the tokens?"). Bounded
                %% by the serving catalog, the same justification the
                %% existing `provider' label uses.
                <<"gen_ai.request.model">> => model_label(),
                %% Mandated `unknown', never inferred: providers fold image
                %% and audio input into `prompt_tokens', so the COUNT is
                %% known but not the mix.
                <<"gen_ai.token.modality">> => <<"unknown">>
            },
            _ = bump_token(gen_ai_client_inference_usage_input_tokens_total, Labels, Prompt),
            _ = bump_token(gen_ai_client_inference_usage_output_tokens_total, Labels, Completion),
            %% Cache dimensions report only when non-zero: a provider
            %% without caching must not emit a constant 0 series.
            _ = bump_token(
                gen_ai_client_inference_usage_cache_read_input_tokens_total, Labels, CacheRead
            ),
            _ = bump_token(
                gen_ai_client_inference_usage_cache_write_input_tokens_total, Labels, CacheWrite
            ),
            ok
    end.

%% The served model for this request, for the token counters.
%%
%% Read from the pdict entry the proxy sets at resolution time (the same
%% one usage rows record as `requested_model'). `_unknown' rather than
%% omitted: the semconv wants the discriminator present, and a missing
%% model must not silently collapse into another model's series.
model_label() ->
    case get(janus_req_model) of
        M when is_binary(M), M =/= <<>> -> M;
        _ -> <<"_unknown">>
    end.

%% Add a token count. `inc/3' ignores non-positive values, which is exactly
%% the non-zero-only rule the cache dimensions need — so there is one
%% helper, not two.
bump_token(_Name, _Labels, null) -> ok;
bump_token(_Name, _Labels, undefined) -> ok;
bump_token(Name, Labels, N) when is_integer(N) ->
    janus_metrics:inc(Name, Labels, N),
    ok;
bump_token(_, _, _) -> ok.

%% The semconv says report a cache attribute only when non-zero, so a
%% provider that does not do caching does not emit a constant 0.
nonzero(0) -> undefined;
nonzero(undefined) -> undefined;
nonzero(null) -> undefined;
nonzero(V) -> V.

%% @doc Hand this request's finished spans to the exporter. Called once on
%% the terminal path, AFTER the SERVER span is closed so the batch is
%% complete. Each span is passed individually and the exporter batches;
%% `record/1' is a cast, so this costs the request one message send and
%% never waits on the collector.
%%
%% Order matters for a reader: the SERVER span is emitted last so a
%% backend that ingests a batch in order sees the parent after its
%% children. OTLP does not require it, but a human tailing the collector
%% log finds it easier.
export_request_spans() ->
    try
        case get(janus_otel_server_span) of
            undefined ->
                ok;
            Server ->
                _ = [janus_otel_export:record(S) || S <- lists:reverse(attempt_spans())],
                janus_otel_export:record(Server),
                ok
        end
    catch
        _:_ -> ok
    end.

%% @doc Spans recorded for this request, newest first. Read by the usage
%% writer to stamp span ids on the ledger.
attempt_spans() ->
    case get(janus_otel_spans) of
        L when is_list(L) -> L;
        _ -> []
    end.

%% Span identity for a ledger row: the request's SERVER span and the
%% attempt's CLIENT span. Both are `null' when unsampled, which is
%% correct - an unsampled request has no span to join to, and writing a
%% fabricated id would make the ledger lie.
row_span_ids() ->
    Server =
        case get(janus_otel_server_span) of
            undefined -> null;
            S -> janus_otel_span:id(S)
        end,
    Client =
        case attempt_spans() of
            [Latest | _] -> janus_otel_span:id(Latest);
            [] -> null
        end,
    #{span_id => Client, parent_span_id => Server}.

