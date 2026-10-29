%% @doc Mandatory on-disk config snapshot with HMAC integrity.
%%
%% File format (big-endian), magic `JSNP`:
%% <pre>
%%   << "JSNP",                 %% 4 bytes magic
%%      Version:8,              %% 1
%%      BodyLen:32, Body/binary,
%%      Mac:32/binary >>        %% HMAC-SHA256 over Body, key = active AES key
%% </pre>
%%
%% Body is `term_to_binary({janus_snap, 1, MetaMap, CatalogTerm})` where
%% sensitive map fields (`secret`, `api_secret`, `provider_secret`,
%% `access_token`, `plaintext_secret`) are AES-GCM envelopes from
%% `janus_secrets` (ciphertext at rest). HMAC uses the active
%% `JANUS_SECRETS_KEY` material.
%%
%% Atomic write: temp file + `file:sync/1` + `file:rename/2`. Retains
%% last `JANUS_SNAPSHOT_RETAIN` (default 5) files named
%% `janus-snapshot-&lt;unix_us&gt;.jsnp`.
%%
%% Catalog agent integration:
%% <ul>
%%   <li>On successful DB load / publish: `janus_snapshot:write_snapshot(Catalog)`.</li>
%%   <li>On poll with new generation: same after ETS swap.</li>
%%   <li>Cold start DB down: `load_latest()` → serve; mutations refused by catalog.</li>
%%   <li>No/corrupt/stale snapshot: `{error, _}` → refuse traffic (`/readyz` fail).</li>
%% </ul>
-module(janus_snapshot).
-behaviour(gen_server).

