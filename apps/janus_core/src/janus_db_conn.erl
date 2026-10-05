%%%-------------------------------------------------------------------
%%% @doc Thin gen_server facade over {@link janus_db_postgres} /
%%% {@link janus_db_sqlite} backend processes (`Conn` = backend pid).
%%%
%%% Started from {@link janus_core_sup} before {@link janus_config}.
%%% Runs {@link migrate/0} once on boot. Postgres: `LISTEN janus_config`
%%% with notifications forwarded to `janus_config`.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_db_conn).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    stop/0,
    query/1,
    query/2,
    with_tx/1,
    with_transaction/1,
    listen/1,
    migrate/0,
    get_generation/0,
    cas_generation/1,
    fetch_catalog/0,
    backend/0,
    conn/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(NOTIFY_CHANNEL, <<"janus_config">>).

-record(state, {
    mod :: module(),
    dialect :: janus_db:backend(),
    conn :: janus_db:conn()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

-spec query(iodata()) -> {ok, [term()]} | {error, term()}.
query(Sql) ->
    query(Sql, []).

-spec query(iodata(), [term()]) -> {ok, [term()]} | {error, term()}.
query(Sql, Params) ->
    gen_server:call(?SERVER, {query, Sql, Params}, infinity).

-spec with_tx(fun((janus_db:conn()) -> Result)) -> Result | {error, term()} when
    Result :: term().
with_tx(Fun) when is_function(Fun, 1) ->
    gen_server:call(?SERVER, {with_tx, Fun}, infinity).

-spec with_transaction(fun((janus_db:conn()) -> Result)) -> Result | {error, term()} when
    Result :: term().
with_transaction(Fun) ->
    with_tx(Fun).

-spec listen(atom() | binary() | string()) -> ok | {error, term()}.
listen(Channel) ->
    gen_server:call(?SERVER, {listen, Channel}).

-spec migrate() -> ok | {error, term()}.
migrate() ->
    gen_server:call(?SERVER, migrate, infinity).

-spec get_generation() -> {ok, non_neg_integer()} | {error, term()}.
get_generation() ->
    gen_server:call(?SERVER, get_generation).

-spec cas_generation(non_neg_integer()) ->
    {ok, non_neg_integer()} | {error, conflict | term()}.
cas_generation(Expected) ->
    gen_server:call(?SERVER, {cas_generation, Expected}).

-spec fetch_catalog() -> {ok, map()} | {error, term()}.
fetch_catalog() ->
    gen_server:call(?SERVER, fetch_catalog, infinity).

-spec backend() -> janus_db:backend().
backend() ->
    gen_server:call(?SERVER, backend).

-spec conn() -> {ok, module(), janus_db:conn()}.
conn() ->
    gen_server:call(?SERVER, conn).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    Dialect = maps:get(backend, Opts, janus_db:select_backend()),
    Mod = janus_db:backend_module(),
    ConnOpts = connect_opts(Dialect, Opts),
    case Mod:start_link(ConnOpts) of
        {ok, Pid} ->
            link(Pid),
            case Mod:migrate(Pid) of
                ok ->
                    ok = maybe_listen(Dialect, Mod, Pid),
                    logger:info(#{what => janus_db_conn_started, backend => Dialect}),
                    {ok, #state{mod = Mod, dialect = Dialect, conn = Pid}};
                {error, Reason} ->
                    {stop, {migrate_failed, Reason}}
            end;
        {error, Reason} ->
            {stop, {backend_start_failed, Reason}}
    end.

handle_call({query, Sql, Params}, _From, #state{mod = M, conn = C} = State) ->
    {reply, M:query(C, Sql, Params), State};
handle_call({with_tx, Fun}, _From, #state{mod = M, conn = C} = State) ->
    {reply, M:with_tx(C, Fun), State};
handle_call({listen, Channel}, _From, #state{mod = M, conn = C} = State) ->
    {reply, M:listen(C, normalize_channel(Channel)), State};
handle_call(migrate, _From, #state{mod = M, conn = C} = State) ->
    {reply, M:migrate(C), State};
handle_call(get_generation, _From, #state{mod = M, conn = C} = State) ->
    {reply, M:get_generation(C), State};
handle_call({cas_generation, Expected}, _From, #state{mod = M, conn = C} = State) ->
    {reply, M:cas_generation(C, Expected), State};
handle_call(fetch_catalog, _From, State) ->
    {reply, do_fetch_catalog(State), State};
handle_call(backend, _From, #state{dialect = D} = State) ->
    {reply, D, State};
handle_call(conn, _From, #state{mod = M, conn = C} = State) ->
    {reply, {ok, M, C}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, #state{conn = Pid} = State) ->
    {stop, {backend_exit, Reason}, State};
handle_info({epgsql, Conn, {notification, Channel, Payload}}, State) ->
    forward_notify({epgsql, Conn, {notification, Channel, Payload}}),
    {noreply, State};
handle_info({epgsql, Conn, {notification, BePid, Channel, Payload}}, State) ->
    forward_notify({epgsql, Conn, {notification, BePid, Channel, Payload}}),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn = Pid}) when is_pid(Pid) ->
    catch gen_server:stop(Pid),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

connect_opts(postgres, Opts) ->
    Base = maps:merge(janus_db:postgres_opts(), #{async => self()}),
    maps:merge(Base, maps:with([url, host, port, username, password, database, async], Opts));
connect_opts(sqlite, Opts) ->
    Path = maps:get(path, Opts, maps:get(sqlite_path, Opts, janus_db:sqlite_path())),
    #{path => Path}.

maybe_listen(postgres, Mod, Pid) ->
    Mod:listen(Pid, ?NOTIFY_CHANNEL);
maybe_listen(sqlite, _Mod, _Pid) ->
    ok.

normalize_channel(Ch) when is_binary(Ch) -> Ch;
normalize_channel(Ch) when is_atom(Ch) -> atom_to_binary(Ch, utf8);
normalize_channel(Ch) when is_list(Ch) -> list_to_binary(Ch).

forward_notify(Msg) ->
    case erlang:whereis(janus_config) of
        undefined -> ok;
        Pid when is_pid(Pid) -> Pid ! Msg
    end.

do_fetch_catalog(#state{mod = M, conn = C}) ->
    Queries = [
        {models, <<"SELECT id, name, enabled FROM models ORDER BY id">>, [id, name, enabled]},
        {model_routes,
            <<
                "SELECT model_id, provider_id, upstream_model_id, weight, priority, enabled "
                "FROM model_routes ORDER BY model_id, priority, provider_id"
            >>,
            [model_id, provider_id, upstream_model_id, weight, priority, enabled]},
        {providers, <<"SELECT id, name, base_url, protocol, enabled FROM providers ORDER BY id">>, [
                id, name, base_url, protocol, enabled
            ]},
        {provider_keys,
            <<
                "SELECT id, provider_id, secret_ciphertext, key_id, weight, enabled "
                "FROM provider_keys ORDER BY provider_id, id"
            >>,
            [id, provider_id, secret_ciphertext, key_id, weight, enabled]},
        {api_keys, <<"SELECT id, prefix, key_hash, enabled FROM api_keys ORDER BY id">>, [
            id, prefix, key_hash, enabled
        ]},
        {api_key_models,
            <<"SELECT api_key_id, model_id FROM api_key_models ORDER BY api_key_id, model_id">>, [
                api_key_id, model_id
            ]},
        {provider_models,
            <<
                "SELECT pm.id, pm.provider_id, pm.name, pm.enabled, pm.meta "
                "FROM provider_models pm ORDER BY pm.provider_id, pm.name"
            >>,
            [id, provider_id, name, enabled, meta]},
        {settings, <<"SELECT key, value FROM settings">>, [key, value]},
        %% Entitlement carrier (dashboard-owned tables). POSTGRES-ONLY
        %% by design: on SQLite (or a dashboard that never ran) these
        %% queries fail and the carrier stays empty = fully fail-open.
        %% Per-spec TTL windows are enforced HERE — reads are fresh by
        %% construction; nothing re-checks checked_at gateway-side.
        {optional, key_entitlements,
            <<
                "SELECT ke.provider_key_id, ke.model_name, ke.status, pk.provider_id "
                "FROM key_entitlements ke "
                "JOIN provider_keys pk ON pk.id = ke.provider_key_id "
                "WHERE (ke.status IN ('deny','broken') AND ke.checked_at > now() - interval '24 hours') "
                "OR (ke.status = 'balance' AND ke.checked_at > now() - interval '1 hour')"
            >>,
            [provider_key_id, model_name, status, provider_id]},
        {optional, entitlement_codes,
            <<
                "SELECT provider, match_status, code_keyword, outcome "
                "FROM entitlement_codes"
            >>,
            [provider, match_status, code_keyword, outcome]}
    ],
    fetch_all(M, C, Queries, #{}).

fetch_all(_M, _C, [], Acc) ->
    {ok, Acc};
fetch_all(M, C, [{optional, Key, Sql, Fields} | Rest], Acc) ->
    case M:query(C, Sql, []) of
        {ok, Rows} ->
            fetch_all(M, C, Rest, Acc#{Key => [row_map(Fields, R) || R <- Rows]});
        {error, Reason} ->
            %% Undefined table is a defined state (dashboard has not
            %% created the matrix yet): log ONCE per fetch, ship empty.
            logger:warning(#{
                what => janus_entitlement_carrier_missing,
                key => Key,
                reason => Reason
            }),
            fetch_all(M, C, Rest, Acc#{Key => []})
    end;
fetch_all(M, C, [{Key, Sql, Fields} | Rest], Acc) ->
    case M:query(C, Sql, []) of
        {ok, Rows} ->
            fetch_all(M, C, Rest, Acc#{Key => [row_map(Fields, R) || R <- Rows]});
        {error, _} = Err ->
            Err
    end.

row_map(_Fields, Row) when is_map(Row) ->
    Row;
row_map(Fields, Row) when is_tuple(Row) ->
    maps:from_list(lists:zip(Fields, tuple_to_list(Row)));
row_map(Fields, Row) when is_list(Row) ->
    row_map(Fields, list_to_tuple(Row));
row_map(_Fields, Row) ->
    #{value => Row}.
