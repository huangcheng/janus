%%%-------------------------------------------------------------------
%%% @doc Master-side remote upstream via worker pool (spec §4–5 / W2.1).
%%%
%%% Seams around `janus_http_proxy:upstream_call/5`: pick a worker, send
%%% `janus_job`, wait ack, credit+relay stream chunks into the existing
%%% Drain fun shape, or fall back to local `call_adapter` on empty pool /
%%% send fail / ack miss. Does not change translate module exports.
%%%
%%% v2.1 Part E — unary worker_lost local fallback (OFF by default,
%%% env `JANUS_SCHED_UNARY_FALLBACK`, boot-time): a NON-STREAM,
%%% CHAT-FAMILY job (openai_chat / openai_responses /
%%% anthropic_messages — image/TTS/ASR/video and the Decisions face
%%% are EXCLUDED: double-billing a generation is a different order of
%%% cost) that fails with the worker session's `{'DOWN'}` (worker_lost
%%% — never a timeout, never send-fail, which already falls back, and
%%% NEVER a `janus_error` completion — the upstream ANSWERED and the
%%% provider-failover layer owns those) may execute the local `LocalFun`
%%% ONCE. "Pre-byte" is ONE predicate: the master session's
%%% `janus_worker_forwarded` pdict flag (set on the first ChunkFun
%%% invoke / client-bound emit; read at fallback time; dies with the
%%% session). D4: a pre-forward worker HTTP error done must NOT set
%%% this flag — remap eligibility tracks real client forwards, not
%%% post-done bookkeeping. Bytes buffered at the WORKER but not yet
%%% forwarded are still pre-byte to the client — that window IS the
%%% documented double-billing risk (F5), the operator's accepted trade.
%%% CAPACITY BYPASS (documented, deliberate): the fallback releases the
%%% reservation FIRST and then runs local WITHOUT re-reserving — mass
%%% worker loss admits unbounded local execution, the knob's
%%% availability-over-discipline trade (local fallback is the terminal
%%% sink anyway). The fallback never re-dispatches to a worker for that
%%% call (LocalFun is terminal).
%%%
%%% v2.2 — the same fallback covers STREAM jobs at the PRE-FLIGHT
%%% stage only (remote_stream's {error, worker_lost} arm): preflight
%%% never forwards a single byte, so a worker death there is
%%% client-side-effect-free and the master re-executes locally — the
%%% 2026-10-27 live case (carrier brownout, two workers nodedowned, an
%%% in-preflight step-5-preview stream died 502 with nothing
%%% delivered). Once a chunk exists the request is DRAIN-phase: loss
%%% there stays abort-by-design (the proxy is already committed to the
%%% 200 stream; LocalFun's result would have nowhere to go). Counter
%%% reason `stream_pre_byte_fallback` beside Part E's
%%% `unary_fallback`.
%%%
%%% Wire compression (spec 2026-10-12-wire-compression F1/F2/D2): the
%%% job-session receive loop is the FIRST master-side {janus_chunk}
%%% matcher — it normalizes both chunk arities (4-tuple => 5-tuple),
%%% inflates `enc => zlib` payloads TAG-DRIVEN (env-independent), and
%%% decodes done bodies. Decode failure takes the F2 ABORT: a distinct
%%% `{wire_enc_inflate_fail, Reason}` error into the same proxy
%%% branches worker_lost rides (byte-identical client bytes), with a
%%% cancel toward the worker, the distinguishing usage outcome, and NO
%%% provider benching (internal hop, not a provider fault).
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
    video_path/1,
    %% v2.1 Part E: unary-fallback knob (boot env -> persistent_term).
    init_knob/0,
    unary_fallback_enabled/0,
    chat_family/1,
    %% v2.1 Part E test seam: the pre-byte flag round-trip.
    forwarded/0,
    mark_forwarded/0,
    %% Wire compression pure seams (spec 2026-10-12-wire-compression
    %% D2/F1/F2 — eunit: first-receive normalization, tag-driven
    %% decode, done-body decode).
    normalize_chunk/1,
    decode_chunk/2,
    decode_done/1
]).

-define(PT_UNARY_FALLBACK, {janus_http_worker_client, unary_fallback}).

%%--------------------------------------------------------------------
%% Public: same result shapes as call_adapter / upstream_call
%%--------------------------------------------------------------------

