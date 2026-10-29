%% @doc Gateway-owned Files API core (2026-10-26).
%%
%% Standard /v1/files so agent harnesses (dsh file-mode etc.) work
%% against ANY chat-family upstream: uploads live gateway-side
%% (content-addressed store backend, janus_files_store), and chat
%% requests referencing a `file-janus-*` id are MATERIALIZED before
%% routing/translation — text-ish files become text parts, images
%% become image_url data parts, so every upstream just sees ordinary
%% content. No provider file dialects, ever; foreign file ids pass
%% through untouched (provider-local stores are not our business).
%%
%% Ownership: every file belongs to the agent key that uploaded it;
%% cross-key access answers not_found (never leaks existence).
%% Metadata ONLY in Postgres (migration 026); bytes never touch the DB.
-module(janus_files).
-export([
    enabled/0,
    retention_days/0,
    sweep/0,
    create/4,
    fetch/2,
    list/1,
    remove/2,
    materialize/2,
    has_references/1
]).

-define(MAX_FILE_BYTES, 52_428_800).    %% 50 MiB per file
-define(QUOTA_BYTES, 10_737_418_240).  %% 10 GiB per agent key
-define(MATERIALIZE_TEXT_CAP, 262_144). %% 256 KiB inlined per text file
-define(ID_PREFIX, <<"file-janus-">>).

%% Feature knob — same doctrine as the modality gates: settings key
%% `files` = {"enabled": true} via persistent_term; absent = OFF.
enabled() ->
    case persistent_term:get({janus, files_cfg}, undefined) of
        #{<<"enabled">> := true} -> true;
        _ -> false
    end.

%% Retention knob (same settings map): files older than N days are
%% swept (row + orphaned blob). 0/absent = keep forever.
retention_days() ->
    case persistent_term:get({janus, files_cfg}, undefined) of
        #{<<"retention_days">> := N} when is_number(N), N > 0 -> round(N);
        _ -> 0
    end.

