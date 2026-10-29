%% File-materialization bounds regression (security audit run-1,
%% confirmed gateway/apps/janus_http/src/janus_files.erl:materialize:
%% unbounded-file-reference-expansion). materialize/2 expanded EVERY
%% file reference independently with no aggregate bound — one chat
%% request repeating a stored file id N times expanded the blob N
%% times (measured 1560x amplification at 1024 refs; a 50 MiB image
%% makes each ~54-byte reference worth ~66.7 MB, so one ~5 MiB body
%% could demand terabytes) — before any model ACL or token charge.
%%
%% The fix bounds the walk: max ?MAX_FILE_REFS references, aggregate
%% ?MAX_EXPAND_BYTES budget, per-request memoization (one repeated id
%% expands once), and a distinct 413 file_expansion_limit at the
%% proxy. These tests drive the exported materialize/2 against a
%% scratch ETS-backed file row; like the other suites here they run
%% via `rebar3 eunit` (CI compiles/formats only).
-module(janus_files_materialize_bounds_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TAB, files).

%% Scratch DB stub: janus_files:meta/2 selects from the `files`
%% table via janus_db_conn — we stand up the named table the query
%% layer reads and point the store at a scratch dir. The full
%% janus_db_conn stack is heavy for eunit; instead exercise the bound
%% arithmetic through the INLINE path (no store round trip): inline
%% file_data URIs ride the request and expand through the same
%% budgeted pipeline (charge/2), so they pin the same invariant
%% without any DB.

inline_uri(Text) ->
    <<"data:text/plain;base64,", (base64:encode(Text))/binary>>.

part(Uri) ->
    #{<<"type">> => <<"file">>, <<"file">> => #{<<"file_data">> => Uri}}.

refs(N, Uri) ->
    [part(Uri) || _ <- lists:seq(1, N)].

expansion_limit_trips_test() ->
    Content = refs(65, inline_uri(<<"x">>)),
    Body = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Content}]},
    ?assertEqual({error, file_expansion_limit}, janus_files:materialize(1, Body)).

within_bounds_passes_test() ->
    Uri = inline_uri(<<"hello">>),
    Content = refs(8, Uri),
    Body = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Content}]},
    %% 8 tiny inline refs are far inside both bounds: the rewrite
    %% succeeds and the message shape survives.
    ?assertMatch(#{<<"messages">> := [_]}, janus_files:materialize(1, Body)).

byte_budget_trips_test() ->
    %% IMAGE parts inline the whole blob as a data URI with no
    %% per-part cap: 64 refs x ~2 MB (base64 of 1.5 MB) ~= 128 MB
    %% exceeds the 72 MB budget at the 64-ref cap — the byte budget
    %% is the bound that trips (a text part would be truncated to
    %% 256 KiB and could never cross it inside 64 refs).
    Big = binary:copy(<<"A">>, 1_500_000),
    Uri = <<"data:image/png;base64,", (base64:encode(Big))/binary>>,
    Content = refs(50, Uri),
    Body = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Content}]},
    ?assertEqual({error, file_expansion_limit}, janus_files:materialize(1, Body)).


responses_part(Uri) ->
    #{<<"type">> => <<"input_file">>, <<"file">> => #{<<"file_data">> => Uri}}.

responses_refs(N, Uri) ->
    [responses_part(Uri) || _ <- lists:seq(1, N)].

ref_cap_boundary_test() ->
    Uri = inline_uri(<<"x">>),
    %% Exactly at the cap passes; one more trips. The cap lives in the
    %% module (?MAX_FILE_REFS = 64) — mirrored here as a literal so a
    %% cap change forces this suite to be revisited.
    Cap = 64,
    Ok = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => refs(Cap, Uri)}]},
    ?assertMatch(#{<<"messages">> := [_]}, janus_files:materialize(1, Ok)),
    Over = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => refs(Cap + 1, Uri)}]},
    ?assertEqual({error, file_expansion_limit}, janus_files:materialize(1, Over)).

non_map_part_before_refs_test() ->
    %% A non-map member ahead of the refs must neither crash the walk
    %% (hard-matched {ok,...}) nor reset the face so later parts skip
    %% expansion — the bound still trips with the clean error.
    Content = [<<"not-a-map">> | refs(65, inline_uri(<<"x">>))],
    Body = #{<<"model">> => <<"m">>, <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => Content}]},
    ?assertEqual({error, file_expansion_limit}, janus_files:materialize(1, Body)).

non_map_message_still_expands_test() ->
    %% A non-map ITEM (message-level) ahead of file parts: the tail
    %% must still expand — assert the walk rewrites later parts (the
    %% inline text becomes a {type:text} part, not the raw file map).
    Uri = inline_uri(<<"hi">>),
    Msg = #{<<"role">> => <<"user">>, <<"content">> => [part(Uri)]},
    Body = #{<<"model">> => <<"m">>, <<"messages">> => [<<"bare">>, Msg]},
    #{<<"messages">> := [<<"bare">>, #{<<"content">> := [P | _]}]} =
        janus_files:materialize(1, Body),
    ?assertMatch(#{<<"type">> := <<"text">>}, P).

responses_face_byte_budget_test() ->
    %% The Responses face converts images to input_image with a BINARY
    %% image_url — byte accounting must charge that shape (a 0-byte
    %% miss would let 64 refs x ~66 MB through).
    Big = binary:copy(<<"A">>, 1_500_000),
    Uri = <<"data:image/png;base64,", (base64:encode(Big))/binary>>,
    Content = responses_refs(64, Uri),
    Body = #{<<"model">> => <<"m">>, <<"input">> => [#{<<"content">> => Content}]},
    ?assertEqual({error, file_expansion_limit}, janus_files:materialize(1, Body)).
