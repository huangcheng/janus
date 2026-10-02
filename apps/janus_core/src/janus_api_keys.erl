%% @doc Agent API key hashing: HMAC-SHA256 + pepper.
%%
%% - `hash_key/1` — HMAC-SHA256(`JANUS_API_KEY_PEPPER`, RawKey)
%% - `verify/2` — constant-time compare via `crypto:hash_equals/2`
%% - `prefix/1` — first 8 bytes of the raw key (for `sk-...` index)
%%
%% Store `{prefix, key_hash}` in `api_keys`; never store plaintext.
-module(janus_api_keys).

-export([
    hash_key/1,
    verify/2,
    prefix/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(PREFIX_LEN, 8).

-spec hash_key(binary() | string()) -> {Prefix :: binary(), Hash :: binary()}.
hash_key(Raw) when is_list(Raw) ->
    hash_key(list_to_binary(Raw));
hash_key(Raw) when is_binary(Raw), Raw =/= <<>> ->
    Pepper = janus_crypto_env:api_key_pepper(),
    Hash = crypto:mac(hmac, sha256, Pepper, Raw),
    {prefix(Raw), Hash}.

-spec verify(binary() | string(), binary()) -> boolean().
verify(Raw, StoredHash) when is_list(Raw) ->
    verify(list_to_binary(Raw), StoredHash);
verify(Raw, StoredHash) when is_binary(Raw), is_binary(StoredHash) ->
    try
        {_Prefix, Hash} = hash_key(Raw),
        case byte_size(Hash) =:= byte_size(StoredHash) of
            true -> crypto:hash_equals(Hash, StoredHash);
            false -> false
        end
    catch
        _:_ -> false
    end;
verify(_, _) ->
    false.

-spec prefix(binary() | string()) -> binary().
prefix(Raw) when is_list(Raw) ->
    prefix(list_to_binary(Raw));
prefix(Raw) when is_binary(Raw) ->
    Len = min(?PREFIX_LEN, byte_size(Raw)),
    binary:part(Raw, 0, Len).

-ifdef(TEST).

hash_verify_test() ->
    os:putenv("JANUS_API_KEY_PEPPER", "test-pepper-please-change"),
    Key = <<"sk-testABCDEF1234567890">>,
    {Pref, Hash} = hash_key(Key),
    ?assertEqual(<<"sk-testA">>, Pref),
    ?assertEqual(true, verify(Key, Hash)),
    ?assertEqual(false, verify(<<"sk-other">>, Hash)),
    ?assertEqual(false, verify(Key, <<Hash/binary, 0>>)).

prefix_short_test() ->
    ?assertEqual(<<"sk">>, prefix(<<"sk">>)).

-endif.
