%%%-------------------------------------------------------------------
%%% @doc Shared dialect-aware migration runner.
%%%
%%% Files: `priv/migrations/NNN_name.{postgres|sqlite}.sql`
%%% Version = basename without dialect suffix (e.g. `001_init`).
%%%
%%% Invocation:
%%% ```
%%% ok = janus_migrate:run().
%%% ok = janus_migrate:run(postgres, Conn).
%%% ok = janus_db:migrate(Conn).   %% delegates here
%%% ok = janus_db_conn:migrate().  %% via owned connection
%%% ```
%%% @end
%%%-------------------------------------------------------------------
-module(janus_migrate).

-export([run/0, run/2, migrations_dir/0]).

-type dialect() :: postgres | sqlite.
-type conn() :: term().

-spec run() -> ok | {error, term()}.
run() ->
    case erlang:whereis(janus_db_conn) of
        Pid when is_pid(Pid) ->
            janus_db_conn:migrate();
        undefined ->
            Dialect = janus_db:select_backend(),
            Mod = janus_db:backend_module(),
            Opts =
                case Dialect of
                    postgres ->
                        janus_db:postgres_opts();
                    sqlite ->
                        #{path => janus_db:sqlite_path()}
                end,
            case Mod:start_link(Opts) of
                {ok, Conn} ->
                    try
                        Mod:migrate(Conn)
                    after
                        catch gen_server:stop(Conn)
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

-spec run(dialect(), conn()) -> ok | {error, term()}.
run(Dialect, Conn) when Dialect =:= postgres; Dialect =:= sqlite ->
    Mod = backend_mod(Dialect),
    case ensure_migrations_table(Mod, Conn, Dialect) of
        ok ->
            case list_migration_files(Dialect) of
                {ok, Files} -> apply_all(Mod, Conn, Dialect, Files);
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec migrations_dir() -> file:filename_all().
migrations_dir() ->
    case code:priv_dir(janus_core) of
        {error, _} ->
            filename:join(["apps", "janus_core", "priv", "migrations"]);
        Priv ->
            filename:join(Priv, "migrations")
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

backend_mod(postgres) -> janus_db_postgres;
backend_mod(sqlite) -> janus_db_sqlite.

ensure_migrations_table(Mod, Conn, postgres) ->
    Sql =
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        "version TEXT PRIMARY KEY, "
        "applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())",
    case Mod:execute(Conn, Sql, []) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end;
ensure_migrations_table(Mod, Conn, sqlite) ->
    Sql =
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        "version TEXT PRIMARY KEY, "
        "applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')))",
    case Mod:execute(Conn, Sql, []) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.

list_migration_files(Dialect) ->
    Dir = migrations_dir(),
    case filelib:is_dir(Dir) of
        false ->
            {error, {migrations_dir_missing, Dir}};
        true ->
            Suffix = suffix(Dialect),
            Files = lists:sort(filelib:wildcard(filename:join(Dir, "*" ++ Suffix))),
            {ok, [{F, filename:basename(F, Suffix)} || F <- Files]}
    end.

suffix(postgres) -> ".postgres.sql";
suffix(sqlite) -> ".sqlite.sql".

apply_all(_Mod, _Conn, _Dialect, []) ->
    ok;
apply_all(Mod, Conn, Dialect, [{Path, Version} | Rest]) ->
    case already_applied(Mod, Conn, Dialect, Version) of
        {ok, true} ->
            apply_all(Mod, Conn, Dialect, Rest);
        {ok, false} ->
            case apply_one(Mod, Conn, Dialect, Path, Version) of
                ok -> apply_all(Mod, Conn, Dialect, Rest);
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

already_applied(Mod, Conn, postgres, Version) ->
    case Mod:query(Conn, "SELECT 1 FROM schema_migrations WHERE version = $1", [Version]) of
        {ok, []} -> {ok, false};
        {ok, _} -> {ok, true};
        {error, _} = Err -> Err
    end;
already_applied(Mod, Conn, sqlite, Version) ->
    case Mod:query(Conn, "SELECT 1 FROM schema_migrations WHERE version = ?", [Version]) of
        {ok, []} -> {ok, false};
        {ok, _} -> {ok, true};
        {error, _} = Err -> Err
    end.

apply_one(Mod, Conn, Dialect, Path, Version) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            logger:info(#{
                what => janus_migrate_apply,
                dialect => Dialect,
                version => Version,
                file => Path
            }),
            Fun = fun(C) ->
                case Mod:exec_script(C, Bin) of
                    ok ->
                        case record_version(Mod, C, Dialect, Version) of
                            ok -> ok;
                            {error, Reason} -> error({record_version, Reason})
                        end;
                    {error, Reason} ->
                        error({migration_failed, Version, Reason})
                end
            end,
            case Mod:with_transaction(Conn, Fun) of
                {ok, ok} -> ok;
                {ok, _} -> ok;
                {error, _} = Err -> Err
            end;
        {error, Reason} ->
            {error, {read_migration, Path, Reason}}
    end.

record_version(Mod, Conn, postgres, Version) ->
    case Mod:execute(Conn, "INSERT INTO schema_migrations (version) VALUES ($1)", [Version]) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end;
record_version(Mod, Conn, sqlite, Version) ->
    case Mod:execute(Conn, "INSERT INTO schema_migrations (version) VALUES (?)", [Version]) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.
