%%%-------------------------------------------------------------------
%%% @doc DB facade for the admin console. All queries go through
%%% {@link janus_db_conn:query/2}; `?` placeholders are rewritten to
%%% `$N` on Postgres. Mutations validate inputs, then the caller bumps
%%% the config generation (see {@link bump_generation/0}) so the
%%% serving catalog hot-reloads.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_admin_store).

-export([
    %% reads
    providers/0, provider_keys/1, provider_key_counts/0, models/0, routes/0,
    agent_keys/0, grants/0, model_name/1, provider_name/1,
    %% provider mutations
    add_provider/3, set_provider_enabled/2, delete_provider/1,
    add_provider_key/3, set_provider_key_enabled/2, delete_provider_key/1,
    %% model / route mutations
    add_model/1, set_model_enabled/2,
    add_route/5, set_route_enabled/3, delete_route/2,
    %% agent key mutations
    create_agent_key/1, set_agent_key_enabled/2, delete_agent_key/1,
    %% catalog
    bump_generation/0
]).

-define(PROTOCOLS, [<<"openai_chat">>, <<"anthropic_messages">>, <<"openai_responses">>]).

%%%===================================================================
%%% Reads
%%%===================================================================

-spec providers() -> {ok, [map()]} | {error, term()}.
providers() ->
    qmap(
        <<"SELECT id, name, base_url, protocol, enabled FROM providers ORDER BY id">>,
        [],
        [id, name, base_url, protocol, enabled],
        #{enabled => fun truthy/1}
    ).

-spec provider_keys(integer()) -> {ok, [map()]} | {error, term()}.
provider_keys(ProviderId) ->
    qmap(
        <<"SELECT id, key_id, weight, enabled FROM provider_keys "
          "WHERE provider_id = ? ORDER BY id">>,
        [ProviderId],
        [id, key_id, weight, enabled],
        #{enabled => fun truthy/1}
    ).

