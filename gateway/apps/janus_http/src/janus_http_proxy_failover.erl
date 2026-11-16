%%%-------------------------------------------------------------------
%%% @doc In-request key failover and retry classification for the
%%% data-plane proxy. Extracted from `janus_http_proxy` for OCR line budget.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy_failover).

-export([
    failover_start/0,
    failover_classify/2,
    failover_decide/7,
    bump_auto_name_failover/0,
    within_failover_budget/0,
    failover_knobs/0,
    is_advanceable_pick_error/1,
    pick_error_status/1,
    vision_gate/2,
    record_failover_row/3,
    bump_failed_maybe/1,
    error_map/3,
    filter_headers/1,
    filter_headers_json/1,
    filter_stream_headers/1,
    inc_total_once/0,
    mark_client_committed/0,
    maybe_crash_bump_failed/0,
    maybe_next_name_on_pick_error/6,
    note_attempt_outcome/4,
    note_auth_failure/2,
    note_key_failure/3,
    note_key_success/1,
    note_provider_failure/2,
    note_route_failure/2,
    note_route_success/1,
    pd/2,
    release_route_inflight/1,
    maybe_note_latency/1,
    repick_route/3,
    reply_err/6,
    reply_err/7,
    reply_json/4,
    reply_pick_error/4,
    retry_jitter/0,
    stash_classification/2
]).

%% Mirror of the wire-enc abort recognizer in janus_http_proxy.
-define(IS_WIRE_ENC_ABORT(R),
    ((R) =:= wire_enc_inflate_fail orelse
        (is_tuple(R) andalso tuple_size(R) >= 1 andalso
            element(1, R) =:= wire_enc_inflate_fail))
).

%%%--------------------------------------------------------------------
%%% In-request key failover (spec Part C)
%%%
%%% Wraps every upstream attempt: retryable key-scoped failures
%%% (401/403/429/deny-shaped 400/404, 5xx, transport) retry on another
%%% key/route inside the budget; input-shape 400s and committed 2xx
%%% streams are terminal. The FIRST call is unconditional; the knobs
%%% bound RETRIES. Knobs live in the settings table (failover key,
%%% distributed via persistent_term) with sys.config defaults.
%%%--------------------------------------------------------------------

pd(Key, Default) ->
    case get(Key) of
        undefined -> Default;
        V -> V
    end.

failover_knobs() ->
    case persistent_term:get({janus, failover_cfg}, undefined) of
        #{<<"max_attempts">> := A} = Cfg when is_integer(A), A >= 0, A =< 20 ->
            B =
                case maps:get(<<"max_budget_ms">>, Cfg, 45000) of
                    BB when is_integer(BB), BB > 0 -> min(BB, 180000);
                    _ -> 45000
                end,
            {A, B};
        _ ->
            {application:get_env(janus, failover_max_attempts, 3),
                application:get_env(janus, failover_max_budget_ms, 45000)}
    end.

failover_start() ->
    case get(janus_failover_started) of
        undefined ->
            put(janus_failover_started, erlang:monotonic_time(millisecond)),
            put(janus_failover_ref, binary:encode_hex(crypto:strong_rand_bytes(16))),
            %% janus_failover_attempt: monotonic usage attempt (D17).
            %% janus_part_c_attempt: per-name Part C counter (D6; reset
            %% on next-name advance). Both start at 1; stay in sync
            %% unless a next-name advance resets only part_c.
            put(janus_failover_attempt, 1),
            put(janus_part_c_attempt, 1),
            ok;
        _ ->
            ok
    end.

%% Error-status streams are collected HERE (pre-reply upstream state is
%% retryable; the body feeds classification).
normalize_result({ok, stream, Status, Headers, Drain}) when Status >= 400 ->
    case janus_http_proxy:collect_drain(Drain) of
        {ok, Body} -> {ok, Status, Headers, Body};
        {error, Reason} -> {error, Reason}
    end;
normalize_result(R) ->
    R.

%% {continue, Result} -> caller replies via handle_upstream.
%% {handled, {ok, Req, State}} -> a retry completed the request.
%%
%% Next-name (design 2026-10-15 D3/D16): when Part C would surface a
%% retryable error (attempts/budget exhausted OR same-model repick
%% empty), intercept BEFORE continue and try the next snapshotted tier
%% name when gates allow. Judge path never reaches here (D14).
failover_decide(ClientProto, Route, Map, Body, Result0, Req, State) ->
    failover_start(),
    Result = remap_worker_http_status(normalize_result(Result0)),
    janus_http_proxy:stash_upstream_error_detail(Result),
    %% Shape sentinel (2026-10-28): shape-class upstream rejects
    %% capture the structural fingerprint of BOTH sides.
    janus_shape_capture:upstream_reject(Body, Map, Result),
    maybe_count_auto_http_attempt(Result),
    case failover_classify(Route, Result) of
        terminal ->
            {continue, Result};
        {retryable, Reason, NativeCode} ->
            {Attempts, Budget} = failover_knobs(),
            PartC = pd(janus_part_c_attempt, pd(janus_failover_attempt, 1)),
            Elapsed = erlang:monotonic_time(millisecond) - pd(janus_failover_started, 0),
            case PartC =< Attempts andalso Elapsed < Budget of
                true ->
                    mark_key_attempted(Route),
                    case repick_route(ClientProto, Map, 3) of
                        {ok, Route2} ->
                            %% Note/cool only when a same-model retry will
                            %% actually run — otherwise a continue after
                            %% exhausted keys double-counted the failure
                            %% (ocr high on peel).
                            failover_note(Route, Result),
                            failover_record_attempt(Route, Result, {Reason, NativeCode}),
                            %% Spec Part C: sleep the jitter — retry bursts
                            %% must not hammer a sick upstream back-to-back.
                            timer:sleep(retry_jitter()),
                            janus_lb:bump_stat(requests_retried),
                            bump_usage_and_part_c(),
                            {handled, retry_dispatch(ClientProto, Route2, Body, Map, Req, State)};
                        error ->
                            %% Same-model keys exhausted — try next name.
                            %% RecordNeeded=true: we have not noted Route yet
                            %% (note only runs on a successful same-model
                            %% repick above).
                            maybe_advance_tier_name(
                                ClientProto, Route, Map, Result, {Reason, NativeCode}, Req, State,
                                true
                            )
                    end;
                false ->
                    janus_lb:bump_stat(failovers_exhausted),
                    %% Budget / max_attempts for this name — try next name
                    %% (record the failed attempt only if we actually advance).
                    maybe_advance_tier_name(
                        ClientProto, Route, Map, Result, {Reason, NativeCode}, Req, State,
                        true
                    )
            end
    end.

%% D17: usage attempt is monotonic across names; Part C counter tracks
%% per-name key retries.
bump_usage_and_part_c() ->
    put(janus_failover_attempt, pd(janus_failover_attempt, 1) + 1),
    put(janus_part_c_attempt, pd(janus_part_c_attempt, 1) + 1),
    ok.

%% Count real upstream HTTP statuses for D15 (transport errors do not).
maybe_count_auto_http_attempt({ok, Status, _H, _B}) when is_integer(Status) ->
    case get(janus_auto_tier_failover) of
        true -> put(janus_auto_http_attempts, pd(janus_auto_http_attempts, 0) + 1);
        _ -> ok
    end;
