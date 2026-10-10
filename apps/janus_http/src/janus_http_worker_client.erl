%%%-------------------------------------------------------------------
%%% @doc Master-side remote upstream via worker pool (spec §4–5 / W2.1).
%%%
%%% Seams around `janus_http_proxy:upstream_call/5`: pick a worker, send
%%% `janus_job`, wait ack, credit+relay stream chunks into the existing
%%% Drain fun shape, or fall back to local `call_adapter` on empty pool /
%%% send fail / ack miss. Does not change translate module exports.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_worker_client).

-export([
    call/6,
    unary_post/5,
    resolve_unary_upstream/4,
    normalize_want_stream/1,
    outcome_bin/1,
    map_worker_error/2,
    parse_affinity_node/1,
    affinity_opts_from_provider/1,
    video_path/1
]).

%%--------------------------------------------------------------------
%% Public: same result shapes as call_adapter / upstream_call
%%--------------------------------------------------------------------

-spec call(atom(), map(), binary(), map(), term(), fun()) -> term().
call(ProviderProto, Route, _Body, Map, WantStream0, LocalFun) when is_function(LocalFun, 0) ->
    %% Body is ignored: adapters re-encode from Map (same as call_adapter).
    WantStream = normalize_want_stream(WantStream0),
    case should_dispatch() of
        false ->
            LocalFun();
        true ->
            Affinity = affinity_opts(Route),
            JobRef = crypto:strong_rand_bytes(16),
            case safe_pick(pick_opts(Affinity, Route, JobRef)) of
                empty ->
                    LocalFun();
                {ok, WorkerNode} ->
                    case prepare_job(ProviderProto, Route, Map, WantStream) of
                        {error, _} = Err ->
                            %% Same failure local gun would see after resolve.
                            %% Nothing was ever sent — release the pick's
                            %% reservation (send-fail class, spec Part 0.11).
                            ok = sched_release(JobRef),
                            Err;
                        {ok, Fields} ->
                            dispatch(WorkerNode, JobRef, Fields, WantStream, LocalFun)
                    end
            end
    end.

%% Modality image/TTS/ASR unary JSON POST (W2.2). Video paths stay local.
-spec unary_post(map(), binary(), binary(), map(), fun(() -> term())) -> term().
unary_post(Route, PathSuffix, Body, Opts, LocalFun) when
    is_map(Route), is_binary(PathSuffix), is_binary(Body), is_map(Opts), is_function(LocalFun, 0)
->
    case should_dispatch() andalso not video_path(PathSuffix) of
        false ->
            LocalFun();
        true ->
            Affinity = affinity_opts(Route),
            JobRef = crypto:strong_rand_bytes(16),
            case safe_pick(pick_opts(Affinity, Route, JobRef)) of
                empty ->
                    LocalFun();
                {ok, WorkerNode} ->
                    case prepare_unary_job(Route, PathSuffix, Body, Opts) of
                        {error, _} = Err ->
                            ok = sched_release(JobRef),
                            Err;
                        {ok, Fields} ->
                            dispatch(WorkerNode, JobRef, Fields, false, LocalFun)
                    end
            end
    end.

%%--------------------------------------------------------------------
%% Pure helpers (eunit)
%%--------------------------------------------------------------------

