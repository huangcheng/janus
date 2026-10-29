%% @doc Shared env / app-env parsing for Janus crypto modules.
%%
%% Environment contract:
%%
%% <ul>
%%   <li>`JANUS_SECRETS_KEY` — keyring as comma-separated
%%       `key_id:base64,...` entries. Each decoded key must be exactly
%%       32 bytes (AES-256). The <em>first</em> entry is the active
%%       write key (write-new / read-old). Missing / empty = boot fail.</li>
%%   <li>`JANUS_API_KEY_PEPPER` — arbitrary string/binary pepper for
%%       agent API-key HMAC-SHA256. Missing = boot fail for key ops.</li>
%%   <li>`JANUS_SNAPSHOT_DIR` — snapshot directory (default
%%       `data/snapshots`).</li>
%%   <li>`JANUS_SNAPSHOT_MAX_AGE_SEC` — optional max age; when set,
%%       `janus_snapshot:load_latest/0` rejects older snapshots
%%       (`{error, stale}`). Used for auth fail-closed bounds.</li>
%%   <li>`JANUS_SNAPSHOT_RETAIN` — how many snapshot files to keep
%%       (default 5).</li>
%% </ul>
%%
%% App-env fallbacks under application `janus`:
%% `secrets_keyring` (#{KeyId => <<Key:32/binary>>}),
%% `secrets_active_key_id`, `api_key_pepper`, `snapshot_dir`,
%% `snapshot_max_age_sec`, `snapshot_retain`.
-module(janus_crypto_env).

-export([
    ensure_secrets_configured/0,
    secrets_keyring/0,
    active_secrets_key_id/0,
    active_secrets_key/0,
    secrets_key/1,
    api_key_pepper/0,
    snapshot_dir/0,
    snapshot_max_age_sec/0,
    snapshot_retain/0
]).

-define(DEFAULT_SNAPSHOT_DIR, "data/snapshots").
-define(DEFAULT_SNAPSHOT_RETAIN, 5).

-type key_id() :: binary().
-type aes_key() :: <<_:256>>.
-type keyring() :: #{key_id() => aes_key()}.

-spec ensure_secrets_configured() -> ok.
ensure_secrets_configured() ->
    case secrets_keyring() of
        Ring when map_size(Ring) > 0 ->
            _ = active_secrets_key(),
            ok;
        _ ->
            error({janus_boot_fail, missing_JANUS_SECRETS_KEY})
    end.

-spec secrets_keyring() -> keyring().
secrets_keyring() ->
    case os:getenv("JANUS_SECRETS_KEY") of
        Val when is_list(Val), Val =/= [] ->
            parse_keyring_string(Val);
        _ ->
            case application:get_env(janus, secrets_keyring, undefined) of
                Ring when is_map(Ring), map_size(Ring) > 0 ->
                    normalize_keyring(Ring);
                _ ->
                    #{}
            end
    end.

-spec active_secrets_key_id() -> key_id().
active_secrets_key_id() ->
    case os:getenv("JANUS_SECRETS_KEY") of
        Val when is_list(Val), Val =/= [] ->
            case parse_keyring_ordered(Val) of
                [{Id, _} | _] -> Id;
                [] -> error({janus_boot_fail, missing_JANUS_SECRETS_KEY})
            end;
        _ ->
            case application:get_env(janus, secrets_active_key_id, undefined) of
                Id when is_binary(Id) -> Id;
                Id when is_list(Id) -> list_to_binary(Id);
                Id when is_atom(Id) -> atom_to_binary(Id, utf8);
                _ ->
                    case maps:keys(secrets_keyring()) of
                        [Id | _] -> Id;
                        [] -> error({janus_boot_fail, missing_JANUS_SECRETS_KEY})
                    end
            end
    end.

-spec active_secrets_key() -> {key_id(), aes_key()}.
active_secrets_key() ->
    Id = active_secrets_key_id(),
    case secrets_key(Id) of
        {ok, Key} -> {Id, Key};
        {error, _} -> error({janus_boot_fail, unknown_active_key_id, Id})
    end.

-spec secrets_key(key_id() | string()) -> {ok, aes_key()} | {error, unknown_key_id}.
secrets_key(Id) when is_list(Id) ->
    secrets_key(list_to_binary(Id));
secrets_key(Id) when is_binary(Id) ->
    case maps:find(Id, secrets_keyring()) of
        {ok, Key} -> {ok, Key};
        error -> {error, unknown_key_id}
    end.

-spec api_key_pepper() -> binary().
api_key_pepper() ->
    case os:getenv("JANUS_API_KEY_PEPPER") of
        Val when is_list(Val), Val =/= [] ->
            list_to_binary(Val);
        _ ->
            case application:get_env(janus, api_key_pepper, undefined) of
                Bin when is_binary(Bin), Bin =/= <<>> -> Bin;
                List when is_list(List), List =/= [] -> list_to_binary(List);
                _ -> error({janus_boot_fail, missing_JANUS_API_KEY_PEPPER})
            end
    end.

-spec snapshot_dir() -> file:filename_all().
snapshot_dir() ->
    case os:getenv("JANUS_SNAPSHOT_DIR") of
        Val when is_list(Val), Val =/= [] -> Val;
        _ ->
            case application:get_env(janus, snapshot_dir, undefined) of
                Dir when is_list(Dir); is_binary(Dir) -> Dir;
                _ -> ?DEFAULT_SNAPSHOT_DIR
            end
    end.

-spec snapshot_max_age_sec() -> undefined | pos_integer().
snapshot_max_age_sec() ->
    case os:getenv("JANUS_SNAPSHOT_MAX_AGE_SEC") of
        Val when is_list(Val), Val =/= [] ->
            list_to_integer(Val);
        _ ->
            case application:get_env(janus, snapshot_max_age_sec, undefined) of
                N when is_integer(N), N > 0 -> N;
                _ -> undefined
            end
    end.

-spec snapshot_retain() -> pos_integer().
snapshot_retain() ->
    case os:getenv("JANUS_SNAPSHOT_RETAIN") of
        Val when is_list(Val), Val =/= [] ->
            max(1, list_to_integer(Val));
        _ ->
            case application:get_env(janus, snapshot_retain, undefined) of
                N when is_integer(N), N > 0 -> N;
                _ -> ?DEFAULT_SNAPSHOT_RETAIN
            end
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

parse_keyring_string(Str) ->
    maps:from_list(parse_keyring_ordered(Str)).

parse_keyring_ordered(Str) ->
    Parts = [string:trim(P) || P <- string:lexemes(Str, ",")],
    lists:filtermap(
        fun(Part) ->
            case string:split(Part, ":", leading) of
                [IdStr, B64] when IdStr =/= "", B64 =/= "" ->
                    Id = list_to_binary(string:trim(IdStr)),
                    case decode_key_b64(string:trim(B64)) of
                        {ok, Key} -> {true, {Id, Key}};
                        {error, Reason} -> error({janus_boot_fail, bad_secrets_key, Id, Reason})
                    end;
                _ ->
                    error({janus_boot_fail, bad_JANUS_SECRETS_KEY_format, Part})
            end
        end,
        Parts
    ).

normalize_keyring(Ring) ->
    maps:fold(
        fun(K, V, Acc) ->
            Id = normalize_key_id(K),
            Key = normalize_key_bytes(Id, V),
            Acc#{Id => Key}
        end,
        #{},
        Ring
    ).

normalize_key_id(Id) when is_binary(Id) -> Id;
normalize_key_id(Id) when is_list(Id) -> list_to_binary(Id);
normalize_key_id(Id) when is_atom(Id) -> atom_to_binary(Id, utf8).

normalize_key_bytes(_Id, <<_:256>> = Bin) ->
    Bin;
normalize_key_bytes(Id, List) when is_list(List) ->
    case decode_key_b64(List) of
        {ok, Kbin} -> Kbin;
        {error, R} -> error({janus_boot_fail, bad_secrets_key, Id, R})
    end;
normalize_key_bytes(Id, Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        32 ->
            Bin;
        _ ->
            case decode_key_b64(binary_to_list(Bin)) of
                {ok, Kbin} -> Kbin;
                {error, R} -> error({janus_boot_fail, bad_secrets_key, Id, R})
            end
    end.

decode_key_b64(B64) when is_list(B64) ->
    try
        %% Prefer standard base64; also accept base64url.
        Bin =
            try
                base64:decode(B64)
            catch
                _:_ ->
                    base64:decode(base64url_to_std(B64))
            end,
        case byte_size(Bin) of
            32 -> {ok, Bin};
            N -> {error, {bad_key_length, N}}
        end
    catch
        _:_ -> {error, bad_base64}
    end.

base64url_to_std(S) ->
    S1 = lists:map(
        fun
            ($-) -> $+;
            ($_) -> $/;
            (C) -> C
        end,
        S
    ),
    Pad =
        case length(S1) rem 4 of
            0 -> "";
            2 -> "==";
            3 -> "=";
            _ -> ""
        end,
    S1 ++ Pad.
