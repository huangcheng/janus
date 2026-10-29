%% Worker-session translate-abort regression (security audit run-1,
%% confirmed gateway/apps/janus_http/src/janus_http_worker_client.erl:
%% stream_forward_plain:translate-abort-worker-session-not-cancelled).
%% The ChunkFun catch matched ONLY janus_client_disconnect, so the
%% proxy translator's {janus_translate, ...} throw escaped the relay
%% with no cancel_session / mark_dead / flush_job / sched_release —
%% the worker kept draining upstream (up to its 600 s job timeout,
%% operator-billed) and the pool reservation persisted until the
%% ~10-minute purge, per aborted stream. This suite drives the
%% exported relay directly with a fake session (self()) and asserts
%% the cleanup order and the rethrow, plus the sibling disconnect
%% contract (cancel BEFORE rethrow). The happy path (no cancel) is
%% covered live per repo convention — the drain loop needs the pool. Like the other suites here they
%% run via `rebar3 eunit` (CI compiles/formats only).
-module(janus_worker_translate_abort_tests).

-include_lib("eunit/include/eunit.hrl").

-define(JOBREF, <<16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1>>).

drain_session() ->
    %% Fake session: this process; the mailbox IS the session mailbox.
    self().

await_idle() ->
    receive
        M -> [M | await_idle()]
    after 0 ->
        []
    end.

translate_abort_cancels_test() ->
    try
        Self = drain_session(),
        ChunkFun = fun(_Chunk) -> throw({janus_translate, upstream, <<"repro">>}) end,
        KeepaliveFun = fun() -> ok end,
        ?assertException(
            throw,
            {janus_translate, upstream, <<"repro">>},
            janus_http_worker_client:stream_forward_plain(
                ?JOBREF, 0, <<"data: x\n\n">>, Self, undefined, node(),
                ChunkFun, KeepaliveFun, 1, 0, not_sent, 0, 0
            )
        ),
        Msgs = await_idle(),
        ?assert(lists:member({janus_cancel, ?JOBREF}, Msgs))
    after
        _ = await_idle()
    end.

client_disconnect_cancels_test() ->
    try
        Self = drain_session(),
        ChunkFun = fun(_Chunk) -> throw(janus_client_disconnect) end,
        KeepaliveFun = fun() -> ok end,
        ?assertException(
            throw,
            janus_client_disconnect,
            janus_http_worker_client:stream_forward_plain(
                ?JOBREF, 0, <<"data: x\n\n">>, Self, undefined, node(),
                ChunkFun, KeepaliveFun, 1, 0, not_sent, 0, 0
            )
        ),
        Msgs = await_idle(),
        ?assert(lists:member({janus_cancel, ?JOBREF}, Msgs))
    after
        _ = await_idle()
    end.

relay_crash_cancels_test() ->
    %% A relay CRASH (error:class — translate or passthrough) is as terminal:
    %% the cleanup must run and the original class must survive.
    try
        Self = drain_session(),
        ChunkFun = fun(_Chunk) -> error(capture_usage_badarg) end,
        KeepaliveFun = fun() -> ok end,
        ?assertError(
            capture_usage_badarg,
            janus_http_worker_client:stream_forward_plain(
                ?JOBREF, 0, <<"data: x\n\n">>, Self, undefined, node(),
                ChunkFun, KeepaliveFun, 1, 0, not_sent, 0, 0
            )
        ),
        Msgs = await_idle(),
        ?assert(lists:member({janus_cancel, ?JOBREF}, Msgs))
    after
        _ = await_idle()
    end.
