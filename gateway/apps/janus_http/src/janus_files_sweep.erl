%% @doc Retention sweeper for the Files API (2026-10-27).
%%
%% Files live until deleted by their owner — agent clients rarely call
%% DELETE, so without a sweeper the content-addressed tree only grows
%% (quota-capped, but pinned). This gen_server runs janus_files:sweep/0
%% every hour; the retention window itself is the settings knob
%% `files.retention_days` (0/absent = keep forever — sweep becomes a
%% no-op and costs one trivial query per hour).
-module(janus_files_sweep).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SWEEP_INTERVAL_MS, 3_600_000).
-define(FIRST_DELAY_MS, 120_000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = erlang:send_after(?FIRST_DELAY_MS, self(), sweep),
    {ok, #{}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Req, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    {Rows, Blobs} =
        try
            janus_files:sweep()
        catch
            Class:Reason ->
                _ = logger:warning(#{
                    what => files_sweep_crashed, class => Class, reason => Reason
                }),
                {0, 0}
        end,
    case {Rows, Blobs} of
        {0, 0} -> ok;
        _ -> logger:info(#{what => files_sweep_done, rows => Rows, blobs => Blobs})
    end,
    _ = erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
