%% @doc Filesystem Files-API blob backend: content-addressed tree.
%%
%% Root: JANUS_FILES_FS_ROOT (default /var/lib/janus/files). Layout
%% `<root>/<2 hex>/<sha256>` — two-level fanout keeps directories
%% small; write is temp+rename so a reader never sees a partial blob.
%% Mount the root on persistent storage; rsync is the backup story.
-module(janus_files_store_fs).
-export([put/2, get/1, delete/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

root() ->
    os:getenv("JANUS_FILES_FS_ROOT", "/var/lib/janus/files").

path(Sha256Hex) ->
    Hex = binary_to_list(Sha256Hex),
    filename:join([root(), string:slice(Hex, 0, 2), Hex]).

-spec put(binary(), binary()) -> ok | {error, term()}.
put(Sha256Hex, Bytes) when is_binary(Sha256Hex), is_binary(Bytes) ->
    Path = path(Sha256Hex),
    case filelib:ensure_path(filename:dirname(Path)) of
        ok ->
            Tmp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
            case file:write_file(Tmp, Bytes) of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok ->
                            ok;
                        {error, Reason} = Err ->
                            _ = file:delete(Tmp),
                            _ = logger:warning(#{what => files_fs_rename_failed, reason => Reason}),
                            Err
                    end;
                {error, Reason} = Err ->
                    _ = file:delete(Tmp),
                    _ = logger:warning(#{what => files_fs_write_failed, reason => Reason}),
                    Err
            end;
        {error, Reason} = Err ->
            _ = logger:warning(#{what => files_fs_mkdir_failed, reason => Reason}),
            Err
    end.

-spec get(binary()) -> {ok, binary()} | {error, not_found | term()}.
get(Sha256Hex) when is_binary(Sha256Hex) ->
    case file:read_file(path(Sha256Hex)) of
        {ok, Bytes} -> {ok, Bytes};
        {error, enoent} -> {error, not_found};
        {error, Reason} -> {error, Reason}
    end.

-spec delete(binary()) -> ok | {error, term()}.
delete(Sha256Hex) when is_binary(Sha256Hex) ->
    case file:delete(path(Sha256Hex)) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-ifdef(TEST).

roundtrip_test() ->
    os:putenv("JANUS_FILES_FS_ROOT", "/tmp/janus-files-test"),
    Blob = <<"content-addressed roundtrip">>,
    Sha = binary:encode_hex(crypto:hash(sha256, Blob)),
    ok = put(Sha, Blob),
    {ok, Blob} = get(Sha),
    ok = delete(Sha),
    {error, not_found} = get(Sha).

-endif.
