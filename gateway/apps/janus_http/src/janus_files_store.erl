%% @doc Pluggable blob store for the Files API (2026-10-26).
%%
%% Bytes NEVER live in Postgres (metadata only — see migration 026).
%% Backends are selected by `JANUS_FILES_STORE` (fs | s3) and address
%% blobs by their sha256 hex: content-addressed, dedup for free, and a
%% backend migration is a copy of the content-addressed tree/objects
%% plus an env flip — never a data reshape.
%%
%% Backends:
%%   janus_files_store_fs  — content-addressed filesystem (dev/default)
%%   janus_files_store_s3  — any S3-compatible service (MinIO /
%%                          SeaweedFS gateway on-box today; Aliyun OSS /
%%                          Tencent COS later — same API, env flip)
-module(janus_files_store).
-export([backend/0, put/2, get/1, delete/1]).

-callback put(binary(), binary()) -> ok | {error, term()}.
%% Fetch a blob previously put under this digest.
-callback get(binary()) -> {ok, binary()} | {error, not_found | term()}.
-callback delete(binary()) -> ok | {error, term()}.

-spec backend() -> module().
backend() ->
    case os:getenv("JANUS_FILES_STORE", "fs") of
        "s3" -> janus_files_store_s3;
        _ -> janus_files_store_fs
    end.

-spec put(binary(), binary()) -> ok | {error, term()}.
put(Sha256Hex, Bytes) ->
    Mod = backend(),
    Mod:put(Sha256Hex, Bytes).

-spec get(binary()) -> {ok, binary()} | {error, not_found | term()}.
get(Sha256Hex) ->
    Mod = backend(),
    Mod:get(Sha256Hex).

-spec delete(binary()) -> ok | {error, term()}.
delete(Sha256Hex) ->
    Mod = backend(),
    Mod:delete(Sha256Hex).
