%%%-------------------------------------------------------------------
%%% @doc Per-node agent-key quotas (Phase 2 Slice Q).
%%%
%%% RPM / TPM use a rolling 60s bucket; daily uses UTC calendar day.
%%% NULL limits short-circuit with no ETS writes. Admit must run once
%%% per client request (outside failover). Token charge is idempotent
%%% per request_id (pdict + ETS). Modality plugins that only report
%%% `units` (no prompt/completion) do not advance TPM/daily — RPM still
%%% applies via admit/1.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_quota).

-export([
    ensure/0,
    admit/1,
    charge_tokens/4,
    retry_after_sec/1,
    kind_code/1,
    tpm_bucket_now/0,
    reset_for_test/0
]).

-define(RPM, janus_quota_rpm).
-define(TPM, janus_quota_tpm).
-define(DAILY, janus_quota_daily).
-define(CHARGED, janus_quota_charged).
-define(META, janus_quota_meta).
-define(GC_MIN_SEC, 30).

-spec ensure() -> ok.
ensure() ->
    _ = ensure_table(?RPM),
    _ = ensure_table(?TPM),
    _ = ensure_table(?DAILY),
    _ = ensure_table(?CHARGED),
    _ = ensure_table(?META),
    ok.

ensure_table(Name) ->
    case ets:info(Name) of
        undefined ->
            try
                ets:new(Name, [named_table, public, set, {write_concurrency, true}])
            catch
                error:badarg ->
                    Name
            end;
        _ ->
            Name
    end.

%% Test helper — wipe counters between cases.
-spec reset_for_test() -> ok.
reset_for_test() ->
    ensure(),
    true = ets:delete_all_objects(?RPM),
    true = ets:delete_all_objects(?TPM),
    true = ets:delete_all_objects(?DAILY),
    true = ets:delete_all_objects(?CHARGED),
    true = ets:delete_all_objects(?META),
    erase(janus_quota_admitted),
    erase(janus_quota_charged),
    ok.

-spec admit(map()) -> ok | {error, {quota, rpm | tpm | daily, pos_integer()}}.
admit(Agent) when is_map(Agent) ->
    ensure(),
    case get(janus_quota_admitted) of
        true ->
            ok;
        _ ->
            case unlimited(Agent) of
                true ->
                    put(janus_quota_admitted, true),
                    ok;
                false ->
                    maybe_gc_stale(),
                    case check_tpm(Agent) of
                        {error, _} = Err ->
                            Err;
                        ok ->
                            case check_daily(Agent) of
                                {error, _} = Err2 ->
                                    Err2;
                                ok ->
                                    case check_and_bump_rpm(Agent) of
                                        {error, _} = Err3 ->
                                            Err3;
                                        ok ->
                                            put(janus_quota_admitted, true),
                                            ok
                                    end
                            end
                    end
            end
    end;
admit(_) ->
    ok.

unlimited(Agent) ->
    limit_of(Agent, rpm_limit) =:= unlimited andalso
        limit_of(Agent, tpm_limit) =:= unlimited andalso
        limit_of(Agent, daily_token_limit) =:= unlimited.

%% null/undefined = unlimited; 0 = hard block (always exceed); >0 = cap.
limit_of(Agent, Key) ->
    case maps:get(Key, Agent, null) of
        null -> unlimited;
        undefined -> unlimited;
        N when is_integer(N), N >= 0 -> N;
        _ -> unlimited
    end.

check_and_bump_rpm(Agent) ->
    case limit_of(Agent, rpm_limit) of
        unlimited ->
            ok;
        0 ->
            {error, {quota, rpm, retry_after_sec(rpm)}};
        Limit ->
            Id = maps:get(id, Agent),
            Bucket = rpm_bucket_now(),
            Key = {Id, Bucket},
            %% Read-then-bump under one update_counter list: Old is the
            %% pre-increment value; second op clamps at Limit.
            [Old, _New] = ets:update_counter(
                ?RPM, Key, [{2, 0}, {2, 1, Limit, Limit}], {Key, 0}
            ),
            case Old < Limit of
                true ->
                    ok;
                false ->
                    {error, {quota, rpm, retry_after_sec(rpm)}}
            end
    end.

check_tpm(Agent) ->
    case limit_of(Agent, tpm_limit) of
        unlimited ->
            ok;
        0 ->
            {error, {quota, tpm, retry_after_sec(tpm)}};
        Limit ->
            Id = maps:get(id, Agent),
            Bucket = tpm_bucket_now(),
            Cur =
                case ets:lookup(?TPM, {Id, Bucket}) of
                    [{_, N}] -> N;
                    [] -> 0
                end,
            case Cur >= Limit of
                true -> {error, {quota, tpm, retry_after_sec(tpm)}};
                false -> ok
            end
    end.

check_daily(Agent) ->
    case limit_of(Agent, daily_token_limit) of
        unlimited ->
            ok;
        0 ->
            {error, {quota, daily, retry_after_sec(daily)}};
        Limit ->
            Id = maps:get(id, Agent),
            Day = utc_day(),
            Cur =
                case ets:lookup(?DAILY, {Id, Day}) of
                    [{_, N}] -> N;
                    [] -> 0
                end,
            case Cur >= Limit of
                true -> {error, {quota, daily, retry_after_sec(daily)}};
                false -> ok
            end
    end.