-spec normalize_want_stream(term()) -> boolean().
normalize_want_stream(true) -> true;
normalize_want_stream(false) -> false;
normalize_want_stream(#{stream := S}) -> S =:= true;
normalize_want_stream(_) -> false.

%% Video stays master-local (first-ship); match /videos and /videos/...
-spec video_path(binary()) -> boolean().
video_path(<<"/videos">>) -> true;
video_path(<<"/videos/", _/binary>>) -> true;
video_path(_) -> false.

-spec outcome_bin(ok | error | cancelled) -> binary().
outcome_bin(ok) -> <<"completed">>;
outcome_bin(error) -> <<"failed">>;
outcome_bin(cancelled) -> <<"cancelled">>.

-spec map_worker_error(atom(), binary()) -> {error, term()}.
map_worker_error(timeout, _Msg) ->
    {error, {await, timeout}};
map_worker_error(worker_lost, _Msg) ->
    {error, worker_lost};
map_worker_error(Code, _Msg) when is_atom(Code) ->
    {error, {worker_error, Code}}.

-spec parse_affinity_node(term()) -> node() | undefined.
parse_affinity_node(undefined) -> undefined;
parse_affinity_node(null) -> undefined;
parse_affinity_node(<<>>) -> undefined;
parse_affinity_node("") -> undefined;
parse_affinity_node(N) when is_atom(N) -> N;
parse_affinity_node(Bin) when is_binary(Bin) ->
    try
        binary_to_existing_atom(Bin, utf8)
    catch
        error:badarg ->
            %% Unknown atom → no affinity match; avoid permanent atom leak.
            undefined
    end;
parse_affinity_node(List) when is_list(List) ->
    parse_affinity_node(list_to_binary(List));
parse_affinity_node(_) ->
    undefined.

-spec affinity_opts_from_provider(map()) -> map().
affinity_opts_from_provider(Prov) when is_map(Prov) ->
    #{
        region_tag => normalize_region(maps:get(region_tag, Prov, undefined)),
        affinity_node => parse_affinity_node(maps:get(affinity_node, Prov, undefined))
    }.

%%--------------------------------------------------------------------
%% Dispatch decision
%%--------------------------------------------------------------------

should_dispatch() ->
    case application:get_env(janus_core, worker_force_local, false) of
        true ->
            false;
        _ ->
            case safe_role() of
                worker -> false;
                master -> true;
                undefined -> true
            end
    end.

safe_role() ->
    try
        janus_role:get()
    catch
        _:_ -> undefined
    end.

safe_pick(Opts) ->
    try
        janus_worker_pool:pick(Opts)
    catch
        _:_ -> empty
    end.

%% Pick opts (Task C, spec Part C): affinity/region as today, plus
%% `job_ref` (the pick's reserve loop correlates its {track} cast) and
%% `provider_id` (the track row + dispatch_worker_total label).
pick_opts(Affinity, Route, JobRef) ->
    Affinity#{
        provider_id => maps:get(provider_id, Route, undefined),
        job_ref => JobRef
    }.

