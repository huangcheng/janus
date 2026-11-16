%%%-------------------------------------------------------------------
%%% @doc Shape sentinel (2026-10-28): on shape-class failures, capture
%%% the STRUCTURE of the offending request so the next occurrence
%%% self-documents in the log ring.
%%%
%%% Born from a live debugging session: an unknown client shape kept
%%% tripping strict upstreams; six candidate shapes were probed blind
%%% before a one-off capture hook (janus_tool_adjacency_shape) caught
%%% the real one — an orphan tool result, an ID mismatch no position
%%% analysis could find. This module generalizes that hook into a
%%% platform mechanism.
%%%
%%% Disciplines (docs/design/shape-sentinel.md):
%%%
%%% - STRUCTURE ONLY, never content. Fingerprints carry roles, part
%%%   types and opaque call ids — never prompts, tool arguments or
%%%   any user bytes. This is the hard privacy invariant.
%%% - SHAPE-CLASS failures only: upstream 4xx with tool-adjacency or
%%%   invalid-parameter semantics, and gateway translate_unsupported
%%%   rejects. Business errors (auth, quota, routing) stay out — the
%%%   sentinel diagnoses request SHAPES, not traffic.
%%% - DEDUP: the same {class, shape hash} logs once per window
%%%   (default 10 min) — a retry-looping bad harness must not flood
%%%   the ring.
%%% - NEVER in the request path: every entry point is fail-safe; a
%%%   sentinel crash is silently swallowed, the request is unaffected.
%%% - The trigger phrase table is the learning surface: when a new
%%%   failure class is diagnosed, add its phrase + shape kind here in
%%%   the same commit as the fix (the commit message records why).
%%%
%%% Storage is the EXISTING log ring: logger:warning lands in docker
%%% logs, the dashboard nodes poller drains it into gateway_log_events
%%% — queryable history that survives container rebuilds.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_shape_capture).

-export([
    upstream_reject/3,
    translate_reject/3,
    stream_translate_reject/3,
    %% Pure frame sketch, exported so eunit can pin the content discipline
    %% (values reduced to type labels) without running a logger handler.
    stream_frame_shape/1,
    typed_value/1
]).

-define(DEDUP_TABLE, janus_shape_sentinel_dedup).
-define(DEDUP_WINDOW_MS, 600_000).

%%%===================================================================
%%% Entry points (fail-safe: never in the request path)
%%%===================================================================

%% Called from failover_decide with the upstream-bound body and the
%% normalized upstream result. Captures BOTH sides: the provider shape
%% (what we sent) and the client shape (what arrived) — harness bugs
%% read clearest on the client side, translation bugs on the provider
%% side.
-spec upstream_reject(binary() | map(), map() | undefined, {ok, pos_integer(), map(), binary()}) ->
    ok.
upstream_reject(ProviderBody, ClientMap, {ok, Status, _H, RespBody}) when
    Status >= 400, Status =< 422
->
    safe(fun() ->
        case classify_upstream_body(RespBody) of
            none ->
                ok;
            Class ->
                Shape = #{
                    provider => shape_of(ProviderBody),
                    client => client_shape_of(ClientMap)
                },
                log_once(Class, Shape)
        end
    end);
upstream_reject(_, _, _) ->
    ok.

%% Called where a translate_unsupported reply fires — the gateway
%% rejected a shape it cannot carry. The CLIENT shape is the payload
%% (no provider body exists).
-spec translate_reject(atom(), map(), binary()) -> ok.
translate_reject(ClientProto, ClientMap, _Msg) ->
    safe(fun() ->
        Shape = #{
            proto => ClientProto,
            client => client_shape_of(ClientMap)
        },
        log_once(translate_unsupported, Shape)
    end),
    ok.

%% Called when the STREAM mapper rejected an upstream frame mid-flight
%% ("upstream sent an unsupported stream construct"). Distinct from
%% translate_reject/3 above: there the gw rejected the CLIENT's REQUEST shape,
%% here it is the PROVIDER's in-band stream frame that could not be carried.
%%
%% This path used to be entirely silent. The client got the generic construct
%% message, the usage row recorded it as a generic 502, and nothing anywhere
%% said WHICH frame confused the mapper — so the only way to act on it was to
%% reproduce the stream and guess. The fingerprint is the missing half.
%%
%% Content discipline (docs/design/shape-sentinel.md): the frame's KEYS and
%% value TYPES only — never a value. An SSE frame can carry the whole answer.
-spec stream_translate_reject(atom(), atom(), term()) -> ok.
stream_translate_reject(ClientProto, ProviderProto, Frame) ->
    safe(fun() ->
        Shape = #{
            proto => ClientProto,
            provider_proto => ProviderProto,
            frame => stream_frame_shape(Frame)
        },
        log_once(upstream_stream_construct, Shape)
    end),
    ok.

