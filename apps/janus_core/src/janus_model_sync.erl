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
    try gen_server:call(?SERVER, status)
    catch exit:{noproc, _} -> #{enabled => false}
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
    case sync_on_start() of
        true -> _ = spawn(fun() -> {ok, _} = (catch do_sync()) end);
        false -> ok
    end,
    {ok, State}.

handle_call(sync_now, _From, State) ->
    Result = (catch do_sync()),
    %% do_sync now handles DB errors internally; catch guards anything else
    case Result of
        {ok, R} -> {reply, {ok, R}, State#state{last_run = R}};
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
    _ = spawn(fun() -> _ = (catch do_sync()) end),
    {noreply, maybe_start_timer(State#state{timer_ref = undefined})};
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

do_sync() ->
    Started = erlang:system_time(millisecond),
    Providers = case janus_db_conn:query(<<"SELECT id, name FROM providers WHERE enabled = 1">>) of
        {ok, Rows} -> Rows;
        {error, Reason} ->
            logger:warning(#{what => janus_model_sync_db_error, reason => Reason}),
            []
    end,
    PerProvider =
        lists:foldl(
            fun({Id, Name}, Acc) ->
                [{Name, sync_provider(Id)} | Acc]
            end,
            [],
            Providers
        ),
    Result = #{
        ran_at => unicode:characters_to_binary(
            calendar:system_time_to_rfc3339(Started, [{unit, millisecond}, {offset, "Z"}])),
        elapsed_ms => erlang:system_time(millisecond) - Started,
        providers => maps:from_list(PerProvider)
    },
    {Total, Seen, Errs} = lists:foldl(
        fun({_N, #{added := A, seen := S, error := E}}, {T, Se, Er}) ->
            {T + A, Se + S, case E of undefined -> Er; _ -> Er + 1 end}
        end,
        {0, 0, 0},
        PerProvider
    ),
    logger:info(#{
        what => janus_model_sync_done,
        providers => length(Providers),
        models_added => Total,
        models_seen => Seen,
        errors => Errs
    }),
    Result#{models_added => Total, models_seen => Seen, errors => Errs}.

%% Fetches GET {base}/models for one provider and upserts unseen names.
sync_provider(ProviderId) ->
    case fetch_provider_models(ProviderId) of
        {ok, Names} when is_list(Names) ->
            {Added, UpsertErrs} = lists:foldl(
                fun(Name, {A, E}) ->
                    case upsert_listing(ProviderId, Name) of
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
                    N -> {upsert_failed, N}
                end,
            #{added => Added, seen => length(Names), error => Err};
        {error, Reason} ->
            logger:warning(#{what => janus_model_sync_provider_failed,
                provider_id => ProviderId, reason => Reason}),
            #{added => 0, seen => 0, error => Reason}
    end.

fetch_provider_models(ProviderId) ->
    try
        case janus_catalog:lookup_provider(ProviderId) of
            {ok, #{base_url := Base0, enabled := true}} ->
                case janus_catalog:provider_keys(ProviderId) of
                    [#{secret_ref := Ref} | _] ->
                        {ok, Token} = janus_secrets:decrypt(
                            case Ref of {_, Cipher} -> Cipher; C -> C end),
                        Base = binary_to_list(Base0),
                        Url = lists:flatten(rtrim(Base, $/) ++ "/models"),
                        http_get_json(Url, Token);
                    [] ->
                        {error, no_keys}
                end;
            {ok, #{enabled := false}} ->
                {error, disabled};
            error ->
                {error, not_found}
        end
    catch
        Class:Reason:Stack ->
            logger:warning(#{what => janus_model_sync_fetch_crash,
                provider_id => ProviderId, class => Class,
                reason => Reason, stack_top => hd(Stack)}),
            {error, fetch_crashed}
    end.

http_get_json(Url, Token) ->
    _ = application:ensure_all_started(inets),
    _ = application:ensure_all_started(ssl),
    Headers = [
        {"authorization", "Bearer " ++ binary_to_list(Token)},
        {"accept", "application/json"}
    ],
    Req = {Url, Headers},
    HTTPOpts = [{timeout, 15_000}, {autoredirect, true}, {ssl, janus_ssl_opts()}],
    Opts = [{body_format, binary}],
    case httpc:request(get, Req, HTTPOpts, Opts) of
        {ok, {{_V, 200, _}, _H, Body}} ->
            decode_model_names(Body);
        {ok, {{_V, Code, _}, _H, _B}} ->
            {error, {http, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

decode_model_names(Body) ->
    try
        case thoas:decode(Body) of
            {ok, #{<<"data">> := Items}} when is_list(Items) ->
                Names = [Id || #{<<"id">> := Id} <- Items, is_binary(Id), Id =/= <<>>],
                {ok, lists:usort(Names)};
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
    %% Dashboard-set app env wins over the boot-time os env default.
    case application:get_env(janus, model_sync_interval_sec, undefined) of
        N when is_integer(N), N >= 0 -> N;
        _ ->
            case os:getenv("JANUS_MODEL_SYNC_INTERVAL_SEC") of
                Val when is_list(Val), Val =/= [] ->
                    (catch list_to_integer(Val));
                _ ->
                    ?DEFAULT_INTERVAL
            end
    end.

sync_on_start() ->
    truthy(os:getenv("JANUS_MODEL_SYNC_ON_START"))
        orelse truthy(application:get_env(janus, model_sync_on_start, undefined)).

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

cancel_timer(undefined) -> ok;
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

-endif.

janus_ssl_opts() ->
    case os:getenv("JANUS_UPSTREAM_TLS_VERIFY") of
        "none" -> [{verify, verify_none}];
        _ ->
            [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}, {depth, 3}]
    end.
