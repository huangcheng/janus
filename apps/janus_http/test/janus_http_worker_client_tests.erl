%%% @doc Pure helpers + scheduler v2 Task C dispatch seams for
%%% master→worker proxy dispatch (W2.1 / spec rev 10 Part 0.11).
%%%
%%% Live tests boot the REAL janus_worker_pool (heir + sqlite + pool —
%%% janus_worker_pool_v2_tests fixture pattern) with a FAKE local
%%% worker registered under `janus_worker_dispatch` (the worker node
%%% is this node; the fake acks and completes with production-shaped
%%% done maps carrying the additive `rtt_ms`), then drive
%%% `unary_post/5` end-to-end and assert the client's {sched, 2, _}
%%% casts land: rtt ingest, TTFB health feed, release-on-completion,
%%% send-fail release + metric, and ack-miss STAYS PENDING.
-module(janus_http_worker_client_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_want_stream_test() ->
    ?assertEqual(true, janus_http_worker_client:normalize_want_stream(true)),
    ?assertEqual(false, janus_http_worker_client:normalize_want_stream(false)),
    ?assertEqual(false, janus_http_worker_client:normalize_want_stream(#{stream => false})),
    ?assertEqual(true, janus_http_worker_client:normalize_want_stream(#{stream => true})).

outcome_bin_test() ->
    ?assertEqual(<<"completed">>, janus_http_worker_client:outcome_bin(ok)),
    ?assertEqual(<<"failed">>, janus_http_worker_client:outcome_bin(error)),
    ?assertEqual(<<"cancelled">>, janus_http_worker_client:outcome_bin(cancelled)).

video_path_test() ->
    ?assertEqual(true, janus_http_worker_client:video_path(<<"/videos">>)),
    ?assertEqual(true, janus_http_worker_client:video_path(<<"/videos/abc">>)),
    ?assertEqual(false, janus_http_worker_client:video_path(<<"/images/generations">>)),
    ?assertEqual(false, janus_http_worker_client:video_path(<<"/chat/completions">>)).

map_worker_error_test() ->
    ?assertEqual({error, {await, timeout}}, janus_http_worker_client:map_worker_error(timeout, <<"x">>)),
    ?assertEqual({error, {worker_error, connect}}, janus_http_worker_client:map_worker_error(connect, <<"x">>)),
    ?assertEqual({error, worker_lost}, janus_http_worker_client:map_worker_error(worker_lost, <<"x">>)).

affinity_node_parse_test() ->
    ?assertEqual(undefined, janus_http_worker_client:parse_affinity_node(undefined)),
    ?assertEqual(undefined, janus_http_worker_client:parse_affinity_node(null)),
    ?assertEqual(undefined, janus_http_worker_client:parse_affinity_node(<<>>)),
    %% Unknown node name must not create atoms.
    ?assertEqual(
        undefined,
        janus_http_worker_client:parse_affinity_node(<<"no_such_node@nowhere.example">>)
    ),
    Node = node(),
    Bin = atom_to_binary(Node, utf8),
    ?assertEqual(Node, janus_http_worker_client:parse_affinity_node(Bin)).

affinity_opts_test() ->
    Opts = janus_http_worker_client:affinity_opts_from_provider(#{
        region_tag => <<"cn-hz">>,
        affinity_node => atom_to_binary(node(), utf8)
    }),
    ?assertEqual(<<"cn-hz">>, maps:get(region_tag, Opts)),
    ?assertEqual(node(), maps:get(affinity_node, Opts)).

%%%===================================================================
%%% Task C — live dispatch seams (real pool + fake local worker)
%%%===================================================================

%% Happy path: done with rtt_ms => the client forwards rtt (passive
%% row keyed by the pick-time provider_id), feeds TTFB, and releases
%% the reservation. The job Fields carry the additive provider_id and
%% NO internal marker.
live_unary_done_rtt_ttfb_release_test_() ->
    {timeout, 15, fun live_unary_done_rtt_ttfb_release/0}.

live_unary_done_rtt_ttfb_release() ->
    Stack = start_stack(),
    Fake = start_fake_worker(ack_and_done),
    try
        Result = run_unary(),
        ?assertEqual({ok, 200, #{}, <<"{\"ok\":true}">>}, Result),
        %% The job Fields the worker received carry the additive
        %% provider_id (worker EWMA attribution) and NEVER internal.
        {JobRef, Fields} = expect_job(),
        ?assertEqual(16, byte_size(JobRef)),
        ?assertEqual(<<"p1">>, maps:get(provider_id, Fields)),
        ?assertEqual(false, maps:is_key(internal, Fields)),
        %% Reservation released (counter back to 0).
        ok = wait_until(fun() ->
            lists:sort([C || {_, C} <- ets:tab2list(sched_reserve)]) =:= [0]
        end, 200),
        %% rtt ingest: passive row keyed {Node, ProviderId} via the
        %% pick-time provider_id (Task C threading).
        ok = wait_until(fun() ->
            Rows = [
                Row
             || {{N, P}, _, passive, _, _} = Row <- ets:tab2list(sched_rtt),
                N =:= node(),
                P =:= <<"p1">>
            ],
            length(Rows) =:= 1
        end, 200),
        %% TTFB health feed: one sample on this node; dispatch metrics.
        Stats = janus_worker_pool:sched_stats(),
        ?assert(maps:is_key(node(), maps:get(health_ewma, Stats))),
        ?assertEqual(1, maps:get({dispatch_worker, node(), <<"p1">>}, Stats, 0)),
        ?assertEqual(0, maps:get({dispatch_local, send_fail}, Stats, 0)),
        ?assertEqual(0, maps:get({dispatch_local, ack_miss}, Stats, 0))
    after
        stop_fake_worker(Fake),
        stop_stack(Stack)
    end.

%% Send-fail branch primitives (Task C): the client's send-fail path
%% is `{sched,2,{release,JobRef}}` + `note_dispatch_local(send_fail)`.
%% The `!`-badarg that triggers it in production cannot be raised on
%% an UNDISTRIBUTED eunit runtime (tuple sends to unregistered names
%% are silently dropped), so the two primitives are driven directly
%% against the live pool with the pick's own reservation.
live_send_fail_primitives_test_() ->
    {timeout, 15, fun live_send_fail_primitives/0}.

live_send_fail_primitives() ->
    Stack = start_stack(),
    try
        %% The pick reserves + tracks exactly as a real dispatch.
        JobRef = crypto:strong_rand_bytes(16),
        {ok, Node} = janus_worker_pool:pick(#{
            provider_id => <<"p1">>, job_ref => JobRef
        }),
        ?assertEqual(node(), Node),
        ?assertEqual([{node(), 1}], lists:sort(ets:tab2list(sched_reserve))),
        %% The client's send-fail hooks: release, then the metric.
        gen_server:cast(janus_worker_pool, {sched, 2, {release, JobRef}}),
        _ = (catch janus_worker_pool:note_dispatch_local(send_fail)),
        ok = wait_until(fun() ->
            lists:sort([C || {_, C} <- ets:tab2list(sched_reserve)]) =:= [0]
        end, 200),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({dispatch_local, send_fail}, Stats, 0)),
        ?assertEqual(0, maps:get({dispatch_local, ack_miss}, Stats, 0))
    after
        stop_stack(Stack)
    end.

%% Ack-miss (worker silent): the master executes locally and the
%% reservation STAYS PENDING (spec Part 0.11) — reserve counter 1.
live_ack_miss_stays_pending_test_() ->
    {timeout, 15, fun live_ack_miss_stays_pending/0}.

live_ack_miss_stays_pending() ->
    Stack = start_stack(),
    Fake = start_fake_worker(silent),
    try
        Result = run_unary(),
        ?assertEqual({local, fell_back}, Result),
        Stats = janus_worker_pool:sched_stats(),
        ?assertEqual(1, maps:get({dispatch_local, ack_miss}, Stats, 0)),
        ?assertEqual(0, maps:get({dispatch_local, send_fail}, Stats, 0)),
        %% PENDING: the worker may still execute (duplicate execution
        %% is inherited v1 behavior) — no release until done/purge.
        ?assertEqual([{node(), 1}], lists:sort(ets:tab2list(sched_reserve))),
        %% The silent fake forwarded the received job — CONSUME it:
        %% eunit runs tests sequentially in one runner process, so a
        %% leftover here would surface in a later module's receive.
        {_JobRef, _Fields} = expect_job()
    after
        stop_fake_worker(Fake),
        stop_stack(Stack)
    end.

%%%===================================================================
%%% Fixture — real pool stack + fake local worker (v2-tests pattern)
%%%===================================================================

%% Runs one unary_post dispatch in the TEST process (the pick/prepare
%% path is in-process). A minimal catalog rides the PRODUCTION
%% persistent_term seam (janus_catalog:get/0 reads PT): empty tabs +
%% one enabled provider row in the LOOKUP shape.
run_unary() ->
    Tabs = janus_catalog:build(#{}),
    Providers = maps:get(providers, Tabs),
    true = ets:insert(
        Providers,
        {<<"p1">>, #{base_url => <<"https://up.example">>, enabled => true}}
    ),
    ok = janus_catalog:publish(1, Tabs),
    try
        {ok, Cipher} = janus_secrets:encrypt(<<"sk-test">>),
        Route = #{provider_id => <<"p1">>, provider_key => #{secret_ref => Cipher}},
        janus_http_worker_client:unary_post(
            Route, <<"/images/generations">>, <<"{\"model\":\"x\"}">>, #{},
            fun() -> {local, fell_back} end
        )
    after
        persistent_term:erase(janus_catalog:pt_key())
    end.

expect_job() ->
    receive
        {fake_job, JobRef, Fields} -> {JobRef, Fields}
    after 5000 ->
        error(no_job)
    end.

%% Fake LOCAL janus_worker_dispatch (name free under eunit — the real
%% one only boots on worker nodes). Modes:
%%  - ack_and_done: reports the job to the test, acks, completes with a
%%    production-shaped done map carrying the additive rtt_ms float
%%    (exactly what a Task-C worker sends).
%%  - silent: receives the job, never acks (ack-miss).
start_fake_worker(Mode) ->
    Parent = self(),
    Pid = spawn(fun() ->
        register(janus_worker_dispatch, self()),
        Parent ! {fake_worker_ready, self()},
        fake_worker_loop(Mode, Parent)
    end),
    receive
        {fake_worker_ready, Pid} -> {ok, Pid}
    after 5000 ->
        error(fake_worker_not_ready)
    end.

fake_worker_loop(Mode, Parent) ->
    receive
        {janus_job, JobRef, MasterSessionPid, Fields} ->
            Parent ! {fake_job, JobRef, Fields},
            case Mode of
                ack_and_done ->
                    MasterSessionPid ! {janus_job_ack, JobRef, self()},
                    MasterSessionPid ! {janus_done, JobRef, #{
                        usage => undefined,
                        status => 200,
                        trailers => #{},
                        body => <<"{\"ok\":true}">>,
                        rtt_ms => 42.5
                    }},
                    fake_worker_loop(Mode, Parent);
                silent ->
                    fake_worker_loop(Mode, Parent)
            end;
        stop ->
            ok
    after 10_000 ->
        ok
    end.

stop_fake_worker({ok, Pid}) ->
    case is_process_alive(Pid) of
        true ->
            Ref = monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', Ref, process, Pid, _} -> ok
            after 1000 ->
                ok
            end;
        false ->
            ok
    end,
    catch unregister(janus_worker_dispatch),
    ok.

%% Real pool stack (janus_worker_pool_v2_tests fixture): heir + sqlite
%% db_conn + pool; the local node hellos as the fake worker node so
%% pick reserves HERE.
start_stack() ->
    {ok, _} = application:ensure_all_started(crypto),
    set_test_secrets_key(),
    process_flag(trap_exit, true),
    {ok, Heir} = janus_ets_heir:start_link(),
    Path =
        "/tmp/janus_client_c_" ++
            integer_to_list(erlang:unique_integer([positive, monotonic])) ++ ".db",
    {ok, Db} = janus_db_conn:start_link(#{backend => sqlite, path => Path}),
    {ok, Pool} = janus_worker_pool:start_link(),
    hello_local(Pool),
    ok = wait_until(fun() ->
        [{candidates, Snap}] = ets:lookup(sched_snapshot, candidates),
        lists:keymember(node(), 1, Snap)
    end, 200),
    {Heir, Db, Pool, Path}.

stop_stack({Heir, Db, Pool, Path}) ->
    os:unsetenv("JANUS_SECRETS_KEY"),
    try
        gen_server:stop(Pool)
    catch
        _:_ -> ok
    end,
    try
        gen_server:stop(Db)
    catch
        _:_ -> ok
    end,
    try
        gen_server:stop(Heir)
    catch
        _:_ -> ok
    end,
    _ = file:delete(Path),
    ok.

hello_local(Pool) ->
    Pool ! {janus_worker_hello, self(), node(), #{role => worker, vsn => 1, region => undefined}},
    receive
        {janus_worker_hello_ack, N, _} when N =:= node() -> ok
    after 5000 ->
        error(hello_no_ack)
    end.

set_test_secrets_key() ->
    os:putenv(
        "JANUS_SECRETS_KEY",
        "k1:" ++ base64:encode_to_string(crypto:strong_rand_bytes(32))
    ).

wait_until(_Fun, 0) ->
    error(wait_timeout);
wait_until(Fun, Tries) when Tries > 0 ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(25),
            wait_until(Fun, Tries - 1)
    end.
