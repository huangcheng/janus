%%% @doc Scheduler v2 Task C tests for `janus_worker_session` (spec
%%% rev 10 Part A.3 / E.6): the rtt_ms piggyback on done AND error,
%%% the internal (probe) three-seam exclusion (no rtt_ms key, no EWMA
%%% report), and the successful-completions-only duration report to
%%% the dispatcher.
%%%
%%% Sessions run as REAL spawned processes against real I/O: error
%%% paths use an unroutable 127.0.0.1:1 target (instant refusal); the
%%% done paths use a one-shot local HTTP server (production gun path).
%%% Each test uses a UNIQUE JobRef — a session from a timed-out
%%% earlier test can deliver late messages.
-module(janus_worker_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% rtt_ms piggyback (spec A.3)
%%%===================================================================

%% Normal job, upstream refused: the ERROR map carries the raw
%% per-job upstream duration as an additive float key. (The refusal
%% can surface at gun's 5 s connect budget — generous receive.)
error_carries_rtt_ms_test_() ->
    {timeout, 20, fun error_carries_rtt_ms/0}.

error_carries_rtt_ms() ->
    Forwarder = start_dispatcher_forwarder(),
    try
        JobRef = jref(<<"err">>),
        run_refused(JobRef, #{provider_id => <<"p1">>}),
        receive
            {janus_error, JobRef, ErrMap} ->
                %% Refusal class (connect/timeout — either way the map
                %% carries the raw upstream duration).
                ?assert(is_atom(maps:get(code, ErrMap))),
                ?assert(is_binary(maps:get(message, ErrMap))),
                Rtt = maps:get(rtt_ms, ErrMap, undefined),
                ?assert(is_float(Rtt)),
                ?assert(Rtt >= 0.0)
        after 12000 ->
            error({no_error_message, pending()})
        end,
        %% Error completions never feed the worker EWMA.
        timer:sleep(150),
        ?assertEqual(none, check_mailbox(job_duration))
    after
        stop_dispatcher_forwarder(Forwarder)
    end.

%% Internal (probe) job, upstream refused: NEITHER the rtt_ms key NOR
%% the EWMA report (three-seam exclusion, spec E.6 — the message stays
%% byte-compatible with the old shape).
internal_error_has_no_rtt_ms_test_() ->
    {timeout, 20, fun internal_error_has_no_rtt_ms/0}.

internal_error_has_no_rtt_ms() ->
    Forwarder = start_dispatcher_forwarder(),
    try
        JobRef = jref(<<"err-int">>),
        run_refused(JobRef, #{provider_id => <<"p1">>, internal => true}),
        receive
            {janus_error, JobRef, ErrMap} ->
                ?assert(is_atom(maps:get(code, ErrMap))),
                ?assert(is_binary(maps:get(message, ErrMap))),
                ?assertEqual(false, maps:is_key(rtt_ms, ErrMap))
        after 12000 ->
            error({no_error_message, pending()})
        end,
        ?assertEqual(none, check_mailbox(job_duration))
    after
        stop_dispatcher_forwarder(Forwarder)
    end.

%% Normal 200 completion: done carries rtt_ms AND the successful
%% duration is reported to the dispatcher for the per-provider EWMA.
done_carries_rtt_ms_and_reports_test_() ->
    {timeout, 20, fun done_carries_rtt_ms_and_reports/0}.

done_carries_rtt_ms_and_reports() ->
    Forwarder = start_dispatcher_forwarder(),
    try
        JobRef = jref(<<"done-ok">>),
        {Server, Port} = start_http_server(200),
        run_local(JobRef, Port, #{provider_id => <<"p1">>}),
        receive
            {janus_done, JobRef, DoneMap} ->
                ?assertEqual(200, maps:get(status, DoneMap)),
                Rtt = maps:get(rtt_ms, DoneMap, undefined),
                ?assert(is_float(Rtt)),
                ?assert(Rtt >= 0.0)
        after 8000 ->
            error({no_done_message, pending()})
        end,
        receive
            {job_duration, <<"p1">>, Reported} ->
                ?assert(is_float(Reported)),
                ?assert(Reported >= 0.0)
        after 5000 ->
            error({no_duration_report, pending()})
        end,
        stop_http_server(Server)
    after
        stop_dispatcher_forwarder(Forwarder)
    end.

%% Error-status (>= 400) completion: done STILL carries rtt_ms (error
%% completions write passive rows on the master) but the worker EWMA
%% feed stays success-only — NO {job_duration,...} report.
error_status_done_carries_rtt_but_no_report_test_() ->
    {timeout, 20, fun error_status_done_carries_rtt_but_no_report/0}.

error_status_done_carries_rtt_but_no_report() ->
    Forwarder = start_dispatcher_forwarder(),
    try
        JobRef = jref(<<"done-500">>),
        {Server, Port} = start_http_server(500),
        run_local(JobRef, Port, #{provider_id => <<"p1">>}),
        receive
            {janus_done, JobRef, DoneMap} ->
                ?assertEqual(500, maps:get(status, DoneMap)),
                ?assert(is_float(maps:get(rtt_ms, DoneMap, undefined)))
        after 8000 ->
            error({no_done_message, pending()})
        end,
        timer:sleep(150),
        ?assertEqual(none, check_mailbox(job_duration)),
        stop_http_server(Server)
    after
        stop_dispatcher_forwarder(Forwarder)
    end.

%% Internal 200 completion: no rtt_ms on done, no EWMA report.
internal_done_has_no_rtt_ms_test_() ->
    {timeout, 20, fun internal_done_has_no_rtt_ms/0}.

internal_done_has_no_rtt_ms() ->
    Forwarder = start_dispatcher_forwarder(),
    try
        JobRef = jref(<<"done-int">>),
        {Server, Port} = start_http_server(200),
        run_local(JobRef, Port, #{provider_id => <<"p1">>, internal => true}),
        receive
            {janus_done, JobRef, DoneMap} ->
                ?assertEqual(200, maps:get(status, DoneMap)),
                ?assertEqual(false, maps:is_key(rtt_ms, DoneMap))
        after 8000 ->
            error({no_done_message, pending()})
        end,
        timer:sleep(150),
        ?assertEqual(none, check_mailbox(job_duration)),
        stop_http_server(Server)
    after
        stop_dispatcher_forwarder(Forwarder)
    end.

%%%===================================================================
%%% Fixtures
%%%===================================================================

%% Unique per-test JobRef.
jref(Suffix) ->
    <<"sess-job-", Suffix/binary>>.

%% Production-shaped job Fields against a refused local port.
run_refused(JobRef, Extra) ->
    Fields = base_fields(<<"http://127.0.0.1:1/v1/chat">>, Extra),
    run_session(JobRef, Fields).

run_local(JobRef, Port, Extra) ->
    Url = <<"http://127.0.0.1:", (integer_to_binary(Port))/binary, "/v1/chat">>,
    Fields = base_fields(Url, Extra),
    run_session(JobRef, Fields).

run_session(JobRef, Fields) ->
    %% gun:open needs the gun supervision tree (gun_conns_sup) — the
    %% release starts it; eunit must not rely on that.
    {ok, _} = application:ensure_all_started(gun),
    Master = self(),
    {Pid, _Mon} = spawn_monitor(fun() -> janus_worker_session:run(JobRef, Master, Fields) end),
    %% The session acks before any upstream I/O (production handshake).
    receive
        {janus_job_ack, JobRef, Pid} -> ok
    after 5000 ->
        error(no_job_ack)
    end,
    ok.

base_fields(Url, Extra) ->
    maps:merge(
        #{
            url => Url,
            method => post,
            headers => [
                {<<"authorization">>, <<"Bearer sk-test">>},
                {<<"content-type">>, <<"application/json">>}
            ],
            body => <<"{\"model\":\"x\"}">>,
            stream => false,
            timeout_ms => 30_000,
            protocol_meta => #{}
        },
        Extra
    ).

%% The session reports durations to the janus_worker_dispatch NAME —
%% register a forwarder that mirrors every message to the test process
%% (the real dispatcher only boots on worker nodes).
start_dispatcher_forwarder() ->
    Parent = self(),
    Pid = spawn(fun() ->
        register(janus_worker_dispatch, self()),
        Parent ! forwarder_ready,
        forward_loop(Parent)
    end),
    receive
        forwarder_ready -> Pid
    after 5000 ->
        error(forwarder_not_ready)
    end.

forward_loop(Parent) ->
    receive
        stop ->
            ok;
        Msg ->
            Parent ! Msg,
            forward_loop(Parent)
    after 10_000 ->
        ok
    end.

stop_dispatcher_forwarder(Pid) ->
    Pid ! stop,
    ok.

%% One-shot local HTTP server: accepts ONE connection, DRAINS the
%% request head, answers a canned content-length response, lingers,
%% closes (gun's production response path — no invented frames). The
%% drain + linger matter: closing with unread request data RSTs the
%% connection and the response is lost.
start_http_server(Status) ->
    Parent = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Reason =
        case Status of
            200 -> <<"OK">>;
            500 -> <<"Internal Server Error">>
        end,
    Body = <<"{\"ok\":true}">>,
    Spawned =
        spawn(fun() ->
            {ok, Sock} = gen_tcp:accept(Listen, 5000),
            ok = drain_request_head(Sock),
            Resp = [
                <<"HTTP/1.1 ">>,
                integer_to_binary(Status),
                <<" ">>,
                Reason,
                <<"\r\ncontent-type: application/json\r\ncontent-length: ">>,
                integer_to_binary(byte_size(Body)),
                <<"\r\n\r\n">>,
                Body
            ],
            ok = gen_tcp:send(Sock, Resp),
            timer:sleep(100),
            gen_tcp:close(Sock),
            gen_tcp:close(Listen),
            Parent ! {http_server_done, self()}
        end),
    {Spawned, Port}.

drain_request_head(Sock) ->
    case gen_tcp:recv(Sock, 0, 3000) of
        {ok, Bin} ->
            case binary:match(Bin, <<"\r\n\r\n">>) of
                nomatch -> drain_request_head(Sock);
                _ -> ok
            end;
        {error, _} ->
            ok
    end.

stop_http_server(_Spawned) ->
    %% The server is one-shot and self-closing; the completion message
    %% is drained opportunistically by later receives.
    ok.

%% Non-blocking mailbox probe for a tagged message.
check_mailbox(Tag) ->
    receive
        Msg when element(1, Msg) =:= Tag -> {found, Msg}
    after 0 ->
        none
    end.

%% Debug helper: what is still queued in this test process's mailbox.
pending() ->
    receive
        M -> [M | pending()]
    after 0 ->
        []
    end.