maybe_count_auto_http_attempt({ok, stream, Status, _H, _D}) when is_integer(Status) ->
    case get(janus_auto_tier_failover) of
        true -> put(janus_auto_http_attempts, pd(janus_auto_http_attempts, 0) + 1);
        _ -> ok
    end;
maybe_count_auto_http_attempt(_) ->
    ok.

%% D4: pre-forward worker HTTP errors arrive as a 4-tuple carrying the
%% upstream Headers/Body. Remap to the local {ok,Status,H,B} shape
%% BEFORE classify so deny/rate/balance body rules apply unchanged.
%% The 2-tuple form means post-forward (or bodyless) and stays N9.
%% Remapped non-2xx must NOT take the success commit path — classify
%% + failover_note see the status, never treat it as 2xx.
remap_worker_http_status({error, {worker_http_status, Status, Headers, Body}}) when
    is_integer(Status), is_map(Headers), is_binary(Body)
->
    {ok, Status, Headers, Body};
remap_worker_http_status(R) ->
    R.

%%--------------------------------------------------------------------
%% Same-tier next-name failover (design 2026-10-15 D3/D5/D6/D7/D15/D16)
%%--------------------------------------------------------------------

%% RecordNeeded=true: Part C budget/attempts exhausted without having
%% written a non-terminal usage row yet — note+record only if we advance.
%% RecordNeeded=false: already noted/recorded/bumped before a failed repick.
maybe_advance_tier_name(ClientProto, Route, Map, Result, Classified, Req, State, RecordNeeded) ->
    case next_name_gates_ok(Result) of
        false ->
            logger:info(#{
                what => janus_auto_walk_gate_closed,
                tier => get(janus_auto_tier),
                %% A4: which zone/rule settled this tier, and what a judge
                %% was shown (shape only). Without these a surprising tier
                %% is unexplainable without replaying the request.
                decided => get(janus_auto_decided),
                shape => get(janus_auto_shape),
                enabled => get(janus_auto_tier_failover),
                committed => client_committed(),
                names => get(janus_auto_tier_names),
                attempted => pd(janus_auto_names_attempted, [])
            }),
            {continue, Result};
        true ->
            case next_eligible_carry(ClientProto, Map) of
                {ok, Next, Route2} ->
                    logger:info(#{
                        what => janus_auto_walk_advance,
                        from => get(janus_req_model),
                        to => Next
                    }),
                    case RecordNeeded of
                        true ->
                            failover_note(Route, Result),
                            failover_record_attempt(Route, Result, Classified),
                            put(janus_failover_attempt, pd(janus_failover_attempt, 1) + 1);
                        false ->
                            ok
                    end,
                    advance_tier_name(Next, Route2, ClientProto, Map, Req, State);
                {exhausted, Why} ->
                    logger:info(#{
                        what => janus_auto_walk_exhausted,
                        tier => get(janus_auto_tier),
                        decided => get(janus_auto_decided),
                        shape => get(janus_auto_shape),
                        why => Why,
                        names => get(janus_auto_tier_names),
                        attempted => pd(janus_auto_names_attempted, [])
                    }),
                    bump_auto_name_exhausted(Why),
                    case Why =:= all_cooling andalso pd(janus_auto_http_attempts, 0) =:= 0 of
                        true ->
                            %% D15.1: zero HTTP attempts → all_cooling/503.
                            %% Still release the picked route's inflight —
                            %% failover_note never ran on this path (ocr high).
                            _ = janus_http_proxy:release_route_inflight(Route),
                            {handled, reply_pick_error(ClientProto, Req, State, all_cooling)};
                        false ->
                            %% D15.2: last upstream error (already in Result).
                            %% Ensure the failed attempt is noted if we never
                            %% recorded it on the way here.
                            case RecordNeeded of
                                true ->
                                    failover_note(Route, Result),
                                    failover_record_attempt(Route, Result, Classified);
                                false ->
                                    ok
                            end,
                            {continue, Result}
                    end
            end
    end.

%% Pick-error entry (initial empty pick before any upstream HTTP):
%% all_cooling, provider_disabled, keys_disabled and
%% missing_provider_key all mean "this tier member cannot serve", so
%% the walk may probe the next name (D7's empty-pick class). When the
%% walk exhausts, the caller replies with the ORIGINAL reason — the
%% client-visible status stays honest.
maybe_next_name_on_pick_error(ClientProto, Reason, _Body, Map, Req, State) ->
    case next_name_gates_ok(pick_error) andalso is_advanceable_pick_error(Reason) of
        false ->
            continue;
        true ->
            case next_eligible_carry(ClientProto, Map) of
                {ok, Next, Route2} ->
                    %% advance_tier_name already returns `{handled, _}`.
                    advance_tier_name(Next, Route2, ClientProto, Map, Req, State);
                {exhausted, Why} ->
                    bump_auto_name_exhausted(Why),
                    %% Fall through to the original pick-error reply.
                    continue
            end
    end.

%% Pick errors the next-name walk can skip. catalog_not_ready and a
%% plain no_route stay terminal (the former is a node-wide condition,
%% the latter a 404 with no tier semantics). Other reasons keep their
%% current terminal behaviour.
is_advanceable_pick_error(all_cooling) -> true;
is_advanceable_pick_error({all_cooling, _}) -> true;
is_advanceable_pick_error(provider_disabled) -> true;
is_advanceable_pick_error(keys_disabled) -> true;
is_advanceable_pick_error(missing_provider_key) -> true;
is_advanceable_pick_error(_) -> false.

%% D5's commit marker is the Cowboy WRITE (mark_client_committed on
%% every reply / stream_reply). janus_worker_forwarded is NOT a client
%% commit: it is the worker client's per-dispatch pre-byte predicate
%% for the unary fallback, and the worker client sets it on result
%% emission (janus_error / unary done legs) even when zero bytes ever
%% reached the client. OR-ing it here closed the same-tier walk for
%% every worker-path upstream error — a TTFB timeout 504'd with the
%% walk frozen despite healthy tier siblings (2026-10-21, flag
%% visible in janus_auto_walk_gate_closed: committed=true on a
%% zero-byte timeout).
client_committed() ->
    get(janus_client_committed) =:= true.

%% D5: any Cowboy write commits the request against next-name.
mark_client_committed() ->
    put(janus_client_committed, true),
    ok.

upstream_2xx_result(pick_error) -> false;
upstream_2xx_result({ok, Status, _H, _B}) when is_integer(Status), Status >= 200, Status < 300 ->
    true;
upstream_2xx_result({ok, stream, Status, _H, _D}) when is_integer(Status), Status >= 200, Status < 300 ->
    true;
upstream_2xx_result(_) ->
    false.

within_failover_budget() ->
    {_Attempts, Budget} = failover_knobs(),
    Started = pd(janus_failover_started, undefined),
    case Started of
        undefined ->
            %% No upstream yet (pick-error path) — budget starts at first
            %% attempt; allow the advance probe.
            true;
        S when is_integer(S) ->
            erlang:monotonic_time(millisecond) - S < Budget
    end.

