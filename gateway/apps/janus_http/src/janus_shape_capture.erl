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
    translate_reject/3
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
            Owner ! go,
            receive
                ready -> ok
            after 5000 -> ok
            end;
        _ ->
            ok
    end.

owner_loop() ->
    receive
        go ->
            Tid =
                ets:new(?DEDUP_TABLE, [
                    named_table, public, set, {write_concurrency, true}
                ]),
            %% Periodic sweep so the table stays bounded by the
            %% DISTINCT shapes in the window, not by history.
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
