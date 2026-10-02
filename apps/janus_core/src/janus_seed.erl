%%%-------------------------------------------------------------------
%%% @doc CLI seed from a local JSON file (never commit secrets).
%%%
%%% Default path: `data/seed.providers.json` or `JANUS_SEED_PATH`.
%%% Requires `JANUS_SECRETS_KEY` + `JANUS_API_KEY_PEPPER`.
%%%
%%% Providers may list multiple `keys` — Janus LB does weighted RR +
%%% per-key cool-down inside the provider (fault tolerance).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_seed).

-export([from_file/0, from_file/1]).

-spec from_file() -> ok | {error, term()}.
from_file() ->
    Path =
        case os:getenv("JANUS_SEED_PATH") of
            false -> "data/seed.providers.json";
            "" -> "data/seed.providers.json";
            P -> P
        end,
    from_file(Path).

-spec from_file(file:filename_all()) -> ok | {error, term()}.
from_file(Path0) ->
    Path = to_list(Path0),
    case file:read_file(Path) of
        {ok, Bin} ->
            case thoas:decode(Bin) of
                {ok, Map} when is_map(Map) -> apply_seed(Map);
                {error, Reason} -> {error, {json, Reason}}
            end;
        {error, Reason} ->
            {error, {read, Path, Reason}}
    end.

apply_seed(Map) ->
    case ensure_db() of
        ok ->
            case map_get(Map, providers, undefined) of
                undefined ->
                    {error, missing_providers};
                Providers when is_list(Providers) ->
                    lists:foreach(fun seed_provider/1, Providers),
                    maybe_seed_agent_key(Map),
                    case janus_db_conn:get_generation() of
                        {ok, Gen} ->
                            case janus_db_conn:cas_generation(Gen) of
                                {ok, _} ->
                                    _ = catch janus_config:reload(),
                                    ok;
                                {error, _} = Err ->
                                    Err
                            end;
                        {error, _} = Err ->
                            Err
                    end
            end;
        {error, _} = Err ->
            Err
    end.

ensure_db() ->
    case erlang:whereis(janus_db_conn) of
        Pid when is_pid(Pid) -> ok;
        undefined -> {error, db_not_started}
    end.

seed_provider(P) when is_map(P) ->
    Name = bin(map_get(P, name)),
    Base = bin(map_get(P, base_url)),
    Proto = bin(map_get(P, protocol, <<"openai_chat">>)),
    Keys = map_get(P, keys, []),
    Models = map_get(P, models, []),
    ProviderId = upsert_provider(Name, Base, Proto),
    lists:foreach(fun(K) -> insert_provider_key(ProviderId, K) end, Keys),
    lists:foreach(
        fun(ModelName0) ->
            ModelId = upsert_model(bin(ModelName0)),
            ensure_route(ModelId, ProviderId)
        end,
        Models
    ),
    logger:info(#{
        what => janus_seed_provider,
        name => Name,
        provider_id => ProviderId,
        keys => length(Keys),
        models => length(Models)
    }),
    ok.

upsert_provider(Name, Base, Proto) ->
    case q(<<"SELECT id FROM providers WHERE name = ?">>, [Name]) of
        {ok, [{Id}]} ->
            _ = q(
                    <<"UPDATE providers SET base_url = ?, protocol = ?, enabled = 1 WHERE id = ?">>,
                    [Base, Proto, Id]
                ),
            Id;
        {ok, []} ->
            case q(
                     <<"INSERT INTO providers (name, base_url, protocol, enabled) VALUES (?, ?, ?, 1)">>,
                     [Name, Base, Proto]
                 ) of
                {ok, _} -> ok;
                {error, Reason} -> error({insert_provider, Reason})
            end,
            case q(<<"SELECT id FROM providers WHERE name = ?">>, [Name]) of
                {ok, [{Id}]} -> Id;
                Other -> error({provider_id_missing, Other})
            end;
        {error, Reason} ->
            error({upsert_provider, Reason})
    end.