-export([
    start_link/0,
    write_snapshot/1,
    load_latest/0,
    write/1,
    read_latest/0,
    encrypt_sensitive/1,
    decrypt_sensitive/1,
    snapshot_path_meta/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
%% Portable temp root: /tmp on unix, %TEMP% on Windows.
temp_root() ->
    case os:type() of
        {win32, _} ->
            T = os:getenv("TEMP"),
            case is_list(T) andalso T =/= [] of
                true -> T;
                false -> "."
            end;
        _ ->
            "/tmp"
    end.

-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(MAGIC, "JSNP").
-define(VERSION, 1).
-define(MAC_LEN, 32).
-define(SENSITIVE_KEYS, [
    secret,
    api_secret,
    provider_secret,
    access_token,
    plaintext_secret,
    <<"secret">>,
    <<"api_secret">>,
    <<"provider_secret">>,
    <<"access_token">>,
    <<"plaintext_secret">>
]).

-record(state, {
    dir :: file:filename_all()
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Alias matching SCHEMA_ETS_CONTRACT (`write/1`).
-spec write(term()) -> ok | {error, term()}.
write(Catalog) ->
    write_snapshot(Catalog).

%% @doc Alias matching SCHEMA_ETS_CONTRACT (`read_latest/0`).
-spec read_latest() -> {ok, term(), map()} | {error, term()}.
read_latest() ->
    load_latest().

-spec write_snapshot(term()) -> ok | {error, term()}.
write_snapshot(Catalog) ->
    try
        janus_crypto_env:ensure_secrets_configured(),
        Dir = janus_crypto_env:snapshot_dir(),
        ok = ensure_dir(Dir),
        NowUs = erlang:system_time(microsecond),
        NowSec = erlang:system_time(second),
        EncryptedCatalog = encrypt_sensitive(Catalog),
        Meta0 = extract_meta(Catalog),
        Meta = Meta0#{
            written_at => NowSec,
            written_at_us => NowUs,
            format => 1
        },
        Body = term_to_binary({janus_snap, 1, Meta, EncryptedCatalog}, [
            {compressed, 1}
        ]),
        BodyLen = byte_size(Body),
        {_KeyId, MacKey} = janus_crypto_env:active_secrets_key(),
        Mac = crypto:mac(hmac, sha256, MacKey, Body),
        FileBin = <<?MAGIC, ?VERSION:8, BodyLen:32, Body/binary, Mac/binary>>,
        %% Zero-padded digits (20 wide): legal on Windows too. The old
        %% ~20.10.0w produced asterisks for >10-digit integers — illegal
        %% filename chars on Windows (enoent).
        Base = snapshot_base_name(NowUs),
        FinalPath = filename:join(Dir, lists:flatten(Base)),
        TmpPath = FinalPath ++ ".tmp",
        case atomic_write(TmpPath, FinalPath, FileBin) of
            ok ->
                prune_old(Dir),
                ok;
            {error, _} = Err ->
                _ = file:delete(TmpPath),
                Err
        end
    catch
        error:{janus_boot_fail, _} = Reason ->
            {error, Reason};
        error:{janus_boot_fail, _, _} = Reason ->
            {error, Reason};
        error:{janus_boot_fail, _, _, _} = Reason ->
            {error, Reason};
        Class:Reason:St ->
            {error, {Class, Reason, St}}
    end.

-spec load_latest() -> {ok, Catalog :: term(), Meta :: map()} | {error, term()}.
load_latest() ->
    try
        janus_crypto_env:ensure_secrets_configured(),
        Dir = janus_crypto_env:snapshot_dir(),
        case list_snapshots(Dir) of
            [] ->
                {error, missing};
            [Newest | _] ->
                case load_file(Newest) of
                    {ok, Catalog, Meta} ->
                        case check_max_age(Meta) of
                            ok -> {ok, Catalog, Meta#{path => Newest}};
                            {error, _} = Err -> Err
                        end;
                    {error, _} = Err ->
                        Err
                end
        end
    catch
        error:{janus_boot_fail, _} = Reason ->
            {error, Reason};
        error:{janus_boot_fail, _, _} = Reason ->
            {error, Reason};
        error:{janus_boot_fail, _, _, _} = Reason ->
            {error, Reason};
        Class:Reason:St ->
            {error, {Class, Reason, St}}
    end.

-spec snapshot_path_meta(file:filename_all()) -> {ok, map()} | {error, term()}.
snapshot_path_meta(Path) ->
    case load_file(Path) of
        {ok, _Catalog, Meta} -> {ok, Meta};
        {error, _} = Err -> Err
    end.

%%--------------------------------------------------------------------
%% Sensitive field walk
%%--------------------------------------------------------------------

-spec encrypt_sensitive(term()) -> term().
encrypt_sensitive(Term) ->
    walk_sensitive(Term, encrypt).

-spec decrypt_sensitive(term()) -> term().
decrypt_sensitive(Term) ->
    walk_sensitive(Term, decrypt).

walk_sensitive(Map, Op) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{K => maybe_transform_field(K, V, Op)}
        end,
        #{},
        Map
    );
walk_sensitive(List, Op) when is_list(List) ->
    %% Preserve improper lists / strings: only map proper term lists.
    case is_proplist_or_terms(List) of
        true -> [walk_sensitive(E, Op) || E <- List];
        false -> List
    end;
walk_sensitive(Tuple, Op) when is_tuple(Tuple) ->
    list_to_tuple([walk_sensitive(E, Op) || E <- tuple_to_list(Tuple)]);
walk_sensitive(Other, _Op) ->
    Other.

maybe_transform_field(Key, Value, Op) ->
    case is_sensitive_key(Key) of
        true -> transform_secret_value(Value, Op);
        false -> walk_sensitive(Value, Op)
    end.

is_sensitive_key(Key) ->
    lists:member(Key, ?SENSITIVE_KEYS).

transform_secret_value(Value, encrypt) when is_binary(Value) ->
    case janus_secrets:is_envelope(Value) of
        true ->
            Value;
        false ->
            case janus_secrets:encrypt(Value) of
                {ok, Env} -> Env;
                {error, Reason} -> error({snapshot_encrypt_failed, Reason})
            end
    end;
transform_secret_value(Value, decrypt) when is_binary(Value) ->
    case janus_secrets:is_envelope(Value) of
        true ->
            case janus_secrets:decrypt(Value) of
                {ok, Plain} -> Plain;
                {error, Reason} -> error({snapshot_decrypt_failed, Reason})
            end;
        false ->
            Value
    end;
transform_secret_value(Value, Op) ->
    walk_sensitive(Value, Op).

is_proplist_or_terms([]) ->
    true;
is_proplist_or_terms([H | T]) when not is_integer(H) ->
    is_proplist_or_terms(T);
is_proplist_or_terms(_) ->
    false.

%%--------------------------------------------------------------------
%% gen_server (optional supervised lifecycle)
%%--------------------------------------------------------------------

init([]) ->
    janus_crypto_env:ensure_secrets_configured(),
    Dir = janus_crypto_env:snapshot_dir(),
    ok = ensure_dir(Dir),
    {ok, #state{dir = Dir}}.

handle_call({write_snapshot, Catalog}, _From, State) ->
    {reply, write_snapshot(Catalog), State};
handle_call(load_latest, _From, State) ->
    {reply, load_latest(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% File helpers
%%--------------------------------------------------------------------

%% Zero-padded, fixed-width (40 chars), [A-Za-z0-9._-] only — legal on
%% every filesystem list_snapshots/1 may run on, and lexicographically
%% time-ordered. The old ~20.10.0w produced asterisks for >10-digit
%% microsecond timestamps (illegal on Windows).
snapshot_base_name(NowUs) when is_integer(NowUs), NowUs > 0 ->
    Digits = integer_to_binary(NowUs),
    PadLen = max(0, 20 - byte_size(Digits)),
    binary_to_list(
        <<"janus-snapshot-", (binary:copy(<<"0">>, PadLen))/binary, Digits/binary, ".jsnp">>
    ).

ensure_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true -> ok;
        false -> filelib:ensure_dir(filename:join(Dir, ".keep"))
    end.

atomic_write(TmpPath, FinalPath, Bin) ->
    case file:open(TmpPath, [write, raw, binary, exclusive]) of
        {ok, Fd} ->
            try
                case file:write(Fd, Bin) of
                    ok ->
                        case file:sync(Fd) of
                            ok ->
                                ok = file:close(Fd),
                                case file:rename(TmpPath, FinalPath) of
                                    ok -> ok;
                                    {error, _} = Err -> Err
                                end;
                            {error, _} = Err ->
                                _ = file:close(Fd),
                                Err
                        end;
                    {error, _} = Err ->
                        _ = file:close(Fd),
                        Err
                end
            catch
                Class:Reason:St ->
                    _ = file:close(Fd),
                    {error, {Class, Reason, St}}
            end;
        {error, _} = Err ->
            Err
    end.

list_snapshots(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            Files =
                [
                    filename:join(Dir, N)
                 || N <- Names,
                    lists:suffix(".jsnp", N),
                    not lists:suffix(".tmp", N)
                ],
            %% Newest first: names embed zero-padded microsecond timestamps.
            lists:reverse(lists:sort(Files));
        {error, enoent} ->
            [];
        {error, _} ->
            []
    end.

load_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            parse_snapshot_bin(Bin);
        {error, enoent} ->
            {error, missing};
        {error, Reason} ->
            {error, Reason}
    end.

parse_snapshot_bin(<<?MAGIC, ?VERSION:8, BodyLen:32, Body:BodyLen/binary, Mac:?MAC_LEN/binary>>) ->
    case verify_mac(Body, Mac) of
        true ->
            try
                case binary_to_term(Body, [safe]) of
                    {janus_snap, 1, Meta, EncCatalog} when is_map(Meta) ->
                        Catalog = decrypt_sensitive(EncCatalog),
                        {ok, Catalog, Meta};
                    _ ->
                        {error, corrupt}
                end
            catch
                _:_ -> {error, corrupt}
            end;
        false ->
            {error, corrupt}
    end;
parse_snapshot_bin(<<?MAGIC, Ver:8, _/binary>>) ->
    {error, {unsupported_version, Ver}};
parse_snapshot_bin(_) ->
    {error, corrupt}.

verify_mac(Body, Mac) ->
    Ring = janus_crypto_env:secrets_keyring(),
    %% Accept HMAC under any keyring key so rotation does not invalidate
    %% snapshots signed with a prior active key.
    lists:any(
        fun(Key) ->
            Expected = crypto:mac(hmac, sha256, Key, Body),
            byte_size(Expected) =:= byte_size(Mac) andalso
                crypto:hash_equals(Expected, Mac)
        end,
        maps:values(Ring)
    ).

check_max_age(Meta) ->
    case janus_crypto_env:snapshot_max_age_sec() of
        undefined ->
            ok;
        MaxAge ->
            WrittenAt =
                case Meta of
                    #{written_at := T} when is_integer(T) -> T;
                    _ -> 0
                end,
            Age = erlang:system_time(second) - WrittenAt,
            case Age =< MaxAge of
                true -> ok;
                false -> {error, stale}
            end
    end.

extract_meta(Catalog) when is_map(Catalog) ->
    Gen =
        case Catalog of
            #{generation := G} -> G;
            #{<<"generation">> := G} -> G;
            _ -> undefined
        end,
    #{generation => Gen};
extract_meta(_) ->
    #{generation => undefined}.

prune_old(Dir) ->
    Retain = janus_crypto_env:snapshot_retain(),
    case list_snapshots(Dir) of
        Files when length(Files) > Retain ->
            {_Keep, Drop} = lists:split(Retain, Files),
            lists:foreach(fun(P) -> _ = file:delete(P) end, Drop),
            ok;
        _ ->
            ok
    end.

-ifdef(TEST).

snapshot_base_name_test() ->
    N1 = snapshot_base_name(1791031970896065),
    N2 = snapshot_base_name(1),
    N3 = snapshot_base_name(999999999999999999),
    [?assert(is_legal_name_char(C)) || C <- N1],
    ?assertEqual(40, length(N1)),
    ?assertEqual(40, length(N2)),
    ?assertEqual(40, length(N3)),
    ?assert(N2 < N1),
    ?assert(N1 < N3).

is_legal_name_char(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse lists:member(C, [$., $_, $-]).

roundtrip_snapshot_test() ->
    Key = crypto:strong_rand_bytes(32),
    os:putenv("JANUS_SECRETS_KEY", "k1:" ++ base64:encode_to_string(Key)),
    os:putenv("JANUS_API_KEY_PEPPER", "pepper"),
    Dir = filename:join(
        temp_root(), "janus-snap-test-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    os:putenv("JANUS_SNAPSHOT_DIR", Dir),
    os:unsetenv("JANUS_SNAPSHOT_MAX_AGE_SEC"),
    Catalog = #{
        generation => 7,
        providers => [
            #{id => 1, name => <<"p">>, secret => <<"upstream-key">>}
        ]
    },
    ok = write_snapshot(Catalog),
    {ok, Loaded, Meta} = load_latest(),
    ?assertEqual(7, maps:get(generation, Meta)),
    ?assertEqual(
        <<"upstream-key">>,
        maps:get(secret, hd(maps:get(providers, Loaded)))
    ),
    ok = file:del_dir_r(Dir).

corrupt_mac_test() ->
    Key = crypto:strong_rand_bytes(32),
    os:putenv("JANUS_SECRETS_KEY", "k1:" ++ base64:encode_to_string(Key)),
    Dir = filename:join(
        temp_root(), "janus-snap-bad-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    os:putenv("JANUS_SNAPSHOT_DIR", Dir),
    ok = write_snapshot(#{generation => 1, secret => <<"x">>}),
    [Path | _] = list_snapshots(Dir),
    {ok, Bin} = file:read_file(Path),
    %% Flip last MAC byte.
    Size = byte_size(Bin),
    <<Prefix:(Size - 1)/binary, Last>> = Bin,
    ok = file:write_file(Path, <<Prefix/binary, (Last bxor 1)>>),
    ?assertEqual({error, corrupt}, load_latest()),
    ok = file:del_dir_r(Dir).

-endif.