%% Walk strictly rightward from the last attempted index (D2/D7).
%% Skips bump skip_total and do not consume max_names. Successful pick
%% is carried into dispatch (no second pick).
next_eligible_carry(ClientProto, Map) ->
    Names = pd(janus_auto_tier_names, []),
    Attempted = pd(janus_auto_names_attempted, []),
    case Attempted of
        [] ->
            {exhausted, no_eligible};
        _ ->
            Last = lists:last(Attempted),
            case index_of_name(Last, Names) of
                error ->
                    {exhausted, no_eligible};
                Idx ->
                    Len = length(Names),
                    walk_eligible(Idx + 1, Len, Names, Attempted, ClientProto, Map, no_eligible)
            end
    end.

walk_eligible(I, Len, _Names, _Attempted, _ClientProto, _Map, LastSkip) when I > Len ->
    {exhausted, LastSkip};
walk_eligible(I, Len, Names, Attempted, ClientProto, Map, LastSkip) ->
    Name = lists:nth(I, Names),
    case lists:member(Name, Attempted) of
        true ->
            walk_eligible(I + 1, Len, Names, Attempted, ClientProto, Map, LastSkip);
        false ->
            case probe_next_name(Name, ClientProto, Map) of
                {ok, Route} ->
                    {ok, Name, Route};
                {skip, Reason} ->
                    bump_auto_name_skip(Reason),
                    NextSkip =
                        case Reason of
                            all_cooling -> all_cooling;
                            _ when LastSkip =:= all_cooling -> all_cooling;
                            _ -> no_eligible
                        end,
                    walk_eligible(I + 1, Len, Names, Attempted, ClientProto, Map, NextSkip)
            end
    end.

index_of_name(Name, Names) ->
    index_of_name(Name, Names, 1).

index_of_name(_Name, [], _) -> error;
index_of_name(Name, [Name | _], I) -> I;
index_of_name(Name, [_ | Rest], I) -> index_of_name(Name, Rest, I + 1).

%% D7 skip classes: unavailable / stream-incompatible / modality /
%% protocol_requires_native / stream_pair_untranslatable / all_cooling.
%% try/catch: a catalog/LB hiccup must skip, not crash the proxy (ocr).
probe_next_name(Name, ClientProto, Map) ->
    try
        probe_next_name_unguarded(Name, ClientProto, Map)
    catch
        Class:Reason:Stack ->
            logger:warning(#{
                what => janus_auto_next_name_probe_crashed,
                name => Name,
                class => Class,
                reason => Reason,
                stack => janus_seed:redact_stack(Stack)
            }),
            {skip, unavailable}
    end.

%% The vision gate as a pure decision, so eunit can pin the exact rule the
%% walk applies instead of re-deriving it: a candidate is unusable when the
%% request carries an image and the candidate cannot read one. Split out
%% because the surrounding probe also consults the catalog and the load
%% balancer, which makes the production regression (an image-bearing
%% request routed to a vision-incapable candidate) impossible to state as
%% a test.
-spec vision_gate(binary(), map()) -> ok | skip.
vision_gate(Name, Constraint) when is_map(Constraint) ->
    case maps:get(vision, Constraint, false) andalso not janus_catalog:vision_capable(Name) of
        true -> skip;
        false -> ok
    end.

probe_next_name_unguarded(Name, ClientProto, Map) ->
    Constraint = #{
        client_proto => ClientProto,
        stream => janus_http_proxy:stream_translate_blocked_for(ClientProto, Map),
        vision => janus_http_proxy:request_has_image(Map)
    },
    case vision_gate(Name, Constraint) of
        skip ->
            {skip, no_vision};
        ok ->
            case janus_auto:model_available(Name) of
                false ->
                    {skip, unavailable};
                true ->
                    case janus_auto:stream_compatible(Name, Constraint) of
                        false ->
                            {skip, stream_incompatible};
                        true ->
                            case janus_http_proxy:proto_gate(ClientProto, Name) of
                                {error, protocol_requires_native} ->
                                    {skip, protocol_requires_native};
                                ok ->
                                    case janus_catalog:model_modality(Name) of
                                        <<"chat">> ->
                                            pick_probe_route(Name, ClientProto, Map);
                                        _ ->
                                            {skip, wrong_modality}
                                    end
                            end
                    end
            end
    end.

pick_probe_route(Name, ClientProto, Map) ->
    PickOpts = janus_http_proxy:stream_pick_opts(ClientProto, Map),
    Pick =
        case janus_http_proxy:resolve_model(Name) of
            {ok, ModelId} -> janus_lb:pick_route(ModelId, PickOpts);
            error -> janus_lb:pick_listing_route(Name, PickOpts)
        end,
    case Pick of
        {ok, Route} ->
            case janus_http_proxy:provider_protocol(Route) of
                {ok, RP} ->
                    StreamUnservable =
                        janus_protocol_translate:wants_stream(Map) andalso
                            janus_protocol_translate:stream_pair_untranslatable(ClientProto, RP),
                    case StreamUnservable of
                        true ->
                            _ = janus_http_proxy:release_route_inflight(Route),
                            {skip, stream_pair_untranslatable};
                        false ->
                            {ok, Route}
                    end;
                {error, unknown_protocol} ->
                    _ = janus_http_proxy:release_route_inflight(Route),
                    {skip, unavailable}
            end;
        {error, all_cooling} ->
            {skip, all_cooling};
        {error, {all_cooling, _}} ->
            {skip, all_cooling};
        {error, _} ->
            %% Not a cooling condition (provider_disabled, malformed
            %% route, ...): report the module's generic skip vocabulary
            %% instead of mislabelling it all_cooling and letting
            %% walk_eligible/7 promote it into a bogus 503 (review 02c
            %% M1).
            {skip, unavailable}
    end.

advance_tier_name(Next, Route2, ClientProto, Map, Req, State) ->
    put(janus_req_model, Next),
    Attempted = pd(janus_auto_names_attempted, []),
    put(janus_auto_names_attempted, Attempted ++ [Next]),
    %% D6: clear per-name Part C key set; reset part_c attempt; keep
    %% shared Deadline / monotonic usage attempt / request_ref.
    erase(janus_failover_keys),
    put(janus_part_c_attempt, 1),
    erase(janus_failover_unclassified_retried),
    bump_auto_name_failover(),
    %% Re-encode from the client Map so cross-protocol next-name does
    %% not reuse a prior provider-shaped body.
    Map2 = Map#{<<"model">> => Next},
    Body2 = thoas:encode(Map2),
    %% D9: do not touch poscache on advance — judge pos_write is the
    %% only writer today; leave pre-existing entries untouched.
    %% Always `{handled, _}` — callers of failover_decide only match
    %% continue|handled (ocr critical on peel).
    {handled, retry_dispatch(ClientProto, Route2, Body2, Map2, Req, State)}.

bump_auto_name_failover() ->
    Tier = auto_tier_label(),
    janus_metrics:inc(auto_tier_name_failover_total, #{tier => Tier}),
    ok.

bump_auto_name_exhausted(Reason) ->
    Tier = auto_tier_label(),
    janus_metrics:inc(auto_tier_name_failover_exhausted_total, #{
        tier => Tier, reason => exhaust_reason(Reason)
    }),
    ok.