%% One retention pass: delete expired rows, then delete blobs no row
%% references anymore (shared content-addressed blobs die with their
%% last row). Returns {deleted_rows, deleted_blobs}.
-spec sweep() -> {non_neg_integer(), non_neg_integer()}.
sweep() ->
    case retention_days() of
        0 ->
            {0, 0};
        Days ->
            Cutoff = os:system_time(second) - Days * 86400,
            case
                janus_db_conn:query(
                    <<"DELETE FROM files WHERE created_at < ? RETURNING sha256">>, [Cutoff]
                )
            of
                {ok, Rows} ->
                    Shas = lists:usort([S || {S} <- Rows]),
                    {length(Rows), gc_blobs(Shas, 0)};
                {error, Reason} ->
                    _ = logger:warning(#{what => files_sweep_failed, reason => Reason}),
                    {0, 0}
            end
    end.

gc_blobs([], N) ->
    N;
gc_blobs([Sha | Rest], N) ->
    case
        janus_db_conn:query(<<"SELECT 1 FROM files WHERE sha256 = ? LIMIT 1">>, [Sha])
    of
        {ok, []} ->
            _ = janus_files_store:delete(Sha),
            gc_blobs(Rest, N + 1);
        _ ->
            gc_blobs(Rest, N)
    end.

%% ---- API surface ---------------------------------------------------------

%% Upload: store bytes (content-addressed — a duplicate upload just
%% adds a metadata row over the same blob), insert metadata, return
%% the OpenAI File wire object.
-spec create(pos_integer(), binary(), binary(), binary()) ->
    {ok, map()} | {error, too_large | empty_file | quota_exceeded | term()}.
create(AgentKeyId, Filename, ContentType, Bytes) ->
    Size = byte_size(Bytes),
    if
        Size > ?MAX_FILE_BYTES ->
            {error, too_large};
        Size =:= 0 ->
            {error, empty_file};
        true ->
            case quota_headroom(AgentKeyId) of
                {ok, Free} when Free < Size ->
                    {error, quota_exceeded};
                {ok, _} ->
                    put_blob(AgentKeyId, Filename, ContentType, Bytes, Size)
            end
    end.

put_blob(AgentKeyId, Filename, ContentType, Bytes, Size) ->
    Sha = binary:encode_hex(crypto:hash(sha256, Bytes)),
    case janus_files_store:put(Sha, Bytes) of
        ok ->
            Id = <<?ID_PREFIX/binary, (unique_id())/binary>>,
            Now = os:system_time(second),
            case
                janus_db_conn:query(
                    <<"INSERT INTO files "
                      "(id, agent_key_id, filename, content_type, purpose, "
                      " sha256, size_bytes, created_at, store) "
                      "VALUES (?, ?, ?, ?, 'file-extract', ?, ?, ?, 'fs')">>,
                    [Id, AgentKeyId, Filename, ContentType, Sha, Size, Now]
                )
            of
                {ok, _} ->
                    {ok, file_object(Id, Filename, Size, Now)};
                {error, Reason} = Err ->
                    _ = logger:warning(#{
                        what => files_meta_insert_failed, reason => Reason
                    }),
                    Err
            end;
        {error, Reason} = Err ->
            _ = logger:warning(#{what => files_store_put_failed, reason => Reason}),
            Err
    end.

-spec fetch(pos_integer(), binary()) -> {ok, map(), binary()} | {error, not_found | term()}.
fetch(AgentKeyId, Id) ->
    case meta(AgentKeyId, Id) of
        {ok, #{sha256 := Sha} = Meta} ->
            case janus_files_store:get(Sha) of
                {ok, Bytes} ->
                    {ok, Meta#{id => Id}, Bytes};
                {error, not_found} ->
                    _ = logger:error(#{what => files_blob_missing, id => Id, sha256 => Sha}),
                    {error, not_found};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} = Err ->
            Err
    end.

-spec list(pos_integer()) -> {ok, [map()]}.
list(AgentKeyId) ->
    Sql =
        <<"SELECT id, filename, size_bytes, created_at, purpose "
          "FROM files WHERE agent_key_id = ? ORDER BY created_at DESC">>,
    case janus_db_conn:query(Sql, [AgentKeyId]) of
        {ok, Rows} ->
            {ok, [
                file_object(Id, Filename, Size, Created, Purpose)
             || {Id, Filename, Size, Created, Purpose} <- Rows
            ]};
        {error, Reason} ->
            _ = logger:warning(#{what => files_list_failed, reason => Reason}),
            {ok, []}
    end.

-spec remove(pos_integer(), binary()) -> ok | {error, not_found | term()}.
remove(AgentKeyId, Id) ->
    case meta(AgentKeyId, Id) of
        {ok, #{sha256 := Sha}} ->
            %% Row first: a dangling blob is invisible; the blob is
            %% shared by sha256, so delete it only when no row remains.
            case janus_db_conn:query(<<"DELETE FROM files WHERE id = ?">>, [Id]) of
                {ok, _} ->
                    case
                        janus_db_conn:query(
                            <<"SELECT 1 FROM files WHERE sha256 = ? LIMIT 1">>, [Sha]
                        )
                    of
                        {ok, []} ->
                            _ = janus_files_store:delete(Sha),
                            ok;
                        _ ->
                            ok
                    end;
                {error, Reason} = Err ->
                    _ = logger:warning(#{what => files_meta_delete_failed, reason => Reason}),
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% ---- Materialization -------------------------------------------------
%%
%% Pure rewrite of the OpenAI-chat body: every content part
%% {type: "file", file_id: <<"file-janus-...">>} OWNED by this agent
%% key becomes ordinary content. Foreign ids pass through. Runs in the
%% proxy BEFORE protocol translation, on the canonical chat shape.

-spec has_references(binary()) -> boolean().
has_references(RawBody) when is_binary(RawBody) ->
    %% Cheap raw-bytes gate before the structural rewrite: the
    %% gateway-owned id prefix, OpenAI inline file_data, or a
    %% Responses-face input_file part. False positives only cost a
    %% structural scan that changes nothing.
    binary:match(RawBody, ?ID_PREFIX) =/= nomatch orelse
        binary:match(RawBody, <<"file_data">>) =/= nomatch orelse
        binary:match(RawBody, <<"input_file">>) =/= nomatch.

-spec materialize(pos_integer(), map()) -> map().
%% Chat shape: messages[].content parts.
materialize(AgentKeyId, #{<<"messages">> := Messages} = Body) when is_list(Messages) ->
    Body#{<<"messages">> := [materialize_message(AgentKeyId, M) || M <- Messages]};
%% Responses shape (dsh and other Responses-face clients): input
%% items' content parts use input_file/input_text/input_image.
materialize(AgentKeyId, #{<<"input">> := Items} = Body) when is_list(Items) ->
    Body#{<<"input">> := [materialize_response_item(AgentKeyId, I) || I <- Items]};
materialize(_AgentKeyId, Body) ->
    Body.

materialize_response_item(AgentKeyId, #{<<"content">> := Parts} = Item) when is_list(Parts) ->
    Item#{<<"content">> := [materialize_response_part(AgentKeyId, P) || P <- Parts]};
materialize_response_item(_AgentKeyId, Item) ->
    Item.

materialize_response_part(AgentKeyId, #{<<"type">> := <<"input_file">>} = Part) ->
    case file_payload(Part) of
        {janus_id, Id} ->
            to_response_part(expand_janus_file(AgentKeyId, Id));
        {inline, Filename, DataUri} ->
            to_response_part(expand_inline_file(Filename, DataUri));
        foreign ->
            Part
    end;
materialize_response_part(_AgentKeyId, Part) ->
    Part.

%% The expand pipeline emits chat-shape parts; a Responses body must
%% carry Responses parts (input_text / input_image with a STRING
%% image_url — not the chat face's nested object).
to_response_part(#{<<"type">> := <<"text">>, <<"text">> := T}) ->
    #{<<"type">> => <<"input_text">>, <<"text">> => T};
to_response_part(#{<<"type">> := <<"image_url">>, <<"image_url">> := #{<<"url">> := U}}) ->
    #{<<"type">> => <<"input_image">>, <<"image_url">> => U};
to_response_part(Part) ->
    Part.

materialize_message(AgentKeyId, #{<<"content">> := Parts} = Msg) when is_list(Parts) ->
    Msg#{<<"content">> := [materialize_part(AgentKeyId, P) || P <- Parts]};
materialize_message(_AgentKeyId, Msg) ->
    Msg.

materialize_part(AgentKeyId, #{<<"type">> := <<"file">>} = Part) ->
    case file_payload(Part) of
        %% Gateway-owned reference: fetch + expand.
        {janus_id, Id} ->
            expand_janus_file(AgentKeyId, Id);
        %% OpenAI inline file object: bytes ride the request itself
        %% (no upload) — same expansion pipeline, no store round trip.
        {inline, Filename, DataUri} ->
            expand_inline_file(Filename, DataUri);
        %% Foreign provider file ids / unknown shapes: not our business.
        foreign ->
            Part
    end;
materialize_part(_AgentKeyId, Part) ->
    Part.

%% The OpenAI surface spells file references two ways: the flat
%% {file_id: "..."} and the nested {file: {file_id | file_data}}.
file_payload(#{<<"file_id">> := Id}) when is_binary(Id) ->
    case is_janus_id(Id) of
        true -> {janus_id, Id};
        false -> foreign
    end;
file_payload(#{<<"file">> := FileObj}) when is_map(FileObj) ->
    case FileObj of
        #{<<"file_id">> := Id} when is_binary(Id) ->
            case is_janus_id(Id) of
                true -> {janus_id, Id};
                false -> foreign
            end;
        #{<<"file_data">> := Data} when is_binary(Data), Data =/= <<>> ->
            Filename = maps:get(<<"filename">>, FileObj, <<"attachment">>),
            {inline, Filename, Data};
        _ ->
            foreign
    end;
file_payload(_) ->
    foreign.

expand_inline_file(Filename, DataUri) ->
    case parse_data_uri(DataUri) of
        {ok, Mime, Bytes} ->
            case is_image(Mime) of
                true ->
                    #{
                        <<"type">> => <<"image_url">>,
                        <<"image_url">> => #{
                            <<"url">> => <<"data:", Mime/binary, ";base64,",
                                          (base64:encode(Bytes))/binary>>
                        }
                    };
                false ->
                    text_part(Filename, Mime, Bytes)
            end;
        {error, bad_data_uri} ->
            note(<<"file part carries an unparsable data URI">>)
    end.

parse_data_uri(<<"data:", Rest/binary>>) ->
    case binary:split(Rest, <<",">>) of
        [Meta, Payload] ->
            case binary:split(Meta, <<";">>) of
                [Mime0, <<"base64">>] ->
                    Mime = case Mime0 of
                        <<>> -> <<"application/octet-stream">>;
                        _ -> Mime0
                    end,
                    try {ok, Mime, base64:decode(Payload)}
                    catch _:_ -> {error, bad_data_uri}
                    end;
                _ ->
                    %% Non-base64 data URIs (rare, plain text): treat the
                    %% payload as utf-8 text.
                    {ok, <<"text/plain">>, Payload}
            end;
        _ ->
            {error, bad_data_uri}
    end;
parse_data_uri(_) ->
    {error, bad_data_uri}.

expand_janus_file(AgentKeyId, Id) ->
    case fetch(AgentKeyId, Id) of
        {ok, Meta, Bytes} ->
            Mime = maps:get(content_type, Meta),
            Filename = maps:get(filename, Meta),
            case is_image(Mime) of
                true ->
                    #{
                        <<"type">> => <<"image_url">>,
                        <<"image_url">> => #{
                            <<"url">> =>
                                <<"data:", Mime/binary, ";base64,",
                                  (base64:encode(Bytes))/binary>>
                        }
                    };
                false ->
                    text_part(Filename, Mime, Bytes)
            end;
        {error, not_found} ->
            note(<<"file not found: ", Id/binary>>);
        {error, Reason} ->
            note(<<"file unavailable: ", (fmt(Reason))/binary>>)
    end.

text_part(Filename, Mime, Bytes) ->
    Prefix = <<"[file: ", Filename/binary, " (", Mime/binary, ")]\n">>,
    case unicode:characters_to_binary(Bytes) of
        Text when is_binary(Text), byte_size(Text) =< ?MATERIALIZE_TEXT_CAP ->
            #{<<"type">> => <<"text">>, <<"text">> => <<Prefix/binary, Text/binary>>};
        _ ->
            %% Non-UTF8 or oversized: inline a bounded prefix with an
            %% explicit truncation marker — never a silent drop.
            Head = binary:part(Bytes, 0, min(byte_size(Bytes), ?MATERIALIZE_TEXT_CAP)),
            Marker = iolist_to_binary([
                <<"[file: ", Filename/binary, " (", Mime/binary, ", ",
                  (integer_to_binary(byte_size(Bytes)))/binary, " bytes, truncated)]\n">>
            ]),
            #{<<"type">> => <<"text">>, <<"text">> => <<Marker/binary, Head/binary>>}
    end.

note(Msg) ->
    #{<<"type">> => <<"text">>, <<"text">> => <<"[", Msg/binary, "]">>}.

is_image(<<"image/", _/binary>>) -> true;
is_image(_) -> false.

is_janus_id(Id) when is_binary(Id) ->
    P = ?ID_PREFIX,
    byte_size(Id) >= byte_size(P) andalso binary:part(Id, 0, byte_size(P)) =:= P;
is_janus_id(_) ->
    false.

%% ---- internals -----------------------------------------------------------

quota_headroom(AgentKeyId) ->
    case
        janus_db_conn:query(
            <<"SELECT COALESCE(SUM(size_bytes), 0) FROM files WHERE agent_key_id = ?">>,
            [AgentKeyId]
        )
    of
        {ok, [{Used}]} when is_number(Used) ->
            {ok, max(0, ?QUOTA_BYTES - Used)};
        _ ->
            %% Unknown usage never blocks an upload below the per-file cap.
            {ok, ?QUOTA_BYTES}
    end.

meta(AgentKeyId, Id) ->
    case
        janus_db_conn:query(
            <<"SELECT filename, content_type, purpose, sha256, size_bytes, created_at "
              "FROM files WHERE id = ? AND agent_key_id = ?">>,
            [Id, AgentKeyId]
        )
    of
        {ok, [{Filename, ContentType, Purpose, Sha, Size, Created}]} ->
            {ok, #{
                filename => Filename,
                content_type => ContentType,
                purpose => Purpose,
                sha256 => Sha,
                size_bytes => Size,
                created_at => Created
            }};
        _ ->
            {error, not_found}
    end.

file_object(Id, Filename, Size, Created) ->
    file_object(Id, Filename, Size, Created, <<"file-extract">>).

file_object(Id, Filename, Size, Created, Purpose) ->
    #{
        id => Id,
        object => <<"file">>,
        bytes => Size,
        created_at => Created,
        filename => Filename,
        purpose => Purpose,
        status => <<"processed">>
    }.

unique_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8)).

fmt(T) when is_binary(T) -> T;
fmt(T) -> list_to_binary(io_lib:format("~p", [T])).
