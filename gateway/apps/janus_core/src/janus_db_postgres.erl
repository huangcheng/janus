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

%% Cluster-wide advisory-lock key for the migration pass. Arbitrary
%% constant, but it must never change: 0x4A414E55534442 = "JANUSDB".
-define(MIGRATION_LOCK_KEY, 16#4A414E55534442).

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
        {ok, [{Gen}]} ->
            case to_non_neg_int(Gen) of
                {ok, N} -> {ok, N};
                error -> {error, {unexpected_generation_row, [{Gen}]}}
            end;
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
    %% Explicit short connect timeout (epgsql's default, spelled out so a
    %% missing Postgres fails boot fast instead of hanging).
    CO0 = maps:merge(#{timeout => 5000}, maps:with(Keys, Opts)),
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
            warn_default_credentials(User, Pass),
            Port =
                case maps:get(port, U, undefined) of
                    undefined -> 5432;
                    P -> P
                end,
            Base = #{
                host => Host,
                port => Port,
                username => User,
                password => Pass,
                database => path_to_db(maps:get(path, U, "/janus"))
            },
            case url_tls_opts(Host, maps:get(query, U, undefined)) of
                {ok, TlsOpts} -> {ok, maps:merge(Base, TlsOpts)};
                {error, _} = Err -> Err
            end;
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

%% TLS (H1): honour `sslmode` from the URL query instead of silently
%% dropping it. `require` encrypts without verifying the server
%% certificate (libpq semantics). `verify-ca`/`verify-full` need a CA
%% file from JANUS_DB_SSL_CA; without one, boot fails with a clear error
%% rather than downgrading to plaintext.
url_tls_opts(Host, Query) ->
    case sslmode(Query) of
        {ok, disable} ->
            {ok, #{}};
        {ok, require} ->
            {ok, #{ssl => true}};
        {ok, verify_ca} ->
            verify_tls_opts([]);
        {ok, verify_full} ->
            verify_tls_opts([
                {server_name_indication, Host},
                {customize_hostname_check, [
                    {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                ]}
            ]);
        {error, _} = Err ->
            Err
    end.

verify_tls_opts(ExtraOpts) ->
    case tls_ca_file() of
        {ok, CaFile} ->
            {ok, #{
                ssl => true,
                ssl_opts => [{verify, verify_peer}, {cacertfile, CaFile} | ExtraOpts]
            }};
        {error, _} = Err ->
            Err
    end.

tls_ca_file() ->
    case os:getenv("JANUS_DB_SSL_CA") of
        CaFile when is_list(CaFile), CaFile =/= false, CaFile =/= "" ->
            case filelib:is_regular(CaFile) of
                true -> {ok, CaFile};
                false -> {error, {db_tls_ca_not_found, CaFile}}
            end;
        _ ->
            {error, {db_tls_ca_missing, "set JANUS_DB_SSL_CA for sslmode=verify-ca/verify-full"}}
    end.

sslmode(undefined) ->
    {ok, disable};
sslmode(Query) ->
    Params = query_params(Query),
    case string:lowercase(string:trim(proplists:get_value("sslmode", Params, ""))) of
        "" ->
            {ok, disable};
        "disable" ->
            {ok, disable};
        "allow" ->
            {ok, disable};
        "prefer" ->
            logger:warning(#{
                what => janus_db_sslmode_prefer,
                detail =>
                    "sslmode=prefer is treated as plaintext: epgsql cannot fall "
                    "back to TLS after a failed handshake. Use sslmode=require."
            }),
            {ok, disable};
        "require" ->
            {ok, require};
        "verify-ca" ->
            {ok, verify_ca};
        "verify-full" ->
            {ok, verify_full};
        Other ->
            {error, {invalid_sslmode, Other}}
    end.

query_params(undefined) ->
    [];
query_params(Query) when is_binary(Query) ->
    query_params(binary_to_list(Query));
query_params(Query) when is_list(Query) ->
    [query_pair(Part) || Part <- string:split(Query, "&", all), Part =/= ""].

query_pair(Part) ->
    case string:split(Part, "=", leading) of
        [Key, Value] -> {uri_decode(Key), uri_decode(Value)};
        [Key] -> {uri_decode(Key), ""}
    end.

warn_default_credentials("janus", "janus") ->
    logger:warning(#{
        what => janus_db_local_credentials,
        detail =>
            "JANUS_DB_URL resolves to the built-in janus/janus credentials; "
            "this is only safe for the documented local Postgres."
    });
warn_default_credentials(_User, "") ->
    logger:warning(#{
        what => janus_db_missing_password,
        detail => "JANUS_DB_URL carries no password; the Postgres server must allow that."
    });
