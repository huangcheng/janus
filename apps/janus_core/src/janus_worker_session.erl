%%% @doc Per-job worker session (spec §3.2 / §4).
%%%
%%% Monitors the master session pid, acks, runs upstream I/O via
%%% `janus_providers_http` (`post/3`, `post_stream/3`, `get/3`), and
%%% relays chunk/done/error. Stream jobs credit-gate chunks (seq from 0);
%%% non-stream jobs emit a single `janus_done` with the full body.
%%%
%%% Stream drain runs in a child process so cancel/timeout can
%%% `exit(Pid, kill)` even while gun:await is blocked.
-module(janus_worker_session).

-export([run/3]).

-define(PDICT_CREDITS, janus_worker_credits).
-define(PDICT_SEQ, janus_worker_seq).
-define(PDICT_JOB, janus_worker_job_ref).
-define(PDICT_MASTER, janus_worker_master).
-define(PDICT_MASTER_MON, janus_worker_master_mon).
-define(PDICT_WORKER, janus_worker_http_pid).

-spec run(binary(), pid(), map()) -> ok.
run(JobRef, MasterSessionPid, Fields) when
    is_binary(JobRef), is_pid(MasterSessionPid), is_map(Fields)
->
    MasterMon = monitor(process, MasterSessionPid),
    put(?PDICT_JOB, JobRef),
    put(?PDICT_MASTER, MasterSessionPid),
    put(?PDICT_MASTER_MON, MasterMon),
    put(?PDICT_CREDITS, 0),
    put(?PDICT_SEQ, janus_worker_wire:initial_chunk_seq()),
    MasterSessionPid ! janus_worker_wire:job_ack(JobRef, self()),
    TimeoutMs = maps:get(timeout_ms, Fields),
    TRef = erlang:send_after(TimeoutMs, self(), job_timeout),
    try
        case maps:get(stream, Fields) of
            true ->
                run_stream(Fields);
            false ->
                run_unary(Fields)
        end
    catch
        throw:cancelled ->
            ok;
        throw:master_down ->
            ok;
        throw:timeout ->
            emit_error(timeout, <<"job timeout_ms exceeded">>);
        throw:{gun_error, Code, Message} ->
            emit_error(Code, Message);
        Class:Reason:Stack ->
            logger:error(#{
                what => janus_worker_session_crashed,
                class => Class,
                reason => redact(Reason),
                stack => janus_seed:redact_stack(Stack)
            }),
            emit_error(internal, <<"session crashed">>)
    after
        case get(?PDICT_WORKER) of
            undefined -> ok;
            WPid when is_pid(WPid) -> exit(WPid, kill)
        end,
        _ = erlang:cancel_timer(TRef),
        demonitor(MasterMon, [flush]),
        erase(?PDICT_JOB),
        erase(?PDICT_MASTER),
        erase(?PDICT_MASTER_MON),
        erase(?PDICT_CREDITS),
        erase(?PDICT_SEQ),
        erase(?PDICT_WORKER)
    end,
    ok.

%%%===================================================================
%%% Unary (non-stream)
%%%===================================================================

