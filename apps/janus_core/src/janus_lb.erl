%%%-------------------------------------------------------------------
%%% @doc Node-local LB runtime ETS owner.
%%%
%%% Owns cool-downs, in-flight counters, and weighted-RR cursors in
%%% separate ETS tables from the catalog. Config publish must never
%%% wipe these tables.
%%%
%%% Weighted RR is intentionally thin for this phase — stubs compile
%%% and preserve the API for the proxy hot path.
%%%-------------------------------------------------------------------
-module(janus_lb).
-behaviour(gen_server).

-export([start_link/0]).
-export([note_failure/2, note_success/1, pick_route/2]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(COOLDOWNS, janus_lb_cooldowns).
-define(INFLIGHT, janus_lb_inflight).
-define(CURSORS, janus_lb_rr_cursors).
-define(DEFAULT_COOLDOWN_MS, 5000).
-define(MAX_RETRY_AFTER_MS, 300000).

-record(state, {
    cooldowns :: ets:tid(),
    inflight :: ets:tid(),
    cursors :: ets:tid()
}).

-type target() ::
    term()
    | #{provider_id := term(), key_id => term(), model_id => term()}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Record a failure against a route/key target; apply cool-down.
-spec note_failure(target(), term()) -> ok.
note_failure(undefined, _Reason) ->
    ok;
note_failure(Target, Reason) ->
    gen_server:cast(?SERVER, {note_failure, Target, Reason}).

%% @doc Record a success; clear cool-down and decrement in-flight.
-spec note_success(target()) -> ok.
note_success(undefined) ->
    ok;
note_success(Target) ->
    gen_server:cast(?SERVER, {note_success, Target}).

%% @doc Pick a route for `ModelId`. `Opts` may include `generation`.
%% Returns `{ok, Route}` or `{error, Reason}`. Weighted RR is stub-thin.
-spec pick_route(term(), map()) -> {ok, map()} | {error, term()}.
pick_route(ModelId, Opts) when is_map(Opts) ->
    gen_server:call(?SERVER, {pick_route, ModelId, Opts}, 5000).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([]) ->
    Cool = ets:new(?COOLDOWNS, [
        named_table, set, public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    Inflight = ets:new(?INFLIGHT, [
        named_table, set, public, {write_concurrency, true}
    ]),
    Cursors = ets:new(?CURSORS, [
        named_table, set, public, {write_concurrency, true}
    ]),
    logger:info(#{what => janus_lb_started}),
    {ok, #state{cooldowns = Cool, inflight = Inflight, cursors = Cursors}}.

handle_call({pick_route, ModelId, Opts}, _From, State) ->
    Reply = do_pick_route(ModelId, Opts, State),
    {reply, Reply, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({note_failure, Target, Reason}, State) ->
    do_note_failure(Target, Reason, State),
    {noreply, State};
handle_cast({note_success, Target}, State) ->
    do_note_success(Target, State),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

do_pick_route(ModelId, Opts, #state{cooldowns = Cool, cursors = Cursors, inflight = Inflight}) ->
    case catalog_generation_ok(Opts) of
        false ->
            {error, catalog_not_ready};
        true ->
            Routes0 = janus_catalog:routes_for_model(ModelId),
            Routes1 = [R || R <- Routes0, maps:get(enabled, R, true)],
            case Routes1 of
                [] ->
                    {error, no_route};
                _ ->
                    Now = erlang:monotonic_time(millisecond),
                    Available = [
                        R
                     || R <- Routes1,
                        not is_cooling(route_target(R), Cool, Now),
                        provider_enabled(R)
                    ],
                    case Available of
                        [] ->
                            {error, all_cooling};
                        Candidates ->
                            Picked = weighted_rr_pick(ModelId, Candidates, Cursors),
                            case maybe_pick_key(Picked, Cool, Cursors, Now) of
                                undefined ->
                                    case janus_catalog:provider_keys(maps:get(provider_id, Picked)) of
                                        [] ->
                                            {error, missing_provider_key};
                                        _ ->
                                            {error, all_cooling}
                                    end;
                                Key ->
                                    bump_inflight(route_target(Picked), Inflight),
                                    {ok, Picked#{provider_key => Key}}
                            end
                    end
            end
    end.

catalog_generation_ok(Opts) ->
    case janus_catalog:get() of
        undefined ->
            false;
        #{generation := Gen} ->
            case maps:get(generation, Opts, undefined) of
                undefined -> true;
                Want when Want =:= Gen -> true;
                _ -> false
            end
    end.

provider_enabled(#{provider_id := ProviderId}) ->
    case janus_catalog:lookup_provider(ProviderId) of
        {ok, #{enabled := false}} -> false;
        {ok, _} -> true;
        error -> false
    end;
provider_enabled(_) ->
    false.

maybe_pick_key(#{provider_id := ProviderId} = Route, Cool, Cursors, Now) ->
    Keys0 = [
        K
     || K <- janus_catalog:provider_keys(ProviderId),
        maps:get(enabled, K, true),
        not is_cooling(key_target(K), Cool, Now)
    ],
    case Keys0 of
        [] ->
            undefined;
        Keys ->
            CursorKey = {provider_keys, ProviderId, maps:get(model_id, Route, undefined)},
            weighted_rr_pick(CursorKey, Keys, Cursors)
    end;
maybe_pick_key(_, _, _, _) ->
    undefined.

weighted_rr_pick(CursorKey, Items, Cursors) ->
    Expanded = lists:append([lists:duplicate(maps:get(weight, I, 1), I) || I <- Items]),
    case Expanded of
        [] ->
            hd(Items);
        _ ->
            Len = length(Expanded),
            Idx = case ets:lookup(Cursors, CursorKey) of
                [{_, N}] -> N rem Len;
                [] -> 0
            end,
            ets:insert(Cursors, {CursorKey, Idx + 1}),
            lists:nth(Idx + 1, Expanded)
    end.

do_note_failure(Target, Reason, #state{cooldowns = Cool, inflight = Inflight}) ->
    Key = normalize_target(Target),
    Ms = cooldown_ms(Reason),
    Until = erlang:monotonic_time(millisecond) + Ms,
    ets:insert(Cool, {Key, Until, Reason}),
    dec_inflight(Key, Inflight),
    logger:info(#{what => janus_lb_cooldown, target => Key, reason => Reason, ms => Ms}),
    ok.

do_note_success(Target, #state{cooldowns = Cool, inflight = Inflight}) ->
    Key = normalize_target(Target),
    ets:delete(Cool, Key),
    dec_inflight(Key, Inflight),
    ok.

is_cooling(Target, Cool, Now) ->
    case ets:lookup(Cool, Target) of
        [{_, Until, _}] when is_integer(Until), Until > Now -> true;
        [{_, Until}] when is_integer(Until), Until > Now -> true;
        [{_, _, _}] ->
            ets:delete(Cool, Target),
            false;
        [{_, _}] ->
            ets:delete(Cool, Target),
            false;
        [] ->
            false
    end.

bump_inflight(Target, Inflight) ->
    Key = normalize_target(Target),
    case ets:lookup(Inflight, Key) of
        [{_, N}] -> ets:insert(Inflight, {Key, N + 1});
        [] -> ets:insert(Inflight, {Key, 1})
    end.

dec_inflight(Target, Inflight) ->
    Key = normalize_target(Target),
    case ets:lookup(Inflight, Key) of
        [{_, N}] when N > 1 -> ets:insert(Inflight, {Key, N - 1});
        [{_, _}] -> ets:delete(Inflight, Key);
        [] -> ok
    end.

route_target(#{provider_id := P, model_id := M}) ->
    {route, M, P};
route_target(#{provider_id := P}) ->
    {route, P};
route_target(Other) ->
    normalize_target(Other).

key_target(#{id := Id}) ->
    {provider_key, Id};
key_target(Other) ->
    normalize_target(Other).

normalize_target(#{provider_id := P, key_id := K}) ->
    {provider_key, P, K};
normalize_target(#{provider_id := P, model_id := M}) ->
    {route, M, P};
normalize_target(#{provider_id := P}) ->
    {route, P};
normalize_target(#{id := Id}) ->
    Id;
normalize_target(Target) ->
    Target.

cooldown_ms({retry_after, Ms}) when is_integer(Ms), Ms > 0 ->
    min(Ms, ?MAX_RETRY_AFTER_MS);
cooldown_ms(#{retry_after_ms := Ms}) when is_integer(Ms), Ms > 0 ->
    min(Ms, ?MAX_RETRY_AFTER_MS);
cooldown_ms(_Reason) ->
    case os:getenv("JANUS_LB_COOLDOWN_MS") of
        false -> ?DEFAULT_COOLDOWN_MS;
        "" -> ?DEFAULT_COOLDOWN_MS;
        Val ->
            try list_to_integer(Val) catch _:_ -> ?DEFAULT_COOLDOWN_MS end
    end.