-spec charge_tokens(binary() | undefined, term(), term(), term()) -> ok.
charge_tokens(RequestId, AgentKeyId, Prompt, Completion) when
    is_binary(RequestId), RequestId =/= <<>>, is_integer(AgentKeyId)
->
    ensure(),
    case already_charged(RequestId) of
        true ->
            ok;
        false ->
            Tokens = tok(Prompt) + tok(Completion),
            case Tokens > 0 of
                true ->
                    mark_charged(RequestId),
                    Bucket = tpm_bucket_now(),
                    _ = ets:update_counter(
                        ?TPM, {AgentKeyId, Bucket}, {2, Tokens}, {{AgentKeyId, Bucket}, 0}
                    ),
                    Day = utc_day(),
                    _ = ets:update_counter(
                        ?DAILY, {AgentKeyId, Day}, {2, Tokens}, {{AgentKeyId, Day}, 0}
                    ),
                    ok;
                false ->
                    %% No tokens (null usage / modality units-only): do not
                    %% mark charged so a later tokenized finalize can still charge.
                    ok
            end
    end;
charge_tokens(_, _, _, _) ->
    ok.

already_charged(RequestId) ->
    case get(janus_quota_charged) of
        true ->
            true;
        _ ->
            ets:member(?CHARGED, RequestId)
    end.

mark_charged(RequestId) ->
    put(janus_quota_charged, true),
    ets:insert(?CHARGED, {RequestId, erlang:system_time(second)}),
    ok.

tok(N) when is_integer(N), N > 0 -> N;
tok(_) -> 0.

rpm_bucket_now() ->
    erlang:system_time(second) div 60.

-spec tpm_bucket_now() -> non_neg_integer().
tpm_bucket_now() ->
    rpm_bucket_now().

utc_day() ->
    {{UY, UM, UD}, _} = calendar:universal_time(),
    {UY, UM, UD}.

-spec retry_after_sec(rpm | tpm | daily) -> pos_integer().
retry_after_sec(daily) ->
    {_, {H, Mi, S}} = calendar:universal_time(),
    SecToday = H * 3600 + Mi * 60 + S,
    max(1, min(86400, 86400 - SecToday));
retry_after_sec(_) ->
    Rem = 60 - (erlang:system_time(second) rem 60),
    max(1, min(60, Rem)).

-spec kind_code(rpm | tpm | daily) -> binary().
kind_code(rpm) -> <<"quota_rpm">>;
kind_code(tpm) -> <<"quota_tpm">>;
kind_code(daily) -> <<"quota_daily">>.

maybe_gc_stale() ->
    Now = erlang:system_time(second),
    case ets:lookup(?META, last_gc) of
        [{_, Last}] when is_integer(Last), Now - Last < ?GC_MIN_SEC ->
            ok;
        _ ->
            %% Only one concurrent admit wins the throttle window.
            case ets:insert_new(?META, {gc_lock, Now}) of
                true ->
                    try
                        ets:insert(?META, {last_gc, Now}),
                        gc_stale()
                    after
                        ets:delete(?META, gc_lock)
                    end;
                false ->
                    ok
            end
    end.

%% Collect keys then delete — never delete inside foldl (ETS traversal).
gc_stale() ->
    NowBucket = rpm_bucket_now(),
    CutBucket = NowBucket - 2,
    delete_keys(
        ?RPM,
        ets:foldl(
            fun({{Id, B} = K, _N}, Acc) when is_integer(Id), is_integer(B), B < CutBucket ->
                    [K | Acc];
                (_, Acc) ->
                    Acc
            end,
            [],
            ?RPM
        )
    ),
    delete_keys(
        ?TPM,
        ets:foldl(
            fun({{Id, B} = K, _N}, Acc) when is_integer(Id), is_integer(B), B < CutBucket ->
                    [K | Acc];
                (_, Acc) ->
                    Acc
            end,
            [],
            ?TPM
        )
    ),
    {UY, UM, UD} = utc_day(),
    CutDay = calendar:date_to_gregorian_days({UY, UM, UD}) - 2,
    delete_keys(
        ?DAILY,
        ets:foldl(
            fun({{_Id, {Y, M, D}} = K, _N}, Acc) ->
                    case calendar:date_to_gregorian_days({Y, M, D}) < CutDay of
                        true -> [K | Acc];
                        false -> Acc
                    end;
                (_, Acc) ->
                    Acc
            end,
            [],
            ?DAILY
        )
    ),
    CutTs = erlang:system_time(second) - 7200,
    delete_keys(
        ?CHARGED,
        ets:foldl(
            fun({Rid, Ts}, Acc) when is_integer(Ts), Ts < CutTs ->
                    [Rid | Acc];
                (_, Acc) ->
                    Acc
            end,
            [],
            ?CHARGED
        )
    ),
    ok.

delete_keys(Tab, Keys) ->
    lists:foreach(fun(K) -> ets:delete(Tab, K) end, Keys).
