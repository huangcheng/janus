%%%-------------------------------------------------------------------
%%% @doc In-memory audit trail for the admin console. Ring buffer of
%%% the last `?CAP` events; every login attempt and every mutation is
%%% logged with the acting IP. Resets on restart by design.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_admin_audit).

-behaviour(gen_server).

-export([start_link/0]).
-export([log/4, recent/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TAB, ?MODULE).
-define(CAP, 1000).

-record(state, {next = 1 :: pos_integer()}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec log(binary() | string(), binary() | string(), binary() | string() | undefined,
          binary() | string() | undefined) -> ok.
log(Actor, Action, Target, Detail) ->
    gen_server:call(?MODULE, {log, bin(Actor), bin(Action), opt(Target), opt(Detail)}).

-spec recent(non_neg_integer()) -> [map()].
recent(N) when is_integer(N), N >= 0 ->
    try
        Rows = ets:tab2list(?TAB),
        Sorted = lists:reverse(lists:sort(Rows)),
        [Entry || {_, Entry} <- lists:sublist(Sorted, N)]
    catch
        error:badarg -> []
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    ?TAB = ets:new(?TAB, [named_table, ordered_set, public, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({log, Actor, Action, Target, Detail}, _From, State) ->
    Idx = State#state.next,
    Entry = #{
        ts => ts(),
        actor => Actor,
        action => Action,
        target => Target,
        detail => Detail
    },
    true = ets:insert(?TAB, {Idx, Entry}),
    _ = ets:delete(?TAB, Idx - ?CAP),
    {reply, ok, State#state{next = Idx + 1}};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal
%%%===================================================================

ts() ->
    Str = calendar:system_time_to_rfc3339(erlang:system_time(second),
        [{unit, second}, {offset, "Z"}]),
    unicode:characters_to_binary(Str).

bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(_) -> <<"unknown">>.

opt(undefined) -> null;
opt(B) when is_binary(B) -> B;
opt(L) when is_list(L) -> unicode:characters_to_binary(L);
opt(A) when is_atom(A) -> atom_to_binary(A, utf8);
opt(_) -> null.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

recent_test() ->
    {ok, _} = start_link(),
    try
        ok = log(<<"1.1.1.1">>, <<"test.one">>, <<"a">>, undefined),
        ok = log(<<"1.1.1.1">>, <<"test.two">>, <<"b">>, <<"d">>),
        [Two, One] = recent(2),
        <<"test.two">> = maps:get(action, Two),
        <<"test.one">> = maps:get(action, One)
    after
        gen_server:stop(?MODULE)
    end.

cap_test() ->
    {ok, _} = start_link(),
    try
        [ok = log(<<"ip">>, <<"x">>, undefined, undefined) || _ <- lists:seq(1, 1200)],
        1000 = length(recent(2000)),
        [Oldest | _] = lists:reverse(recent(2000)),
        true = maps:get(ts, Oldest) =/= undefined
    after
        gen_server:stop(?MODULE)
    end.

-endif.
