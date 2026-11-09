%% The mid-stream construct sentinel must log the offending frame's STRUCTURE
%% and never its content.
%%
%% Rationale: docs/design/shape-sentinel.md forbids content in these logs, and
%% an SSE frame can carry the entire answer. This sentinel is the only
%% gateway-side evidence for "upstream sent an unsupported stream construct",
%% so it has to be both useful (event name + key names) and safe (no values).
%%
%% The discipline lives in the pure sketch helpers, so that is what is pinned
%% here — running a logger handler inside the sentinel's own path deadlocks
%% against its dedup-table owner.
-module(janus_shape_capture_capture_tests).

-include_lib("eunit/include/eunit.hrl").

frame_shape_reduces_values_to_types_test() ->
    Frame = #{
        type => <<"content_block_delta">>,
        data => #{
            <<"index">> => 7,
            <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => <<"SECRET">>}
        }
    },
    Shape = janus_shape_capture:stream_frame_shape(Frame),
    Rendered = iolist_to_binary(io_lib:format("~0p", [Shape])),
    %% Structure is retained: the event name and the data key names.
    ?assert(binary:match(Rendered, <<"content_block_delta">>) =/= nomatch),
    ?assert(binary:match(Rendered, <<"delta">>) =/= nomatch),
    %% Content is not: no value ever reaches the sketch.
    ?assertEqual(nomatch, binary:match(Rendered, <<"SECRET">>)),
    %% The event name survives verbatim — it is protocol vocabulary, and it is
    %% the field that actually answers "which construct".
    ?assert(binary:match(Rendered, <<"event =>">>) =/= nomatch),
    %% An integer becomes a type label, never the number itself.
    ?assertEqual(nomatch, binary:match(Rendered, <<"7">>)).

%% A binary payload reports only emptiness, never its bytes — an SSE data
%% field can carry the whole answer.
binary_values_are_labelled_not_echoed_test() ->
    ?assertEqual(binary, janus_shape_capture:typed_value(<<"anything at all">>)),
    ?assertEqual(empty, janus_shape_capture:typed_value(<<>>)).

%% Scalars and nested shapes degrade to labels rather than being echoed.
non_map_frames_are_labelled_test() ->
    ?assertEqual(binary, janus_shape_capture:typed_value(<<"x">>)),
    ?assertEqual(integer, janus_shape_capture:typed_value(1)),
    ?assertEqual(list, janus_shape_capture:typed_value([])),
    ?assertEqual(map, janus_shape_capture:typed_value(#{})).

%% `type` is not a closed vocabulary at this point: sse_event/2 copies the
%% provider's raw `event:` line into the frame, so an upstream can put
%% arbitrary bytes there. Only allow-listed names are echoed; anything else is
%% labelled, so this log line can never carry provider-controlled content.
unknown_event_names_are_labelled_test() ->
    Attacker = <<"my-whole-secret-answer-is-here">>,
    Frame = #{type => Attacker, data => #{<<"a">> => <<"b">>}},
    Rendered = iolist_to_binary(io_lib:format("~0p", [janus_shape_capture:stream_frame_shape(Frame)])),
    ?assertEqual(nomatch, binary:match(Rendered, Attacker)),
    ?assert(binary:match(Rendered, <<"unknown_event">>) =/= nomatch),
    %% A known one is still echoed, so the diagnostic still works.
    Known = #{type => <<"content_block_delta">>, data => #{}},
    Rendered2 = iolist_to_binary(io_lib:format("~0p", [janus_shape_capture:stream_frame_shape(Known)])),
    ?assert(binary:match(Rendered2, <<"content_block_delta">>) =/= nomatch).