bump_auto_name_skip(Reason) ->
    Tier = auto_tier_label(),
    janus_metrics:inc(auto_tier_name_skip_total, #{
        tier => Tier, reason => skip_reason(Reason)
    }),
    ok.

%% The `tier' label value, enum-validated at the PRODUCER.
%%
%% The router only ever emits `fast'/`big'/`flagship' (`janus_auto:atomize_tier_keys/1`
%% drops every other key), so those are the only values that may become a
%% label. Anything else -- an operator typo in a future code path, or a
%% caller that derives a tier from request data -- collapses to the
%% reserved `unknown' instead of creating a new series. The
%% `?SCHED_FAMILY_CAP' (256) in `janus_http_metrics' would eventually bound
%% the damage, but a label is supposed to be a closed enum by contract,
%% not bounded by a safety net: rely on the producer's validation, not the
%% consumer's cap.
%%
%% `unknown' is reserved for this purpose and is never a legitimate tier,
%% so its presence in a dashboard MEANS a value escaped the enum.
auto_tier_label() ->
    Raw = get(janus_auto_tier),
    case canonical_tier(Raw) of
        unknown when Raw =/= undefined ->
            %% Logged HERE, against the RAW value. Putting the warning on a
            %% `canonical_tier/1' fall-through branch would make it
            %% unreachable: that function only ever returns a member of the
            %% vocabulary or `unknown', so the diagnostic would be dead
            %% code and an off-enum caller would vanish silently.
            logger:warning(#{
                what => janus_metrics_unmapped_auto_tier,
                tier => redact_bin(Raw)
            }),
            unknown;
        Tier ->
            Tier
    end.

%% Map a stored tier onto the router's closed vocabulary.
%%
%% Atoms and the binary spellings the config decoder accepts both resolve
%% here, so the label follows `janus_auto:known_tiers/0' instead of a copy
%% that would drift the first time a tier is added.
canonical_tier(V) when is_atom(V), V =/= undefined ->
    case lists:member(V, janus_auto:known_tiers()) of
        true -> V;
        false -> unknown
    end;
canonical_tier(V) when is_binary(V) ->
    Matches = [T || T <- janus_auto:known_tiers(),
                    atom_to_binary(T, utf8) =:= V],
    case Matches of
        [Tier] -> Tier;
        [] -> unknown
    end;
canonical_tier(_) ->
    unknown.

%% Bounded rendering of an unexpected value for the log line.
%%
%% Atoms are returned as-is: they come from a finite set and the operator
%% needs to know WHICH one escaped to fix it. Anything that could carry
%% arbitrary operator input (a binary or a list) is rendered as its type
%% only.
redact_bin(V) when is_atom(V) -> V;
redact_bin(V) when is_binary(V) -> <<"<binary>">>;
redact_bin(V) when is_list(V) -> <<"<list>">>;
redact_bin(V) when is_integer(V) -> V;
redact_bin(_) -> <<"<other>">>.

