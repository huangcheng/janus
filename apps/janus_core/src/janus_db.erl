%%%-------------------------------------------------------------------
%%% @doc Janus DB behaviour and backend selection helpers.
%%%
%%% Backends: {@link janus_db_postgres}, {@link janus_db_sqlite}.
%%%
%%% ```erlang
%%% Mod = janus_db:backend_module(),
%%% {ok, Conn} = Mod:start_link(#{}),
%%% ok = Mod:migrate(Conn),
%%% {ok, Gen} = Mod:get_generation(Conn).
%%% ```
%%% @end
%%%-------------------------------------------------------------------
-module(janus_db).

-export([select_backend/0, sqlite_path/0, postgres_opts/0, backend_module/0]).

-export_type([backend/0, conn/0]).

-type backend() :: postgres | sqlite.
-type conn() :: pid().

-callback start_link(Opts :: map()) -> {ok, pid()} | {error, term()}.
-callback migrate(Conn :: conn()) -> ok | {error, term()}.
-callback query(Conn :: conn(), Sql :: iodata(), Params :: [term()]) ->
    {ok, Rows :: [term()]} | {error, term()}.
-callback with_tx(Conn :: conn(), fun((conn()) -> Result)) ->
    Result | {error, term()}.
-callback listen(Conn :: conn(), Channel :: binary()) -> ok | {error, term()}.
-callback get_generation(Conn :: conn()) ->
    {ok, non_neg_integer()} | {error, term()}.
-callback cas_generation(Conn :: conn(), Expected :: non_neg_integer()) ->
    {ok, NewGen :: non_neg_integer()} | {error, conflict | term()}.

-spec select_backend() -> backend().
select_backend() ->
    case application:get_env(janus, db, #{}) of
        #{backend := postgres} ->
            postgres;
        #{backend := sqlite} ->
            sqlite;
        _ ->
            case {os:getenv("JANUS_DB_URL"), os:getenv("JANUS_DB_HOST")} of
                {Url, _} when is_list(Url), Url =/= false -> postgres;
                {_, Host} when is_list(Host), Host =/= false -> postgres;
                _ -> sqlite
            end
    end.

-spec sqlite_path() -> file:filename_all().
sqlite_path() ->
    case os:getenv("JANUS_SQLITE_PATH") of
        Path when is_list(Path), Path =/= false -> Path;
        _ ->
            case application:get_env(janus, db, #{}) of
                #{sqlite_path := P} -> P;
                _ -> "data/janus.db"
            end
    end.

-spec postgres_opts() -> map().
postgres_opts() ->
    case os:getenv("JANUS_DB_URL") of
        Url when is_list(Url), Url =/= false ->
            #{url => list_to_binary(Url)};
        _ ->
            #{
                host => getenv_default("JANUS_DB_HOST", "127.0.0.1"),
                port => list_to_integer(getenv_default("JANUS_DB_PORT", "5432")),
                username => getenv_default("JANUS_DB_USER", "janus"),
                password => getenv_default("JANUS_DB_PASSWORD", "janus"),
                database => getenv_default("JANUS_DB_NAME", "janus")
            }
    end.

-spec backend_module() -> module().
backend_module() ->
    case select_backend() of
        postgres -> janus_db_postgres;
        sqlite -> janus_db_sqlite
    end.

getenv_default(Key, Default) ->
    case os:getenv(Key) of
        Val when is_list(Val), Val =/= false -> Val;
        _ -> Default
    end.