-spec call(atom(), map(), binary(), map(), term(), fun()) -> term().
call(ProviderProto, Route, _Body, Map, WantStream0, LocalFun) when is_function(LocalFun, 0) ->
    %% Per-DISPATCH reset of the unary-fallback pre-byte flag: the
    %% handler process is reused across keep-alive requests AND
    %% failover retries reuse this same process — a stale `true`
    %% from a prior attempt would silently disable the fallback
    %% forever on this connection (ocr high).
    erase(janus_worker_forwarded),
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
                            %% v2.1 Part E / v2.2: chat-family jobs carry
                            %% the worker_lost fallback path — unary jobs
                            %% at the session DOWN, stream jobs at the
                            %% PRE-FLIGHT result only (preflight never
                            %% forwards; the `janus_worker_forwarded`
                            %% flag enforces zero client bytes either
                            %% way). Modality/Decisions stay excluded.
                            Fallback = chat_family(ProviderProto),
                            dispatch(WorkerNode, JobRef, Fields, WantStream, LocalFun, Fallback)
                    end
            end
    end.

%% Modality image/TTS/ASR unary JSON POST (W2.2). Video paths stay local.
%% v2.1 Part E: modality jobs NEVER take the unary fallback (excluded
%% by spec — image/TTS/ASR/video double-billing).
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
                            dispatch(WorkerNode, JobRef, Fields, false, LocalFun, false)
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
    Pin = maps:get(affinity_node, Prov, undefined),
    #{
        region_tag => normalize_region(maps:get(region_tag, Prov, undefined)),
        affinity_node => parse_affinity_node(Pin),
        %% Declared pin label, RAW (observability only; spec 2026-10-22
        %% §6/D4). parse_affinity_node/1 returns `undefined' for a name
        %% that is not an existing atom, which would alias "no pin" — the
        %% label lets the pick report `affinity_miss' for the §7.6 typo
        %% case instead of silently counting it as unpinned. Never used
        %% for matching (the pin itself still comes from
        %% parse_affinity_node/1; fail-open semantics unchanged).
        affinity_node_raw => affinity_pin_name(Pin)
    }.

