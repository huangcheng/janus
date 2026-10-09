%%% @doc Live adopt-cycle tests for `janus_ets_heir` (scheduler v2
%%% spec Part 0.5). Supervisors silently drop `{'ETS-TRANSFER'}` info
%%% messages — a supervisor heir would LOSE every table whose owner
%%% died; these tests pin the real heir behavior: hold on owner death,
%%% identifier-stable adopt by TableTag, not_held retry semantics.
-module(janus_ets_heir_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TAG, janus_geo_test_tab).

adopt_cycle_test() ->
    {ok, Heir} = janus_ets_heir:start_link(),
    try
        ?assert(is_pid(janus_ets_heir:heir_for(?TAG))),
        %% spawn_monitor so an owner crash (e.g. ets:new badarg on a
        %% stale named table) fails the test with its TRUE cause
        %% instead of a misleading adopt timeout (ocr review).
        {Owner, _Mon} = spawn_monitor(fun() ->
            Tab = ets:new(?TAG, [
                set,
                public,
                named_table,
                {heir, janus_ets_heir:heir_for(?TAG), {?TAG, self()}}
            ]),
            ets:insert(Tab, {<<"host">>, <<"cn-east">>}),
            receive
                die -> ok
            end
        end),
        Owner ! die,
        receive {'DOWN', _Mon, process, Owner, normal} -> ok after 5000 -> error(owner_stuck) end,
        %% RETRY semantics live at the caller: the heir may not yet
        %% have processed the old owner's transfer when asked.
        Tab = wait_adopt(?TAG, 50),
        ?assertEqual([{<<"host">>, <<"cn-east">>}], ets:lookup(Tab, <<"host">>)),
        %% Ownership moved to the caller of adopt/1 (this process).
        ?assertEqual(self(), ets:info(Tab, owner)),
        ?assertEqual(not_held, janus_ets_heir:adopt(?TAG)),
        ets:delete(Tab)
    after
        stop_heir(Heir)
    end.

adopt_not_held_test() ->
    {ok, Heir} = janus_ets_heir:start_link(),
    try
        ?assertEqual(not_held, janus_ets_heir:adopt(no_such_table))
    after
        stop_heir(Heir)
    end.

heir_for_fails_loud_when_stopped_test() ->
    ?assertException(
        error, {heir_not_running, _},
        janus_ets_heir:heir_for(?TAG)
    ).

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

wait_adopt(Tag, Tries) ->
    case janus_ets_heir:adopt(Tag) of
        {ok, Tab} ->
            Tab;
        not_held when Tries > 0 ->
            timer:sleep(20),
            wait_adopt(Tag, Tries - 1);
        not_held ->
            erlang:error({adopt_never_succeeded, Tag})
    end.

stop_heir(Heir) ->
    try
        gen_server:stop(Heir)
    catch
        _:_ -> ok
    end.