affinity_opts(#{provider_id := Pid}) ->
    case janus_catalog:lookup_provider(Pid) of
        {ok, Prov} -> affinity_opts_from_provider(Prov);
        error -> #{}
    end;
affinity_opts(_) ->
    #{}.

normalize_region(undefined) -> undefined;
normalize_region(null) -> undefined;
normalize_region(<<>>) -> undefined;
normalize_region(R) when is_binary(R) -> R;
normalize_region(R) when is_list(R) -> list_to_binary(R);
normalize_region(_) -> undefined.

%%--------------------------------------------------------------------
%% Prepare job fields (decrypt + URL — same as adapters)
%%--------------------------------------------------------------------

prepare_job(openai_chat, Route, Map, WantStream) ->
    finish_prepare(
        janus_providers_openai:prepare(chat_completions, Route, Map, WantStream),
        provider_id(Route),
        WantStream
    );
prepare_job(openai_responses, Route, Map, WantStream) ->
    finish_prepare(
        janus_providers_openai:prepare(responses, Route, Map, WantStream),
        provider_id(Route),
        WantStream
    );
prepare_job(openai_decisions, Route, Map, WantStream) ->
    finish_prepare(
        janus_providers_openai:prepare(decisions, Route, Map, WantStream),
        provider_id(Route),
        WantStream
    );
prepare_job(anthropic_messages, Route, Map, WantStream) ->
    finish_prepare(
        janus_providers_anthropic:prepare(Route, Map, WantStream),
        provider_id(Route),
        WantStream
    );
prepare_job(_, _, _, _) ->
    {error, unknown_protocol}.

provider_id(Route) when is_map(Route) ->
    maps:get(provider_id, Route, undefined).

finish_prepare({error, _} = Err, _ProviderId, _WantStream) ->
    Err;
finish_prepare({ok, #{url := Url, method := Method, headers := Headers, body := Body}}, ProviderId, WantStream) ->
    Timeout =
        case WantStream of
            true -> janus_worker_wire:stream_timeout_ms();
            false -> janus_worker_wire:non_stream_timeout_ms()
        end,
    %% The additive `provider_id` key (Task C, spec A.3) lets the
    %% worker attribute its per-provider passive EWMA; normal jobs
    %% NEVER carry `internal` (omitted — probes are pool-issued only).
    %% Extra keys pass wire validation untouched (spec Part 0.10).
    Fields0 = #{
        url => Url,
        method => Method,
        headers => Headers,
        body => Body,
        stream => WantStream,
        timeout_ms => Timeout,
        protocol_meta => #{}
    },
    Fields =
        case ProviderId of
            undefined -> Fields0;
            _ -> Fields0#{provider_id => ProviderId}
        end,
    {ok, Fields}.

%% Shared resolve for modality unary (local post + worker job). No stream/model rewrite.
-spec resolve_unary_upstream(map(), binary(), binary(), map()) ->
    {ok, #{
        host := string(),
        port := inet:port_number(),
        path := binary(),
        tls := boolean(),
        headers := [{binary(), binary()}],
        body := binary(),
        timeout_ms := pos_integer()
    }}
    | {error, term()}.
resolve_unary_upstream(Route, PathSuffix, Body, Opts) when
    is_map(Route), is_binary(PathSuffix), is_binary(Body), is_map(Opts)
->
    case janus_catalog:lookup_provider(maps:get(provider_id, Route)) of
        {ok, #{base_url := BaseUrl0, enabled := true}} ->
            case janus_providers_http:decrypt_key(maps:get(provider_key, Route, undefined)) of
                {ok, Token} ->
                    case janus_providers_http:parse_base(iolist_to_binary(BaseUrl0)) of
                        {ok, Host, Port, BasePath, Tls} ->
                            Path = janus_providers_http:join_path(BasePath, PathSuffix),
                            Headers = [
                                {<<"authorization">>, <<"Bearer ", Token/binary>>},
                                {<<"content-type">>, <<"application/json">>},
                                {<<"accept">>, <<"application/json">>},
                                {<<"user-agent">>, janus_providers_http:user_agent()}
                            ],
                            Timeout = maps:get(
                                timeout_ms, Opts, janus_worker_wire:non_stream_timeout_ms()
                            ),
                            {ok, #{
                                host => Host,
                                port => Port,
                                path => Path,
                                tls => Tls,
                                headers => Headers,
                                body => Body,
                                timeout_ms => Timeout
                            }};
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {ok, #{enabled := false}} ->
            {error, provider_disabled};
        error ->
            {error, provider_not_found}
    end.

prepare_unary_job(Route, PathSuffix, Body, Opts) ->
    case resolve_unary_upstream(Route, PathSuffix, Body, Opts) of
        {error, _} = Err ->
            Err;
        {ok, #{
            host := Host,
            port := Port,
            path := Path,
            tls := Tls,
            headers := Headers,
            body := BodyBin,
            timeout_ms := Timeout
        }} ->
            Target = #{host => Host, port => Port, path => Path, tls => Tls},
            Fields0 = #{
                url => janus_providers_http:target_url(Target),
                method => post,
                headers => Headers,
                body => BodyBin,
                stream => false,
                timeout_ms => Timeout,
                protocol_meta => #{}
            },
            Fields =
                case maps:get(provider_id, Route, undefined) of
                    undefined -> Fields0;
                    ProviderId -> Fields0#{provider_id => ProviderId}
                end,
            {ok, Fields}
    end.

%%--------------------------------------------------------------------
%% Send job / ack / relay
%%--------------------------------------------------------------------

