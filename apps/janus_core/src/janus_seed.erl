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

-export([from_file/0, from_file/1, sanitize_error/1, redact_stack/1]).

-define(PROTOCOLS, [<<"openai_chat">>, <<"anthropic_messages">>, <<"openai_responses">>]).

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
                {ok, _} -> {error, json_not_object};
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
                    try
                        Validated = [validate_provider(P) || P <- Providers],
                        AgentKey = validate_agent_key(Map),
                        lists:foreach(fun apply_provider/1, Validated),
                        maybe_seed_agent_key(AgentKey),
                        bump_generation()
                    catch
                        Class:Reason:Stack ->
                            {error, {Class, sanitize_error(Reason), redact_stack(Stack)}}
                    end;
                _Other ->
                    {error, bad_providers}
            end;
        {error, _} = Err ->
            Err
    end.

bump_generation() ->
    bump_generation(3).

bump_generation(0) ->
    {error, generation_cas_exhausted};
bump_generation(N) when N > 0 ->
    case janus_db_conn:get_generation() of
        {ok, Gen} ->
            case janus_db_conn:cas_generation(Gen) of
                {ok, _} ->
                    _ = catch janus_config:reload(),
                    ok;
                {error, conflict} ->
                    timer:sleep(50 * (4 - N)),
                    bump_generation(N - 1);
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

ensure_db() ->
    case erlang:whereis(janus_db_conn) of
        Pid when is_pid(Pid) -> ok;
        undefined -> {error, db_not_started}
    end.

validate_provider(P) when is_map(P) ->
    Name = required_bin(P, name),
    Base = required_bin(P, base_url),
    Proto0 = map_get(P, protocol, <<"openai_chat">>),
    Proto =
        try
            bin(Proto0)
        catch
            error:bad_field_value -> error({bad_protocol, Proto0})
        end,
    case lists:member(Proto, ?PROTOCOLS) of
        true -> ok;
        false -> error({bad_protocol, Proto})
    end,
    Keys0 = map_get(P, keys, undefined),
    Models0 = map_get(P, models, undefined),
    case Keys0 of
        undefined -> error({missing_field, keys});
        [] -> error({empty_field, keys});
        _ when is_list(Keys0) -> ok;
        _ -> error({bad_provider_lists, Name})
    end,
    case Models0 of
        undefined -> error({missing_field, models});
        [] -> error({empty_field, models});
        _ when is_list(Models0) -> ok;
        _ -> error({bad_provider_lists, Name})
    end,
    Keys = [required_secret(K, key) || K <- Keys0],
    Models = [required_bin_value(M, model) || M <- Models0],
    #{name => Name, base_url => Base, protocol => Proto, keys => Keys, models => Models};
validate_provider(_Other) ->
    error(bad_provider).

validate_agent_key(Map) ->
    case map_get(Map, agent_api_key, undefined) of
        undefined -> undefined;
        Raw0 -> required_secret(Raw0, agent_api_key)
    end.

