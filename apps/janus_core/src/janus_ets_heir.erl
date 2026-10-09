%%%-------------------------------------------------------------------
%%% @doc ETS heir: holds owner-less tables and gives them back.
%%%
%%% Supervisors silently drop `{'ETS-TRANSFER', _}` info messages, so a
%%% supervisor heir would LOSE every table whose owner died. This tiny
%%% gen_server (scheduler v2 spec Part 0.5) is the stable heir process
%%% for the pool-owned scheduler tables (`sched_snapshot`,
%%% `sched_reserve`, `sched_workers`, `geo_cache`, `sched_rtt`) and any
%%% other table created with
%%% `{heir, janus_ets_heir:heir_for(Tag), {Tag, self()}}`.
%%%
%%% GiftData shape is pinned by the spec:
%%% `{TableTag :: atom(), Owner :: pid()}` — adoption resolves by the
%%% stable `TableTag`, never by the (long-gone) owner pid. When an
%%% owner dies its tables transfer here and are held until a restarting
%%% owner calls {@link adopt/1}. `adopt/1` has no internal retry: the
%%% boot-path adopt request RETRIES with backoff at the CALLER — the
%%% heir may not yet have processed the old owner's
%%% `{'ETS-TRANSFER'}` when the new owner asks, and `not_held` is the
%%% honest answer until then.
%%%
%%% If the heir itself dies, held tables are destroyed with it and
%%% owners recreate them cold on their next boot (the accepted
%%% cold-reset class, spec Part 0.5).
%%%-------------------------------------------------------------------
-module(janus_ets_heir).
-behaviour(gen_server).

%% API
-export([start_link/0, heir_for/1, adopt/1]).
%% gen_server
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).

-type table_tag() :: atom().

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Heir pid for `ets:new` options:
%% `{heir, janus_ets_heir:heir_for(Tag), {Tag, self()}}`. Fails loud
%% when the heir is not running — an owner must never boot with a dead
%% heir (its table would be lost on the first owner crash).
-spec heir_for(table_tag()) -> pid().
heir_for(TableTag) when is_atom(TableTag) ->
    case whereis(?SERVER) of
        Pid when is_pid(Pid) ->
            Pid;
        undefined ->
            erlang:error({heir_not_running, TableTag})
    end.

%% @doc Boot-path adopt: give back the held table whose GiftData is
%% `{TableTag, _OldOwner}`. The CALLER owns the table afterwards.
%% Returns `not_held` when the heir holds no such table yet — the
%% caller retries with backoff (spec Part 0.5).
%%
%% SIDE EFFECT: `ets:give_away/3` ALWAYS delivers an asynchronous
%% `{'ETS-TRANSFER', Tab, HeirPid, GiftData}` info message to the
%% adopter (OTP semantics — the gift payload cannot suppress it).
%% Adopters must tolerate the message via their `handle_info`
%% catch-alls; the authoritative hand-back is this call's reply.
%% A failed transfer (caller died mid-request, non-public table)
%% answers `{error, give_away_failed}` for THAT request only — an
%% unguarded `give_away` would crash this shared heir and destroy
%% every table it holds for unrelated owners.
-spec adopt(table_tag()) ->
    {ok, ets:tid()} | not_held | {error, give_away_failed}.
adopt(TableTag) when is_atom(TableTag) ->
    gen_server:call(?SERVER, {adopt, TableTag}, 5000).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

%% State: TableId => GiftData (held tables, newest last).
init([]) ->
    {ok, #{}}.

handle_call({adopt, TableTag}, {FromPid, _Tag}, Tables) ->
    case find_held(Tables, TableTag) of
        {ok, Tab, GiftData} ->
            case catch ets:give_away(Tab, FromPid, GiftData) of
                true ->
                    {reply, {ok, Tab}, maps:remove(Tab, Tables)};
                _ ->
                    %% Caller died mid-request or the table is not
                    %% public — keep holding; never take the shared
                    %% heir down for one request.
                    {reply, {error, give_away_failed}, Tables}
            end;
        error ->
            {reply, not_held, Tables}
    end;
handle_call(_Req, _From, Tables) ->
    {reply, {error, unknown}, Tables}.

handle_cast(_Msg, Tables) ->
    {noreply, Tables}.

handle_info({'ETS-TRANSFER', Tab, _FromPid, GiftData}, Tables) ->
    %% An owner died (or gave the table away voluntarily): hold the
    %% table until a restarting owner adopts it. Unrecognized
    %% GiftData shapes are held but logged — they would never be
    %% adoptable by tag (visible leak, not a silent one).
    case GiftData of
        {TableTag, _Owner} when is_atom(TableTag) ->
            ok;
        Other ->
            logger:warning(#{
                what => janus_ets_heir_unexpected_gift,
                table => Tab,
                gift_data => Other
            })
    end,
    {noreply, Tables#{Tab => GiftData}};
handle_info(_Info, Tables) ->
    {noreply, Tables}.

terminate(_Reason, _Tables) ->
    %% Held tables are destroyed with this process; owners recreate
    %% them cold (accepted cold-reset class, spec Part 0.5).
    ok.

code_change(_OldVsn, Tables, _Extra) ->
    {ok, Tables}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

-spec find_held(map(), table_tag()) ->
    {ok, ets:tid(), {table_tag(), pid()}} | error.
find_held(Tables, TableTag) when is_atom(TableTag) ->
    Matches = [
        {Tab, GiftData}
     || {Tab, GiftData} <- maps:to_list(Tables),
        is_tuple(GiftData),
        tuple_size(GiftData) =:= 2,
        element(1, GiftData) =:= TableTag
    ],
    case Matches of
        [{Tab, GiftData} | _] ->
            {ok, Tab, GiftData};
        [] ->
            error
    end.