%% Structural sketch of one upstream SSE frame: the event name, and the shape
%% of its data map. Values never appear — only key names and types — so this
%% is safe to log for any provider.
stream_frame_shape(Frame) when is_map(Frame) ->
    #{
        %% The EVENT NAME is protocol vocabulary ("content_block_delta"), not
        %% user content, and it is the single most useful field for diagnosing
        %% "which frame confused the mapper" — so it is logged as its own
        %% short binary rather than collapsed to a type label.
        event => event_name(maps:get(type, Frame, undefined)),
        keys => lists:sort([K || K <- maps:keys(Frame), is_binary(K)]),
        data => stream_data_shape(maps:get(data, Frame, undefined))
    };
stream_frame_shape(Other) ->
    typed_value(Other).

stream_data_shape(D) when is_map(D) ->
    #{
        keys => lists:sort([K || K <- maps:keys(D), is_binary(K)]),
        types => maps:from_list([
            {K, typed_value(V)}
         || {K, V} <- maps:to_list(D), is_binary(K)
        ])
    };
stream_data_shape(Other) ->
    typed_value(Other).

%% SSE event names are a closed protocol vocabulary, so they are safe — and
%% essential — to log verbatim. Anything long or non-binary degrades to a type
%% label, since at that point it is no longer distinguishable from content.
%% Allow-listed, because `type` is NOT a closed vocabulary at the point this
%% runs: sse_event/2 copies the provider's raw `event:` line straight into the
%% map, so an arbitrary (provider-controlled) binary can arrive here. Echoing
%% any short binary would break this module's "structure only, never user
%% bytes" invariant — 64 bytes of provider-controlled text is still content.
%% Anything unrecognised is reported as `unknown_event`; the frame's KEYS and
%% TYPES below still identify it.
-define(KNOWN_EVENTS, [
    <<"chunk">>,
    <<"done">>,
    <<"error">>,
    <<"message_start">>,
    <<"message_delta">>,
    <<"message_stop">>,
    <<"content_block_start">>,
    <<"content_block_delta">>,
    <<"content_block_stop">>,
    <<"response.created">>,
    <<"response.completed">>,
    <<"response.failed">>,
    <<"response.output_item.added">>,
    <<"response.output_item.done">>,
    <<"response.content_part.added">>,
    <<"response.content_part.done">>,
    <<"response.output_text.delta">>,
    <<"response.output_text.done">>,
    <<"response.reasoning_summary_text.delta">>,
    <<"response.reasoning_summary_text.done">>,
    <<"response.function_call_arguments.delta">>,
    <<"response.function_call_arguments.done">>
]).

event_name(V) when is_atom(V) -> V;
event_name(V) when is_binary(V) ->
    case lists:member(V, ?KNOWN_EVENTS) of
        true -> V;
        false -> unknown_event
    end;
event_name(V) -> typed_value(V).

%% A type label, never the value. Binaries report only whether they are empty.
typed_value(undefined) -> undefined;
typed_value(V) when is_binary(V) ->
    case V of
        <<>> -> empty;
        _ -> binary
    end;
typed_value(V) when is_integer(V) -> integer;
typed_value(V) when is_float(V) -> float;
typed_value(V) when is_boolean(V) -> boolean;
typed_value(V) when is_atom(V) -> atom;
typed_value(V) when is_list(V) -> list;
typed_value(V) when is_map(V) -> map;
typed_value(_) -> other.

%%%===================================================================
%%% Classification (the learning surface — extend with every new
%%% diagnosed failure class)
%%%===================================================================

classify_upstream_body(B) when is_binary(B), byte_size(B) > 0 ->
    case tool_adjacency_phrase(B) of
        true ->
            tool_adjacency;
        false ->
            case invalid_parameter_phrase(B) of
                true -> invalid_parameter;
                false -> none
            end
    end;
classify_upstream_body(_) ->
    none.

tool_adjacency_phrase(B) ->
    binary:match(B, [
        <<"must be followed by tool messages">>,
        <<"insufficient tool messages">>,
        <<"tool call result does not follow">>,
        <<"(2013)">>,
        <<"tool_call_id in the response message does not match">>
    ]) =/= nomatch.

invalid_parameter_phrase(B) ->
    binary:match(B, [
        <<"InvalidParameter">>,
        <<"invalid_request_error">>,
        <<"invalid params">>,
        <<"does not match">>
    ]) =/= nomatch.

%%%===================================================================
%%% Shapes — structure only, content never
%%%===================================================================