apply_provider(#{name := Name, base_url := Base, protocol := Proto, keys := Keys, models := Models}) ->
    ProviderId = upsert_provider(Name, Base, Proto),
    replace_provider_keys(ProviderId, Keys),
    lists:foreach(
        fun(ModelName) ->
            ModelId = upsert_model(ModelName),
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

required_bin(Map, Key) ->
    case map_get(Map, Key, undefined) of
        undefined ->
            error({missing_field, Key});
        <<>> ->
            error({empty_field, Key});
        "" ->
            error({empty_field, Key});
        V when is_binary(V) -> V;
        V when is_list(V) ->
            case io_lib:char_list(V) of
                true -> bin(V);
                false -> error({bad_field, Key})
            end;
        _Other ->
            error({bad_field, Key})
    end.

required_bin_value(V, _Label) when is_binary(V), V =/= <<>> -> V;
required_bin_value(V, Label) when is_list(V), V =/= "" ->
    case io_lib:char_list(V) of
        true -> bin(V);
        false -> error({bad_field, Label})
    end;
required_bin_value(_, Label) ->
    error({bad_field, Label}).

required_secret(V, _Label) when is_binary(V), V =/= <<>> -> V;
required_secret(V, Label) when is_list(V), V =/= "" ->
    case io_lib:char_list(V) of
        true -> bin(V);
        false -> error({bad_field, Label})
    end;
required_secret(_, Label) ->
    error({bad_field, Label}).

%% Encrypt first, then DELETE+INSERT in one backend transaction.
replace_provider_keys(ProviderId, Keys) ->
    Encrypted =
        lists:map(
            fun(Raw) ->
                case janus_secrets:encrypt(Raw) of
                    {ok, Cipher} ->
                        {KeyId, _} = janus_crypto_env:active_secrets_key(),
                        {Cipher, KeyId};
                    {error, Reason} ->
                        error({encrypt, Reason})
                end
            end,
            Keys
        ),
    {ok, Mod, Conn} = janus_db_conn:conn(),
    DelSql = sql(<<"DELETE FROM provider_keys WHERE provider_id = ?">>),
    InsSql = sql(
        <<
            "INSERT INTO provider_keys "
            "(provider_id, secret_ciphertext, key_id, weight, enabled) "
            "VALUES (?, ?, ?, 1, 1)"
        >>
    ),
    case
        Mod:with_tx(Conn, fun(C) ->
            case Mod:query(C, DelSql, [ProviderId]) of
                {ok, _} ->
                    lists:foreach(
                        fun({Cipher, KeyId}) ->
                            case Mod:query(C, InsSql, [ProviderId, Cipher, KeyId]) of
                                {ok, _} -> ok;
                                {error, Reason} -> error({insert_provider_key, Reason})
                            end
                        end,
                        Encrypted
                    ),
                    ok;
                {error, Reason} ->
                    {error, {delete_provider_keys, Reason}}
            end
        end)
    of
        ok ->
            ok;
        {error, Reason} ->
            error(Reason);
        Other ->
            error({replace_provider_keys, Other})
    end.

upsert_provider(Name, Base, Proto) ->
    case q(<<"SELECT id FROM providers WHERE name = ?">>, [Name]) of
        {ok, [{Id}]} ->
            case
                q(
                    <<"UPDATE providers SET base_url = ?, protocol = ?, enabled = 1 WHERE id = ?">>,
                    [Base, Proto, Id]
                )
            of
                {ok, _} -> Id;
                {error, Reason} -> error({update_provider, Reason})
            end;
        {ok, []} ->
            case
                q(
                    <<"INSERT INTO providers (name, base_url, protocol, enabled) VALUES (?, ?, ?, 1)">>,
                    [Name, Base, Proto]
                )
            of
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

upsert_model(Name) ->
    case q(<<"SELECT id FROM models WHERE name = ?">>, [Name]) of
        {ok, [{Id}]} ->
            Id;
        {ok, []} ->
            case q(<<"INSERT INTO models (name, enabled) VALUES (?, 1)">>, [Name]) of
                {ok, _} -> ok;
                {error, Reason} -> error({insert_model, Reason})
            end,
            case q(<<"SELECT id FROM models WHERE name = ?">>, [Name]) of
                {ok, [{Id}]} -> Id;
                Other -> error({model_id_missing, Other})
            end;
        {error, Reason} ->
            error({upsert_model, Reason})
    end.

ensure_route(ModelId, ProviderId) ->
    case
        q(
            <<"SELECT 1 FROM model_routes WHERE model_id = ? AND provider_id = ?">>,
            [ModelId, ProviderId]
        )
    of
        {ok, [_ | _]} ->
            ok;
        {ok, []} ->
            case
                q(
                    <<
                        "INSERT INTO model_routes "
                        "(model_id, provider_id, upstream_model_id, weight, priority, enabled) "
                        "VALUES (?, ?, NULL, 1, 0, 1)"
                    >>,
                    [ModelId, ProviderId]
                )
            of
                {ok, _} -> ok;
                {error, Reason} -> error({insert_route, Reason})
            end;
        {error, Reason} ->
            error({ensure_route, Reason})
    end.

maybe_seed_agent_key(undefined) ->
    ok;
maybe_seed_agent_key(Raw) when is_binary(Raw) ->
    {Prefix, Hash} = janus_api_keys:hash_key(Raw),
    case q(<<"SELECT id FROM api_keys WHERE key_hash = ?">>, [Hash]) of
        {ok, [_ | _]} ->
            ok;
        {ok, []} ->
            case
                q(
                    <<"INSERT INTO api_keys (prefix, key_hash, enabled) VALUES (?, ?, 1)">>,
                    [Prefix, Hash]
                )
            of
                {ok, _} -> ok;
                {error, Reason} -> error({seed_agent_key, Reason})
            end;
        {error, Reason} ->
            error({seed_agent_key, Reason})
    end.

-spec sanitize_error(term()) -> term().
sanitize_error({bad_providers, _}) ->
    bad_providers;
sanitize_error({bad_provider, _}) ->
    bad_provider;
sanitize_error({bad_field, Key, _}) ->
    {bad_field, Key};
sanitize_error({bad_field, Key}) ->
    {bad_field, Key};
sanitize_error({missing_field, Key}) ->
    {missing_field, Key};
sanitize_error({empty_field, Key}) ->
    {empty_field, Key};
sanitize_error({bad_protocol, _}) ->
    bad_protocol;
sanitize_error({read, Path, Reason}) ->
    {read, Path, sanitize_error(Reason)};
sanitize_error({Class, Reason, _Stack}) when
    Class =:= error; Class =:= throw; Class =:= exit
->
    {Class, sanitize_error(Reason)};
sanitize_error(Reason) when is_atom(Reason) -> Reason;
sanitize_error(Reason) when is_tuple(Reason), tuple_size(Reason) >= 1 ->
    case element(1, Reason) of
        Tag when is_atom(Tag) -> Tag;
        _ -> seed_error
    end;
sanitize_error(_) ->
    seed_error.

-spec redact_stack(list()) -> list().
redact_stack(Stack) when is_list(Stack) ->
    [
        case Frame of
            {M, F, A, Loc} when is_list(A) -> {M, F, length(A), Loc};
            {M, F, A, Loc} when is_integer(A) -> {M, F, A, Loc};
            {M, F, A} when is_list(A) -> {M, F, length(A)};
            Other -> Other
        end
     || Frame <- Stack
    ];
redact_stack(Other) ->
    Other.

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

sql(Sql0) ->
    case janus_db_conn:backend() of
        sqlite -> Sql0;
        postgres -> rewrite_pg(Sql0)
    end.

q(Sql0, Params) ->
    janus_db_conn:query(sql(Sql0), Params).

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
bin(L) when is_list(L) ->
    case io_lib:char_list(L) of
        true ->
            case unicode:characters_to_binary(L) of
                Bin when is_binary(Bin) -> Bin;
                _ -> error(bad_field_value)
            end;
        false ->
            error(bad_field_value)
    end;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(_) ->
    error(bad_field_value).

to_list(P) when is_list(P) -> P;
to_list(P) when is_binary(P) -> binary_to_list(P).
