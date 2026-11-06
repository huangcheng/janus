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

double_dash_inside_string_literal_survives_test() ->
    %% A literal must not be truncated by the comment stripper.
    Sql = <<"SELECT '--not a comment' AS v\n">>,
    ?assertEqual([<<"SELECT '--not a comment' AS v">>], split_via_seam(Sql)).

doubled_quote_escapes_test() ->
    %% SQL escapes a quote by doubling it; the toggle must handle that.
    Sql = <<"SELECT 'it''s -- fine' AS v\n">>,
    ?assertEqual([<<"SELECT 'it''s -- fine' AS v">>], split_via_seam(Sql)).

inline_comment_after_statement_is_ignored_test() ->
    Sql = <<"SELECT 1 -- trailing note\n">>,
    ?assertEqual([<<"SELECT 1">>], split_via_seam(Sql)).

%% `split_sql/1' is internal; `split_sql_for_test/1' is the documented
%% test seam and does nothing but delegate to it.
split_via_seam(Sql) ->
    janus_db_sqlite:split_sql_for_test(Sql).