warn_default_credentials(_User, _Pass) ->
    ok.

do_query(Conn, Sql, Params) ->
    %% Always use equery so integer/boolean columns keep typed values.
    %% squery returns every cell as a binary (breaks get_generation/1, etc.).
    %% App SQL is SQLite-shaped (`?` binds); rewrite to `$1..$N` for epgsql.
    %% Callers that already pass `$N` are unchanged (no `?` left to rewrite).
    SqlBin = rewrite_placeholders(iolist_to_binary(Sql)),
    normalize_epgsql(epgsql:equery(Conn, SqlBin, Params)).

%% Convert SQLite `?` placeholders to Postgres `$1`, `$2`, ...
%%
%% The scan is lexical, not a SQL parser: `?` inside string literals,
%% quoted identifiers, dollar-quoted bodies and comments is copied
%% verbatim. A `?` in operator position (the jsonb existence operator,
%% `meta ? 'key'`) is also left alone; only binds in value position are
%% numbered. Leaving an operator `?` untouched is safe because Postgres
%% understands it; rewriting it would shift every later bind.
rewrite_placeholders(Sql) when is_binary(Sql) ->
    iolist_to_binary(lists:reverse(rp(binary_to_list(Sql), 1, none, []))).

%% rp(Chars, NextBind, PrevToken, Acc)
%%   PrevToken: none | kw | op | value — the class of the last
%%   significant token. A `?` after a value is the jsonb operator.
rp([], _N, _Prev, Acc) ->
    Acc;
rp([$? | Rest], N, value, Acc) ->
    rp(Rest, N, op, ["?" | Acc]);
rp([$? | Rest], N, _Prev, Acc) ->
    rp(Rest, N + 1, value, [["$", integer_to_list(N)] | Acc]);
rp([$-, $- | Rest], N, Prev, Acc) ->
    {Seg, Rest1} = take_line_comment(Rest),
    rp(Rest1, N, Prev, [["--" | Seg] | Acc]);
rp([$/, $* | Rest], N, Prev, Acc) ->
    {Seg, Rest1} = take_block_comment(Rest, 1),
    rp(Rest1, N, Prev, [["/*" | Seg] | Acc]);
