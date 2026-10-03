%% @doc AES-256-GCM envelope encryption for Janus provider secrets.
%%
%% Envelope binary format (big-endian), magic `JSEC`:
%% <pre>
%%   << "JSEC",                 %% 4 bytes magic
%%      Version:8,              %% 1 = this format
%%      KeyIdLen:16, KeyId/binary,
%%      IvLen:8, Iv/binary,     %% IV length 12
%%      TagLen:8, Tag/binary,   %% tag length 16
%%      Ciphertext/binary >>
%% </pre>
%%
%% AAD bound into GCM is the `key_id` binary (rotation-safe).
%% Write uses the active key (first `JANUS_SECRETS_KEY` entry);
%% decrypt looks up `key_id` in the keyring (read-old / write-new).
-module(janus_secrets).

-export([
    encrypt/1,
    decrypt/1,
    is_envelope/1,
    encode_envelope/1,
    decode_envelope/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(MAGIC, "JSEC").
-define(VERSION, 1).
-define(IV_LEN, 12).
-define(TAG_LEN, 16).

-type key_id() :: binary().
-type envelope() :: #{
    key_id := key_id(),
    iv := binary(),
    tag := binary(),
    ciphertext := binary()
}.

-spec encrypt(binary()) -> {ok, binary()} | {error, term()}.
encrypt(Plain) when is_binary(Plain) ->
    try
        {KeyId, Key} = janus_crypto_env:active_secrets_key(),
        IV = crypto:strong_rand_bytes(?IV_LEN),
        AAD = KeyId,
        {Ciphertext, Tag} =
            crypto:crypto_one_time_aead(aes_256_gcm, Key, IV, Plain, AAD, true),
        Env = #{
            key_id => KeyId,
            iv => IV,
            tag => Tag,
            ciphertext => Ciphertext
        },
        {ok, encode_envelope(Env)}
    catch
        error:{janus_boot_fail, _} = Reason ->
            {error, Reason};
        error:{janus_boot_fail, _, _} = Reason ->
            {error, Reason};
        error:{janus_boot_fail, _, _, _} = Reason ->
            {error, Reason};
        Class:Reason:St ->
            {error, {Class, Reason, St}}
    end;
encrypt(_) ->
    {error, badarg}.

-spec decrypt(binary()) -> {ok, binary()} | {error, term()}.
decrypt(EnvelopeBin) when is_binary(EnvelopeBin) ->
    case decode_envelope(EnvelopeBin) of
        {ok, #{key_id := KeyId, iv := IV, tag := Tag, ciphertext := CT}} ->
            case janus_crypto_env:secrets_key(KeyId) of
                {ok, Key} ->
                    case
                        crypto:crypto_one_time_aead(
                            aes_256_gcm, Key, IV, CT, KeyId, Tag, false
                        )
                    of
                        Plain when is_binary(Plain) ->
                            {ok, Plain};
                        error ->
                            {error, decrypt_failed};
                        Other ->
                            {error, {decrypt_failed, Other}}
                    end;
                {error, unknown_key_id} ->
                    {error, {unknown_key_id, KeyId}}
            end;
        {error, _} = Err ->
            Err
    end;
decrypt(_) ->
    {error, badarg}.

-spec is_envelope(binary()) -> boolean().
is_envelope(<<?MAGIC, _/binary>>) -> true;
is_envelope(_) -> false.

-spec encode_envelope(envelope()) -> binary().
encode_envelope(#{
    key_id := KeyId,
    iv := IV,
    tag := Tag,
    ciphertext := CT
}) when
    is_binary(KeyId),
    is_binary(IV),
    is_binary(Tag),
    is_binary(CT)
->
    KeyIdLen = byte_size(KeyId),
    IvLen = byte_size(IV),
    TagLen = byte_size(Tag),
    true = KeyIdLen =< 16#ffff,
    true = IvLen =< 16#ff,
    true = TagLen =< 16#ff,
    <<?MAGIC, ?VERSION:8, KeyIdLen:16, KeyId/binary, IvLen:8, IV/binary, TagLen:8, Tag/binary,
        CT/binary>>.

-spec decode_envelope(binary()) -> {ok, envelope()} | {error, term()}.
decode_envelope(<<?MAGIC, ?VERSION:8, KeyIdLen:16, Rest/binary>>) when KeyIdLen > 0 ->
    case Rest of
        <<KeyId:KeyIdLen/binary, IvLen:8, Rest2/binary>> when IvLen > 0 ->
            case Rest2 of
                <<IV:IvLen/binary, TagLen:8, Rest3/binary>> when TagLen > 0 ->
                    case Rest3 of
                        <<Tag:TagLen/binary, CT/binary>> ->
                            {ok, #{
                                key_id => KeyId,
                                iv => IV,
                                tag => Tag,
                                ciphertext => CT
                            }};
                        _ ->
                            {error, truncated_envelope}
                    end;
                _ ->
                    {error, truncated_envelope}
            end;
        _ ->
            {error, truncated_envelope}
    end;
decode_envelope(<<?MAGIC, Ver:8, _/binary>>) ->
    {error, {unsupported_version, Ver}};
decode_envelope(_) ->
    {error, bad_magic}.

-ifdef(TEST).

roundtrip_test() ->
    Key = crypto:strong_rand_bytes(32),
    B64 = base64:encode_to_string(Key),
    os:putenv("JANUS_SECRETS_KEY", "k1:" ++ B64),
    Plain = <<"provider-secret-xyz">>,
    {ok, Env} = encrypt(Plain),
    true = is_envelope(Env),
    {ok, Plain} = decrypt(Env).

rotation_read_old_test() ->
    Old = crypto:strong_rand_bytes(32),
    New = crypto:strong_rand_bytes(32),
    os:putenv(
        "JANUS_SECRETS_KEY",
        "k2:" ++ base64:encode_to_string(New) ++ ",k1:" ++ base64:encode_to_string(Old)
    ),
    %% Encrypt under k1 by temporarily making it active.
    os:putenv("JANUS_SECRETS_KEY", "k1:" ++ base64:encode_to_string(Old)),
    {ok, Env} = encrypt(<<"old-secret">>),
    os:putenv(
        "JANUS_SECRETS_KEY",
        "k2:" ++ base64:encode_to_string(New) ++ ",k1:" ++ base64:encode_to_string(Old)
    ),
    {ok, <<"old-secret">>} = decrypt(Env),
    {ok, NewEnv} = encrypt(<<"new-secret">>),
    {ok, #{key_id := <<"k2">>}} = decode_envelope(NewEnv).

-endif.