-spec provider_key_counts() -> {ok, #{integer() => non_neg_integer()}} | {error, term()}.
provider_key_counts() ->
    case q(<<"SELECT provider_id, COUNT(*) FROM provider_keys "
            "GROUP BY provider_id">>, []) of
        {ok, Rows} ->
            {ok, maps:from_list([{Pid, Cnt} || {Pid, Cnt} <- Rows])};
        {error, Reason} ->
            {error, Reason}
    end.

-spec models() -> {ok, [map()]} | {error, term()}.
models() ->
    qmap(
        <<"SELECT id, name, enabled FROM models ORDER BY id">>,
        [],
        [id, name, enabled],
        #{enabled => fun truthy/1}
    ).

-spec routes() -> {ok, [map()]} | {error, term()}.
routes() ->
    qmap(
        <<"SELECT model_id, provider_id, upstream_model_id, weight, priority, enabled "
          "FROM model_routes ORDER BY model_id, priority, provider_id">>,
        [],
        [model_id, provider_id, upstream_model_id, weight, priority, enabled],
        #{enabled => fun truthy/1}
    ).

-spec agent_keys() -> {ok, [map()]} | {error, term()}.
agent_keys() ->
    qmap(
        <<"SELECT id, prefix, enabled, created_at FROM api_keys ORDER BY id">>,
        [],
        [id, prefix, enabled, created_at],
        #{enabled => fun truthy/1}
    ).

-spec grants() -> {ok, [map()]} | {error, term()}.
grants() ->
    qmap(
        <<"SELECT api_key_id, model_id FROM api_key_models ORDER BY api_key_id, model_id">>,
        [],
        [api_key_id, model_id],
        #{}
    ).

-spec model_name(integer()) -> {ok, binary()} | {error, not_found}.
model_name(ModelId) ->
    one_name(<<"SELECT name FROM models WHERE id = ?">>, ModelId).

-spec provider_name(integer()) -> {ok, binary()} | {error, not_found}.
provider_name(ProviderId) ->
    one_name(<<"SELECT name FROM providers WHERE id = ?">>, ProviderId).

%%%===================================================================
%%% Provider mutations
%%%===================================================================

-spec add_provider(binary(), binary(), binary()) ->
    {ok, integer()} | {error, invalid | duplicate | term()}.
add_provider(Name, BaseUrl, Protocol) when
    is_binary(Name), Name =/= <<>>, is_binary(BaseUrl), is_binary(Protocol)
->
    case lists:member(Protocol, ?PROTOCOLS) of
        false -> {error, invalid_protocol};
        true ->
            case http_url(BaseUrl) of
                false -> {error, invalid_url};
                true ->
                    case q(<<"INSERT INTO providers (name, base_url, protocol, enabled) "
                            "VALUES (?, ?, ?, 1)">>, [Name, BaseUrl, Protocol]) of
                        {ok, _} ->
                            case q(<<"SELECT id FROM providers WHERE name = ?">>, [Name]) of
                                {ok, [{Id}]} -> {ok, Id};
                                _ -> {error, lookup_failed}
                            end;
                        {error, _} -> {error, duplicate}
                    end
            end
    end;
add_provider(_, _, _) ->
    {error, invalid}.

-spec set_provider_enabled(integer(), boolean()) -> ok | {error, term()}.
set_provider_enabled(Id, Enabled) when is_boolean(Enabled) ->
    exec(<<"UPDATE providers SET enabled = ? WHERE id = ?">>,
        [bool_int(Enabled), Id]).

-spec delete_provider(integer()) -> ok | {error, term()}.
delete_provider(Id) ->
    exec(<<"DELETE FROM providers WHERE id = ?">>, [Id]).

-spec add_provider_key(integer(), binary(), pos_integer()) ->
    {ok, integer()} | {error, invalid | encrypt_unavailable | term()}.
add_provider_key(ProviderId, Secret, Weight)
    when is_integer(ProviderId), is_binary(Secret), Secret =/= <<>> ->
    case is_pos_int(Weight) of
        false -> {error, invalid};
        true ->
            case janus_secrets:encrypt(Secret) of
                {ok, Cipher} ->
                    {KeyId, _} = janus_crypto_env:active_secrets_key(),
                    case q(<<"INSERT INTO provider_keys "
                            "(provider_id, secret_ciphertext, key_id, weight, enabled) "
                            "VALUES (?, ?, ?, ?, 1)">>,
                        [ProviderId, Cipher, KeyId, Weight]) of
                        {ok, _} ->
                            case q(<<"SELECT id FROM provider_keys WHERE provider_id = ? "
                                    "ORDER BY id DESC LIMIT 1">>, [ProviderId]) of
                                {ok, [{Id}]} -> {ok, Id};
                                _ -> {ok, 0}
                            end;
                        {error, R} -> {error, R}
                    end;
                {error, Reason} ->
                    {error, {encrypt_unavailable, Reason}}
            end
    end;
add_provider_key(_, _, _) ->
    {error, invalid}.

-spec set_provider_key_enabled(integer(), boolean()) -> ok | {error, term()}.
set_provider_key_enabled(Id, Enabled) when is_boolean(Enabled) ->
    exec(<<"UPDATE provider_keys SET enabled = ? WHERE id = ?">>,
        [bool_int(Enabled), Id]).

-spec delete_provider_key(integer()) -> ok | {error, term()}.
delete_provider_key(Id) ->
    exec(<<"DELETE FROM provider_keys WHERE id = ?">>, [Id]).

%%%===================================================================
%%% Model / route mutations
%%%===================================================================

-spec add_model(binary()) -> {ok, integer()} | {error, invalid | duplicate | term()}.
add_model(Name) when is_binary(Name), Name =/= <<>> ->
    case q(<<"INSERT INTO models (name, enabled) VALUES (?, 1)">>, [Name]) of
        {ok, _} ->
            case q(<<"SELECT id FROM models WHERE name = ?">>, [Name]) of
                {ok, [{Id}]} -> {ok, Id};
                _ -> {error, lookup_failed}
            end;
        {error, _} ->
            {error, duplicate}
    end;
add_model(_) ->
    {error, invalid}.

-spec set_model_enabled(integer(), boolean()) -> ok | {error, term()}.
set_model_enabled(Id, Enabled) when is_boolean(Enabled) ->
    exec(<<"UPDATE models SET enabled = ? WHERE id = ?">>, [bool_int(Enabled), Id]).

-spec add_route(integer(), integer(), binary() | undefined, pos_integer(), integer()) ->
    ok | {error, invalid | duplicate | term()}.
add_route(ModelId, ProviderId, Upstream, Weight, Priority)
    when is_integer(ModelId), is_integer(ProviderId) ->
    UpstreamNorm = norm_optional(Upstream),
    case is_pos_int(Weight) andalso is_int(Priority) of
        false -> {error, invalid};
        true ->
            exec(<<"INSERT INTO model_routes "
                   "(model_id, provider_id, upstream_model_id, weight, priority, enabled) "
                   "VALUES (?, ?, ?, ?, ?, 1)">>,
                [ModelId, ProviderId, UpstreamNorm, Weight, Priority])
    end;
add_route(_, _, _, _, _) ->
    {error, invalid}.

-spec set_route_enabled(integer(), integer(), boolean()) -> ok | {error, term()}.
set_route_enabled(ModelId, ProviderId, Enabled) when is_boolean(Enabled) ->
    exec(<<"UPDATE model_routes SET enabled = ? WHERE model_id = ? AND provider_id = ?">>,
        [bool_int(Enabled), ModelId, ProviderId]).

-spec delete_route(integer(), integer()) -> ok | {error, term()}.
delete_route(ModelId, ProviderId) ->
    exec(<<"DELETE FROM model_routes WHERE model_id = ? AND provider_id = ?">>,
        [ModelId, ProviderId]).

%%%===================================================================
%%% Agent key mutations
%%%===================================================================

-spec create_agent_key([integer()]) ->
    {ok, Key :: binary(), Prefix :: binary(), integer()} | {error, invalid | term()}.
create_agent_key(ModelIds) when is_list(ModelIds), ModelIds =/= [] ->
    case lists:all(fun is_pos_int/1, ModelIds) of
        false -> {error, invalid};
        true ->
            Key = gen_key(),
            {Prefix, Hash} = janus_api_keys:hash_key(Key),
            case q(<<"INSERT INTO api_keys (prefix, key_hash, enabled) VALUES (?, ?, 1)">>,
                [Prefix, Hash]) of
                {ok, _} ->
                    case q(<<"SELECT id FROM api_keys WHERE key_hash = ?">>, [Hash]) of
                        {ok, [{Id}]} ->
                            lists:foreach(
                                fun(Mid) ->
                                    {ok, _} = q(
                                        <<"INSERT INTO api_key_models "
                                          "(api_key_id, model_id) VALUES (?, ?)">>,
                                        [Id, Mid]
                                    )
                                end,
                                ModelIds
                            ),
                            {ok, Key, Prefix, Id};
                        Other ->
                            {error, {lookup_failed, Other}}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end;
create_agent_key(_) ->
    {error, invalid}.

-spec set_agent_key_enabled(integer(), boolean()) -> ok | {error, term()}.
set_agent_key_enabled(Id, Enabled) when is_boolean(Enabled) ->
    exec(<<"UPDATE api_keys SET enabled = ? WHERE id = ?">>, [bool_int(Enabled), Id]).

-spec delete_agent_key(integer()) -> ok | {error, term()}.
delete_agent_key(Id) ->
    exec(<<"DELETE FROM api_keys WHERE id = ?">>, [Id]).

%%%===================================================================
%%% Catalog
%%%===================================================================

-spec bump_generation() -> {ok, non_neg_integer()} | {error, term()}.
bump_generation() ->
    bump_generation(3).

bump_generation(0) ->
    {error, generation_cas_exhausted};
bump_generation(N) ->
    case janus_db_conn:get_generation() of
        {ok, Gen} ->
            case janus_db_conn:cas_generation(Gen) of
                {ok, NewGen} ->
                    _ = catch janus_config:reload(),
                    {ok, NewGen};
                {error, conflict} ->
                    bump_generation(N - 1);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

q(Sql, Params) ->
    case janus_db_conn:backend() of
        postgres -> janus_db_conn:query(rewrite_pg(Sql), Params);
        _ -> janus_db_conn:query(Sql, Params)
    end.

exec(Sql, Params) ->
    case q(Sql, Params) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

qmap(Sql, Params, Fields, Coerce) ->
    case q(Sql, Params) of
        {ok, Rows} ->
            {ok, [row_map(Fields, Coerce, R) || R <- Rows]};
        {error, Reason} ->
            {error, Reason}
    end.

row_map(Fields, Coerce, Row) when is_tuple(Row) ->
    maps:from_list([
        {K, coerce(Coerce, K, V)}
     || {K, V} <- lists:zip(Fields, tuple_to_list(Row))
    ]);
row_map(Fields, _Coerce, Row) when is_list(Row) ->
    row_map(Fields, #{}, list_to_tuple(Row));
row_map(_, _, _) ->
    #{}.

coerce(Coerce, K, V) ->
    case maps:find(K, Coerce) of
        {ok, F} -> F(V);
        error -> V
    end.

one_name(Sql, Id) ->
    case q(Sql, [Id]) of
        {ok, [{Name}]} -> {ok, Name};
        _ -> {error, not_found}
    end.

gen_key() ->
    Rand = b64url(crypto:strong_rand_bytes(24)),
    <<Head:5/binary, _/binary>> = Rand,
    <<"sk-", Head/binary, "-", Rand/binary>>.

b64url(Bin) ->
    B64 = base64:encode(Bin),
    << <<(b64c(C))/binary>> || <<C>> <= B64, C =/= $= >>.

b64c($+) -> <<"-">>;
b64c($/) -> <<"_">>;
b64c(C) -> <<C>>.

http_url(<<"http://", _/binary>>) -> true;
http_url(<<"https://", _/binary>>) -> true;
http_url(_) -> false.

norm_optional(undefined) -> null;
norm_optional(<<>>) -> null;
norm_optional(B) when is_binary(B) -> B;
norm_optional(L) when is_list(L) ->
    case unicode:characters_to_binary(L) of
        B when is_binary(B) -> norm_optional(B);
        _ -> null
    end;
norm_optional(_) -> null.

is_pos_int(N) when is_integer(N), N > 0 -> true;
is_pos_int(N) when is_binary(N) ->
    try binary_to_integer(N) > 0 catch _:_ -> false end;
is_pos_int(_) -> false.

is_int(N) when is_integer(N) -> true;
is_int(N) when is_binary(N) ->
    try begin _ = binary_to_integer(N), true end catch _:_ -> false end;
is_int(_) -> false.

bool_int(true) -> 1;
bool_int(false) -> 0.

truthy(true) -> true;
truthy(1) -> true;
truthy(<<"t">>) -> true;
truthy(<<"true">>) -> true;
truthy(false) -> false;
truthy(0) -> false;
truthy(<<"f">>) -> false;
truthy(<<"false">>) -> false;
truthy(null) -> true;
truthy(undefined) -> true;
truthy(_) -> true.

rewrite_pg(Sql) ->
    rewrite_pg(binary_to_list(iolist_to_binary(Sql)), 1, []).

rewrite_pg([], _N, Acc) ->
    list_to_binary(lists:reverse(Acc));
rewrite_pg([$? | Rest], N, Acc) ->
    Frag = "$" ++ integer_to_list(N),
    rewrite_pg(Rest, N + 1, lists:reverse(Frag) ++ Acc);
rewrite_pg([C | Rest], N, Acc) ->
    rewrite_pg(Rest, N, [C | Acc]).

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

gen_key_test() ->
    K1 = gen_key(),
    K2 = gen_key(),
    ?assertEqual(<<"sk-">>, binary:part(K1, 0, 3)),
    %% prefixes (first 8 bytes) are unique across fresh keys
    ?assertNotEqual(janus_api_keys:prefix(K1), janus_api_keys:prefix(K2)).

url_validation_test() ->
    ?assertEqual(true, http_url(<<"https://api.example.com/v1">>)),
    ?assertEqual(true, http_url(<<"http://localhost:9200">>)),
    ?assertEqual(false, http_url(<<"ftp://x">>)),
    ?assertEqual(false, http_url(<<"api.example.com">>)).

rewrite_pg_test() ->
    ?assertEqual(
        <<"SELECT a FROM t WHERE x = $1 AND y = $2">>,
        rewrite_pg(<<"SELECT a FROM t WHERE x = ? AND y = ?">>)
    ).

-endif.
