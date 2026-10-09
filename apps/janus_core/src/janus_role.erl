-module(janus_role).

-export([resolve/0, get/0]).

-define(PT_KEY, {janus, role}).

-spec resolve() -> {ok, master | worker} | {error, unknown_role | missing_master_node}.
resolve() ->
    case parse_role(os:getenv("JANUS_ROLE")) of
        {ok, Role} = Ok ->
            persistent_term:put(?PT_KEY, Role),
            Ok;
        {error, _} = Err ->
            Err
    end.

-spec get() -> master | worker.
get() ->
    persistent_term:get(?PT_KEY).

parse_role(false) ->
    {ok, master};
parse_role("master") ->
    {ok, master};
parse_role("worker") ->
    case master_node_env() of
        {ok, _} ->
            {ok, worker};
        {error, _} = Err ->
            Err
    end;
parse_role(_) ->
    {error, unknown_role}.

master_node_env() ->
    case os:getenv("JANUS_MASTER_NODE") of
        false ->
            {error, missing_master_node};
        "" ->
            {error, missing_master_node};
        _Node ->
            {ok, ok}
    end.