rp([$' | Rest], N, _Prev, Acc) ->
    {Seg, Rest1} = take_quoted(Rest, $'),
    rp(Rest1, N, value, [[$' | Seg] | Acc]);
rp([$" | Rest], N, _Prev, Acc) ->
    {Seg, Rest1} = take_quoted(Rest, $"),
    rp(Rest1, N, value, [[$" | Seg] | Acc]);
rp([$$ | Rest], N, _Prev, Acc) ->
    case dollar_quote(Rest) of
        {ok, Delim, Body} ->
            {Seg, Rest1} = take_until(Body, Delim),
            rp(Rest1, N, value, [[Delim, Seg] | Acc]);
        error ->
            {Word, Rest1} = take_word(Rest, []),
            rp(Rest1, N, value, [[$$ | Word] | Acc])
    end;
rp([C | Rest], N, Prev, Acc) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    rp(Rest, N, Prev, [[C] | Acc]);
rp([C | _] = Chars, N, _Prev, Acc) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $_
->
    {Word, Rest} = take_word(Chars, []),
    Prev1 =
        case sql_keyword(Word) of
            true -> kw;
            false -> value
        end,
    rp(Rest, N, Prev1, [Word | Acc]);
rp([C | Rest], N, _Prev, Acc) when C =:= $(; C =:= $[; C =:= ${ ->
    rp(Rest, N, op, [[C] | Acc]);
rp([C | Rest], N, _Prev, Acc) when C =:= $); C =:= $]; C =:= $} ->
    rp(Rest, N, value, [[C] | Acc]);
rp([C | Rest], N, _Prev, Acc) when C =:= $,; C =:= $; ->
    rp(Rest, N, op, [[C] | Acc]);
rp([C | Rest], N, _Prev, Acc) when
    C =:= $=;
    C =:= $<;
    C =:= $>;
    C =:= $!;
    C =:= $~;
    C =:= $+;
    C =:= $-;
    C =:= $*;
    C =:= $/;
    C =:= $%;
    C =:= $^;
    C =:= $|;
    C =:= $&;
    C =:= $:;
    C =:= $@;
    C =:= $#;
    C =:= $.
->
    rp(Rest, N, op, [[C] | Acc]);
rp([C | Rest], N, Prev, Acc) ->
    rp(Rest, N, Prev, [[C] | Acc]).

take_word([C | Rest], Acc) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $_
->
    take_word(Rest, [C | Acc]);
take_word(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%% Copy a quoted run (after the opening quote) up to and including the
%% closing quote. A doubled quote is an escaped quote, not a terminator.
take_quoted([Q, Q | Rest], Q) ->
    {More, Rest1} = take_quoted(Rest, Q),
    {[Q, Q | More], Rest1};
take_quoted([Q | Rest], Q) ->
    {[Q], Rest};
take_quoted([C | Rest], Q) ->
    {More, Rest1} = take_quoted(Rest, Q),
    {[C | More], Rest1};
take_quoted([], _Q) ->
    {[], []}.

take_line_comment([$\n | Rest]) ->
    {[$\n], Rest};
take_line_comment([C | Rest]) ->
    {More, Rest1} = take_line_comment(Rest),
    {[C | More], Rest1};
take_line_comment([]) ->
    {[], []}.

%% Postgres block comments nest.
take_block_comment([$/, $* | Rest], Depth) ->
    {More, Rest1} = take_block_comment(Rest, Depth + 1),
    {[$/, $* | More], Rest1};
take_block_comment([$*, $/ | Rest], 1) ->
    {[$*, $/], Rest};
take_block_comment([$*, $/ | Rest], Depth) ->
    {More, Rest1} = take_block_comment(Rest, Depth - 1),
    {[$*, $/ | More], Rest1};
take_block_comment([C | Rest], Depth) ->
    {More, Rest1} = take_block_comment(Rest, Depth),
    {[C | More], Rest1};
take_block_comment([], _Depth) ->
    {[], []}.

%% `$$...$$`, `$tag$...$tag$`. Rest starts after the opening `$`.
dollar_quote([$$ | Rest]) ->
    {ok, "$$", Rest};
dollar_quote([C | _] = Chars) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        C =:= $_
->
    {Tag, Rest} = take_word(Chars, []),
    case Rest of
        [$$ | Rest1] -> {ok, "$" ++ Tag ++ "$", Rest1};
        _ -> error
    end;
dollar_quote(_) ->
    error.

take_until([], _Delim) ->
    {[], []};
take_until(Chars, Delim) ->
    case lists:prefix(Delim, Chars) of
        true ->
            {Delim, lists:nthtail(length(Delim), Chars)};
        false ->
            [C | Rest] = Chars,
            {More, Rest1} = take_until(Rest, Delim),
            {[C | More], Rest1}
    end.

%% Keywords after which an expression (and therefore a bind) may start.
%% A bare word not in this list is an identifier/value, so a following
%% `?` is the jsonb operator. The list is deliberately limited to
%% reserved words (plus BY) so it cannot shadow a real column name.
sql_keyword(Word) ->
    lists:member(
        string:uppercase(Word),
        [
            "SELECT",
            "FROM",
            "WHERE",
            "AND",
            "OR",
            "NOT",
            "IN",
            "IS",
            "LIKE",
            "ILIKE",
            "BETWEEN",
            "THEN",
            "ELSE",
            "WHEN",
            "VALUES",
            "SET",
            "RETURNING",
            "HAVING",
            "ON",
            "USING",
            "LIMIT",
            "OFFSET",
            "BY",
            "CASE",
            "DISTINCT",
            "ALL",
            "ANY",
            "SOME",
            "EXISTS",
            "CAST",
            "TO",
            "FOR"
        ]
    ).

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
        {ok, [{NewGen}]} ->
            case to_non_neg_int(NewGen) of
                {ok, N} -> {ok, N};
                error -> {error, {unexpected_cas_row, [{NewGen}]}}
            end;
        {ok, []} -> {error, conflict};
        {error, _} = Err -> Err;
        Other -> {error, {unexpected_cas_row, Other}}
    end.

%% epgsql squery returns int8/bigint as binaries; equery usually returns integers.
to_non_neg_int(N) when is_integer(N), N >= 0 -> {ok, N};
to_non_neg_int(B) when is_binary(B) ->
    try
        N = binary_to_integer(B),
        case N >= 0 of
            true -> {ok, N};
            false -> error
        end
    catch
        _:_ -> error
    end;
to_non_neg_int(_) ->
    error.

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
    %% Two un-migrated nodes booting together must not race the
    %% check-then-apply pass (or the CREATE TABLE IF NOT EXISTS probe):
    %% serialize the whole pass on a session advisory lock. The lock is
    %% released on unlock or when the connection dies.
    case advisory_lock(Conn) of
        ok ->
            try
                do_migrate_locked(Conn)
            after
                _ = advisory_unlock(Conn)
            end;
        {error, _} = Err ->
            Err
    end.

do_migrate_locked(Conn) ->
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
    %% is_applied is checked with the advisory lock already held (see
    %% do_migrate/1), so a second node sees the first node's rows.
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

advisory_lock(Conn) ->
    case do_query(Conn, <<"SELECT pg_advisory_lock($1)">>, [?MIGRATION_LOCK_KEY]) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.

advisory_unlock(Conn) ->
    case do_query(Conn, <<"SELECT pg_advisory_unlock($1)">>, [?MIGRATION_LOCK_KEY]) of
        {ok, _} -> ok;
        {error, _} = Err -> Err
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

rewrite_placeholders_test() ->
    ?assertEqual(
        <<"SELECT a FROM t WHERE x = $1 AND y = $2">>,
        rewrite_placeholders(<<"SELECT a FROM t WHERE x = ? AND y = ?">>)
    ),
    ?assertEqual(
        <<"SELECT 1 FROM schema_migrations WHERE version = $1">>,
        rewrite_placeholders(<<"SELECT 1 FROM schema_migrations WHERE version = $1">>)
    ).

%% A literal `?` must not consume a bind number, and the jsonb
%% existence operator must stay an operator (M2).
rewrite_placeholders_literal_test() ->
    ?assertEqual(
        <<"SELECT a FROM t WHERE name = 'why?' AND x = $1">>,
        rewrite_placeholders(<<"SELECT a FROM t WHERE name = 'why?' AND x = ?">>)
    ),
    ?assertEqual(
        <<"SELECT a FROM t WHERE meta ? 'k' AND x = $1">>,
        rewrite_placeholders(<<"SELECT a FROM t WHERE meta ? 'k' AND x = ?">>)
    ),
    ?assertEqual(
        <<"SELECT a FROM t WHERE x = $1 -- ?\nAND y = $2">>,
        rewrite_placeholders(<<"SELECT a FROM t WHERE x = ? -- ?\nAND y = ?">>)
    ),
    ?assertEqual(
        <<"SELECT $$?$$, a FROM t WHERE x = $1">>,
        rewrite_placeholders(<<"SELECT $$?$$, a FROM t WHERE x = ?">>)
    ),
    ?assertEqual(
        <<"SELECT a FROM t WHERE x = $1 AND y = $1">>,
        rewrite_placeholders(<<"SELECT a FROM t WHERE x = ? AND y = $1">>)
    ).

-endif.