%% JobRef is generated BEFORE pick (Task C): the pick opts carry it so
%% the pool's reserve loop correlates its {track} cast with this
%% dispatch's release/rtt/ttfb casts (spec Part 0.11).
dispatch(WorkerNode, JobRef, Fields, WantStream, LocalFun) ->
    case janus_worker_wire:job(JobRef, self(), Fields) of
        {error, _} ->
            %% Never sent: reclaim the reservation (send-fail class).
            ok = sched_release(JobRef),
            LocalFun();
        {ok, JobMsg} ->
            note_inflight(WorkerNode, 1),
            case send_job(WorkerNode, JobMsg) of
                {error, _} ->
                    note_inflight(WorkerNode, -1),
                    %% Send-fail: release + dispatch_local{send_fail}
                    %% (spec Part 0.11 / Part C metrics).
                    ok = sched_release(JobRef),
                    ok = note_dispatch_local(send_fail),
                    LocalFun();
                ok ->
                    case wait_ack(JobRef, WorkerNode) of
                        {error, ack_timeout} ->
                            mark_dead(JobRef),
                            cancel_dispatch(WorkerNode, JobRef),
                            flush_job(JobRef),
                            note_inflight(WorkerNode, -1),
                            %% Ack-miss: the reservation stays PENDING
                            %% (late, not absent — spec Part 0.11); the
                            %% master executes locally.
                            ok = note_dispatch_local(ack_miss),
                            LocalFun();
                        {ok, WorkerSessionPid} ->
                            Mon = monitor(process, WorkerSessionPid),
                            %% TTFB clock starts at ack receipt (spec A.4).
                            TtfbStart = erlang:monotonic_time(millisecond),
                            case WantStream of
                                true ->
                                    %% Drain runs AFTER upstream_call returns —
                                    %% release inflight / demonitor inside Drain.
                                    grant_credit(WorkerSessionPid, JobRef),
                                    remote_stream(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart);
                                false ->
                                    try
                                        remote_unary(
                                            JobRef,
                                            WorkerSessionPid,
                                            Mon,
                                            WorkerNode,
                                            Fields,
                                            TtfbStart
                                        )
                                    after
                                        finish_remote(Mon, WorkerNode)
                                    end
                            end
                    end
            end
    end.

finish_remote(Mon, WorkerNode) ->
    demonitor(Mon, [flush]),
    note_inflight(WorkerNode, -1),
    ok.

send_job(WorkerNode, JobMsg) ->
    try
        {janus_worker_dispatch, WorkerNode} ! JobMsg,
        ok
    catch
        _:_ -> {error, send_failed}
    end.

wait_ack(JobRef, WorkerNode) ->
    Deadline = janus_worker_wire:ack_deadline_ms(),
    receive
        {janus_job_ack, JobRef, WorkerSessionPid} when is_pid(WorkerSessionPid) ->
            {ok, WorkerSessionPid}
    after Deadline ->
        logger:warning(#{
            what => janus_worker_ack_timeout,
            worker_node => WorkerNode,
            job_ref => binary:encode_hex(JobRef)
        }),
        {error, ack_timeout}
    end.

grant_credit(WorkerSessionPid, JobRef) ->
    N = janus_worker_wire:credit_window_initial(),
    try
        WorkerSessionPid ! janus_worker_wire:credit(JobRef, N)
    catch
        _:_ -> ok
    end,
    ok.

cancel_session(WorkerSessionPid, JobRef) ->
    try
        WorkerSessionPid ! janus_worker_wire:cancel(JobRef)
    catch
        _:_ -> ok
    end,
    ok.

cancel_dispatch(WorkerNode, JobRef) ->
    try
        {janus_worker_dispatch, WorkerNode} ! janus_worker_wire:cancel(JobRef)
    catch
        _:_ -> ok
    end,
    ok.

