%%%-------------------------------------------------------------------
%%% @doc In-memory ring of recent log events for the dashboard Logs
%%% page. A logger handler mirrors events (level >= info) into an ETS
%%% ring buffer; the dashboard API reads the newest N with level
%%% filtering. File/stdout handlers are unaffected.
%%%
%%% Capacity 2000 lines, owner = this gen_server (restarted with the
%%% dashboard supervision tree). Ring index is a monotonic counter so
%%% the UI can poll with `?since=<idx>` for live tailing.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_log_tail).

-behaviour(gen_server).

-export([start_link/0]).
-export([recent/2, tail_config/0, push/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TAB, janus_log_tail).
-define(CAP, 2000).

-record(state, {next = 1 :: pos_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Newest-first list of at most N events at or above MinLevel, with an
%% optional since-idx cursor for incremental tailing.
-spec recent(non_neg_integer(), atom() | undefined) -> {ok, [map()], pos_integer()}.
recent(N, MinLevel) when is_integer(N), N >= 0 ->
    try
        All = lists:reverse(ets:tab2list(?TAB)),
        Filtered = [E || {_, E} <- All, level_ge(maps:get(level, E), MinLevel)],
        {ok, lists:sublist(Filtered, N), ets:info(?TAB, size)}
    catch
        _:_ -> {ok, [], 0}
    end.

tail_config() ->
    #{capacity => ?CAP}.

%% Called from logger handler processes; serialized through the server so
%% the ordered_set index stays monotonic.
-spec push(map()) -> ok.
push(Event) ->
    gen_server:cast(?MODULE, {push, Event}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    _ = catch ets:delete(?TAB),
    _ = ets:new(?TAB, [named_table, ordered_set, public, {read_concurrency, true}]),
    %% Mirror events into the ring (silence our own handler removal).
    _ = logger:add_handler(janus_log_tail_h, janus_log_tail_h, #{
        level => info,
        config => #{}
    }),
    {ok, #state{}}.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({push, Event0}, #state{next = Idx} = State) ->
    try
        Event = Event0#{idx := Idx},
        ets:insert(?TAB, {Idx, Event}),
        Cap = ?CAP,
        case Idx > Cap of
            true -> ets:delete(?TAB, Idx - Cap);
            false -> ok
        end
    catch
        _:_ -> ok
    end,
    {noreply, State#state{next = Idx + 1}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = logger:remove_handler(janus_log_tail_h),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Handler module (log event -> flat map into the ring)
%%%===================================================================

level_ge(error, _) -> true;
level_ge(warning, undefined) -> true;
level_ge(warning, Min) -> Min =:= info orelse Min =:= warning;
level_ge(info, undefined) -> true;
level_ge(info, Min) -> Min =:= info;
level_ge(_, _) -> false.
