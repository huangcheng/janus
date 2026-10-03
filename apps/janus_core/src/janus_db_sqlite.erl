%%%-------------------------------------------------------------------
%%% @doc SQLite backend for {@link janus_db} (esqlite3).
%%% Conn is the gen_server pid from start_link/1.
%%% listen/2 is a documented no-op (single-node; use poll).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_db_sqlite).
-behaviour(janus_db).
-behaviour(gen_server).

-export([
    start_link/1,
    migrate/1,
    query/3,
    with_tx/2,
    listen/2,
    get_generation/1,
    cas_generation/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(TX_KEY(Server), {janus_db_tx, Server}).

-record(state, {
    conn :: term(),
    path :: file:filename_all()
}).

%%%===================================================================
%%% janus_db callbacks
%%%===================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec migrate(pid()) -> ok | {error, term()}.
migrate(Server) ->
    call(Server, migrate).

-spec query(pid(), iodata(), [term()]) -> {ok, [term()]} | {error, term()}.
query(Server, Sql, Params) when is_list(Params) ->
    case erlang:get(?TX_KEY(Server)) of
        undefined -> call(Server, {query, Sql, Params});
        Conn -> do_query(Conn, Sql, Params)
    end.

-spec with_tx(pid(), fun((pid()) -> Result)) -> Result | {error, term()}.
with_tx(Server, Fun) when is_function(Fun, 1) ->
    call(Server, {with_tx, Fun}).

%% @doc No-op on SQLite (no LISTEN/NOTIFY). Catalog should poll / reload locally.
-spec listen(pid(), binary()) -> ok.
listen(_Server, _Channel) ->
    ok.

-spec get_generation(pid()) -> {ok, non_neg_integer()} | {error, term()}.
get_generation(Server) ->
    case query(Server, <<"SELECT config_generation FROM config_meta WHERE id = 1">>, []) of
        {ok, [{Gen}]} when is_integer(Gen), Gen >= 0 -> {ok, Gen};
        {ok, []} -> {error, missing_config_meta};
        {ok, Other} -> {error, {unexpected_generation_row, Other}};
        {error, _} = Err -> Err
    end.

-spec cas_generation(pid(), non_neg_integer()) ->
    {ok, non_neg_integer()} | {error, conflict | term()}.
cas_generation(Server, Expected) when is_integer(Expected), Expected >= 0 ->
    case
        with_tx(Server, fun(_C) ->
            case erlang:get(?TX_KEY(Server)) of
                undefined -> {error, missing_tx_conn};
                Raw -> do_cas(Raw, Expected)
            end
        end)
    of
        {ok, _} = Ok -> Ok;
        {error, _} = Err -> Err;
        Other -> {error, {unexpected_cas_result, Other}}
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Path = maps:get(path, Opts, maps:get(sqlite_path, Opts, janus_db:sqlite_path())),
    PathStr = to_path_string(Path),
    ok = ensure_parent_dir(PathStr),
    case esqlite3:open(PathStr) of
        {ok, Conn} ->
            _ = esqlite3:exec(Conn, <<"PRAGMA foreign_keys = ON">>),
            _ = esqlite3:exec(Conn, <<"PRAGMA journal_mode = WAL">>),
            {ok, #state{conn = Conn, path = PathStr}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(migrate, _From, State = #state{conn = Conn}) ->
    {reply, do_migrate(Conn), State};
handle_call({query, Sql, Params}, _From, State = #state{conn = Conn}) ->
    {reply, do_query(Conn, Sql, Params), State};
handle_call({with_tx, Fun}, _From, State = #state{conn = Conn}) ->
    {reply, run_with_tx(Conn, Fun, self()), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{conn = Conn}) ->
    catch esqlite3:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% internal
%%%===================================================================

call(Server, Req) ->
    gen_server:call(Server, Req, infinity).

to_path_string(Path) when is_list(Path) -> Path;
to_path_string(Path) when is_binary(Path) -> binary_to_list(Path).

ensure_parent_dir(PathStr) ->
    case filename:dirname(PathStr) of
        "." ->
            ok;
        Dir ->
            case filelib:ensure_dir(filename:join(Dir, "dummy")) of
                ok -> ok;
                {error, Reason} -> error({sqlite_parent_dir, Dir, Reason})
            end
    end.

do_query(Conn, Sql, Params) ->
    SqlBin = iolist_to_binary(Sql),
    Result =
        case Params of
            [] -> esqlite3:q(Conn, SqlBin);
            _ -> esqlite3:q(Conn, SqlBin, Params)
        end,
    normalize_esqlite(Result).

normalize_esqlite({error, _} = Err) ->
    Err;
normalize_esqlite(Rows) when is_list(Rows) ->
    {ok, [normalize_row(R) || R <- Rows]};
normalize_esqlite(Other) ->
    {error, {unexpected_esqlite_result, Other}}.

normalize_row(Row) when is_tuple(Row) -> Row;
normalize_row(Row) when is_list(Row) -> list_to_tuple(Row);
normalize_row(Other) -> {Other}.

run_with_tx(Conn, Fun, Server) ->
    case esqlite3:exec(Conn, <<"BEGIN IMMEDIATE">>) of
        ok ->
            erlang:put(?TX_KEY(Server), Conn),
            try Fun(Server) of
                {error, _} = Err ->
                    _ = esqlite3:exec(Conn, <<"ROLLBACK">>),
                    Err;
                Result ->
                    case esqlite3:exec(Conn, <<"COMMIT">>) of
                        ok ->
                            Result;
                        {error, CommitErr} ->
                            _ = esqlite3:exec(Conn, <<"ROLLBACK">>),
                            {error, CommitErr}
                    end
            catch
                Class:CatchReason:Stack ->
                    _ = esqlite3:exec(Conn, <<"ROLLBACK">>),
                    {error, {Class, CatchReason, Stack}}
            after
                erlang:erase(?TX_KEY(Server))
            end;
        {error, BeginErr} ->
            {error, BeginErr}
    end.

do_cas(Conn, Expected) ->
    Sql = <<
        "UPDATE config_meta "
        "SET config_generation = config_generation + 1 "
        "WHERE id = 1 AND config_generation = ?"
    >>,
    case normalize_esqlite(esqlite3:q(Conn, Sql, [Expected])) of
        {ok, _} ->
            case esqlite3:changes(Conn) of
                1 ->
                    case
                        do_query(
                            Conn,
                            <<"SELECT config_generation FROM config_meta WHERE id = 1">>,
                            []
                        )
                    of
                        {ok, [{NewGen}]} when is_integer(NewGen) -> {ok, NewGen};
                        {ok, Other} -> {error, {unexpected_cas_row, Other}};
                        {error, _} = Err -> Err
                    end;
                0 ->
                    {error, conflict};
                N ->
                    {error, {unexpected_cas_changes, N}}
            end;
        {error, _} = Err ->
            Err
    end.

do_migrate(Conn) ->
    case ensure_migrations_table(Conn) of
        ok ->
            case migration_files() of
                {ok, Files} -> apply_migrations(Conn, Files);
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

ensure_migrations_table(Conn) ->
    Sql = <<
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        "version TEXT PRIMARY KEY, "
        "applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')))"
    >>,
    case esqlite3:exec(Conn, Sql) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

migration_files() ->
    case migrations_dir() of
        {ok, Dir} ->
            case file:list_dir(Dir) of
                {ok, Names} ->
                    SqlNames = lists:sort([N || N <- Names, lists:suffix(".sql", N)]),
                    {ok, [{filename:basename(N, ".sql"), filename:join(Dir, N)} || N <- SqlNames]};
                {error, Reason} ->
                    {error, {list_migrations, Reason}}
            end;
        {error, _} = Err ->
            Err
    end.

migrations_dir() ->
    case code:priv_dir(janus_core) of
        {error, bad_name} ->
            Candidate = filename:join(["apps", "janus_core", "priv", "migrations", "sqlite"]),
            case filelib:is_dir(Candidate) of
                true -> {ok, Candidate};
                false -> {error, {priv_dir, janus_core}}
            end;
        Priv ->
            {ok, filename:join([Priv, "migrations", "sqlite"])}
    end.

apply_migrations(_Conn, []) ->
    ok;
apply_migrations(Conn, [{Version, Path} | Rest]) ->
    case is_applied(Conn, Version) of
        {ok, true} ->
            apply_migrations(Conn, Rest);
        {ok, false} ->
            case file:read_file(Path) of
                {ok, Sql} ->
                    case apply_one(Conn, Version, Sql) of
                        ok -> apply_migrations(Conn, Rest);
                        {error, _} = Err -> Err
                    end;
                {error, Reason} ->
                    {error, {read_migration, Path, Reason}}
            end;
        {error, _} = Err ->
            Err
    end.

is_applied(Conn, Version) ->
    case
        do_query(
            Conn,
            <<"SELECT 1 FROM schema_migrations WHERE version = ?">>,
            [list_to_binary(Version)]
        )
    of
        {ok, [_ | _]} -> {ok, true};
        {ok, []} -> {ok, false};
        {error, _} = Err -> Err
    end.

apply_one(Conn, Version, Sql) ->
    case esqlite3:exec(Conn, <<"BEGIN IMMEDIATE">>) of
        ok ->
            case exec_script(Conn, Sql) of
                ok ->
                    Ins = <<"INSERT INTO schema_migrations (version) VALUES (?)">>,
                    case normalize_esqlite(esqlite3:q(Conn, Ins, [list_to_binary(Version)])) of
                        {ok, _} ->
                            case esqlite3:exec(Conn, <<"COMMIT">>) of
                                ok ->
                                    ok;
                                {error, Reason} ->
                                    _ = esqlite3:exec(Conn, <<"ROLLBACK">>),
                                    {error, Reason}
                            end;
                        {error, Reason} ->
                            _ = esqlite3:exec(Conn, <<"ROLLBACK">>),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    _ = esqlite3:exec(Conn, <<"ROLLBACK">>),
                    {error, {migration_failed, Version, Reason}}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

exec_script(Conn, Sql) when is_binary(Sql) ->
    exec_stmts(Conn, split_sql(Sql)).

exec_stmts(_Conn, []) ->
    ok;
exec_stmts(Conn, [Stmt | Rest]) ->
    case esqlite3:exec(Conn, Stmt) of
        ok -> exec_stmts(Conn, Rest);
        {error, _} = Err -> Err
    end.

split_sql(Sql) ->
    Parts = binary:split(Sql, <<";">>, [global]),
    lists:filtermap(
        fun(Part) ->
            Trimmed = strip_leading_sql_comments(trim_sql(Part)),
            case Trimmed of
                <<>> -> false;
                _ -> {true, Trimmed}
            end
        end,
        Parts
    ).

strip_leading_sql_comments(<<>>) ->
    <<>>;
strip_leading_sql_comments(<<"--", Rest/binary>>) ->
    case binary:split(Rest, <<"\n">>) of
        [_Comment, After] -> strip_leading_sql_comments(trim_sql_left(After));
        [_] -> <<>>
    end;
strip_leading_sql_comments(Bin) ->
    Bin.

trim_sql(Bin) -> trim_sql_right(trim_sql_left(Bin)).

trim_sql_left(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    trim_sql_left(Rest);
trim_sql_left(Bin) ->
    Bin.

trim_sql_right(<<>>) ->
    <<>>;
trim_sql_right(Bin) ->
    Size = byte_size(Bin),
    case binary:at(Bin, Size - 1) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            trim_sql_right(binary:part(Bin, 0, Size - 1));
        _ ->
            Bin
    end.
