%%%-------------------------------------------------------------------
%%% @doc Periodic provider model-list synchronization.
%%%
%%% Providers (DashScope, Ark, StepFun, ...) refresh their model
%%% catalogs continuously; Janus's public `models` table does not follow.
%%% This worker polls each enabled provider's OpenAI-compatible
%%% `GET /v1/models` and upserts names into `provider_models` (inventory
%%% under that vendor). Agent-facing names are created only when bound
%%% on the Router page.
%%%
%%% Config (`janus` app env / os env):
%%%   - JANUS_MODEL_SYNC_INTERVAL_SEC — poll period, default 21600 (6h);
%%%     0 disables the timer (manual-only sync)
%%%   - JANUS_MODEL_SYNC_ON_START    — "1"/"true" to sync once at boot
%%%
%%% A restart no longer leaves the task dormant: at boot the worker also
%%% runs once when the last successful run (and the last attempt) is
%%% older than the interval. Per-provider failures are classed
%%% (transport / truncated / timeout / http_status / bad_json), retried
%%% once when transient, and named in `task_runs.error`; disabled or
%%% deleted providers are skipped instead of failing the whole pass.
%%%
%%% API:
%%%   - `sync_now/0` — one manual pass (dashboard button), also
%%%     `gen_server:call` so the UI can await the result
%%%   - `status/0` — {LastRun, Added, Errors} for the UI
%%% @end
%%%-------------------------------------------------------------------
-module(janus_model_sync).

-behaviour(gen_server).