exhaust_reason(all_cooling) -> all_cooling;
exhaust_reason(no_eligible) -> no_eligible;
exhaust_reason(budget) -> budget;
exhaust_reason(max_names) -> max_names;
%% Deliberately NO "any atom passes through" clause. A metric label must
%% come from a closed set: an unexpected atom would silently create a new
%% time series, and a per-request label value is unbounded cardinality.
%% Callers that reach here with something new collapse to a known class
%% and the miss is visible in the logs rather than in the metric.
exhaust_reason(R) ->
    logger:warning(#{what => janus_metrics_unmapped_exhaust_reason, reason => R}),
    no_eligible.

skip_reason(unavailable) -> unavailable;
skip_reason(stream_incompatible) -> stream_incompatible;
skip_reason(stream_pair_untranslatable) -> stream_pair_untranslatable;
skip_reason(wrong_modality) -> wrong_modality;
skip_reason(protocol_requires_native) -> protocol_requires_native;
skip_reason(all_cooling) -> all_cooling;
skip_reason(no_vision) -> no_vision;
%% Closed set, same reason as exhaust_reason/1: an unmapped atom must not
%% mint a new time series per request.
skip_reason(R) ->
    logger:warning(#{what => janus_metrics_unmapped_skip_reason, reason => R}),
    unavailable.

%% Distinguish budget vs max_names exhaustion when gates fail mid-walk.
%% (Caller already bumped no_eligible/all_cooling from next_eligible.)
next_name_gates_ok(Result) ->
    Enabled = get(janus_auto_tier_failover) =:= true,
    case Enabled of
        false ->
            false;
        true ->
            case
                not client_committed() andalso
                    not upstream_2xx_result(Result) andalso
                    is_list(get(janus_auto_tier_names))
            of
                false ->
                    false;
                true ->
                    AttemptedN = length(pd(janus_auto_names_attempted, [])),
                    MaxN = pd(janus_auto_tier_max_names, 3),
                    case AttemptedN < MaxN of
                        false ->
                            bump_auto_name_exhausted(max_names),
                            false;
                        true ->
                            case within_failover_budget() of
                                true ->
                                    true;
                                false ->
                                    bump_auto_name_exhausted(budget),
                                    false
                            end
                    end
            end
    end.

retry_dispatch(ClientProto, Route2, Body, Map, Req, State) ->
    case janus_http_proxy:provider_protocol(Route2) of
        {ok, ProviderProto2} ->
            %% Body may be provider-encoded for the FAILED attempt's
            %% protocol (translate path). Re-dispatch from the client
            %% Map so a protocol-changing repick cannot replay the wrong
            %% shape (ocr high on peel).
            Body2 = retry_body(ClientProto, ProviderProto2, Body, Map),
            janus_http_proxy:dispatch(
                ClientProto, ProviderProto2, Route2, Body2, Map, Req, State
            );
        {error, unknown_protocol} ->
            _ = janus_http_proxy:release_route_inflight(Route2),
            janus_http_proxy:reply_err(
                ClientProto, Req, State, 502, <<"unknown_protocol">>, <<"provider has unknown protocol">>
            )
    end.

%% Always rebuild from the client Map. Body may be provider-shaped for
%% the FAILED attempt (call_translate passes OutBody into failover_decide)
%% even when the repicked route keeps the same ClientProto atom.
retry_body(ClientProto, ProviderProto, Body, Map) ->
    case janus_protocol_translate:translate_request(ClientProto, ProviderProto, Map) of
        {ok, ProviderMap} when is_map(ProviderMap) -> thoas:encode(ProviderMap);
        _ -> Body
    end.

retry_jitter() ->
    rand:uniform(200) + 99.

mark_key_attempted(Route) ->
    case janus_http_proxy:key_id_of(Route) of
        Kid when is_integer(Kid) ->
            Attempted = [Kid | lists:delete(Kid, key_attempt_list())],
            put(janus_failover_keys, Attempted);
        _ ->
            ok
    end.

key_attempt_list() ->
    case get(janus_failover_keys) of
        L when is_list(L) -> L;
        _ -> []
    end.

key_attempted(Route) ->
    case janus_http_proxy:key_id_of(Route) of
        Kid when is_integer(Kid) -> lists:member(Kid, key_attempt_list());
        _ -> false
    end.

%% Re-pick a route for the SAME model, skipping already-attempted keys
%% and (for translate-blocked streams) protocol-incompatible routes.
repick_route(_ClientProto, _Map, 0) ->
    error;
repick_route(ClientProto, Map, Tries) ->
    ModelName = get(janus_req_model),
    Blocked =
        janus_protocol_translate:wants_stream(Map) andalso
            janus_protocol_translate:stream_translate_blocked(ClientProto, Map),
    %% Spend attempts on candidate routes (ocr review 2026-10-07):
    %% the same same-protocol bias the initial pick applies, else the
    %% round-robin cursor can burn the retry budget on routes the
    %% ProtoOK filter below would discard anyway.
    PickOpts = janus_http_proxy:stream_pick_opts(ClientProto, Map),
    Pick =
        case janus_http_proxy:resolve_model(ModelName) of
            {ok, ModelId} -> janus_lb:pick_route(ModelId, PickOpts);
            error -> janus_lb:pick_listing_route(ModelName, PickOpts)
        end,
    case Pick of
        {ok, Route} ->
            RouteProto = janus_http_proxy:provider_protocol(Route),
            %% Never fail over INTO a responses-protocol provider on a
            %% stream it cannot serve (audit R2, C-1): that turns a
            %% recoverable failure into the dispatch guard's terminal 400.
            StreamUnservable =
                janus_protocol_translate:wants_stream(Map) andalso
                    case RouteProto of
                        {ok, RP} ->
                            janus_protocol_translate:stream_pair_untranslatable(ClientProto, RP);
                        _ ->
                            false
                    end,
            ProtoOK =
                ((not Blocked) orelse (RouteProto =:= {ok, ClientProto})) andalso
                    (not StreamUnservable),
            case key_attempted(Route) orelse not ProtoOK of
                true ->
                    _ = janus_http_proxy:release_route_inflight(Route),
                    repick_route(ClientProto, Map, Tries - 1);
                false ->
                    {ok, Route}
            end;
        {error, _} ->
            error
    end.

failover_note(Route, {ok, 401, _H, _B}) ->
    _ = note_auth_failure(Route, 401),
    _ = janus_http_proxy:release_route_inflight(Route),
    ok;
failover_note(Route, {ok, 403, _H, _B}) ->
    _ = note_route_failure(Route, {http, 403}),
    _ = janus_http_proxy:release_route_inflight(Route),
    ok;
failover_note(Route, {ok, 429, H, _B}) ->
    _ = note_key_failure(Route, H, 429),
    _ = janus_http_proxy:release_route_inflight(Route),
    ok;
failover_note(Route, {ok, Status, _H, _B}) when Status >= 500 ->
    _ = note_provider_failure(Route, {http, Status}),
    _ = janus_http_proxy:release_route_inflight(Route),
    ok;
failover_note(Route, {error, Reason}) ->
    %% Transport-class failure: bench the provider like a mid-loop 5xx,
    %% else every subsequent request keeps re-opening connections to a
    %% sick endpoint until a TERMINAL outcome finally cools it.
    _ = note_provider_failure(Route, janus_http_proxy:sanitize_upstream_error(Reason)),
    _ = janus_http_proxy:release_route_inflight(Route),
    ok;
failover_note(Route, _Other) ->
    %% Deny-shaped 4xx: key-scoped — bench the key briefly.
    _ = note_key_failure(Route, #{}, 400),
    _ = janus_http_proxy:release_route_inflight(Route),
    ok.

%% Non-terminal usage row for a retried attempt (terminal row comes
%% from track/3 on the final outcome; it attaches the same
%% request_ref/attempt from the process dictionary).
%% TF-A.0b (reorder spec D8/terminal_count): this IS the per-attempt
%% cascade row — every attempted listing in the failover cascade gets
%% exactly one row (retried attempts here with tokens null + latency 0;
%% the final attempt's terminal row via track_proxied, mid-stream
%% aborts at 5xx-class statuses through native_stream_fail /
%% handle_upstream's worker_lost 502). Routes here always carry an
%% integer provider_id (a pick produced them) — the writer-side pin
%% holds.
%% {Reason, NativeCode} comes straight from failover_classify/2 (the
%% single derivation — observability-depth Task 2); error_code now
%% carries the parsed provider-native code (previously the parsed
%% binary was discarded and the column was never populated).
failover_record_attempt(Route, {ok, Status, _H, _B}, Classified) ->
    record_failover_row(Route, Status, Classified);
failover_record_attempt(Route, {error, crashed}, Classified) ->
    record_failover_row(Route, 500, Classified);
failover_record_attempt(Route, {error, _Reason}, Classified) ->
    record_failover_row(Route, 502, Classified).

record_failover_row(Route, Status, {Reason, NativeCode}) ->
    case get(janus_usage_ctx) of
        #{started := _Started, agent := Agent, client_proto := Proto, stream := Stream} ->
            janus_usage:record((janus_http_proxy_otel:row_span_ids())#{
                ts => erlang:system_time(second),
                requested_model => pd(janus_requested_model, null),
                agent_key_id => maps:get(id, Agent, null),
                model_id => maps:get(model_id, Route, null),
                provider_id => maps:get(provider_id, Route, null),
                provider_key_id => janus_http_proxy:key_id_of(Route),
                protocol => Proto,
                stream => janus_http_proxy:usage_bool_int(Stream),
                status => Status,
                prompt => null,
                completion => null,
                latency_ms => 0,
                error_code => NativeCode,
                attempt => pd(janus_failover_attempt, 1),
                request_ref => pd(janus_failover_ref, null),
                is_terminal => false,
                request_id => get(janus_request_id),
                failover_reason => atom_to_binary(Reason, utf8),
                %% Per-attempt attribution: the arrival stash belongs to
                %% THIS attempt's upstream answer — without it the walk's
                %% terminal row kept attempt 1's message.
                error_detail =>
                    case get(janus_error_detail) of
                        D when is_binary(D) -> D;
                        _ -> null
                    end,
                trace_id => janus_trace:trace_id(get(janus_trace))
            }),
            %% The next attempt (Part C retry or auto-walk) re-stashes
            %% its OWN message on arrival; clear so a walk path that
            %% never stashes cannot inherit this attempt's text.
            erase(janus_error_detail),
            ok;
        _ ->
            ok
    end.

%%% Retry-time classification (codes table single-source, spec C.1)
%%%
%%% Observability-depth Task 2: the classifier is the SINGLE derivation
%%% the write path consumes — each retryable call returns
%%% {retryable, Reason, NativeCode} AND stashes both values
%%% (janus_last_reason / janus_last_native_code), so the terminal row
%%% surfaces the LAST retryable classification. Terminal branches stash
%%% NOTHING: a terminal failure must surface the previous retryable
%%% classification (a terminal-first request records NULL/NULL). Status
%%% classes are checked BEFORE body classification (401/403 -> auth even
%%% when the body matches an entitlement code). Total — never raises: an
%%% unexpected shape returns {retryable, unclassified, null}.

-type failover_reason() ::
    auth | rate | balance | deny | input_shape | unclassified | upstream_5xx | transport.

-spec failover_classify(map(), term()) ->
    terminal | {retryable, failover_reason(), binary() | null}.
%% Worker mesh failures are terminal (N9: no in-flight retry / no
%% key-failover on worker_lost, worker-emitted transport errors, or
%% post-forward worker_http_status) and stash nothing. D4 amends N9
%% ONLY for the remapped pre-forward retryable set: the 4-tuple
%% `{worker_http_status,Status,H,B}` is rewritten to `{ok,Status,H,B}`
%% in remap_worker_http_status/1 before this classifier runs, so
%% 401/403/429/5xx/deny enter the same clauses as the local path.
%% Raw 2-tuple worker_http_status (post-forward / non-remapped) and
%% an unremapped 4-tuple (fail-closed) stay terminal here. The
%% janus_error wire map carries only code+message — the upstream body
%% does NOT survive that path — so a worker-executed terminal failure
%% can only surface a PREVIOUS attempt's retryable classification; a
%% first-attempt worker_* terminal records failover_reason NULL +
%% error_code NULL. (Unary / pre-forward stream errors return the body
%% in janus_done and classify with the native code intact after remap.)
failover_classify(_Route, {error, worker_lost}) ->
    terminal;
%% Internal-hop inflate failure (spec 2026-10-12-wire-compression F2):
%% terminal for the same N9 reason — a retry would re-dispatch a NEW
%% job while the client already owns any committed bytes, and the
%% fault is OUR wire, not a candidate key/provider.
failover_classify(_Route, {error, Reason}) when ?IS_WIRE_ENC_ABORT(Reason) ->
    terminal;
failover_classify(_Route, {error, {worker_error, _}}) ->
    terminal;
%% Post-forward (2-tuple) or remap-miss 4-tuple: N9 terminal.
failover_classify(_Route, {error, {worker_http_status, _}}) ->
    terminal;
failover_classify(_Route, {error, {worker_http_status, _, _, _}}) ->
    terminal;
failover_classify(_Route, {error, _Reason}) ->
    %% Transport errors behave like 5xx: retryable within the budget.
    stash_classification(transport, null),
    {retryable, transport, null};
failover_classify(_Route, {ok, Status, _H, Body}) when
    Status =:= 401; Status =:= 403
->
    NativeCode = native_code_of(Body),
    stash_classification(auth, NativeCode),
    {retryable, auth, NativeCode};
failover_classify(_Route, {ok, Status, _H, Body}) when Status >= 500 ->
    NativeCode = native_code_of(Body),
    stash_classification(upstream_5xx, NativeCode),
    {retryable, upstream_5xx, NativeCode};
failover_classify(Route, {ok, Status, _H, Body}) when Status >= 400, Status < 500 ->
    {Code, Message} = extract_error_code_message(Body),
    NativeCode = code_or_null(Code),
    case classify_client_error(Route, Code, Message) of
        deny ->
            stash_classification(deny, NativeCode),
            {retryable, deny, NativeCode};
        balance ->
            stash_classification(balance, NativeCode),
            {retryable, balance, NativeCode};
        rate ->
            stash_classification(rate, NativeCode),
            {retryable, rate, NativeCode};
        input_shape ->
            %% Known input-shape mismatch: TERMINAL, zero retries (the
            %% same request shape fails identically on every key —
            %% entitlement spec). Stash untouched.
            terminal;
        unclassified ->
            %% A 429 is rate-shaped even when the codes table has no
            %% matching row. Any other unclassified 4xx gets ONE
            %% failover attempt, then terminal (codes-table feedback for
            %% the next seed update). Fully fail-open when the table is
            %% empty.
            case Status of
                429 ->
                    stash_classification(rate, NativeCode),
                    {retryable, rate, NativeCode};
                _ ->
                    case get(janus_failover_unclassified_retried) of
                        true ->
                            terminal;
                        _ ->
                            put(janus_failover_unclassified_retried, true),
                            stash_classification(unclassified, NativeCode),
                            {retryable, unclassified, NativeCode}
                    end
            end
    end;
%% Success (2xx/3xx) and committed streams are terminal — never a
%% reason, never a stash write.
failover_classify(_Route, {ok, _Status, _H, _B}) ->
    terminal;
failover_classify(_Route, {ok, stream, _Status, _H, _Drain}) ->
    terminal;
failover_classify(_Route, _Unexpected) ->
    %% Totality guard: the classifier runs inside the failover loop and
    %% must never raise on an unexpected shape.
    stash_classification(unclassified, null),
    {retryable, unclassified, null}.

stash_classification(Reason, NativeCode) ->
    put(janus_last_reason, Reason),
    put(janus_last_native_code, NativeCode),
    ok.

native_code_of(Body) ->
    {Code, _Message} = extract_error_code_message(Body),
    code_or_null(Code).

code_or_null(Code) when is_binary(Code) -> Code;
code_or_null(_) -> null.

classify_client_error(Route, Code, Message) ->
    Codes = janus_catalog:entitlement_codes(),
    Provider = janus_http_proxy:route_provider_name(Route),
    Rows = maps:get(Provider, Codes, []),
    classify_with_rows(Rows, Code, Message).

classify_with_rows([], _Code, _Message) ->
    unclassified;
classify_with_rows([Row | Rest], Code, Message) ->
    MS = maps:get(match_status, Row, undefined),
    KW = maps:get(code_keyword, Row, undefined),
    Outcome = maps:get(outcome, Row, undefined),
    Matched =
        case MS of
            <<"regex">> -> regex_matches(KW, Message) orelse regex_matches(KW, Code);
            _ -> is_binary(KW) andalso KW =/= <<>> andalso KW =:= Code
        end,
    case Matched of
        true -> outcome_atom(Outcome);
        false -> classify_with_rows(Rest, Code, Message)
    end.

regex_matches(Pattern, Subject) when is_binary(Pattern), is_binary(Subject), Subject =/= <<>> ->
    try
        re:run(Subject, Pattern, [{capture, none}]) =:= match
    catch
        _:_ -> false
    end;
regex_matches(_, _) ->
    false.

outcome_atom(<<"deny">>) -> deny;
outcome_atom(<<"balance">>) -> balance;
outcome_atom(<<"rate">>) -> rate;
outcome_atom(<<"input_shape">>) -> input_shape;
outcome_atom(_) -> unclassified.

%% Provider-native error code + message from the error body. Tolerant:
%% OpenAI {error:{code,message}}, DashScope top-level {code,message},
%% Anthropic {type:error,error:{type,message}}.
extract_error_code_message(Body) when is_binary(Body) ->
    case thoas:decode(Body) of
        {ok, Map} when is_map(Map) ->
            Err = maps:get(<<"error">>, Map, #{}),
            Inner =
                case Err of
                    E when is_map(E) -> E;
                    _ -> #{}
                end,
            Code =
                first_bin([
                    maps:get(<<"code">>, Map, undefined),
                    maps:get(<<"code">>, Inner, undefined),
                    maps:get(<<"type">>, Inner, undefined)
                ]),
            Message =
                first_bin([
                    maps:get(<<"message">>, Map, undefined),
                    maps:get(<<"message">>, Inner, undefined)
                ]),
            {Code, Message};
        _ ->
            {undefined, undefined}
    end;
extract_error_code_message(_) ->
    {undefined, undefined}.

first_bin([B | Rest]) when is_binary(B), B =/= <<>> -> B;
first_bin([_ | Rest]) -> first_bin(Rest);
first_bin([]) -> undefined.

%%--------------------------------------------------------------------
%% Errors / replies
%%--------------------------------------------------------------------

reply_pick_error(ClientProto, Req, State, Reason) ->
    %% Pick failures happen INSIDE do_proxy (already counted). track/3
    %% writes the usage row (null route ids) and bumps failed. The
    %% status must be the class of the reply the client actually gets:
    %% a bare all_cooling answers 503 and used to be tracked as 404
    %% (review 06d M5), hiding D15.1 exhaustion from 5xx alerting.
    _ = janus_http_proxy:track(pick_error_status(Reason), #{}, #{}),
    do_reply_pick_error(ClientProto, Req, State, Reason).

pick_error_status(all_cooling) -> 503;
pick_error_status({all_cooling, _}) -> 503;
pick_error_status(provider_disabled) -> 503;
pick_error_status(keys_disabled) -> 503;
pick_error_status(missing_provider_key) -> 503;
pick_error_status(catalog_not_ready) -> 503;
pick_error_status(_) -> 404.

do_reply_pick_error(ClientProto, Req, State, all_cooling) ->
    do_reply_pick_error(ClientProto, Req, State, {all_cooling, 5000});
do_reply_pick_error(ClientProto, Req, State, {all_cooling, Ms}) when is_integer(Ms), Ms > 0 ->
    Sec = max(1, (Ms + 999) div 1000),
    janus_http_proxy:reply_err(
        ClientProto,
        Req,
        State,
        503,
        <<"all_cooling">>,
        <<"all upstream routes are cooling down">>,
        #{<<"retry-after">> => integer_to_binary(Sec)}
    );
%% Malformed cooldown: still a cooling condition, never a 404 — keep
%% the reply class identical to pick_error_status/1.
do_reply_pick_error(ClientProto, Req, State, {all_cooling, _}) ->
    do_reply_pick_error(ClientProto, Req, State, {all_cooling, 5000});
do_reply_pick_error(ClientProto, Req, State, provider_disabled) ->
    janus_http_proxy:reply_err(
        ClientProto, Req, State, 503, <<"provider_disabled">>,
        <<"the provider for this model is disabled">>
    );
do_reply_pick_error(ClientProto, Req, State, keys_disabled) ->
    janus_http_proxy:reply_err(ClientProto, Req, State, 503, <<"no_usable_key">>, <<"no enabled upstream keys">>);
do_reply_pick_error(ClientProto, Req, State, missing_provider_key) ->
    janus_http_proxy:reply_err(
        ClientProto, Req, State, 503, <<"no_usable_key">>, <<"provider has no keys configured">>
    );
do_reply_pick_error(ClientProto, Req, State, catalog_not_ready) ->
    janus_http_proxy:reply_err(
        ClientProto,
        Req,
        State,
        503,
        <<"catalog_not_ready">>,
        <<"catalog not ready">>,
        #{<<"retry-after">> => <<"1">>}
    );
%% Decisions face (D2): empty pick after require_proto means the model
%% has no openai_decisions listing — report that explicitly so operators
%% do not chase a generic "no route" on a chat-only name.
do_reply_pick_error(openai_decisions, Req, State, _Reason) ->
    janus_http_proxy:reply_err(
        openai_decisions,
        Req,
        State,
        404,
        <<"no_route">>,
        <<"no decisions-capable route for model (provider protocol must be openai_decisions)">>
    );
do_reply_pick_error(ClientProto, Req, State, _Reason) ->
    janus_http_proxy:reply_err(ClientProto, Req, State, 404, <<"no_route">>, <<"no route for model">>).

reply_err(ClientProto, Req, State, Status, Code, Msg) ->
    reply_err(ClientProto, Req, State, Status, Code, Msg, #{}).

reply_err(ClientProto, Req, State, Status, Code, Msg, Extra) ->
    %% The message rides the terminal usage row (error_detail) so the
    %% Failures page can show WHY (e.g. the upstream's own sentence)
    %% instead of a bare status+code. Binary messages only; the list
    %% of tuples shapes stay unrecorded. Cleared per request in the
    %% preamble (keep-alive hygiene).
    case is_binary(Msg) of
        true -> put(janus_error_detail, Msg);
        false -> ok
    end,
    %% Every agent-facing rejection is logged (warning): the dashboard
    %% Logs page is the first place operators look when a client reports
    %% "provider rejected my request" — silent 400s forced Caddy-log
    %% archaeography once too often.
    logger:warning(#{
        what => janus_agent_reject,
        status => Status,
        code => Code,
        model => get(janus_req_model),
        %% The resolved name is unset for pre-pick rejects (allowlist,
        %% missing model) — the client's raw name is what operators need.
        requested_model => get(janus_requested_model),
        method => cowboy_req:method(Req),
        path => cowboy_req:path(Req),
        request_id => get(janus_request_id)
    }),
    case get(janus_req_counted) of
        true ->
            ok;
        _ ->
            put(janus_req_counted, true),
            janus_metrics:inc(requests_total, #{
                endpoint => janus_http_classify:endpoint(cowboy_req:path(Req)),
                protocol => janus_http_classify:protocol(cowboy_req:path(Req)),
                status_class => janus_http_classify:status_class(Status)
            })
    end,
    reply_json(Req, State, Status, error_map(ClientProto, Code, Msg), Extra).

error_map(anthropic_messages, Code, Msg) ->
    #{
        type => <<"error">>,
        error => #{
            type => <<"invalid_request_error">>,
            message => Msg,
            code => Code
        }
    };
error_map(_ClientProto, Code, Msg) ->
    #{
        error => #{
            message => Msg,
            type => <<"janus_error">>,
            code => Code
        }
    }.

reply_json(Req, State, Status, Body) ->
    reply_json(Req, State, Status, Body, #{}).

reply_json(Req, State, Status, Body, ExtraHeaders) when is_binary(Body), is_map(ExtraHeaders) ->
    Headers = maps:merge(#{<<"content-type">> => <<"application/json">>}, ExtraHeaders),
    %% Downstream gzip seam (spec 2026-10-12-wire-compression F6/D8):
    %% the ONE unary reply choke point — SSE never passes here.
    mark_client_committed(),
    Req2 = janus_downstream_enc:reply(Status, Headers, Body, Req),
    {ok, Req2, State};
reply_json(Req, State, Status, Map, ExtraHeaders) when is_map(Map), is_map(ExtraHeaders) ->
    reply_json(Req, State, Status, thoas:encode(Map), ExtraHeaders).

%% Upstream headers distilled to content-type ONLY (sensitive
%% upstream headers stripped). TWO variants, split by what the caller
%% KNOWS about the body (ocr r3 scoping):
%%
%%   - filter_headers_json/1: JSON-by-contract paths (the native
%%     same-protocol faces, the error-envelope relay, the Decisions
%%     face). A headers map WITHOUT content-type defaults to
%%     application/json — the worker-dispatch unary done carries
%%     `trailers => #{}` (janus_worker_session emit_done; D2 keeps
%%     only body/status/usage), so without the default that
%%     execution path's client reply would carry no content-type
%%     while the local-fallback path carries the provider's (spec
%%     2026-10-12-wire-compression F6: the downstream gzip seam's
%%     content-type enumeration must see the same application/json on
%%     both execution paths). Total via maps:get — a partial map
%%     pattern would case_clause the reply on exactly such a map
%%     (ocr r1).
%%
%%   - filter_headers/1: unknown-shape bodies (the non-JSON 2xx
%%     passthrough). Keeps ONLY an existing content-type — never
%%     LABELS an unknown body as application/json (mislabelling would
%%     both lie to the client and make the body gzip-eligible under
%%     the JSON label; the gate's conservatism is compress only
%%     positively-identified types).
filter_headers_json(Headers) when is_map(Headers) ->
    case maps:get(<<"content-type">>, Headers, undefined) of
        undefined -> #{<<"content-type">> => <<"application/json">>};
        Ct -> #{<<"content-type">> => Ct}
    end;
filter_headers_json(_) ->
    #{<<"content-type">> => <<"application/json">>}.

filter_headers(Headers) when is_map(Headers) ->
    maps:with([<<"content-type">>], Headers);
filter_headers(_) ->
    #{<<"content-type">> => <<"application/json">>}.

filter_stream_headers(_Headers) when is_map(_Headers) ->
    %% Always SSE, even if the upstream advertised JSON (some OpenAI-
    %% compatible proxies lie on the streaming face).
    #{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>,
        <<"connection">> => <<"keep-alive">>,
        <<"x-accel-buffering">> => <<"no">>
    };
filter_stream_headers(_) ->
    #{<<"content-type">> => <<"text/event-stream">>}.

%%--------------------------------------------------------------------
%% Node counters (Slice B): one client LLM call = +1 total at
%% do_proxy entry; +1 failed exactly once on a client-visible >=400
%% outcome (outer track) or the crash fallback. Inner calls (a future
%% janus-auto/failover inner do_proxy) never bump either counter.
%%--------------------------------------------------------------------

inc_total_once() ->
    case get(janus_stats_inner) of
        true ->
            ok;
        _ ->
            janus_http_stats:inc_total(),
            put(janus_stats_counted, true)
    end.

bump_failed_maybe(Status) when Status >= 400 ->
    case {get(janus_stats_inner), get(janus_stats_failed)} of
        {true, _} ->
            ok;
        {_, true} ->
            ok;
        _ ->
            janus_http_stats:inc_failed(),
            put(janus_stats_failed, true)
    end;
bump_failed_maybe(_Status) ->
    ok.

maybe_crash_bump_failed() ->
    %% Cowboy keep-alive leaves inner as undefined after erase/1, not
    %% the atom false. Only skip when this process is an inner call.
    Counted = get(janus_stats_counted) =:= true,
    Inner = get(janus_stats_inner) =:= true,
    Tracked = get(janus_stats_tracked) =:= true,
    Failed = get(janus_stats_failed) =:= true,
    case Counted andalso (not Inner) andalso (not Tracked) andalso (not Failed) of
        true ->
            janus_http_stats:inc_failed(),
            put(janus_stats_failed, true);
        false ->
            ok
    end.

%%--------------------------------------------------------------------
%% LB helpers (same contracts as former janus_http_chat)
%%--------------------------------------------------------------------

note_auth_failure(Route, Status) ->
    note_attempt_outcome(Route, provider_key, auth, {auth, Status}).

note_key_failure(Route, Headers, Status) when is_integer(Status) ->
    Reason = janus_http_proxy:retry_reason(Headers, Status),
    note_attempt_outcome(Route, provider_key, reason_class_atom(Reason), Reason).

%% Key cool-clear only — the paired note_route_success/1 owns the
%% single attempt_id rate bump for a successful attempt (spec §4.5
%% at-most-once).
note_key_success(Route) ->
    janus_lb:note_success(janus_http_proxy:key_target(Route)).

note_provider_failure(Route, Reason) ->
    note_attempt_outcome(Route, provider, reason_class_atom(Reason), Reason).

note_route_failure(Route, Reason) ->
    note_attempt_outcome(Route, route, reason_class_atom(Reason), Reason).

note_route_success(Route) ->
    maybe_note_latency(Route),
    note_attempt_outcome(Route, route, ok, ok).

%% Master-minted attempt_id + entity + class → janus_lb:note_attempt/1
%% (cool + rates atomically). Kind selects which cool/rate entity the
%% attempt attaches to (key / provider / route).
note_attempt_outcome(Route, Kind, Class, Reason) ->
    case attempt_entity(Route, Kind) of
        undefined ->
            ok;
        Entity ->
            janus_lb:note_attempt(#{
                attempt_id => mint_attempt_id(),
                entity => Entity,
                class => Class,
                reason => Reason
            })
    end.

