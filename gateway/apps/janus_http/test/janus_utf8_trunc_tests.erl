%% Terminal-frame truncation (2026-10-29).
%%
%% A terminal error frame carries the UPSTREAM's own words, which are
%% often non-ASCII (the incident providers replied in Chinese). The
%% message is capped at 200 BYTES before encoding, and a naive byte cut
%% can split a multi-byte UTF-8 codepoint — the encoder emits such bytes
%% unescaped, so the client receives invalid UTF-8 JSON and rejects the
%% very frame explaining the failure.
-module(janus_utf8_trunc_tests).

-include_lib("eunit/include/eunit.hrl").

%% 100 three-byte characters = 300 bytes, so a 200-byte cut lands in the
%% middle of a codepoint.
chinese_cut_stays_valid_test() ->
    Msg = unicode:characters_to_binary(lists:duplicate(100, <<"中"/utf8>>)),
    ?assert(byte_size(Msg) > 200),
    Cut = janus_protocol_translate:trunc_200(Msg),
    ?assert(byte_size(Cut) =< 200),
    ?assertEqual(Cut, unicode:characters_to_binary(Cut)).

%% Every cut point across a boundary must yield valid UTF-8, not just the
%% one at 200: the trimmer must not assume a magic length.
all_cut_lengths_valid_test() ->
    Msg = unicode:characters_to_binary(lists:duplicate(20, <<"中文a"/utf8>>)),
    lists:foreach(
        fun(N) ->
            Cut = binary:part(Msg, 0, N),
            Trimmed = janus_protocol_translate:trim_partial_utf8(Cut),
            ?assertEqual(Trimmed, unicode:characters_to_binary(Trimmed))
        end,
        lists:seq(0, byte_size(Msg))
    ).

%% Short ASCII passes through untouched.
short_passthrough_test() ->
    ?assertEqual(<<"boom">>, janus_protocol_translate:trunc_200(<<"boom">>)).

%% Exactly 200 bytes is not truncated (boundary is exclusive).
exact_limit_untouched_test() ->
    B = binary:copy(<<"a">>, 200),
    ?assertEqual(B, janus_protocol_translate:trunc_200(B)).