%% The provider body: the chat/anthropic messages shape, or the
%% passthrough map for modality bodies (roles/units only).
shape_of(Body) when is_binary(Body) ->
    case thoas:decode(Body) of
        {ok, Dec} when is_map(Dec) -> shape_of(Dec);
        _ -> []
    end;
shape_of(#{<<"messages">> := _} = Map) ->
    janus_protocol_translate:message_shape(Map);
shape_of(Map) when is_map(Map) ->
    maps:filter(
        fun
            (<<"messages">>, _) -> false;
            (<<"input">>, _) -> false;
            (_, V) when is_binary(V) -> byte_size(V) =< 40;
            (_, _) -> false
        end,
        Map
    );
shape_of(Other) ->
    Other.

%% The client map: messages shape for the chat family, the items
%% shape for responses (type/role/call-id triples only).
client_shape_of(#{<<"input">> := Items} = Map) when is_list(Items) ->
    #{
        model => maps:get(<<"model">>, Map, undefined),
        items => [input_item_shape(I) || I <- Items]
    };
client_shape_of(#{<<"messages">> := _} = Map) ->
    janus_protocol_translate:message_shape(Map);
client_shape_of(Map) when is_map(Map) ->
    maps:filter(
        fun
            (<<"messages">>, _) -> false;
            (_, V) when is_binary(V) -> byte_size(V) =< 40;
            (_, _) -> false
        end,
        Map
    );
client_shape_of(Other) ->
    Other.

input_item_shape(#{<<"type">> := <<"function_call">>, <<"call_id">> := Id, <<"name">> := N}) ->
    #{t => call, id => Id, name => N};
input_item_shape(#{<<"type">> := <<"function_call_output">>, <<"call_id">> := Id}) ->
    #{t => output, id => Id};
input_item_shape(#{<<"type">> := T, <<"role">> := R}) ->
    #{t => T, role => R};
input_item_shape(#{<<"type">> := T}) ->
    #{t => T};
input_item_shape(#{<<"role">> := R}) ->
    %% The bare (untyped) message-item form the translate accepts.
    #{t => message_implicit, role => R};
input_item_shape(I) when is_map(I) ->
    #{t => map};
input_item_shape(_) ->
    #{t => other}.

%%%===================================================================
%%% Dedup + logging
%%%===================================================================

log_once(Class, Shape) ->
    Hash = erlang:phash2({Class, Shape}),
    case recent(Hash) of
        true ->
            ok;
        false ->
            logger:warning(#{
                what => janus_shape_sentinel,
                class => Class,
                shape => Shape
            })
    end.

recent(Hash) ->
    ensure_table(),
    Now = erlang:monotonic_time(millisecond),
    try
        case ets:lookup(?DEDUP_TABLE, Hash) of
            [{_, At}] when Now - At < ?DEDUP_WINDOW_MS ->
                true;
            _ ->
                ets:insert(?DEDUP_TABLE, {Hash, Now}),
                false
        end
    catch
        _:_ ->
            %% A broken dedup table must never silence the sentinel.
            false
    end.

ensure_table() ->
    case whereis(janus_shape_sentinel_owner) of
        undefined ->
            Owner = spawn(fun owner_loop/0),
            register(janus_shape_sentinel_owner, Owner),
            Owner ! {go, self()},
            receive
                ready -> ok
            after 5000 -> ok
            end;
        _ ->
            ok
    end.

owner_loop() ->
    receive
        {go, From} when is_pid(From) ->
            Tid =
                ets:new(?DEDUP_TABLE, [
                    named_table, public, set, {write_concurrency, true}
                ]),
            %% Unblock ensure_table/0 — without this the first caller
            %% always burns the full 5s receive timeout.
            From ! ready,
            %% Periodic sweep so the table stays bounded by the
            %% DISTINCT shapes in the window, not by history.
            sweep_loop(Tid);
        %% Legacy atom form (tests / older callers): create the table
        %% but nobody is waiting.
        go ->
            Tid =
                ets:new(?DEDUP_TABLE, [
                    named_table, public, set, {write_concurrency, true}
                ]),
            sweep_loop(Tid)
    end.

sweep_loop(Tid) ->
    receive
    after ?DEDUP_WINDOW_MS ->
        Now = erlang:monotonic_time(millisecond),
        ets:safe_fixtable(Tid, true),
        _ = [ets:delete(Tid, K) || {K, At} <- ets:tab2list(Tid), Now - At >= ?DEDUP_WINDOW_MS],
        ets:safe_fixtable(Tid, false),
        sweep_loop(Tid)
    end.

safe(F) ->
    try
        F()
    catch
        _:_ ->
            ok
    end.