mark_dead(JobRef) ->
    Dead = case get(janus_dead_jobs) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    put(janus_dead_jobs, Dead#{JobRef => true}),
    ok.

is_dead(JobRef) ->
    case get(janus_dead_jobs) of
        #{JobRef := true} -> true;
        _ -> false
    end.

flush_job(JobRef) ->
    receive
        {janus_job_ack, JobRef, _} -> flush_job(JobRef);
        {janus_chunk, JobRef, _, _} -> flush_job(JobRef);
        {janus_done, JobRef, _} -> flush_job(JobRef);
        {janus_error, JobRef, _} -> flush_job(JobRef)
    after 0 ->
        ok
    end.

note_inflight(Node, Delta) ->
    try
        janus_worker_pool:note_inflight(Node, Delta)
    catch
        _:_ -> ok
    end.

%%--------------------------------------------------------------------
%% Scheduler v2 casts (Task C, spec Part 0.11 / A.3 / A.4)
%%--------------------------------------------------------------------

%% All `{sched, 2, _}` messages go via gen_server:cast to the LOCAL
%% master pool (the spec-pinned delivery class — an older pool drops
%% and counts them in its catch-all). Casts from this process are
%% FIFO, so rtt always precedes its release at the pool.
sched_cast(Msg) ->
    try
        gen_server:cast(janus_worker_pool, Msg)
    catch
        _:_ -> ok
    end,
    ok.

sched_release(JobRef) ->
    sched_cast({sched, 2, {release, JobRef}}).

%% Forward the worker's additive `rtt_ms` piggyback (done AND error
%% completions; internal jobs never carry it, worker-side).
maybe_ingest_rtt(JobRef, CompletionMap) when is_map(CompletionMap) ->
    case maps:get(rtt_ms, CompletionMap, undefined) of
        RttMs when is_number(RttMs) ->
            sched_cast({sched, 2, {rtt, JobRef, RttMs}});
        _ ->
            ok
    end.

%% TTFB (spec A.4): dispatch-ack -> first forwarded chunk, with the
%% done-completion fallback (full elapsed) for single-chunk/non-stream
%% jobs. Successful non-internal completions only — error completions
%% never feed the health EWMA. Send once per job.
maybe_send_ttfb(_JobRef, _TtfbStart, already_sent) ->
    already_sent;
maybe_send_ttfb(JobRef, TtfbStart, not_sent) ->
    Elapsed = max(0, erlang:monotonic_time(millisecond) - TtfbStart),
    ok = sched_cast({sched, 2, {ttfb, JobRef, Elapsed}}),
    already_sent.

note_dispatch_local(Reason) ->
    try
        janus_worker_pool:note_dispatch_local(Reason)
    catch
        _:_ -> ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Non-stream relay
%%--------------------------------------------------------------------