-export([start_link/0]).
-export([sync_now/0, status/0, set_interval/1, interval/0, unique_violation/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_INTERVAL, 21600).
%% One retry per provider for a transient `/models` failure (a body cut
%% mid-flight, a dropped connection, a read timeout, a 5xx). 500 ms is
%% enough for a server that closed the body early to serve the next
%% request, and short enough that a pass cannot stall on it.
-define(RETRY_BACKOFF_MS, 500).
%% Retries are only started while the pass is younger than this: an
%% unhealthy endpoint fails fast, so the bound keeps the retry from
%% doubling the worst case of an already-slow pass (review risk note).
-define(RETRY_WINDOW_MS, 60_000).
%% One re-check when init/1 finds the catalog snapshot still cold
%% (janus_config publishes right after this child starts).
-define(CATCHUP_RECHECK_MS, 5_000).
%% DashScope native ``/api/v1/models`` pagination (control-plane catalog).
-define(DASHSCOPE_PAGE_SIZE, 100).
-define(DASHSCOPE_MAX_PAGES, 50).

-record(state, {
    timer_ref :: reference() | undefined,
    last_run :: map() | undefined
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Manual trigger; returns the per-provider result summary synchronously
%% (bounded by the HTTP budget of the providers module).
-spec sync_now() -> {ok, map()}.
sync_now() ->
    gen_server:call(?SERVER, sync_now, 120_000).

-spec status() -> map().
status() ->
    try
        gen_server:call(?SERVER, status)
    catch
        exit:{noproc, _} -> #{enabled => false}
    end.

%% Runtime interval change (seconds); 0 = manual-only. The os env value
%% remains the boot default — the dashboard override persists in app env
%% so it survives a worker restart but not a node restart (env wins).
-spec set_interval(non_neg_integer()) -> {ok, non_neg_integer()}.
set_interval(Secs) when is_integer(Secs), Secs >= 0 ->
    ok = application:set_env(janus, model_sync_interval_sec, Secs),
    gen_server:call(?SERVER, reschedule),
    {ok, Secs}.

-spec interval() -> non_neg_integer().
interval() ->
    case interval_sec() of
        N when is_integer(N), N >= 0 -> N;
        _ -> 0
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    State0 = #state{},
    State = maybe_start_timer(State0),
    maybe_boot_sync(),
    {ok, State}.

handle_call(sync_now, _From, State) ->
    case run_sync(true) of
        {ok, R} when is_map(R) ->
            {reply, {ok, R}, State#state{last_run = R}};
        {'EXIT', Reason} ->
            ErrMap = #{error => Reason},
            {reply, {ok, ErrMap}, State#state{last_run = ErrMap}};
        Other ->
            ErrMap = #{error => Other},
            {reply, {ok, ErrMap}, State#state{last_run = ErrMap}}
    end;
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(reschedule, _From, State) ->
    {reply, ok, maybe_start_timer(State)};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sync_tick, State) ->
    _ = spawn(fun() -> _ = run_sync(false) end),
    {noreply, maybe_start_timer(State#state{timer_ref = undefined})};
handle_info(sync_catchup_recheck, State) ->
    %% Bounded second look when init/1 raced the catalog publish.
    case catch_up_due() of
        {true, Why} -> start_sync(Why);
        {false, _Why} -> ok
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer_ref = Ref}) ->
    _ = cancel_timer(Ref),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%% Sync pass
%%%===================================================================

%% One sync pass under the failure-observability task runner
%% (spec §4.3, priority-1 task). MUST-COMPLETE: a pass is a sequence of
%% inventory inserts per provider; killing it on a wall overrun would
%% leave a provider half-synced, so an overrun only emits a one-shot
%% `timeout` task_run event and the pass runs to completion (the HTTP
%% budget per provider is bounded at 15s). `OnDemand` = the dashboard
%% button (sync_now): adds the on-demand grace to the deadline.
%%
%% Returns what `catch do_sync()` used to: `{ok, Summary}`, or
%% `{'EXIT', Reason}` when the pass crashed. A pass whose providers
%% reported errors is an `error` task outcome even though the summary
%% still returns `{ok, _}` to the caller.
run_sync(OnDemand) ->
    Meta = #{
        must_complete => true,
        on_demand => OnDemand,
        classify => fun classify_sync/1
    },
    case janus_task_run:with(model_sync, Meta, fun do_sync/0) of
        {done, Result} -> Result;
        {crash, Reason} -> {'EXIT', Reason};
        timeout -> {error, task_timeout}
    end.

%% `errors > 0` => error outcome classed by the first provider failure
%% (providers sorted by name for a stable representative); DB outage
%% from do_sync/0 is `{error, {db, _}}` so it cannot masquerade as ok.
%% Since 2026-10-23 every failure is a classed map carrying the provider
%% id/name and host, so `task_runs.error` names what to fix (prod rows
%% used to read `unclassified` / `{sync_errors,2,11,unexpected_end_of_input}`).
classify_sync({error, {db, Reason}}) ->
    {error, <<"unclassified">>, {db, Reason}};
classify_sync({ok, #{errors := N, providers := Providers}}) when is_integer(N), N > 0 ->
    Failures = [
        F
     || {_Name, #{error := F}} <- lists:keysort(1, maps:to_list(Providers)),
        F =/= undefined
    ],
    First = hd(Failures ++ [#{class => <<"unclassified">>}]),
    Class = maps:get(class, First, <<"unclassified">>),
    {error, Class, {sync_errors, N, maps:size(Providers), Failures}};
classify_sync(_Other) ->
    ok.

do_sync() ->
    Started = erlang:system_time(millisecond),
    case janus_db_conn:query(<<"SELECT id, name FROM providers WHERE enabled = 1">>) of
        {error, Reason} ->
            logger:warning(#{what => janus_model_sync_db_error, reason => Reason}),
            {error, {db, Reason}};
        {ok, Providers} ->
            do_sync_providers(Started, Providers)
    end.

do_sync_providers(Started, Providers) ->
    %% Transient-failure retries stay inside the early part of the pass.
    RetryUntil = Started + ?RETRY_WINDOW_MS,
    PerProvider =
        lists:foldl(
            fun({Id, Name}, Acc) ->
                [{Name, sync_provider(Id, Name, RetryUntil)} | Acc]
            end,
            [],
            Providers
        ),
    Result = #{
        ran_at => unicode:characters_to_binary(
            calendar:system_time_to_rfc3339(Started, [{unit, millisecond}, {offset, "Z"}])
        ),
        elapsed_ms => erlang:system_time(millisecond) - Started,
        providers => maps:from_list(PerProvider)
    },
    {Total, Seen, Errs, Skipped} = lists:foldl(
        fun({_N, P}, {T, Se, Er, Sk}) ->
            {
                T + maps:get(added, P, 0),
                Se + maps:get(seen, P, 0),
                case maps:get(error, P, undefined) of
                    undefined -> Er;
                    _ -> Er + 1
                end,
                case maps:get(skipped, P, undefined) of
                    undefined -> Sk;
                    _ -> Sk + 1
                end
            }
        end,
        {0, 0, 0, 0},
        PerProvider
    ),
    logger:info(#{
        what => janus_model_sync_done,
        providers => length(Providers),
        models_added => Total,
        models_seen => Seen,
        providers_skipped => Skipped,
        errors => Errs
    }),
    {ok, Result#{
        models_added => Total,
        models_seen => Seen,
        providers_skipped => Skipped,
        errors => Errs
    }}.

%% Fetches GET {base}/models for one provider and upserts unseen names.
%% A provider that is disabled or absent from the config snapshot is a
%% SKIP, not a failure: a name that can never succeed must not keep the
%% whole task red forever.
sync_provider(ProviderId, Name, RetryUntil) ->
    case fetch_provider_models(ProviderId, Name, RetryUntil) of
        {ok, Ctx, Names} when is_list(Names) ->
            {Added, UpsertErrs} = lists:foldl(
                fun(N, {A, E}) ->
                    case upsert_listing(ProviderId, N) of
                        created -> {A + 1, E};
                        exists -> {A, E};
                        {error, _} -> {A, E + 1}
                    end
                end,
                {0, 0},
                Names
            ),
            Err =
                case UpsertErrs of
                    0 -> undefined;
                    N -> provider_failure(Ctx, {upsert_failed, N})
                end,
            #{added => Added, seen => length(Names), error => Err};
        {skip, Why, _Ctx} ->
            logger:info(#{
                what => janus_model_sync_provider_skipped,
                provider_id => ProviderId,
                provider => Name,
                reason => Why
            }),
            #{added => 0, seen => 0, error => undefined, skipped => Why};
        {error, Failure} ->
            logger:warning(#{
                what => janus_model_sync_provider_failed,
                provider_id => maps:get(provider_id, Failure),
                provider => maps:get(provider, Failure),
                host => maps:get(host, Failure),
                class => maps:get(class, Failure),
                reason => maps:get(detail, Failure)
            }),
            #{added => 0, seen => 0, error => Failure}
    end.

fetch_provider_models(ProviderId, Name, RetryUntil) ->
    try
        case janus_catalog:lookup_provider(ProviderId) of
            {ok, #{base_url := Base0, enabled := true}} ->
                Ctx = #{provider => Name, provider_id => ProviderId, host => Base0},
                case
                    [K || K <- janus_catalog:provider_keys(ProviderId), maps:get(enabled, K, true)]
                of
                    [#{secret_ref := Ref} | _] ->
                        {ok, Token} = janus_secrets:decrypt(
                            case Ref of
                                {_, Cipher} -> Cipher;
                                C -> C
                            end
                        ),
                        Base = binary_to_list(Base0),
                        case fetch_model_names(Base, Token, RetryUntil) of
                            {ok, Models} -> {ok, Ctx, Models};
                            {error, Detail} -> {error, provider_failure(Ctx, Detail)}
                        end;
                    [] ->
                        %% Enabled but no usable key: a config problem, so a
                        %% failure — classed and named all the same.
                        {error, provider_failure(Ctx, no_keys)}
                end;
            {ok, #{enabled := false}} ->
                {skip, disabled, #{provider => Name, provider_id => ProviderId}};
            error ->
                %% Gone from the config snapshot while the row was still
                %% enabled in `providers` (config lag / deleted provider):
                %% it can never succeed, so it is skipped, not failed.
                {skip, not_found, #{provider => Name, provider_id => ProviderId}}
        end
    catch
        Class:Reason:Stack ->
            logger:warning(#{
                what => janus_model_sync_fetch_crash,
                provider_id => ProviderId,
                class => Class,
                reason => Reason,
                stack_top => hd(Stack)
            }),
            {error,
                provider_failure(
                    #{provider => Name, provider_id => ProviderId, host => undefined},
                    {fetch_crashed, Reason}
                )}
    end.

%% One provider failure, as carried in the run summary, in the log line
%% and (rendered) in `task_runs.error`: the class is what the operator
%% triages on, provider id/name/host say which endpoint to fix.
provider_failure(Ctx, Detail) ->
    #{
        class => failure_class(Detail),
        provider => maps:get(provider, Ctx, undefined),
        provider_id => maps:get(provider_id, Ctx, undefined),
        host => maps:get(host, Ctx, undefined),
        detail => Detail
    }.

%% Stable classes. HTTP statuses keep janus_cool_view's existing mapping
%% (429 -> rate, 5xx -> upstream_5xx, ...) so alerts are unaffected; the
%% classes this module adds: a `/models` body cut mid-flight
%% (`unexpected_end_of_input`, prod voyah) is `truncated`, other
%% socket-level failures are `transport`, an undecodable/unusable body is
%% `bad_json`.
failure_class({http_status, Code}) -> janus_cool_view:reason_class({http, Code});
failure_class({truncated, _}) -> <<"truncated">>;
failure_class({transport, _}) -> <<"transport">>;
failure_class({timeout, _}) -> <<"transport">>;
failure_class({bad_json, _}) -> <<"bad_json">>;
failure_class({upsert_failed, _}) -> <<"db">>;
failure_class({fetch_crashed, _}) -> <<"fetch_crashed">>;
failure_class(no_keys) -> <<"no_keys">>;
failure_class(Other) -> janus_cool_view:reason_class(Other).

%% Transient: the connection dropped / truncated mid-body, a read
%% timeout, or a 5xx. A 4xx or an undecodable body is the provider's
%% answer and is not retried.
retryable({truncated, _}) -> true;
retryable({transport, _}) -> true;
retryable({timeout, _}) -> true;
retryable({http_status, Code}) when is_integer(Code), Code >= 500 -> true;
retryable(_) -> false.

%% Classified `/models` fetch: at most one retry, and only for transient
%% failures inside the pass's retry window.
http_get_json(Url, Token, RetryUntil) ->
    case http_get_models(Url, Token) of
        {error, Detail} = Err ->
            Retry =
                retryable(Detail) andalso erlang:system_time(millisecond) < RetryUntil,
            case Retry of
                true ->
                    logger:info(#{
                        what => janus_model_sync_retry,
                        class => failure_class(Detail),
                        host => host_of(Url),
                        reason => detail_of(Detail)
                    }),
                    timer:sleep(?RETRY_BACKOFF_MS),
                    http_get_models(Url, Token);
                false ->
                    Err
            end;
        Ok ->
            Ok
    end.

%% Prefer DashScope's native paginated catalog when the provider base is a
%% Bailian / Model Studio host: the OpenAI-compatible ``/models`` list is a
%% lagging subset (qwen4-max was callable + listed natively while absent from
%% compatible-mode /models). Non-DashScope providers keep the OpenAI path.
fetch_model_names(Base, Token, RetryUntil) ->
    OpenAIUrl = lists:flatten(rtrim(Base, $/) ++ "/models"),
    case is_dashscope_base(Base) of
        true ->
            case http_get_json_dashscope_native(Base, Token, RetryUntil) of
                {ok, Names} when Names =/= [] ->
                    {ok, Names};
                {ok, []} ->
                    logger:warning(#{
                        what => janus_model_sync_dashscope_native_empty,
                        host => host_of(OpenAIUrl)
                    }),
                    http_get_json(OpenAIUrl, Token, RetryUntil);
                {error, NativeDetail} ->
                    logger:warning(#{
                        what => janus_model_sync_dashscope_native_failed,
                        host => host_of(OpenAIUrl),
                        reason => NativeDetail
                    }),
                    http_get_json(OpenAIUrl, Token, RetryUntil)
            end;
        false ->
            http_get_json(OpenAIUrl, Token, RetryUntil)
    end.

is_dashscope_base(Base) when is_list(Base) ->
    case uri_string:parse(Base) of
        #{host := Host} ->
            is_dashscope_host(string:lowercase(uri_host_list(Host)));
        _ ->
            false
    end;
is_dashscope_base(_) ->
    false.

uri_host_list(Host) when is_list(Host) -> Host;
uri_host_list(Host) when is_binary(Host) -> binary_to_list(Host).

is_dashscope_host(Host) ->
    lists:suffix(".maas.aliyuncs.com", Host) orelse Host =:= "maas.aliyuncs.com" orelse
        (string:find(Host, "dashscope") =/= nomatch andalso
            lists:suffix(".aliyuncs.com", Host)).

dashscope_native_url(Base) ->
    case uri_string:parse(Base) of
        #{scheme := Scheme, host := Host} = Uri ->
            SchemeL = uri_scheme_list(Scheme),
            HostL = uri_host_list(Host),
            PortSuffix =
                case maps:get(port, Uri, undefined) of
                    undefined -> "";
                    443 when SchemeL =:= "https" -> "";
                    80 when SchemeL =:= "http" -> "";
                    P when is_integer(P), P > 0 -> ":" ++ integer_to_list(P);
                    _ -> ""
                end,
            SchemeL ++ "://" ++ HostL ++ PortSuffix ++ "/api/v1/models";
        _ ->
            undefined
    end.

uri_scheme_list(https) -> "https";
uri_scheme_list(http) -> "http";
uri_scheme_list(S) when is_atom(S) -> atom_to_list(S);
uri_scheme_list(S) when is_list(S) -> S;
uri_scheme_list(S) when is_binary(S) -> binary_to_list(S).

http_get_json_dashscope_native(Base, Token, RetryUntil) ->
    case dashscope_native_url(Base) of
        undefined ->
            {error, {bad_json, no_host}};
        Root ->
            http_get_dashscope_pages(Root, Token, RetryUntil, 1, [], 0)
    end.

http_get_dashscope_pages(_Root, _Token, _RetryUntil, Page, Acc, _Total) when
    Page > ?DASHSCOPE_MAX_PAGES
->
    {ok, lists:usort(Acc)};
http_get_dashscope_pages(Root, Token, RetryUntil, Page, Acc, Total0) ->
    Url =
        lists:flatten(
            io_lib:format("~s?page_no=~B&page_size=~B", [
                Root, Page, ?DASHSCOPE_PAGE_SIZE
            ])
        ),
    case http_get_json_raw(Url, Token, RetryUntil) of
        {ok, Body} ->
            case decode_dashscope_native_page(Body) of
                {ok, Names, Total, PageCount} ->
                    Acc1 = Names ++ Acc,
                    Total1 =
                        case Total of
                            undefined -> Total0;
                            T -> T
                        end,
                    Done =
                        Names =:= [] orelse
                            (Total1 > 0 andalso length(lists:usort(Acc1)) >= Total1) orelse
                            PageCount < ?DASHSCOPE_PAGE_SIZE,
                    case Done of
                        true ->
                            {ok, lists:usort(Acc1)};
                        false ->
                            http_get_dashscope_pages(
                                Root, Token, RetryUntil, Page + 1, Acc1, Total1
                            )
                    end;
                {error, Reason} ->
                    {error, {bad_json, Reason}}
            end;
        {error, _} = Err ->
            Err
    end.

decode_dashscope_native_page(Body) ->
    try
        case thoas:decode(Body) of
            {ok, #{<<"success">> := true, <<"output">> := Output}} when is_map(Output) ->
                Models = maps:get(<<"models">>, Output, []),
                Total =
                    case maps:get(<<"total">>, Output, undefined) of
                        T when is_integer(T) -> T;
                        _ -> undefined
                    end,
                case is_list(Models) of
                    true ->
                        Names = [
                            Id
                         || #{<<"model">> := Id} <- Models,
                            is_binary(Id),
                            Id =/= <<>>
                        ],
                        {ok, Names, Total, length(Models)};
                    false ->
                        {error, unexpected_shape}
                end;
            {ok, _} ->
                {error, unexpected_shape};
            {error, _} = E ->
                E
        end
    catch
        _:_ -> {error, decode_crashed}
    end.

http_get_models(Url, Token) ->
    case http_get_body(Url, Token) of
        {ok, Body} ->
            case decode_model_names(Body) of
                {ok, _} = Ok -> Ok;
                {error, Reason} -> {error, {bad_json, Reason}}
            end;
        {error, _} = Err ->
            Err
    end.

%% Like http_get_json/3 but returns the raw body for a secondary decoder.
http_get_json_raw(Url, Token, RetryUntil) ->
    case http_get_body(Url, Token) of
        {error, Detail} = Err ->
            Retry =
                retryable(Detail) andalso erlang:system_time(millisecond) < RetryUntil,
            case Retry of
                true ->
                    logger:info(#{
                        what => janus_model_sync_retry,
                        class => failure_class(Detail),
                        host => host_of(Url),
                        reason => detail_of(Detail)
                    }),
                    timer:sleep(?RETRY_BACKOFF_MS),
                    http_get_body(Url, Token);
                false ->
                    Err
            end;
        Ok ->
            Ok
    end.

%% Same upstream body budget as gun collect_body (security audit run-2).
-define(MAX_MODELS_BODY_BYTES, 32 * 1024 * 1024).
%% Align with DashScope native page budget; refuse uncapped OpenAI lists.
-define(MAX_MODELS_PER_PROVIDER, 5000).

http_get_body(Url, Token) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    %% Task 3 exclusion: background catalog sync is not request-scoped
    %% (no trace context exists in this process) — no traceparent here.
    Headers = [
        {"authorization", "Bearer " ++ binary_to_list(Token)},
        {"accept", "application/json"}
    ],
    Req = {Url, Headers},
    %% Never autoredirect while carrying Authorization — a
    %% provider-controlled 3xx can otherwise replay the Bearer token
    %% to an attacker-controlled Location (ocr security high).
    HTTPOpts = [{timeout, 15_000}, {autoredirect, false}, {ssl, janus_ssl_opts()}],
    %% httpc has no request-time body cap in our OTP (max_body_size is
    %% not a request option and is silently ignored). Cap after receive
    %% and refuse oversize before decode (security audit run-2).
    Opts = [{body_format, binary}],
    case httpc:request(get, Req, HTTPOpts, Opts) of
        {ok, {{_V, 200, _}, _H, Body}} when is_binary(Body) ->
            case byte_size(Body) > ?MAX_MODELS_BODY_BYTES of
                true -> {error, {bad_json, body_too_large}};
                false -> {ok, Body}
            end;
        {ok, {{_V, Code, _}, _H, _B}} ->
            {error, {http_status, Code}};
        {error, Reason} ->
            {error, {transport_class(Reason), Reason}}
    end.

%% `unexpected_end_of_input` (a body cut mid-flight) is not in
%% janus_cool_view's transport tag list, which is why prod rows read
%% `unclassified`; it gets its own class here.
transport_class(unexpected_end_of_input) -> truncated;
transport_class(timeout) -> timeout;
transport_class(connect_timeout) -> timeout;
transport_class(etimedout) -> timeout;
transport_class(_) -> transport.

detail_of({_, Detail}) -> Detail;
detail_of(Detail) -> Detail.

host_of(Url) ->
    try
        {_, _Scheme, Host, _Port, _Path, _Query} = http_uri:parse(Url),
        unicode:characters_to_binary(Host)
    catch
        _:_ -> undefined
    end.

decode_model_names(Body) ->
    try
        case thoas:decode(Body) of
            {ok, #{<<"data">> := Items}} when is_list(Items) ->
                Names = [Id || #{<<"id">> := Id} <- Items, is_binary(Id), Id =/= <<>>],
                Unique = lists:usort(Names),
                case length(Unique) > ?MAX_MODELS_PER_PROVIDER of
                    true ->
                        {error, {bad_json, too_many_models}};
                    false ->
                        {ok, Unique}
                end;
            {ok, _Other} ->
                {error, unexpected_shape};
            {error, _} = E ->
                E
        end
    catch
        _:_ -> {error, decode_crashed}
    end.

%% Insert-only into this provider's inventory. Does not create a public
%% model name — Router bindings stay explicit.
upsert_listing(ProviderId, Name) ->
    case
        janus_db_conn:query(
            <<"SELECT 1 FROM provider_models WHERE provider_id = ? AND name = ?">>,
            [ProviderId, Name]
        )
    of
        {ok, [_ | _]} ->
            exists;
        {ok, []} ->
            case
                janus_db_conn:query(
                    <<"INSERT INTO provider_models (provider_id, name, enabled) VALUES (?, ?, 1)">>,
                    [ProviderId, Name]
                )
            of
                {ok, _} ->
                    created;
                {error, Reason} ->
                    case unique_violation(Reason) of
                        true ->
                            exists;
                        false ->
                            logger:warning(#{
                                what => janus_model_sync_upsert_failed,
                                provider_id => ProviderId,
                                model => Name,
                                reason => Reason
                            }),
                            {error, Reason}
                    end
            end;
        {error, Reason} ->
            logger:warning(#{
                what => janus_model_sync_lookup_failed,
                provider_id => ProviderId,
                model => Name,
                reason => Reason
            }),
            {error, Reason}
    end.

%% Concurrent sync_tick + sync_now can race the unique name index.
-spec unique_violation(term()) -> boolean().
unique_violation(Reason) ->
    Flatten = flatten_term(Reason),
    lists:member(unique_violation, Flatten) orelse
        lists:member(<<"23505">>, Flatten) orelse
        lists:any(
            fun
                (B) when is_binary(B) -> binary:match(B, <<"UNIQUE">>) =/= nomatch;
                (L) when is_list(L) -> contains_unique_substring(L);
                (_) -> false
            end,
            Flatten
        ).

contains_unique_substring(L) ->
    try string:find(L, "UNIQUE") =/= nomatch of
        true -> true;
        false -> false
    catch
        _:_ -> false
    end.

flatten_term(T) when is_tuple(T) ->
    lists:append([flatten_term(X) || X <- tuple_to_list(T)]);
flatten_term(L) when is_list(L), L =/= [], not is_integer(hd(L)) ->
    lists:append([flatten_term(X) || X <- L]);
flatten_term(T) ->
    [T].

%%%===================================================================
%% Timer / config
%%%===================================================================

interval_sec() ->
    %% Hot path: settings.model_sync → app-env (set_interval) → OS env
    %% (clamped) → default 21600. Settings raw wins when present so a
    %% dashboard clear falls back correctly; set_interval still works
    %% mid-flight when no settings row exists.
    case janus_sched_knobs:model_sync_raw() of
        Map when is_map(Map) ->
            {Sec, _} = janus_sched_knobs:resolve_model_sync_interval(),
            Sec;
        _ ->
            case application:get_env(janus, model_sync_interval_sec, undefined) of
                N when is_integer(N), N >= 0 ->
                    N;
                _ ->
                    {Sec, _} = janus_sched_knobs:resolve_model_sync_interval(),
                    Sec
            end
    end.

sync_on_start() ->
    truthy(os:getenv("JANUS_MODEL_SYNC_ON_START")) orelse
        truthy(application:get_env(janus, model_sync_on_start, undefined)).

%% Boot cadence (2026-10-23): init/1 used to reset the 6 h timer without
%% ever running, so a gateway that restarts more often than the interval
%% stayed dormant for days (prod: no model_sync attempt between
%% 2026-10-19 and 2026-10-23). Run once at boot when there is no
%% SUCCESSFUL run inside the interval AND no attempt either, so a
%% permanently broken provider cannot turn every restart into a sync.
maybe_boot_sync() ->
    case sync_on_start() of
        true ->
            start_sync(on_start);
        false ->
            case catch_up_due() of
                {true, Why} ->
                    start_sync(Why);
                {false, catalog_cold} ->
                    %% janus_config publishes the snapshot right after this
                    %% child starts: re-check once (bounded, no loop).
                    _ = erlang:send_after(?CATCHUP_RECHECK_MS, self(), sync_catchup_recheck),
                    ok;
                {false, _Why} ->
                    ok
            end
    end.

start_sync(Why) ->
    logger:info(#{what => janus_model_sync_scheduled, reason => Why}),
    _ = spawn(fun() -> _ = run_sync(false) end),
    ok.

%% Manual-only mode (interval 0) is an explicit operator choice: no
%% catch-up then, unless JANUS_MODEL_SYNC_ON_START is set.
catch_up_due() ->
    case {interval_sec(), janus_catalog:get() =/= undefined} of
        {0, _} ->
            {false, manual_only};
        {_, false} ->
            {false, catalog_cold};
        {Interval, true} ->
            case last_run_ages() of
                {ok, OkAge, AnyAge} ->
                    Stale = OkAge =:= none orelse OkAge >= Interval,
                    Attempted = AnyAge =/= none andalso AnyAge < Interval,
                    case Stale andalso not Attempted of
                        true ->
                            {true, #{
                                reason => stale_success,
                                ok_age_sec => OkAge,
                                last_attempt_age_sec => AnyAge
                            }};
                        false ->
                            {false, fresh}
                    end;
                {error, Reason} ->
                    %% History unreadable (task_runs absent / DB blip): bias
                    %% to running so a restart cannot leave the task dormant.
                    {true, #{reason => history_unavailable, error => Reason}}
            end
    end.

%% `task_runs` is the dashboard-owned history fed from the ops ring; the
%% gateway only reads it here. Ages are seconds, `none` = no such row.
last_run_ages() ->
    Sql = <<
        "SELECT EXTRACT(EPOCH FROM (now() - max(finished_at) FILTER (WHERE outcome = 'ok')))::bigint,"
        " EXTRACT(EPOCH FROM (now() - max(finished_at)))::bigint"
        " FROM task_runs WHERE name = 'model_sync'"
    >>,
    case janus_db_conn:query(Sql) of
        {ok, [{OkAge, AnyAge}]} -> {ok, age_sec(OkAge), age_sec(AnyAge)};
        {ok, _Other} -> {ok, none, none};
        {error, Reason} -> {error, Reason}
    end.

age_sec(null) ->
    none;
age_sec(undefined) ->
    none;
age_sec(V) when is_integer(V), V >= 0 -> V;
age_sec(V) when is_binary(V) ->
    try binary_to_integer(V) of
        I when I >= 0 -> I;
        _ -> none
    catch
        _:_ -> none
    end;
age_sec(_) ->
    none.

maybe_start_timer(State) ->
    cancel_timer(State#state.timer_ref),
    case interval_sec() of
        N when is_integer(N), N > 0 ->
            Ref = erlang:send_after(N * 1000, self(), sync_tick),
            State#state{timer_ref = Ref};
        _ ->
            %% 0/negative: manual-only mode
            State#state{timer_ref = undefined}
    end.

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) when is_reference(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

truthy(Val) when is_list(Val) -> lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
truthy(true) -> true;
truthy(_) -> false.

status_map(#state{last_run = undefined}) ->
    #{enabled => interval_sec() > 0, last_run => null};
status_map(#state{last_run = Last}) ->
    Last#{enabled => interval_sec() > 0}.

rtrim(S, Ch) ->
    case lists:reverse(S) of
        [Ch | Rest] -> lists:reverse(Rest);
        _ -> S
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

unique_violation_test() ->
    ?assert(unique_violation({error, unique_violation})),
    ?assert(unique_violation({error, {error, <<"23505">>, <<"unique_violation">>}})),
    ?assert(unique_violation("UNIQUE constraint failed: models.name")),
    ?assertNot(unique_violation({error, timeout})),
    ?assertNot(unique_violation([])),
    ?assertNot(unique_violation([1, foo])).

classify_sync_db_outage_test() ->
    ?assertMatch(
        {error, <<"unclassified">>, {db, timeout}},
        classify_sync({error, {db, timeout}})
    ).

classify_sync_picks_first_provider_by_name_test() ->
    Providers = #{
        <<"zulu">> =>
            #{
                error =>
                    #{
                        class => <<"upstream_5xx">>,
                        provider => <<"zulu">>,
                        provider_id => 2,
                        host => <<"http://z.invalid">>,
                        detail => {http_status, 503}
                    },
                added => 0,
                seen => 0
            },
        <<"alpha">> =>
            #{
                error =>
                    #{
                        class => <<"rate">>,
                        provider => <<"alpha">>,
                        provider_id => 1,
                        host => <<"http://a.invalid">>,
                        detail => {http_status, 429}
                    },
                added => 0,
                seen => 0
            }
    },
    {error, Class, {sync_errors, 2, 2, Failures}} =
        classify_sync({ok, #{errors => 2, providers => Providers}}),
    ?assertEqual(<<"rate">>, Class),
    ?assertMatch([#{provider := <<"alpha">>, class := <<"rate">>} | _], Failures).

-endif.

%% Same verify shape as janus_providers_http:janus_tls_opts/0. OTP's
%% default hostname check rejects wildcard SANs (*.example.com vs
%% api.example.com); HTTPS match_fun is required for catalog sync over
%% httpc the same way gun needs it for request traffic.
janus_ssl_opts() ->
    case os:getenv("JANUS_UPSTREAM_TLS_VERIFY") of
        "none" ->
            [{verify, verify_none}];
        _ ->
            [
                {verify, verify_peer},
                {cacerts, public_key:cacerts_get()},
                {depth, 3},
                {customize_hostname_check, [
                    {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                ]}
            ]
    end.