mint_attempt_id() ->
    Ref = pd(janus_failover_ref, <<>>),
    Attempt = pd(janus_failover_attempt, 1),
    case Ref of
        R when is_binary(R), R =/= <<>> ->
            <<R/binary, "-", (integer_to_binary(Attempt))/binary>>;
        _ ->
            binary:encode_hex(crypto:strong_rand_bytes(16))
    end.

attempt_entity(Route, provider_key) ->
    case janus_http_proxy:key_id_of(Route) of
        Kid when Kid =/= null, Kid =/= undefined ->
            #{
                kind => <<"provider_key">>,
                id => id_bin(Kid),
                provider_id => id_bin(maps:get(provider_id, Route, <<"unknown">>)),
                model_id => null
            };
        _ ->
            undefined
    end;
attempt_entity(Route, provider) ->
    case maps:get(provider_id, Route, undefined) of
        undefined ->
            undefined;
        Pid ->
            P = id_bin(Pid),
            #{kind => <<"provider">>, id => P, provider_id => P, model_id => null}
    end;
attempt_entity(Route, route) ->
    case maps:get(provider_id, Route, undefined) of
        undefined ->
            undefined;
        Pid ->
            P = id_bin(Pid),
            #{
                kind => <<"route">>,
                id => P,
                provider_id => P,
                model_id =>
                    case maps:get(model_id, Route, null) of
                        null -> null;
                        undefined -> null;
                        M -> id_bin(M)
                    end
            }
    end.

id_bin(B) when is_binary(B) -> B;
id_bin(I) when is_integer(I) -> integer_to_binary(I);
id_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
id_bin(_) -> <<"unknown">>.

reason_class_atom(Reason) ->
    %% janus_cool_view:reason_class/1 returns binaries; note_attempt
    %% accepts atoms or binaries — normalize to atom for the class field.
    Bin = janus_cool_view:reason_class(Reason),
    janus_rate_view:normalize_class(Bin).

maybe_note_latency(Route) ->
    case get(janus_upstream_ms) of
        Ms when is_integer(Ms), Ms >= 0 ->
            _ = janus_http_proxy_otel:maybe_observe_genai_duration(Route),
            janus_lb:note_latency(janus_http_proxy:route_target(Route), Ms);
        _ ->
            ok
    end.

release_route_inflight(Route) ->
    janus_lb:release_inflight(janus_http_proxy:route_target(Route)).
