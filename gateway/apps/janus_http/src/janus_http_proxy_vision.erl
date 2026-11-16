%%%-------------------------------------------------------------------
%%% @doc Vision / image-shape detection for the data-plane proxy.
%%% Extracted from `janus_http_proxy` so OCR can scan the orchestrator
%%% under the line budget. Inputs to the tier walk vision gate.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_proxy_vision).

-export([request_has_image/1]).

%% Both keys, OR-ed rather than first-match: a body carrying `messages`
%% and `input` together would otherwise have its images inspected only in
%% whichever key happened to be listed first — the same blindness this
%% function exists to remove, moved to a different axis.
request_has_image(Map) when is_map(Map) ->
    item_list_has_image(maps:get(<<"messages">>, Map, undefined)) orelse
        item_list_has_image(maps:get(<<"input">>, Map, undefined));
request_has_image(_) ->
    false.

item_list_has_image(Items) when is_list(Items) ->
    lists:any(fun item_has_image/1, Items);
item_list_has_image(_) ->
    false.

%% An image can ride an input item in more places than a user message's
%% content array, and the places it does not cover are the agent ones:
%%
%%   - a standalone `input_image` item at the top level of `input`
%%     (a Responses client may hoist it out of `content`),
%%   - a tool result: `function_call_output.output` may be a list of
%%     parts, which is exactly where a screenshot from a tool lands.
%%
%% Missing either one makes the tier walk's vision gate blind for the
%% requests that carry the most images, and the walk then hands the
%% image to a model that cannot read it — the client sees an upstream
%% 400 that names neither the model nor the image.
%% One clause, OR-ing every place an image can sit, rather than clauses
%% keyed on `content` / `output` in order: an item is allowed to carry
%% more than one of them, and a first-match walk would inspect only the
%% first key present. That is the same blindness this change removes,
%% just moved to a different shape.
%% `computer_call_output` is never itself an image part — the screenshot
%% lives in its `output` — so only `content` and `output` are read here.
item_has_image(#{<<"type">> := <<"computer_call_output">>} = M) ->
    container_has_image(maps:get(<<"content">>, M, undefined)) orelse
        output_object_has_image(maps:get(<<"output">>, M, undefined));
item_has_image(M) when is_map(M) ->
    part_is_image(M) orelse container_has_image(maps:get(<<"content">>, M, undefined)) orelse
        container_has_image(maps:get(<<"output">>, M, undefined));
item_has_image(_) ->
    false.

%% The one item type whose `output` is an OBJECT rather than a list: a
%% Responses `computer_call_output` wraps its screenshot that way. Listed
%% types are kept narrow on purpose — see container_has_image/1.
output_object_has_image(Inner) when is_map(Inner) ->
    item_has_image(Inner);
output_object_has_image(Inner) ->
    container_has_image(Inner).

%% `content` / `output` may be a list of parts, or a plain string (a
%% text-only tool result). Only the LIST form can hide an image here.
%%
%% A map-valued `output` is handled by its own clause in item_has_image/1
%% and only for `computer_call_output`: elsewhere a map is not a part at
%% all (the translate layer accepts a tool result as binary, null or a
%% list, and rejects a map as malformed). Recursing into any map would
%% report a browser or image-search tool result whose JSON happens to
%% carry an `image_url` field as image-bearing, moving a text-only
%% request onto the vision pool.
container_has_image(Parts) when is_list(Parts) ->
    lists:any(fun item_has_image/1, Parts);
container_has_image(_) ->
    false.

%% Type first, data second. The type name is required for every shape:
%% a tool result is free-form JSON, so a browser or image-search tool
%% echoing a result that happens to contain an `image_url` field would
%% otherwise read as image-bearing and push a text-only request onto the
%% vision pool — or exhaust an all-blind tier over a request that carried
%% no image. This also matches the translate layer, which decides by type
%% and rejects an unrecognized part rather than passing it through.
%%
%% A `computer_screenshot` is in the allowlist for exactly this reason:
%% its data lives in `image_url` but its type is its own.
part_is_image(P) when is_map(P) ->
    is_image_type(P) andalso part_carries_image_data(P);
part_is_image(_) ->
    false.

%% The three data fields are INDEPENDENT and OR-ed. Keying on one in
%% order hides the others: an SDK that serializes an unused optional
%% field as `image_url: null` beside a valid `source` would match the
%% `image_url` clause, find no url, and never look at `source` — blind
%% for a genuine image, which is the failure this whole change removes.
part_carries_image_data(P) when is_map(P) ->
    url_has_image(maps:get(<<"image_url">>, P, undefined)) orelse
        source_has_image(maps:get(<<"source">>, P, undefined)) orelse
        references_a_file(P).

%% Anthropic carries the bytes in `source` rather than `image_url`. Both
%% accepted forms are spelled out to match image_block_to_chat_part/1
%% exactly: a base64 source needs a non-empty media_type AND data, a url
%% source a non-empty url. Anything else is an error there, so accepting
%% it here would mark a data-less part vision-bearing and route a request
%% onto the vision pool over an image it does not carry.
source_has_image(#{<<"type">> := <<"base64">>, <<"media_type">> := MT, <<"data">> := Data}) when
    is_binary(MT), MT =/= <<>>, is_binary(Data), Data =/= <<>>
->
    true;
source_has_image(#{<<"type">> := <<"url">>, <<"url">> := U}) when is_binary(U), U =/= <<>> ->
    true;
source_has_image(_) ->
    false.

url_has_image(U) when is_binary(U) -> U =/= <<>>;
url_has_image(#{<<"url">> := U}) when is_binary(U) -> U =/= <<>>;
url_has_image(_) -> false.

is_image_type(#{<<"type">> := T}) ->
    lists:member(T, [
        <<"image_url">>, <<"image">>, <<"input_image">>, <<"computer_screenshot">>
    ]);
is_image_type(_) ->
    false.

%% A `file_id` only makes a part an image when the part is claiming to be
%% one: an ordinary text part that happens to carry a file attachment is
%% still text, and counting it would move a text-only request onto the
%% vision pool.
references_a_file(P) ->
    non_empty_file_id(P).

non_empty_file_id(#{<<"file_id">> := F}) when is_binary(F), F =/= <<>> -> true;
non_empty_file_id(_) -> false.