run_unary(#{method := Method, url := Url, headers := Headers, body := Body0} = _Fields) ->
    Body = iolist_to_binary(Body0),
    case target_from_url(Url) of
        {ok, Target} ->
            Self = self(),
            {HttpPid, HttpMon} = spawn_monitor(fun() ->
                Result = unary_http(Method, Target, Headers, Body),
                Self ! {http_result, self(), Result}
            end),
            put(?PDICT_WORKER, HttpPid),
            wait_unary(HttpPid, HttpMon);
        {error, Reason} ->
            throw({gun_error, connect, fmt_bin(Reason)})
    end.

unary_http(get, Target, Headers, _Body) ->
    %% get/3 timeout: use non-stream budget from wire as the per-await cap;
    %% overall wall clock is still enforced by the session timer.
    janus_providers_http:get(Target, Headers, janus_worker_wire:non_stream_timeout_ms());
unary_http(post, Target, Headers, Body) ->
    %% post/3 uses fixed gun TTFB/body budgets; session timer is the
    %% job-level wall clock (may kill the HTTP worker early).
    janus_providers_http:post(Target, Headers, Body);
unary_http(Method, _Target, _Headers, _Body) ->
    {error, {unsupported_method, Method}}.

wait_unary(HttpPid, HttpMon) ->
    receive
        {http_result, HttpPid, {ok, Status, _RespHeaders, RespBody}} ->
            demonitor(HttpMon, [flush]),
            ensure_clear_control(),
            emit_done(Status, RespBody);
        {http_result, HttpPid, {error, Reason}} ->
            demonitor(HttpMon, [flush]),
            {Code, Msg} = map_gun_error(Reason),
            throw({gun_error, Code, Msg});
        job_timeout ->
            kill_worker(HttpPid, HttpMon),
            throw(timeout);
        {janus_cancel, JobRef} ->
            case get(?PDICT_JOB) of
                JobRef ->
                    kill_worker(HttpPid, HttpMon),
                    throw(cancelled);
                _ ->
                    wait_unary(HttpPid, HttpMon)
            end;
        {'DOWN', Mon, process, _Pid, Reason} ->
            case get(?PDICT_MASTER_MON) of
                Mon ->
                    kill_worker(HttpPid, HttpMon),
                    throw(master_down);
                _ ->
                    case Mon of
                        HttpMon ->
                            throw(
                                {gun_error, internal,
                                    <<"http worker died: ", (fmt_bin(Reason))/binary>>}
                            );
                        _ ->
                            wait_unary(HttpPid, HttpMon)
                    end
            end;
        {janus_credit, _JobRef, _N} ->
            %% Non-stream ignores credits.
            wait_unary(HttpPid, HttpMon)
    end.

%%%===================================================================
%%% Stream — drain in a child so session can kill on cancel/timeout
%%%===================================================================

run_stream(#{url := Url, headers := Headers, body := Body0} = _Fields) ->
    Body = iolist_to_binary(Body0),
    case target_from_url(Url) of
        {ok, Target} ->
            Self = self(),
            {DrainPid, DrainMon} = spawn_monitor(fun() ->
                stream_worker(Self, Target, Headers, Body)
            end),
            put(?PDICT_WORKER, DrainPid),
            wait_stream(DrainPid, DrainMon);
        {error, Reason} ->
            throw({gun_error, connect, fmt_bin(Reason)})
    end.

stream_worker(Session, Target, Headers, Body) ->
    %% Exit if the session dies while we wait for continue/stop.
    SessionMon = monitor(process, Session),
    case janus_providers_http:post_stream(Target, Headers, Body) of
        {ok, Status, _RespHeaders, Drain} when is_function(Drain, 1) ->
            Session ! {stream_open, self(), Status},
            Result =
                try
                    Drain(fun(Chunk) ->
                        Session ! {stream_chunk, self(), Chunk},
                        receive
                            {stream_continue, Session} ->
                                ok;
                            {stream_stop, Session} ->
                                throw(stopped);
                            {'DOWN', SessionMon, process, Session, _} ->
                                throw(stopped)
                        end
                    end)
                catch
                    throw:stopped ->
                        {error, cancelled}
                end,
            demonitor(SessionMon, [flush]),
            Session ! {stream_drain_done, self(), Result};
        {error, Reason} ->
            demonitor(SessionMon, [flush]),
            Session ! {stream_open_error, self(), Reason}
    end.

wait_stream(DrainPid, DrainMon) ->
    receive
        {stream_open, DrainPid, Status} ->
            wait_stream_body(DrainPid, DrainMon, Status);
        {stream_open_error, DrainPid, Reason} ->
            demonitor(DrainMon, [flush]),
            {Code, Msg} = map_gun_error(Reason),
            throw({gun_error, Code, Msg});
        job_timeout ->
            kill_worker(DrainPid, DrainMon),
            throw(timeout);
        {janus_cancel, JobRef} ->
            case get(?PDICT_JOB) of
                JobRef ->
                    kill_worker(DrainPid, DrainMon),
                    throw(cancelled);
                _ ->
                    wait_stream(DrainPid, DrainMon)
            end;
        {'DOWN', Mon, process, _Pid, Reason} ->
            case get(?PDICT_MASTER_MON) of
                Mon ->
                    kill_worker(DrainPid, DrainMon),
                    throw(master_down);
                _ ->
                    case Mon of
                        DrainMon ->
                            throw(
                                {gun_error, internal,
                                    <<"stream worker died: ", (fmt_bin(Reason))/binary>>}
                            );
                        _ ->
                            wait_stream(DrainPid, DrainMon)
                    end
            end;
        {janus_credit, JobRef, N} when is_integer(N), N > 0 ->
            case get(?PDICT_JOB) of
                JobRef -> put(?PDICT_CREDITS, get(?PDICT_CREDITS) + N);
                _ -> ok
            end,
            wait_stream(DrainPid, DrainMon)
    end.

wait_stream_body(DrainPid, DrainMon, Status) ->
    receive
        {stream_chunk, DrainPid, Bin} when is_binary(Bin) ->
            try
                await_credit_then_send(Bin)
            catch
                throw:Stop ->
                    DrainPid ! {stream_stop, self()},
                    kill_worker(DrainPid, DrainMon),
                    throw(Stop)
            end,
            DrainPid ! {stream_continue, self()},
            wait_stream_body(DrainPid, DrainMon, Status);
        {stream_drain_done, DrainPid, ok} ->
            demonitor(DrainMon, [flush]),
            ensure_clear_control(),
            emit_done(Status, undefined);
        {stream_drain_done, DrainPid, {error, cancelled}} ->
            demonitor(DrainMon, [flush]),
            throw(cancelled);
        {stream_drain_done, DrainPid, {error, Reason}} ->
            demonitor(DrainMon, [flush]),
            {Code, Msg} = map_gun_error(Reason),
            throw({gun_error, Code, Msg});
        job_timeout ->
            DrainPid ! {stream_stop, self()},
            kill_worker(DrainPid, DrainMon),
            throw(timeout);
        {janus_cancel, JobRef} ->
            case get(?PDICT_JOB) of
                JobRef ->
                    DrainPid ! {stream_stop, self()},
                    kill_worker(DrainPid, DrainMon),
                    throw(cancelled);
                _ ->
                    wait_stream_body(DrainPid, DrainMon, Status)
            end;
        {'DOWN', Mon, process, _Pid, Reason} ->
            case get(?PDICT_MASTER_MON) of
                Mon ->
                    DrainPid ! {stream_stop, self()},
                    kill_worker(DrainPid, DrainMon),
                    throw(master_down);
                _ ->
                    case Mon of
                        DrainMon ->
                            throw(
                                {gun_error, internal,
                                    <<"stream worker died: ", (fmt_bin(Reason))/binary>>}
                            );
                        _ ->
                            wait_stream_body(DrainPid, DrainMon, Status)
                    end
            end;
        {janus_credit, JobRef, N} when is_integer(N), N > 0 ->
            case get(?PDICT_JOB) of
                JobRef -> put(?PDICT_CREDITS, get(?PDICT_CREDITS) + N);
                _ -> ok
            end,
            wait_stream_body(DrainPid, DrainMon, Status)
    end.

await_credit_then_send(Bin) ->
    case get(?PDICT_CREDITS) of
        N when is_integer(N), N > 0 ->
            put(?PDICT_CREDITS, N - 1),
            Seq = get(?PDICT_SEQ),
            JobRef = get(?PDICT_JOB),
            Master = get(?PDICT_MASTER),
            Master ! janus_worker_wire:chunk(JobRef, Seq, Bin),
            put(?PDICT_SEQ, Seq + 1),
            ok;
        _ ->
            receive
                {janus_credit, JobRef, N} when is_integer(N), N > 0 ->
                    case get(?PDICT_JOB) of
                        JobRef ->
                            put(?PDICT_CREDITS, get(?PDICT_CREDITS) + N),
                            await_credit_then_send(Bin);
                        _ ->
                            await_credit_then_send(Bin)
                    end;
                {janus_cancel, JobRef} ->
                    case get(?PDICT_JOB) of
                        JobRef -> throw(cancelled);
                        _ -> await_credit_then_send(Bin)
                    end;
                job_timeout ->
                    throw(timeout);
                {'DOWN', Mon, process, _Pid, _Reason} ->
                    case get(?PDICT_MASTER_MON) of
                        Mon -> throw(master_down);
                        _ -> await_credit_then_send(Bin)
                    end
            end
    end.

kill_worker(Pid, Mon) ->
    exit(Pid, kill),
    demonitor(Mon, [flush]),
    flush_worker_msgs(Pid).

flush_worker_msgs(Pid) ->
    receive
        {http_result, Pid, _} -> flush_worker_msgs(Pid);
        {stream_open, Pid, _} -> flush_worker_msgs(Pid);
        {stream_open_error, Pid, _} -> flush_worker_msgs(Pid);
        {stream_chunk, Pid, _} -> flush_worker_msgs(Pid);
        {stream_drain_done, Pid, _} -> flush_worker_msgs(Pid);
        {'DOWN', _Mon, process, Pid, _} -> flush_worker_msgs(Pid)
    after 0 ->
        ok
    end.

%% Reject late cancel/timeout/DOWN before emitting done.
ensure_clear_control() ->
    receive
        job_timeout ->
            throw(timeout);
        {janus_cancel, JobRef} ->
            case get(?PDICT_JOB) of
                JobRef -> throw(cancelled);
                _ -> ensure_clear_control()
            end;
        {'DOWN', Mon, process, _Pid, _Reason} ->
            case get(?PDICT_MASTER_MON) of
                Mon -> throw(master_down);
                _ -> ensure_clear_control()
            end;
        {janus_credit, _JobRef, _N} ->
            ensure_clear_control()
    after 0 ->
        ok
    end.

%%%===================================================================
%%% Emit helpers
%%%===================================================================

emit_done(Status, Body) ->
    JobRef = get(?PDICT_JOB),
    Master = get(?PDICT_MASTER),
    Fields = #{
        usage => undefined,
        status => Status,
        trailers => #{},
        body => Body
    },
    Master ! janus_worker_wire:done(JobRef, Fields),
    ok.

emit_error(Code, Message) when is_atom(Code), is_binary(Message) ->
    JobRef = get(?PDICT_JOB),
    Master = get(?PDICT_MASTER),
    case janus_worker_wire:error(JobRef, Code, Message) of
        {ok, Err} ->
            Master ! Err;
        {error, _} ->
            ok
    end,
    ok.

%%%===================================================================
%%% URL / error mapping
%%%===================================================================

target_from_url(Url) ->
    case janus_providers_http:parse_base(Url) of
        {ok, Host, Port, Path0, Tls} ->
            Path1 =
                case Path0 of
                    <<>> -> <<"/">>;
                    _ -> Path0
                end,
            Path = append_query(Path1, Url),
            {ok, #{host => Host, port => Port, path => Path, tls => Tls}};
        {error, _} = Err ->
            Err
    end.

append_query(Path, Url) ->
    case uri_string:parse(Url) of
        #{query := Q} when is_binary(Q), byte_size(Q) > 0 ->
            <<Path/binary, $?, Q/binary>>;
        #{query := Q} when is_list(Q), Q =/= [] ->
            <<Path/binary, $?, (list_to_binary(Q))/binary>>;
        _ ->
            Path
    end.

map_gun_error({open, Reason}) ->
    {connect, fmt_bin({open, Reason})};
map_gun_error({await_up, Reason}) ->
    case looks_tls(Reason) of
        true -> {tls, fmt_bin({await_up, Reason})};
        false -> {connect, fmt_bin({await_up, Reason})}
    end;
map_gun_error({await, timeout}) ->
    {timeout, <<"upstream await timeout">>};
map_gun_error({await, Reason}) ->
    {upstream_closed, fmt_bin({await, Reason})};
map_gun_error({body, timeout}) ->
    {timeout, <<"upstream body timeout">>};
map_gun_error({body, Reason}) ->
    {upstream_closed, fmt_bin({body, Reason})};
map_gun_error({unsupported_method, Method}) ->
    {internal, fmt_bin({unsupported_method, Method})};
map_gun_error(timeout) ->
    {timeout, <<"timeout">>};
map_gun_error(cancelled) ->
    {internal, <<"cancelled">>};
map_gun_error(Reason) ->
    {internal, fmt_bin(Reason)}.

looks_tls(Reason) ->
    Bin = fmt_bin(Reason),
    case
        binary:matches(string:lowercase(Bin), [<<"tls">>, <<"ssl">>, <<"handshake">>, <<"cert">>])
    of
        [] -> false;
        _ -> true
    end.

fmt_bin(Term) ->
    iolist_to_binary(io_lib:format("~0p", [Term])).

redact(Reason) ->
    %% Never log job headers/body; keep crash reasons opaque-ish.
    fmt_bin(Reason).
