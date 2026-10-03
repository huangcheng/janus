%%%-------------------------------------------------------------------
%%% @doc Postgres backend for {@link janus_db} (epgsql).
%%% Conn is the gen_server pid from start_link/1.
%%% Successful cas_generation/2 issues NOTIFY janus_config.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_db_postgres).
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

-record(state, {conn :: pid()}).

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
        Conn when is_pid(Conn) ->
            do_query(Conn, Sql, Params);
        _ ->
            call(Server, {query, Sql, Params})
    end.

-spec with_tx(pid(), fun((pid()) -> Result)) -> Result | {error, term()}.
with_tx(Server, Fun) when is_function(Fun, 1) ->
    call(Server, {with_tx, Fun}).

-spec listen(pid(), binary()) -> ok | {error, term()}.
listen(Server, Channel) when is_binary(Channel) ->
    call(Server, {listen, Channel}).

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
                Raw when is_pid(Raw) -> do_cas(Raw, Expected);
                _ -> {error, missing_tx_conn}
            end
        end)
    of
        {ok, NewGen} = Ok when is_integer(NewGen) ->
            _ = call(Server, {notify, integer_to_binary(NewGen)}),
            Ok;
        {error, _} = Err ->
            Err;
        Other ->
            {error, {unexpected_cas_result, Other}}
    end.

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts0) ->
    process_flag(trap_exit, true),
    Opts = maps:merge(janus_db:postgres_opts(), Opts0),
    case connect(Opts) of
        {ok, Conn} ->
            link(Conn),
            {ok, #state{conn = Conn}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(migrate, _From, State = #state{conn = Conn}) ->
    {reply, do_migrate(Conn), State};
handle_call({query, Sql, Params}, _From, State = #state{conn = Conn}) ->
    {reply, do_query(Conn, Sql, Params), State};
handle_call({with_tx, Fun}, _From, State = #state{conn = Conn}) ->
    {reply, run_with_tx(Conn, Fun, self()), State};
handle_call({listen, Channel}, _From, State = #state{conn = Conn}) ->
    {reply, do_listen(Conn, Channel), State};
handle_call({notify, Payload}, _From, State = #state{conn = Conn}) ->
    {reply, do_notify(Conn, Payload), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'EXIT', Conn, Reason}, State = #state{conn = Conn}) ->
    {stop, {db_connection_exit, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn = Conn}) ->
    catch epgsql:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% internal
%%%===================================================================

call(Server, Req) ->
    gen_server:call(Server, Req, infinity).

connect(#{url := Url} = Opts) ->
    case parse_url(Url) of
        {ok, Parsed} -> connect(maps:merge(Parsed, maps:without([url], Opts)));
        {error, _} = Err -> Err
    end;
connect(Opts) ->
    Host = maps:get(host, Opts, "127.0.0.1"),
    Keys = [
        username, password, database, port, ssl, ssl_opts, tcp_opts, timeout, async, codecs, nulls
    ],
    CO0 = maps:with(Keys, Opts),
    CO1 =
        case maps:is_key(username, CO0) of
            true -> CO0;
            false -> CO0#{username => "janus"}
        end,
    CO2 = maps:map(fun ensure_connect_value/2, CO1#{host => Host}),
    case epgsql:connect(CO2) of
        {ok, Conn} = Ok ->
            Async = maps:get(async, Opts, self()),
            _ = epgsql:set_notice_receiver(Conn, Async),
            Ok;
        {error, _} = Err ->
            Err
    end.

ensure_connect_value(port, V) when is_integer(V) -> V;
ensure_connect_value(port, V) when is_list(V) -> list_to_integer(V);
ensure_connect_value(port, V) when is_binary(V) -> binary_to_integer(V);
ensure_connect_value(K, V) when
    K =:= async;
    K =:= ssl;
    K =:= ssl_opts;
    K =:= tcp_opts;
    K =:= timeout;
    K =:= codecs;
    K =:= nulls
->
    V;
ensure_connect_value(_K, V) when is_binary(V) -> binary_to_list(V);
ensure_connect_value(_K, V) when is_list(V) -> V;
ensure_connect_value(_K, V) ->
    V.

parse_url(Url) when is_binary(Url) -> parse_url(binary_to_list(Url));
parse_url(Url) when is_list(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := Host} = U when
            Scheme =:= "postgres"; Scheme =:= "postgresql"
        ->
            {User, Pass} = split_userinfo(maps:get(userinfo, U, "")),
            Port =
                case maps:get(port, U, undefined) of
                    undefined -> 5432;
                    P -> P
                end,
            {ok, #{
                host => Host,
                port => Port,
                username => User,
                password => Pass,
                database => path_to_db(maps:get(path, U, "/janus"))
            }};
        #{scheme := _} ->
            {error, {invalid_db_url, Url}};
        {error, Reason, _} ->
            {error, {invalid_db_url, Reason}};
        Other ->
            {error, {invalid_db_url, Other}}
    end.

path_to_db("/" ++ Rest) ->
    case Rest of
        "" -> "janus";
        Db -> Db
    end;
path_to_db(Path) when is_list(Path) ->
    path_to_db("/" ++ string:trim(Path, leading, "/"));
path_to_db(Path) when is_binary(Path) ->
    path_to_db(binary_to_list(Path)).

split_userinfo("") ->
    {"janus", "janus"};
split_userinfo(UserInfo) when is_list(UserInfo) ->
    case string:split(UserInfo, ":", leading) of
        [U] -> {uri_decode(U), ""};
        [U, P] -> {uri_decode(U), uri_decode(P)}
    end;
split_userinfo(UserInfo) when is_binary(UserInfo) ->
    split_userinfo(binary_to_list(UserInfo)).

uri_decode(S) ->
    case uri_string:percent_decode(S) of
        Decoded when is_list(Decoded) -> Decoded;
        Decoded when is_binary(Decoded) -> binary_to_list(Decoded);
        {error, _, _} -> S
    end.

do_query(Conn, Sql, Params) ->
    SqlBin = iolist_to_binary(Sql),
    Result =
        case Params of
            [] -> epgsql:squery(Conn, SqlBin);
            _ -> epgsql:equery(Conn, SqlBin, Params)
        end,
    normalize_epgsql(Result).

normalize_epgsql({ok, _Columns, Rows}) ->
    {ok, Rows};
normalize_epgsql({ok, _Count}) ->
    {ok, []};
normalize_epgsql({ok, _Count, _Columns, Rows}) ->
    {ok, Rows};
normalize_epgsql({error, Reason}) ->
    {error, Reason};
normalize_epgsql(List) when is_list(List) ->
    case lists:search(fun is_error_tuple/1, List) of
        {value, {error, Reason}} ->
            {error, Reason};
        false ->
            {ok,
                lists:flatten([
                    case R of
                        {ok, _Cols, Rows} -> Rows;
                        {ok, _Count, _Cols, Rows} -> Rows;
                        _ -> []
                    end
                 || R <- List
                ])}
    end;
normalize_epgsql(Other) ->
    {error, {unexpected_epgsql_result, Other}}.

is_error_tuple({error, _}) -> true;
is_error_tuple(_) -> false.

run_with_tx(Conn, Fun, Server) ->
    case epgsql:squery(Conn, <<"BEGIN">>) of
        {ok, [], []} ->
            erlang:put(?TX_KEY(Server), Conn),
            try Fun(Server) of
                {error, _} = Err ->
                    _ = epgsql:squery(Conn, <<"ROLLBACK">>),
                    Err;
                Result ->
                    case epgsql:squery(Conn, <<"COMMIT">>) of
                        {ok, [], []} ->
                            Result;
                        {error, CommitErr} ->
                            _ = epgsql:squery(Conn, <<"ROLLBACK">>),
                            {error, CommitErr};
                        Other ->
                            {error, {unexpected_commit_result, Other}}
                    end
            catch
                Class:CatchReason:Stack ->
                    _ = epgsql:squery(Conn, <<"ROLLBACK">>),
                    {error, {Class, CatchReason, Stack}}
            after
                erlang:erase(?TX_KEY(Server))
            end;
        {error, BeginErr} ->
            {error, BeginErr};
        Other ->
            {error, {unexpected_begin_result, Other}}
    end.

do_cas(Conn, Expected) ->
    Sql = <<
        "UPDATE config_meta "
        "SET config_generation = config_generation + 1 "
        "WHERE id = 1 AND config_generation = $1 "
        "RETURNING config_generation"
    >>,
    case do_query(Conn, Sql, [Expected]) of
        {ok, [{NewGen}]} when is_integer(NewGen) -> {ok, NewGen};
        {ok, []} -> {error, conflict};
        {error, _} = Err -> Err;
        Other -> {error, {unexpected_cas_row, Other}}
    end.

do_notify(Conn, Payload) when is_binary(Payload) ->
    case re:run(Payload, <<"^[0-9]+$">>, [{capture, none}]) of
        match ->
            case epgsql:squery(Conn, [<<"NOTIFY janus_config, '">>, Payload, <<"'">>]) of
                {ok, [], []} -> ok;
                {error, Reason} -> {error, Reason};
                Other -> {error, {unexpected_notify_result, Other}}
            end;
        nomatch ->
            {error, invalid_notify_payload}
    end.

do_listen(Conn, Channel) ->
    case validate_channel(Channel) of
        ok ->
            case epgsql:squery(Conn, [<<"LISTEN ">>, Channel]) of
                {ok, [], []} -> ok;
                {ok, _, _} -> ok;
                {error, Reason} -> {error, Reason};
                Other -> {error, {unexpected_listen_result, Other}}
            end;
        {error, _} = Err ->
            Err
    end.

validate_channel(Channel) when is_binary(Channel) ->
    case re:run(Channel, <<"^[A-Za-z_][A-Za-z0-9_]*$">>, [{capture, none}]) of
        match -> ok;
        nomatch -> {error, invalid_channel}
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
        "applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW())"
    >>,
    case do_query(Conn, Sql, []) of
        {ok, _} -> ok;
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
            Candidate = filename:join(["apps", "janus_core", "priv", "migrations", "postgres"]),
            case filelib:is_dir(Candidate) of
                true -> {ok, Candidate};
                false -> {error, {priv_dir, janus_core}}
            end;
        Priv ->
            {ok, filename:join([Priv, "migrations", "postgres"])}
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
            <<"SELECT 1 FROM schema_migrations WHERE version = $1">>,
            [list_to_binary(Version)]
        )
    of
        {ok, [_ | _]} -> {ok, true};
        {ok, []} -> {ok, false};
        {error, _} = Err -> Err
    end.

apply_one(Conn, Version, Sql) ->
    case epgsql:squery(Conn, <<"BEGIN">>) of
        {ok, [], []} ->
            case normalize_epgsql(epgsql:squery(Conn, Sql)) of
                {ok, _} ->
                    Ins = <<"INSERT INTO schema_migrations (version) VALUES ($1)">>,
                    case do_query(Conn, Ins, [list_to_binary(Version)]) of
                        {ok, _} ->
                            case epgsql:squery(Conn, <<"COMMIT">>) of
                                {ok, [], []} ->
                                    ok;
                                {error, Reason} ->
                                    _ = epgsql:squery(Conn, <<"ROLLBACK">>),
                                    {error, Reason};
                                Other ->
                                    {error, {unexpected_commit_result, Other}}
                            end;
                        {error, Reason} ->
                            _ = epgsql:squery(Conn, <<"ROLLBACK">>),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    _ = epgsql:squery(Conn, <<"ROLLBACK">>),
                    {error, {migration_failed, Version, Reason}}
            end;
        {error, Reason} ->
            {error, Reason};
        Other ->
            {error, {unexpected_begin_result, Other}}
    end.