%% The provider row's affinity_node as a binary when a pin is DECLARED,
%% else `undefined'. Text column (binary/atom/list ingress); junction
%% safety: the atom branch never leaks a new atom.
-spec affinity_pin_name(term()) -> binary() | undefined.
affinity_pin_name(undefined) -> undefined;
affinity_pin_name(null) -> undefined;
affinity_pin_name(<<>>) -> undefined;
affinity_pin_name("") -> undefined;
affinity_pin_name(Bin) when is_binary(Bin) -> Bin;
affinity_pin_name(A) when is_atom(A) -> atom_to_binary(A, utf8);
affinity_pin_name(List) when is_list(List) ->
    case list_to_binary(List) of
        <<>> -> undefined;
        Bin -> Bin
    end;
affinity_pin_name(_) -> undefined.

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

%% Task 3 wire rule: ONLY the bare 32-hex trace-id crosses the
%% master->worker wire. The prepared headers' traceparent was minted
%% HERE on the master, but the parent-id must be minted on the
%% EXECUTING node (janus_trace module doc) — strip it; the worker
%% session re-mints via from_trace_id + upstream_header. The trace-id
%% itself rides the OPTIONAL additive `trace_id' key (omitted when the
%% caller has no trace context — e.g. pool-issued probes never ride this
%% path; old peers tolerate the key either way, no version bump).
wire_trace(#{headers := Headers} = Fields) ->
    Fields1 = Fields#{headers => lists:keydelete(<<"traceparent">>, 1, Headers)},
    case janus_trace:trace_id(get(janus_trace)) of
        undefined -> Fields1;
        TraceId -> Fields1#{trace_id => TraceId}
    end.

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
    Fields1 = wire_trace(Fields0),
    Fields =
        case ProviderId of
            undefined -> Fields1;
            _ -> Fields1#{provider_id => ProviderId}
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
                                {<<"user-agent">>, janus_providers_http:user_agent()},
                                janus_trace:header()
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
            Fields1 = wire_trace(Fields0),
            Fields =
                case maps:get(provider_id, Route, undefined) of
                    undefined -> Fields1;
                    ProviderId -> Fields1#{provider_id => ProviderId}
                end,
            {ok, Fields}
    end.

%%--------------------------------------------------------------------
%% Send job / ack / relay
%%--------------------------------------------------------------------

%% JobRef is generated BEFORE pick (Task C): the pick opts carry it so
%% pick's DIRECT sched_tracked insert correlates with this dispatch's
%% release/rtt/ttfb casts (spec Part 0.11; v2.1 B.1 — pick inserts the
%% tracked row itself, no {track} cast). Fallback (v2.1 Part E) rides
%% through to remote_unary's worker_lost branch (streams ignore it).
dispatch(WorkerNode, JobRef, Fields, WantStream, LocalFun, Fallback) ->
    case janus_worker_wire:job(JobRef, self(), Fields) of
        {error, _} ->
            %% Never sent: reclaim the reservation (send-fail class).
            ok = sched_release(JobRef),
            LocalFun();
        {ok, JobMsg} ->
            case send_job(WorkerNode, JobMsg) of
                {error, _} ->
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
                            %% Ack-miss: the reservation stays PENDING
                            %% (late, not absent — spec Part 0.11); the
                            %% master executes locally. Purge reclaims.
                            ok = note_dispatch_local(ack_miss),
                            LocalFun();
                        {ok, WorkerSessionPid} ->
                            Mon = monitor(process, WorkerSessionPid),
                            %% TTFB clock starts at ack receipt (spec A.4).
                            TtfbStart = erlang:monotonic_time(millisecond),
                            case WantStream of
                                true ->
                                    %% Drain runs AFTER upstream_call returns —
                                    %% release reservation / demonitor inside Drain.
                                    grant_credit(WorkerSessionPid, JobRef),
                                    remote_stream(
                                        JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart, LocalFun, Fallback
                                    );
                                false ->
                                    try
                                        remote_unary(
                                            JobRef,
                                            WorkerSessionPid,
                                            Mon,
                                            WorkerNode,
                                            Fields,
                                            TtfbStart,
                                            LocalFun,
                                            Fallback
                                        )
                                    after
                                        finish_remote(Mon)
                                    end
                            end
                    end
            end
    end.

finish_remote(Mon) ->
    demonitor(Mon, [flush]),
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
        %% Both chunk arities scrub (D2) — a dead job's 5-tuple chunk
        %% must not linger past the abort; no decode here (nothing to
        %% abort — the job already terminated).
        {janus_chunk, JobRef, _, _} -> flush_job(JobRef);
        {janus_chunk, JobRef, _, _, _} -> flush_job(JobRef);
        {janus_done, JobRef, _} -> flush_job(JobRef);
        {janus_error, JobRef, _} -> flush_job(JobRef)
    after 0 ->
        ok
    end.

%% wait_ack/2 consumes THE ack for this job ref, so any ack still in the
%% mailbox is stale (a duplicate). Scrub it before entering a receive
%% loop: matching it must never re-enter the loop (H1).
flush_acks(JobRef) ->
    receive
        {janus_job_ack, JobRef, _} -> flush_acks(JobRef)
    after 0 ->
        ok
    end.

%% Absolute receive deadline for the stream loops (H1): the `after'
%% budget is computed from a monotonic instant, not restarted by each
%% recv iteration, so no stray message can extend the wait.
stream_deadline() ->
    erlang:monotonic_time(millisecond) + janus_worker_wire:stream_timeout_ms().

deadline_remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

%%--------------------------------------------------------------------
%% Scheduler v2 casts (Task C, spec Part 0.11 / A.3 / A.4) + v2.1 B.1
%% caller-side release
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

%% v2.1 B.1: release is CALLER-SIDE — `ets:take` + conditional pinned
%% decrement inside janus_worker_pool:release/1 (never a gen_server
%% call on the completion path), then the {touched, Node} poke cast
%% (the dirty-flush trigger after caller-side ETS writes).
sched_release(JobRef) ->
    try
        janus_worker_pool:release(JobRef)
    catch
        _:_ -> ok
    end,
    ok.

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

remote_unary(JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart, LocalFun, Fallback) ->
    Timeout = maps:get(timeout_ms, Fields) + janus_worker_wire:ack_deadline_ms(),
    receive
        {janus_done, JobRef, Done} ->
            case is_dead(JobRef) of
                true ->
                    {error, worker_lost};
                false ->
                    case decode_done(Done) of
                        {error, Reason} ->
                            %% Failed done never reads as success (F2):
                            %% same abort contract as a failed chunk.
                            wire_enc_abort(JobRef, undefined, Reason, WorkerSessionPid);
                        {ok, Done1} ->
                            remote_unary_done(
                                JobRef, Done1, TtfbStart
                            )
                    end
            end;
        {janus_error, JobRef, #{code := Code, message := Msg} = ErrMap} ->
            stash_outcome(error),
            ok = maybe_ingest_rtt(JobRef, ErrMap),
            ok = sched_release(JobRef),
            %% Error result emitted — pre-byte ends. NEVER a fallback
            %% trigger: the upstream ANSWERED (janus_error exclusion,
            %% spec Part E) and the provider-failover layer owns these.
            ok = mark_forwarded(),
            map_worker_error(Code, Msg);
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            mark_dead(JobRef),
            %% ORDER (pinned, spec Part E): release the reservation
            %% FIRST, then (maybe) the local execution — LocalFun never
            %% observes a reservation it did not make, and the eunit
            %% asserts the order. NEVER re-dispatched: LocalFun is
            %% terminal for this call.
            ok = sched_release(JobRef),
            case Fallback andalso unary_fallback_enabled() andalso not forwarded() of
                true ->
                    %% Capacity bypass (documented at the module head):
                    %% release-then-local, no re-reserve. Counted under
                    %% dispatch_local{unary_fallback} (a VALUE addition
                    %% to the reason enum — schema stays 1). The error
                    %% outcome is NOT stashed — the local execution
                    %% writes the real outcome (ocr: a recovered 200
                    %% must not record outcome=failed).
                    ok = note_dispatch_local(unary_fallback),
                    LocalFun();
                false ->
                    stash_outcome(error),
                    {error, worker_lost}
            end;
        {janus_chunk, JobRef, _, _} = Msg ->
            unary_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart, LocalFun, Fallback);
        {janus_chunk, JobRef, _, _, _} = Msg ->
            unary_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart, LocalFun, Fallback)
    after Timeout ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
        %% Stream/unary timeout with a live worker session: NO release
        %% (spec Part 0.11 — release on done/error/worker_lost/send-fail
        %% ONLY; the 10-min purge reclaims) and NO fallback (a timeout
        %% is NOT worker_lost — the worker may still deliver).
        {error, {await, timeout}}
    end.

%% Done-leg continuation of remote_unary (kept separate so the decode
%% failure branch above stays the single abort site).
remote_unary_done(JobRef, Done, TtfbStart) ->
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
    %% Unary always returns {ok,Status,H,B} (incl. non-2xx) so Part C
    %% classifies like the local path — no worker_http_status wrapper.
    %% Pre-byte ends HERE for unary-fallback: the result is emitted to
    %% the proxy (the one fallback predicate). Status>=400 still marks
    %% forwarded — failover may retry on a fresh call/6 which clears it.
    ok = mark_forwarded(),
    {ok, Status, done_headers(Done), done_body(Done)}.

%% Non-stream chunk (defensive — the wire contract forbids it): both
%% arities normalize + decode (a corrupt zlib payload aborts even
%% here); a decoding chunk is still NOT forwarded (unchanged v1
%% behavior, still pre-byte to the client). A malformed SHAPE routes
%% to the abort too (ocr review — never a function_clause crash).
unary_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart, LocalFun, Fallback) ->
    case normalize_chunk(Msg) of
        bad_chunk ->
            wire_enc_abort(JobRef, undefined, bad_chunk, WorkerSessionPid);
        {janus_chunk, _Ref, Seq, Wire, Meta} ->
            case decode_chunk(Wire, Meta) of
                {error, Reason} ->
                    wire_enc_abort(JobRef, Seq, Reason, WorkerSessionPid);
                {ok, _Plain} ->
                    remote_unary(
                        JobRef, WorkerSessionPid, Mon, WorkerNode, Fields, TtfbStart, LocalFun, Fallback
                    )
            end
    end.

%%--------------------------------------------------------------------
%% v2.1 Part E — pre-byte predicate + boot knob
%%--------------------------------------------------------------------

%% The master session's ONE pre-byte predicate: set on the first
%% client-bound forward (ChunkFun invoke) or a result that has already
%% been committed toward the client. D4: pre-forward HTTP error dones
%% must leave this unset so Part C can remap. Read at unary-fallback
%% time; dies with the session process (no adopt concern).
mark_forwarded() ->
    put(janus_worker_forwarded, true),
    ok.

forwarded() ->
    case get(janus_worker_forwarded) of
        true -> true;
        _ -> false
    end.

%% @doc Boot-time env read of `JANUS_SCHED_UNARY_FALLBACK` (default 0)
%% into persistent_term — restart to change (the pool knob pattern;
%% called from janus_http_app:start BEFORE any listener).
-spec init_knob() -> ok.
init_knob() ->
    persistent_term:put(?PT_UNARY_FALLBACK, env_truthy(os:getenv("JANUS_SCHED_UNARY_FALLBACK"))),
    ok.

%% @doc The unary worker_lost fallback knob (default OFF). Hot via
%% `{janus, sched_unary_fallback}` PT (written by distribute_settings)
%% with boot-time env PT as fallback.
-spec unary_fallback_enabled() -> boolean().
unary_fallback_enabled() ->
    try
        persistent_term:get({janus, sched_unary_fallback})
    catch
        error:badarg ->
            try
                persistent_term:get(?PT_UNARY_FALLBACK)
            catch
                error:badarg -> false
            end
    end.

%% @doc CHAT-FAMILY upstream protocols eligible for the unary
%% fallback (spec Part E: chat_completions + responses endpoint
%% families — image/TTS/ASR/video and the Decisions native face are
%% excluded).
-spec chat_family(atom()) -> boolean().
chat_family(openai_chat) -> true;
chat_family(openai_responses) -> true;
chat_family(anthropic_messages) -> true;
chat_family(_) -> false.

env_truthy(false) ->
    false;
env_truthy("") ->
    false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) ->
    false.

%%--------------------------------------------------------------------
%% Stream relay — returns {ok, stream, Status, Headers, Drain}
%% or pre-forward {ok, Status, Headers, Body} (D4 Part C remap).
%%--------------------------------------------------------------------

remote_stream(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart, LocalFun, Fallback) ->
    %% Preflight BEFORE returning a stream shape: a done with Status>=400
    %% and zero ChunkFun invokes must surface as {ok,Status,H,B} so
    %% failover_decide runs before cowboy stream_reply (D4 / D5).
    %% Success / mid-stream paths keep provisional 200 (spec §4.2).
    case stream_preflight(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart) of
        {http_error, Status, Headers, Body} ->
            finish_remote(Mon),
            {ok, Status, Headers, Body};
        {error, worker_lost} = Err ->
            finish_remote(Mon),
            %% v2.2 stream pre-byte fallback: preflight NEVER forwards
            %% (zero Cowboy writes, `janus_worker_forwarded` unset), so a
            %% worker death here is client-side-effect-free and the
            %% master may re-execute locally ONCE. Live case 2026-10-27
            %% 18:18: a 2-minute carrier brownout nodedowned two workers
            %% and an in-preflight step-5-preview stream died 502 with
            %% nothing delivered. Preflight has already released the
            %% reservation and marked the job dead (same release-first
            %% order as the unary branch). The buffered-at-worker
            %% double-billing window is the Part E accepted trade.
            case Fallback andalso unary_fallback_enabled() andalso not forwarded() of
                true ->
                    %% Undo the preflight's error-outcome stash: the
                    %% local execution writes the REAL outcome (a
                    %% recovered 200 must not record failed — Part E ocr).
                    erase(janus_usage_outcome),
                    ok = note_dispatch_local(stream_pre_byte_fallback),
                    LocalFun();
                false ->
                    Err
            end;
        {error, _} = Err ->
            finish_remote(Mon),
            Err;
        {stream_ready, Prefetch, ExpectSeq, TtfbSent} ->
            Headers = #{<<"content-type">> => <<"text/event-stream">>},
            Drain = fun(ChunkFun) ->
                try
                    stream_drain_start(
                        JobRef,
                        WorkerSessionPid,
                        Mon,
                        WorkerNode,
                        ChunkFun,
                        Prefetch,
                        ExpectSeq,
                        TtfbStart,
                        TtfbSent
                    )
                after
                    finish_remote(Mon)
                end
            end,
            {ok, stream, 200, Headers, Drain}
    end.

%% Wait for the first chunk or done/error before choosing the result
%% shape. Prefetched plaintext (if any) is replayed into ChunkFun once
%% Drain starts — never Cowboy-forwarded during preflight.
stream_preflight(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart) ->
    ok = flush_acks(JobRef),
    stream_preflight(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart, stream_deadline()).

stream_preflight(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart, Deadline) ->
    receive
        {janus_chunk, JobRef, _, _, _} = Msg ->
            stream_preflight_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart);
        {janus_chunk, JobRef, _, _} = Msg ->
            stream_preflight_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart);
        {janus_done, JobRef, Done} ->
            case is_dead(JobRef) of
                true ->
                    {error, worker_lost};
                false ->
                    case decode_done(Done) of
                        {error, Reason} ->
                            wire_enc_abort(JobRef, undefined, Reason, WorkerSessionPid);
                        {ok, Done1} ->
                            stream_preflight_done(JobRef, Done1, TtfbStart)
                    end
            end;
        {janus_error, JobRef, #{code := Code, message := Msg} = ErrMap} ->
            stash_outcome(error),
            ok = maybe_ingest_rtt(JobRef, ErrMap),
            ok = sched_release(JobRef),
            ok = mark_forwarded(),
            map_worker_error(Code, Msg);
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            stash_outcome(error),
            mark_dead(JobRef),
            ok = sched_release(JobRef),
            {error, worker_lost};
        {janus_job_ack, JobRef, _} ->
            %% Carries the ORIGINAL deadline — a stale ack cannot restart
            %% the timeout window (H1).
            stream_preflight(JobRef, WorkerSessionPid, Mon, WorkerNode, TtfbStart, Deadline)
    after deadline_remaining(Deadline) ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
        {error, {await, timeout}}
    end.

stream_preflight_chunk(Msg, JobRef, WorkerSessionPid, _Mon, _WorkerNode, _TtfbStart) ->
    case is_dead(JobRef) of
        true ->
            {error, worker_lost};
        false ->
            case normalize_chunk(Msg) of
                bad_chunk ->
                    wire_enc_abort(JobRef, undefined, bad_chunk, WorkerSessionPid);
                {janus_chunk, _Ref, Seq, Wire, Meta} ->
                    case decode_chunk(Wire, Meta) of
                        {error, Reason} ->
                            wire_enc_abort(JobRef, Seq, Reason, WorkerSessionPid);
                        {ok, Plain} ->
                            %% First chunk — commit to stream shape; replay
                            %% Plain on Drain start (still zero Cowboy writes).
                            {stream_ready, {chunk, Seq, Plain}, Seq + 1, not_sent}
                    end
            end
    end.

stream_preflight_done(JobRef, Done, TtfbStart) ->
    Status = maps:get(status, Done, 200),
    case Status >= 400 of
        true ->
            %% Zero client forwards: release + return local-shaped error
            %% for failover_decide (do NOT mark_forwarded — D4).
            stash_done(Done, error),
            ok = maybe_ingest_rtt(JobRef, Done),
            ok = sched_release(JobRef),
            {http_error, Status, done_headers(Done), done_body(Done)};
        false ->
            %% Empty success stream (done before any chunk).
            {stream_ready, {done, Done, TtfbStart}, 0, not_sent}
    end.

stream_drain_start(
    JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, Prefetch, ExpectSeq, TtfbStart, TtfbSent
) ->
    ok = flush_acks(JobRef),
    case Prefetch of
        {chunk, Seq, Plain} ->
            stream_forward_plain(
                JobRef, Seq, Plain, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent
            );
        {done, Done, TtfbStart1} ->
            stream_done(JobRef, Done, TtfbStart1, TtfbSent)
    end.

stream_drain(
    JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent, Deadline
) ->
    receive
        {janus_chunk, JobRef, _, _, _} = Msg ->
            stream_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent);
        {janus_chunk, JobRef, _, _} = Msg ->
            stream_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent);
        {janus_done, JobRef, Done} ->
            case is_dead(JobRef) of
                true ->
                    ok;
                false ->
                    case decode_done(Done) of
                        {error, Reason} ->
                            wire_enc_abort(JobRef, ExpectSeq, Reason, WorkerSessionPid);
                        {ok, Done1} ->
                            stream_done(JobRef, Done1, TtfbStart, TtfbSent)
                    end
            end;
        {janus_error, JobRef, #{code := Code, message := Msg} = ErrMap} ->
            stash_outcome(error),
            ok = maybe_ingest_rtt(JobRef, ErrMap),
            ok = sched_release(JobRef),
            ok = mark_forwarded(),
            case map_worker_error(Code, Msg) of
                {error, Reason} -> {error, Reason}
            end;
        {'DOWN', Mon, process, WorkerSessionPid, _Reason} ->
            stash_outcome(error),
            mark_dead(JobRef),
            ok = sched_release(JobRef),
            {error, worker_lost};
        {janus_job_ack, JobRef, _} ->
            %% Carries the ORIGINAL deadline — a stale ack cannot restart
            %% the timeout window (H1).
            stream_drain(
                JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent, Deadline
            )
    after deadline_remaining(Deadline) ->
        stash_outcome(error),
        cancel_session(WorkerSessionPid, JobRef),
        mark_dead(JobRef),
        flush_job(JobRef),
        %% No release on timeout (spec Part 0.11 — see remote_unary).
        {error, {await, timeout}}
    end.

%% Chunk-leg continuation of stream_drain: normalization happens HERE,
%% at the FIRST master-side receive, BEFORE any seq/credit/log
%% handling (D2); decode is TAG-DRIVEN (F1) — it never consults this
%% node's env/capability state. A malformed shape routes to the abort
%% (ocr review: the receive loop never crashes on shape — that would
%% skip cancel/release/flush), and only for a LIVE job (a dead job's
%% stragglers keep the drop-only behavior).
stream_chunk(Msg, JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent) ->
    case is_dead(JobRef) of
        true ->
            ok;
        false ->
            case normalize_chunk(Msg) of
                bad_chunk ->
                    wire_enc_abort(JobRef, undefined, bad_chunk, WorkerSessionPid);
                {janus_chunk, _Ref, Seq, Wire, Meta} ->
                    stream_chunk_decoded(
                        JobRef, Seq, Wire, Meta, WorkerSessionPid, Mon, WorkerNode, ChunkFun,
                        ExpectSeq, TtfbStart, TtfbSent
                    )
            end
    end.

stream_chunk_decoded(JobRef, Seq, Wire, Meta, WorkerSessionPid, Mon, WorkerNode, ChunkFun, ExpectSeq, TtfbStart, TtfbSent) ->
    case decode_chunk(Wire, Meta) of
        {error, Reason} ->
            wire_enc_abort(JobRef, Seq, Reason, WorkerSessionPid);
        {ok, Plain} ->
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
            stream_forward_plain(
                JobRef, Seq, Plain, WorkerSessionPid, Mon, WorkerNode, ChunkFun, Seq + 1, TtfbStart, TtfbSent
            )
    end.

%% Client-bound chunk write (ChunkFun). Sets the pre-byte flag ONLY here
%% — D4 zero-forward detection must not trust post-done mark_forwarded.
stream_forward_plain(
    JobRef, _Seq, Plain, WorkerSessionPid, Mon, WorkerNode, ChunkFun, NextSeq, TtfbStart, TtfbSent
) ->
    try
        ChunkFun(Plain)
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
    %% First forwarded byte — the pre-byte predicate ends
    %% (v2.1 Part E; streams never fall back, the flag is
    %% the ONE shared predicate).
    ok = mark_forwarded(),
    %% Top up one credit after client write flushed.
    try
        WorkerSessionPid ! janus_worker_wire:credit(JobRef, 1)
    catch
        _:_ ->
            ok
    end,
    %% A forwarded chunk is progress: the inactivity window restarts from
    %% an absolute instant (never from a stray message — H1).
    stream_drain(
        JobRef, WorkerSessionPid, Mon, WorkerNode, ChunkFun, NextSeq, TtfbStart, TtfbSent1, stream_deadline()
    ).

%% Done-leg continuation of stream_drain (decode already done).
%% Pre-forward HTTP errors are consumed in stream_preflight (never
%% reach a Drain). This path is only after stream_forward_plain
%% (ChunkFun + mark_forwarded) or an empty success done — so Status>=400
%% here is always post-forward N9 (2-tuple). The 4-tuple remap shape is
%% produced only by preflight → {ok,Status,H,B} / proxy remap.
stream_done(JobRef, Done, TtfbStart, TtfbSent) ->
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
    ok = mark_forwarded(),
    case Status >= 400 of
        true ->
            {error, {worker_http_status, Status}};
        false ->
            ok
    end.

done_headers(Done) when is_map(Done) ->
    case maps:get(trailers, Done, #{}) of
        H when is_map(H) -> H;
        _ -> #{}
    end.

done_body(Done) when is_map(Done) ->
    case maps:get(body, Done, undefined) of
        undefined -> <<>>;
        B when is_binary(B) -> B;
        _ -> <<>>
    end.

%%--------------------------------------------------------------------
%% Wire compression (spec 2026-10-12-wire-compression F1/F2/D2):
%% first-receive normalization, tag-driven decode, F2 abort
%%--------------------------------------------------------------------

%% D2: the FIRST master-side clause matching {janus_chunk,...} (the
%% job-session receive loop — this module) normalizes 4-tuple =>
%% 5-tuple (Meta #{}) BEFORE any seq/credit/log handling. TOTAL (ocr
%% review): a malformed chunk (non-binary payload / non-map Meta —
%% unreachable from a validated sender, i.e. corrupt wire) yields
%% `bad_chunk` and the CALLER routes it to the F2 abort — the receive
%% loop must never crash on shape (that would skip cancel/release/
%% flush). Pure.
-spec normalize_chunk(term()) ->
    {janus_chunk, binary(), non_neg_integer(), binary(), map()} | bad_chunk.
normalize_chunk({janus_chunk, JobRef, Seq, Bin}) when
    is_binary(JobRef), is_integer(Seq), Seq >= 0, is_binary(Bin)
->
    {janus_chunk, JobRef, Seq, Bin, #{}};
normalize_chunk({janus_chunk, JobRef, Seq, Bin, Meta}) when
    is_binary(JobRef), is_integer(Seq), Seq >= 0, is_binary(Bin), is_map(Meta)
->
    {janus_chunk, JobRef, Seq, Bin, Meta};
normalize_chunk(_BadShape) ->
    bad_chunk.

%% F1: decode is TAG-DRIVEN — `enc => zlib` inflates regardless of
%% this node's env/capability state (an ack-timing race, a dispatch
%% restart, or a master-instance swap mid-stream still decodes); the
%% codec owns the dir=in zlib counters, the inflate-time counter and
%% `wire_enc_inflate_fail_total` (failure path included — the D9
%% partition). A non-zlib tag value (future/corrupt) is the F2 abort
%% — never passed to parsers. Identity intake bumps the in-identity
%% buckets here (the identity leg never enters the codec).
-spec decode_chunk(binary(), map()) -> {ok, binary()} | {error, term()}.
decode_chunk(Wire, #{enc := zlib}) when is_binary(Wire) ->
    janus_wire_enc:inflate_chunk(Wire);
decode_chunk(_Wire, #{enc := zlib}) ->
    {error, bad_chunk_body};
decode_chunk(_Wire, #{enc := BadTag}) ->
    {error, {bad_enc, BadTag}};
decode_chunk(Bin, _NoEncMeta) when is_binary(Bin) ->
    janus_wire_enc:bump({wire_enc_chunks_total, {in, identity}}, 1),
    janus_wire_enc:bump({wire_enc_bytes_total, {in, identity}}, byte_size(Bin)),
    {ok, Bin}.

%% D2 done decode: `enc => zlib` inflates ONLY the body value; usage/
%% status/trailers (and the additive rtt_ms) stay plaintext on the
%% wire and pass through untouched. The consumed enc key is dropped
%% from the decoded map. Failures (and bad tags) take the same abort
%% contract as chunks (F2 — a failed done never reads as success).
%% The tag and the BODY SHAPE fail separately (ocr review): a valid
%% `zlib` tag with a missing/non-binary body is `bad_done_body` (the
%% sender's validator rejects it — a decode-side fail-safe), never
%% mislabeled `bad_enc`.
-spec decode_done(map()) -> {ok, map()} | {error, term()}.
decode_done(#{enc := zlib, body := Body} = Done) when is_binary(Body) ->
    case janus_wire_enc:inflate_chunk(Body) of
        {ok, Plain} ->
            {ok, maps:remove(enc, Done#{body => Plain})};
        {error, Reason} ->
            {error, Reason}
    end;
decode_done(#{enc := zlib}) ->
    {error, bad_done_body};
decode_done(#{enc := BadTag}) ->
    {error, {bad_enc, BadTag}};
decode_done(#{body := Body} = Done) when is_binary(Body), Body =/= <<>> ->
    %% D9 partition symmetry (ocr review): an identity unary done body
    %% lands in the in-identity buckets like every plain chunk does.
    %% EMPTY bodies are skipped on BOTH sides (the worker guard
    %% skips them too) — in/out stay symmetric (ocr review).
    janus_wire_enc:bump({wire_enc_chunks_total, {in, identity}}, 1),
    janus_wire_enc:bump({wire_enc_bytes_total, {in, identity}}, byte_size(Body)),
    {ok, Done};
decode_done(Done) when is_map(Done) ->
    {ok, Done}.

%% F2 abort (internal-hop inflate failure / enc-tag violation): log
%% (job_ref + seq), cancel the worker session (stop wasted
%% compression), kill stragglers, and return a distinct reason into
%% the SAME proxy branches {error, worker_lost} rides — client bytes
%% stay identical (the proxy branch replies the static worker_lost
%% 502 uncommitted / native_stream_fail verbatim committed). The
%% reservation is released (the job is terminal — the worker_lost
%% class, NOT the no-release timeout class). The usage outcome stash
%% is the spec's distinguishing `wire_enc_inflate_fail` string: the
%% proxy's note_usage_outcome(error) is FIRST-WRITE-WINS and stays
%% inert once the binary is present.
wire_enc_abort(JobRef, Seq, Reason, WorkerSessionPid) ->
    logger:error(#{
        what => janus_wire_enc_inflate_fail,
        job_ref => binary:encode_hex(JobRef),
        seq => Seq,
        reason => Reason
    }),
    ok = cancel_session(WorkerSessionPid, JobRef),
    ok = mark_dead(JobRef),
    ok = flush_job(JobRef),
    %% First-write-wins, mirroring janus_http_proxy:note_usage_outcome/1
    %% (private): an already-final outcome for this request is never
    %% overwritten by the wire-encoding label (M2).
    ok = stash_usage_outcome(<<"wire_enc_inflate_fail">>),
    ok = sched_release(JobRef),
    {error, {wire_enc_inflate_fail, Reason}}.

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

%% First-write-wins variant of the outcome stash, mirroring the proxy's
%% private note_usage_outcome/1: once a final outcome is recorded for
%% this request, a later label must not overwrite it (M2).
stash_usage_outcome(Bin) when is_binary(Bin) ->
    case get(janus_usage_outcome) of
        B when is_binary(B) ->
            ok;
        _ ->
            put(janus_usage_outcome, Bin),
            ok
    end.
