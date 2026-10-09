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
    normalize_want_stream/1,
    outcome_bin/1,
    map_worker_error/2,
    parse_affinity_node/1,
    affinity_opts_from_provider/1
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
            case safe_pick(Affinity) of
                empty ->
                    LocalFun();
                {ok, WorkerNode} ->
                    case prepare_job(ProviderProto, Route, Map, WantStream) of
                        {error, _} = Err ->
                            %% Same failure local gun would see after resolve.
                            Err;
                        {ok, Fields} ->
                            dispatch(WorkerNode, Fields, WantStream, LocalFun)
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
    finish_prepare(janus_providers_openai:prepare(chat_completions, Route, Map, WantStream), WantStream);
prepare_job(openai_responses, Route, Map, WantStream) ->
    finish_prepare(janus_providers_openai:prepare(responses, Route, Map, WantStream), WantStream);
prepare_job(openai_decisions, Route, Map, WantStream) ->
    finish_prepare(janus_providers_openai:prepare(decisions, Route, Map, WantStream), WantStream);
prepare_job(anthropic_messages, Route, Map, WantStream) ->
    finish_prepare(janus_providers_anthropic:prepare(Route, Map, WantStream), WantStream);
prepare_job(_, _, _, _) ->
    {error, unknown_protocol}.

finish_prepare({error, _} = Err, _WantStream) ->
    Err;
finish_prepare({ok, #{url := Url, method := Method, headers := Headers, body := Body}}, WantStream) ->
    Timeout =
        case WantStream of
            true -> janus_worker_wire:stream_timeout_ms();
            false -> janus_worker_wire:non_stream_timeout_ms()
        end,
    Fields = #{
        url => Url,
        method => Method,
        headers => Headers,
        body => Body,
        stream => WantStream,
        timeout_ms => Timeout,
        protocol_meta => #{}
    },
    {ok, Fields}.

%%--------------------------------------------------------------------
%% Send job / ack / relay
%%--------------------------------------------------------------------

dispatch(WorkerNode, Fields, WantStream, LocalFun) ->
    JobRef = crypto:strong_rand_bytes(16),
    case janus_worker_wire:job(JobRef, self(), Fields) of
        {error, _} ->
            LocalFun();
        {ok, JobMsg} ->
            note_inflight(WorkerNode, 1),
            case send_job(WorkerNode, JobMsg) of
                {error, _} ->
                    note_inflight(WorkerNode, -1),
                    LocalFun();
                ok ->
                    case wait_ack(JobRef, WorkerNode) of
                        {error, ack_timeout} ->
                            mark_dead(JobRef),
                            cancel_dispatch(WorkerNode, JobRef),
                            flush_job(JobRef),
                            note_inflight(WorkerNode, -1),
                            LocalFun();
                        {ok, WorkerSessionPid} ->
                            Mon = monitor(process, WorkerSessionPid),
                            case WantStream of
                                true ->
                                    %% Drain runs AFTER upstream_call returns —
                                    %% release inflight / demonitor inside Drain.
                                    grant_credit(WorkerSessionPid, JobRef),
                                    remote_stream(JobRef, WorkerSessionPid, Mon, WorkerNode);
                                false ->
                                    try
                                        remote_unary(
                                            JobRef, WorkerSessionPid, Mon, WorkerNode, Fields
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
%% Non-stream relay
%%--------------------------------------------------------------------

remote_unary(JobRef, WorkerSessionPid, Mon, WorkerNode, Fields) ->
    Timeout = maps:get(timeout_ms, Fields) + janus_worker_wire:ack_deadline_ms(),
    receive
        {janus_done, JobRef, Done} ->
            case is_dead(JobRef) of
                true ->
                    {error, worker_lost};
                false ->
                    stash_done(Done, ok),
                    Status = maps:get(status, Done),
                    Body =
                        case maps:get(body, Done) of
                            undefined -> <<>>;
                            B when is_binary(B) -> B
                        end,
                    Headers = maps:get(trailers, Done, #{}),
                    {ok, Status, Headers, Body}
            end;
        {janus_error, JobRef, #{code := Code, message := Msg}} ->
            stash_outcome(error),
            map_worker_error(Code, Msg);
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            stash_outcome(error),
            mark_dead(JobRef),
            {error, worker_lost};
        {janus_chunk, JobRef, _, _} ->
            %% Non-stream must not chunk; ignore and keep waiting.
            remote_unary(JobRef, WorkerSessionPid, Mon, WorkerNode, Fields)
    after Timeout ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
        {error, {await, timeout}}
    end.

%%--------------------------------------------------------------------
%% Stream relay — returns {ok, stream, Status, Headers, Drain}
%%--------------------------------------------------------------------

remote_stream(JobRef, WorkerSessionPid, Mon, WorkerNode) ->
    %% First-ship: provisional 200 until done.status (spec §4.2 mid-stream
    %% non-2xx). Status is only on janus_done; chunks may precede it.
    Headers = #{<<"content-type">> => <<"text/event-stream">>},
    Drain = fun(ChunkFun) ->
        try
            stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, 0)
        after
            finish_remote(Mon, WorkerNode)
        end
    end,
    {ok, stream, 200, Headers, Drain}.

stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq) ->
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
                    %% Top up one credit after client write flushed.
                    try
                        WorkerSessionPid ! janus_worker_wire:credit(JobRef, 1)
                    catch
                        _:_ ->
                            ok
                    end,
                    stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, Seq + 1)
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
                    case Status >= 400 of
                        true ->
                            {error, {worker_http_status, Status}};
                        false ->
                            ok
                    end
            end;
        {janus_error, JobRef, #{code := Code, message := Msg}} ->
            stash_outcome(error),
            case map_worker_error(Code, Msg) of
                {error, Reason} -> {error, Reason}
            end;
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            stash_outcome(error),
            mark_dead(JobRef),
            {error, worker_lost};
        {janus_job_ack, JobRef, _} ->
            stream_drain(JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq)
    after janus_worker_wire:stream_timeout_ms() ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
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