remote_unary(JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart) ->
    Timeout = maps:get(timeout_ms, Fields) + janus_worker_wire:ack_deadline_ms(),
    receive
        {janus_done, JobRef, Done} ->
            case is_dead(JobRef) of
                true ->
                    {error, worker_lost};
                false ->
                    stash_done(Done, ok),
                    Status = maps:get(status, Done),
                    _ = maybe_ingest_rtt(JobRef, Done),
                    case Status < 400 of
                        true ->
                            %% Single-shot fallback: full elapsed as TTFB.
                            _ = maybe_send_ttfb(JobRef, TtfbStart, not_sent);
                        false ->
                            ok
                    end,
                    ok = sched_release(JobRef),
                    Body =
                        case maps:get(body, Done) of
                            undefined -> <<>>;
                            B when is_binary(B) -> B
                        end,
                    Headers = maps:get(trailers, Done, #{}),
                    {ok, Status, Headers, Body}
            end;
        {janus_error, JobRef, #{code := Code, message := Msg} = ErrMap} ->
            stash_outcome(error),
            ok = maybe_ingest_rtt(JobRef, ErrMap),
            ok = sched_release(JobRef),
            map_worker_error(Code, Msg);
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            stash_outcome(error),
            mark_dead(JobRef),
            ok = sched_release(JobRef),
            {error, worker_lost};
        {janus_chunk, JobRef, _, _} ->
            %% Non-stream must not chunk; ignore and keep waiting.
            remote_unary(JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart)
    after Timeout ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
        %% Stream/unary timeout with a live worker session: NO release
        %% (spec Part 0.11 — release on done/error/worker_lost/send-fail
        %% ONLY; the 10-min purge reclaims).
        {error, {await, timeout}}
    end.

%%--------------------------------------------------------------------
%% Stream relay — returns {ok, stream, Status, Headers, Drain}
%%--------------------------------------------------------------------

remote_stream(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart) ->
    %% First-ship: provisional 200 until done.status (spec §4.2 mid-stream
    %% non-2xx). Status is only on janus_done; chunks may precede it.
    Headers = #{<<"content-type">> => <<"text/event-stream">>},
    Drain = fun(ChunkFun) ->
        try
            stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, 0, TtfbStart, not_sent)
        after
            finish_remote(Mon, WorkerNode)
        end
    end,
    {ok, stream, 200, Headers, Drain}.

stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent) ->
    receive
        {janus_chunk, JobRef, Seq, Bin} when is_binary(Bin) ->
            case is_dead(JobRef) of
                true ->
                    ok;
                false ->
                    case Seq =:= ExpectSeq of
                        true ->
                            ok;
                        false ->
                            logger:warning(#{
                                what => janus_worker_chunk_seq_gap,
                                expected => ExpectSeq,
                                got => Seq,
                                job_ref => binary:encode_hex(JobRef)
                            })
                    end,
                    try
                        ChunkFun(Bin)
                    catch
                        throw:janus_client_disconnect ->
                            stash_outcome(cancelled),
                            cancel_session(WorkerSessionPid, JobRef),
                            mark_dead(JobRef),
                            flush_job(JobRef),
                            throw(janus_client_disconnect)
                    end,
                    %% TTFB on the FIRST forwarded chunk (spec A.4).
                    TtfbSent1 = maybe_send_ttfb(JobRef, TtfbStart, TtfbSent),
                    %% Top up one credit after client write flushed.
                    try
                        WorkerSessionPid ! janus_worker_wire:credit(JobRef, 1)
                    catch
                        _:_ ->
                            ok
                    end,
                    stream_drain(
                        JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, Seq + 1, TtfbStart, TtfbSent1
                    )
            end;
        {janus_done, JobRef, Done} ->
            case is_dead(JobRef) of
                true ->
                    ok;
                false ->
                    Status = maps:get(status, Done, 200),
                    OkOrErr =
                        case Status >= 400 of
                            true -> error;
                            false -> ok
                        end,
                    stash_done(Done, OkOrErr),
                    ok = maybe_ingest_rtt(JobRef, Done),
                    _ =
                        case Status < 400 of
                            true -> maybe_send_ttfb(JobRef, TtfbStart, TtfbSent);
                            false -> TtfbSent
                        end,
                    ok = sched_release(JobRef),
                    case Status >= 400 of
                        true ->
                            {error, {worker_http_status, Status}};
                        false ->
                            ok
                    end
            end;
        {janus_error, JobRef, #{code := Code, message := Msg} = ErrMap} ->
            stash_outcome(error),
            ok = maybe_ingest_rtt(JobRef, ErrMap),
            ok = sched_release(JobRef),
            case map_worker_error(Code, Msg) of
                {error, Reason} -> {error, Reason}
            end;
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            stash_outcome(error),
            mark_dead(JobRef),
            ok = sched_release(JobRef),
            {error, worker_lost};
        {janus_job_ack, JobRef, _} ->
            stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent)
    after janus_worker_wire:stream_timeout_ms() ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
        %% No release on timeout (spec Part 0.11 — see remote_unary).
        {error, {await, timeout}}
    end.

%%--------------------------------------------------------------------
%% Usage / outcome pdict (W2.4 reads outcome; usage from done when set)
%%--------------------------------------------------------------------

stash_done(Done, OkOrErr) when is_map(Done) ->
    stash_outcome(OkOrErr),
    case maps:get(usage, Done, undefined) of
        undefined ->
            ok;
        Usage when is_map(Usage) ->
            put(janus_worker_done_usage, Usage),
            ok;
        _ ->
            ok
    end.

stash_outcome(Kind) ->
    put(janus_usage_outcome, outcome_bin(Kind)),
    ok.