insert_provider_key(ProviderId, Raw0) ->
    Raw = bin(Raw0),
    case janus_secrets:encrypt(Raw) of
        {ok, Cipher} ->
            {KeyId, _} = janus_crypto_env:active_secrets_key(),
            case q(
                     <<"INSERT INTO provider_keys "
                       "(provider_id, secret_ciphertext, key_id, weight, enabled) "
                       "VALUES (?, ?, ?, 1, 1)">>,
                     [ProviderId, Cipher, KeyId]
                 ) of
                {ok, _} -> ok;
                {error, Reason} -> error({insert_provider_key, Reason})
            end;
        {error, Reason} ->
            error({encrypt, Reason})
    end.

upsert_model(Name) ->
    case q(<<"SELECT id FROM models WHERE name = ?">>, [Name]) of
        {ok, [{Id}]} ->
            Id;
        {ok, []} ->
            _ = q(<<"INSERT INTO models (name, enabled) VALUES (?, 1)">>, [Name]),
            case q(<<"SELECT id FROM models WHERE name = ?">>, [Name]) of
                {ok, [{Id}]} -> Id;
                Other -> error({model_id_missing, Other})
            end;
        {error, Reason} ->
            error({upsert_model, Reason})
    end.

ensure_route(ModelId, ProviderId) ->
    case q(
             <<"SELECT 1 FROM model_routes WHERE model_id = ? AND provider_id = ?">>,
             [ModelId, ProviderId]
         ) of
        {ok, [_ | _]} ->
            ok;
        {ok, []} ->
            case q(
                     <<"INSERT INTO model_routes "
                       "(model_id, provider_id, upstream_model_id, weight, priority, enabled) "
                       "VALUES (?, ?, NULL, 1, 0, 1)">>,
                     [ModelId, ProviderId]
                 ) of
                {ok, _} -> ok;
                {error, Reason} -> error({insert_route, Reason})
            end;
        {error, Reason} ->
            error({ensure_route, Reason})
    end.

maybe_seed_agent_key(Map) ->
    case map_get(Map, agent_api_key, undefined) of
        undefined ->
            ok;
        Raw0 ->
            Raw = bin(Raw0),
            {Prefix, Hash} = janus_api_keys:hash_key(Raw),
            case q(<<"SELECT id FROM api_keys WHERE prefix = ?">>, [Prefix]) of
                {ok, [_ | _]} ->
                    ok;
                {ok, []} ->
                    _ = q(
                            <<"INSERT INTO api_keys (prefix, key_hash, enabled) VALUES (?, ?, 1)">>,
                            [Prefix, Hash]
                        ),
                    ok;
                {error, Reason} ->
                    error({seed_agent_key, Reason})
            end
    end.

map_get(Map, Key) ->
    map_get(Map, Key, undefined).

map_get(Map, Key, Default) when is_map(Map), is_atom(Key) ->
    BinKey = atom_to_binary(Key, utf8),
    case maps:find(BinKey, Map) of
        {ok, V} -> V;
        error -> maps:get(Key, Map, Default)
    end;
map_get(Map, Key, Default) when is_map(Map), is_binary(Key) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> Default
    end.

%% Convert `?` placeholders to `$N` for Postgres; leave for SQLite.
q(Sql0, Params) ->
    Sql =
        case janus_db_conn:backend() of
            sqlite -> Sql0;
            postgres -> rewrite_pg(Sql0)
        end,
    janus_db_conn:query(Sql, Params).

rewrite_pg(Sql) ->
    rewrite_pg(binary_to_list(iolist_to_binary(Sql)), 1, []).

rewrite_pg([], _N, Acc) ->
    list_to_binary(lists:reverse(Acc));
rewrite_pg([$? | Rest], N, Acc) ->
    Frag = "$" ++ integer_to_list(N),
    rewrite_pg(Rest, N + 1, lists:reverse(Frag) ++ Acc);
rewrite_pg([C | Rest], N, Acc) ->
    rewrite_pg(Rest, N, [C | Acc]).

bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> list_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(P) when is_list(P) -> P;
to_list(P) when is_binary(P) -> binary_to_list(P).
