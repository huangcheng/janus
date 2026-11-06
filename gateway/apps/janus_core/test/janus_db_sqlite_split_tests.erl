%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the SQLite migration statement
%%% splitter.
%%%
%%% Regression: a migration with a multi-line header comment containing a
%%% semicolon failed to apply at boot, because the body was split on `;'
%%% BEFORE comments were removed — the semicolon inside the comment cut a
%%% statement in half and both halves failed. Comments must never decide
%%% whether a migration applies.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_db_sqlite_split_tests).

-include_lib("eunit/include/eunit.hrl").

%% The splitter is not exported; exercise it through the public seam
%% (a full migration body) and assert the statement count it yields.
migration_with_semicolon_in_comment_applies_test() ->
    Sql = <<
        "-- A comment with a semicolon; right there.\n"
        "-- Another line; also fine.\n"
        "ALTER TABLE t ADD COLUMN a INTEGER;\n"
        "ALTER TABLE t ADD COLUMN b INTEGER;\n"
    >>,
    Stmts = split_via_seam(Sql),
    ?assertEqual(2, length(Stmts)),
    ?assertEqual(<<"ALTER TABLE t ADD COLUMN a INTEGER">>, lists:nth(1, Stmts)),
    ?assertEqual(<<"ALTER TABLE t ADD COLUMN b INTEGER">>, lists:nth(2, Stmts)).

leading_comments_without_semicolon_are_ignored_test() ->
    Sql = <<
        "-- header one\n"
        "-- header two\n"
        "SELECT 1\n"
    >>,
    ?assertEqual([<<"SELECT 1">>], split_via_seam(Sql)).

inline_comment_after_statement_is_ignored_test() ->
    Sql = <<"SELECT 1 -- trailing note\n">>,
    ?assertEqual([<<"SELECT 1">>], split_via_seam(Sql)).

%% The seam: `split_sql/1' is internal, so reach it the same way the
%% runner does — by exporting nothing and calling through the module's
%% own migration path is too heavy for a unit test. Instead assert the
%% behaviour via the documented wrapper used by the runner.
split_via_seam(Sql) ->
    %% erlang:apply on an unexported function is not possible; the
    %% module exports split for tests below.
    janus_db_sqlite:split_sql_for_test(Sql).
