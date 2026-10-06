%%%-------------------------------------------------------------------
%%% @doc EUnit for the audio modality plugins (spec M2.1/M2.2): the
%%% pure multipart parser (janus_multipart), the TTS plugin
%%% (janus_m_audio_speech) and the ASR plugin (janus_m_audio_asr).
%%%
%%% Written BEFORE the implementations. Fixtures are production
%%% shapes: a REAL curl -F shaped multipart body (CRLF line endings,
%%% Content-Disposition headers, binary WAV payload with embedded
%%% CRLF/NUL bytes and a near-boundary trap), plus the two CAPTURED
%%% mimo probe replies (test/fixtures/probes/mimo_asr.json,
%%% mimo_tts_chat2.json) driving the translator/extractor functions.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_audio_tests).

-include_lib("eunit/include/eunit.hrl").

%%%-------------------------------------------------------------------
%%% Fixture material — curl -F emitted body, verbatim shape
%%%-------------------------------------------------------------------

%% The boundary TOKEN exactly as curl generates it (dashes are part
%% of the token; the delimiter LINE is "--" ++ token).
boundary() ->
    <<"------------------------d74496d66958873e">>.

content_type_header() ->
    <<"multipart/form-data; boundary=------------------------d74496d66958873e">>.

%% WAV-looking binary: RIFF/WAVE magic, NUL and 0xFF bytes, embedded
%% CRLF pairs, and a NEAR-BOUNDARY TRAP (CRLF + "--" + the boundary
%% token minus its LAST byte, then junk): the parser must only ever
%% cut on the FULL delimiter, so the trap bytes stay inside the
%% payload.
payload() ->
    B = boundary(),
    Almost = binary:part(B, 0, byte_size(B) - 1),
    Trap = <<"\r\n--", Almost/binary>>,
    <<"RIFF", 36:32/little, "WAVEfmt ", 16#00, 16#FF, 16#0D, 16#0A, "\r\n", Trap/binary,
        " almost a delimiter\r\n", 16#01, 16#02, 16#FF, 16#00, 16#00>>.

multipart_body() ->
    D = <<"--", (boundary())/binary>>,
    P = payload(),
    iolist_to_binary([
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
        "mimo-v2.5-asr\r\n",
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
        "zh\r\n",
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n"
        "unknown field: parser returns it, plugin ignores it\r\n",
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\n"
        "Content-Type: audio/wav\r\n\r\n",
        P,
        "\r\n",
        D,
        "--\r\n"
    ]).

multipart_two_files_body() ->
    D = <<"--", (boundary())/binary>>,
    iolist_to_binary([
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
        "mimo-v2.5-asr\r\n",
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\n"
        "Content-Type: audio/wav\r\n\r\n"
        "first-bytes\r\n",
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"no-type.bin\"\r\n\r\n"
        "second-bytes\r\n",
        D,
        "--"
    ]).

%%%-------------------------------------------------------------------
%%% janus_multipart — whole-body parse
%%%-------------------------------------------------------------------

parse_curl_shaped_body_test() ->
    {ok, Got} = janus_multipart:parse(multipart_body(), boundary()),
    ?assertEqual(
        #{
            fields => #{
                <<"model">> => <<"mimo-v2.5-asr">>,
                <<"language">> => <<"zh">>,
                <<"prompt">> => <<"unknown field: parser returns it, plugin ignores it">>
            },
            files => [
                #{
                    name => <<"file">>,
                    filename => <<"probe.wav">>,
                    content_type => <<"audio/wav">>,
                    data => payload()
                }
            ]
        },
        Got
    ).

two_files_keep_body_order_test() ->
    {ok, #{fields := Fields, files := Files}} =
        janus_multipart:parse(multipart_two_files_body(), boundary()),
    ?assertEqual(#{<<"model">> => <<"mimo-v2.5-asr">>}, Fields),
    ?assertEqual(2, length(Files)),
    [F1, F2] = Files,
    ?assertEqual(#{name => <<"file">>, filename => <<"probe.wav">>, content_type => <<"audio/wav">>, data => <<"first-bytes">>}, F1),
    ?assertEqual(
        #{name => <<"file">>, filename => <<"no-type.bin">>, content_type => undefined, data => <<"second-bytes">>},
        F2
    ).

epilogue_after_close_ignored_test() ->
    D = <<"--", (boundary())/binary>>,
    Body = iolist_to_binary([
        D,
        "\r\n"
        "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
        "m\r\n",
        D,
        "--\r\n",
        "trailing epilogue garbage the RFC allows and we discard"
    ]),
    ?assertEqual(
        {ok, #{fields => #{<<"model">> => <<"m">>}, files => []}},
        janus_multipart:parse(Body, boundary())
    ).

empty_body_ok_test() ->
    D = <<"--", (boundary())/binary>>,
    ?assertEqual(
        {ok, #{fields => #{}, files => []}},
        janus_multipart:parse(<<D/binary, "--">>, boundary())
    ).

no_boundary_error_test() ->
    ?assertEqual(
        {error, bad_multipart},
        janus_multipart:parse(<<"just some plain bytes, no delimiter at all">>, boundary())
    ).

truncated_body_error_test() ->
    %% close delimiter never arrives — malformed, must not silently
    %% emit the dangling part.
    D = <<"--", (boundary())/binary>>,
    Body = iolist_to_binary([
        D, "\r\n", "Content-Disposition: form-data; name=\"model\"\r\n\r\n", "m"
    ]),
    ?assertEqual({error, bad_multipart}, janus_multipart:parse(Body, boundary())).

%%%-------------------------------------------------------------------
%%% janus_multipart — chunked feeds (straddling boundaries/payloads)
%%%-------------------------------------------------------------------

stream_equals_whole_parse_at_every_split_test() ->
    Body = multipart_body(),
    B = boundary(),
    {ok, Expected} = janus_multipart:parse(Body, B),
    Size = byte_size(Body),
    %% EVERY two-chunk split: covers a split inside the boundary
    %% token, inside a header line, inside the payload and inside the
    %% close delimiter.
    [
        begin
            ?assertEqual(
                {ok, Expected},
                janus_multipart:parse_stream(
                    [binary:part(Body, 0, I), binary:part(Body, I, Size - I)], B
                )
            )
        end
     || I <- lists:seq(1, Size - 1)
    ],
    ok.

stream_byte_at_a_time_test() ->
    Body = multipart_two_files_body(),
    {ok, Expected} = janus_multipart:parse(Body, boundary()),
    Chunks = [<<C>> || <<C>> <= Body],
    ?assertEqual({ok, Expected}, janus_multipart:parse_stream(Chunks, boundary())).

stream_boundary_straddling_three_chunks_test() ->
    %% Chunks hand-cut so one seam lands INSIDE the boundary token of
    %% the delimiter right after the "prompt" field, and the next seam
    %% inside the following part's header block.
    B = boundary(),
    Body = multipart_body(),
    Delim = <<"\r\n--", B/binary>>,
    {PromptEnd, _} = binary:match(Body, Delim),
    SplitA = PromptEnd + byte_size(B),
    SplitB = SplitA + byte_size(B) + 20,
    Chunks = [
        binary:part(Body, 0, SplitA),
        binary:part(Body, SplitA, SplitB - SplitA),
        binary:part(Body, SplitB, byte_size(Body) - SplitB)
    ],
    ?assertEqual(janus_multipart:parse(Body, B), janus_multipart:parse_stream(Chunks, B)).

%%%-------------------------------------------------------------------
%%% janus_multipart — boundary extraction from the content-type
%%%-------------------------------------------------------------------

boundary_of_plain_test() ->
    ?assertEqual(
        {ok, boundary()},
        janus_multipart:boundary_of(content_type_header())
    ).

boundary_of_quoted_with_params_test() ->
    ?assertEqual(
        {ok, <<"WebKitFormBoundaryX1y2Z3">>},
        janus_multipart:boundary_of(<<"multipart/form-data; charset=UTF-8; boundary=\"WebKitFormBoundaryX1y2Z3\"">>)
    ).

boundary_of_missing_test() ->
    ?assertEqual(error, janus_multipart:boundary_of(<<"multipart/form-data">>)),
    ?assertEqual(error, janus_multipart:boundary_of(<<"application/json">>)),
    ?assertEqual(error, janus_multipart:boundary_of(<<"multipart/mixed; boundary=x">>)).

%%%-------------------------------------------------------------------
%%% TTS plugin (janus_m_audio_speech) — pure surface
%%%-------------------------------------------------------------------

tts_default_input_cap_test() ->
    persistent_term:erase({janus, tts_max_input_chars}),
    ?assertEqual(5000, janus_m_audio_speech:max_input_chars()).

tts_input_cap_enforced_test() ->
    persistent_term:erase({janus, tts_max_input_chars}),
    Cap = janus_m_audio_speech:max_input_chars(),
    ?assertEqual(
        {ok, <<"mimo-v2.5-tts">>, binary:copy(<<"a">>, Cap)},
        janus_m_audio_speech:validate(#{
            <<"model">> => <<"mimo-v2.5-tts">>,
            <<"input">> => binary:copy(<<"a">>, Cap)
        })
    ),
    ?assertEqual(
        {error, input_too_long},
        janus_m_audio_speech:validate(#{
            <<"model">> => <<"mimo-v2.5-tts">>,
            <<"input">> => binary:copy(<<"a">>, Cap + 1)
        })
    ).

tts_input_cap_knob_override_test() ->
    persistent_term:put({janus, tts_max_input_chars}, 10),
    ?assertEqual(10, janus_m_audio_speech:max_input_chars()),
    ?assertEqual(
        {error, input_too_long},
        janus_m_audio_speech:validate(#{
            <<"model">> => <<"m">>, <<"input">> => binary:copy(<<"a">>, 11)
        })
    ),
    persistent_term:erase({janus, tts_max_input_chars}).

tts_validate_missing_and_bad_params_test() ->
    ?assertEqual({error, missing_model}, janus_m_audio_speech:validate(#{<<"input">> => <<"x">>})),
    ?assertEqual(
        {error, missing_input}, janus_m_audio_speech:validate(#{<<"model">> => <<"m">>})
    ),
    ?assertEqual(
        {error, invalid_input}, janus_m_audio_speech:validate(#{<<"model">> => <<"m">>, <<"input">> => 7})
    ).

tts_translate_request_shape_test() ->
    ?assertEqual(
        #{
            <<"model">> => <<"mimo-v2.5-tts">>,
            <<"messages">> => [
                #{<<"role">> => <<"user">>, <<"content">> => <<"read this aloud">>},
                #{<<"role">> => <<"assistant">>, <<"content">> => <<"你好，世界"/utf8>>}
            ]
        },
        janus_m_audio_speech:translate_request(<<"mimo-v2.5-tts">>, <<"你好，世界"/utf8>>)
    ).

tts_extract_audio_from_captured_probe_test() ->
    #{<<"response">> := Resp} = decode_fixture(<<"mimo_tts_chat2.json">>),
    {ok, B64} = janus_m_audio_speech:extract_audio(Resp),
    Bin = base64:decode(B64),
    ?assertEqual(<<"RIFF">>, binary:part(Bin, 0, 4)),
    ?assertEqual(<<"WAVE">>, binary:part(Bin, 8, 4)).

tts_extract_audio_rejects_audioless_reply_test() ->
    %% the ASR capture has message.audio = null: a 2xx without audio
    %% data must surface as an error, never as empty audio bytes.
    #{<<"response">> := Resp} = decode_fixture(<<"mimo_asr.json">>),
    ?assertEqual(error, janus_m_audio_speech:extract_audio(Resp)).

tts_reply_content_type_test() ->
    %% mimo answers the chat envelope as application/json — the audio
    %% default carries (WAV per capture); an explicit audio/* header
    %% (params stripped) wins when a provider sets one.
    ?assertEqual(<<"audio/wav">>, janus_m_audio_speech:speech_content_type(#{})),
    ?assertEqual(
        <<"audio/wav">>,
        janus_m_audio_speech:speech_content_type(#{<<"content-type">> => <<"application/json">>})
    ),
    ?assertEqual(
        <<"audio/mpeg">>,
        janus_m_audio_speech:speech_content_type(#{<<"content-type">> => <<"audio/mpeg">>})
    ),
    ?assertEqual(
        <<"audio/wav">>,
        janus_m_audio_speech:speech_content_type(#{<<"content-type">> => <<"audio/wav; charset=binary">>})
    ).

tts_modality_and_caps_test() ->
    ?assertEqual(<<"tts">>, janus_m_audio_speech:modality()),
    ?assert(janus_m_audio_speech:max_body() > 8192).

%%%-------------------------------------------------------------------
%%% ASR plugin (janus_m_audio_asr) — pure surface
%%%-------------------------------------------------------------------

asr_modality_and_body_cap_test() ->
    ?assertEqual(<<"asr">>, janus_m_audio_asr:modality()),
    ?assertEqual(25 * 1024 * 1024, janus_m_audio_asr:max_body()).

asr_options_language_test() ->
    ?assertEqual({ok, #{language => auto}}, janus_m_audio_asr:asr_options(#{})),
    ?assertEqual(
        {ok, #{language => auto}}, janus_m_audio_asr:asr_options(#{<<"language">> => <<"auto">>})
    ),
    ?assertEqual({ok, #{language => zh}}, janus_m_audio_asr:asr_options(#{<<"language">> => <<"zh">>})),
    ?assertEqual({ok, #{language => en}}, janus_m_audio_asr:asr_options(#{<<"language">> => <<"en">>})),
    ?assertEqual(
        {error, invalid_language}, janus_m_audio_asr:asr_options(#{<<"language">> => <<"fr">>})
    ).

asr_file_mime_test() ->
    ?assertEqual(<<"audio/wav">>, janus_m_audio_asr:file_mime(undefined)),
    ?assertEqual(<<"audio/wav">>, janus_m_audio_asr:file_mime(<<"audio/wav">>)),
    ?assertEqual(<<"audio/mpeg">>, janus_m_audio_asr:file_mime(<<"audio/mpeg">>)),
    ?assertEqual(<<"audio/mp4">>, janus_m_audio_asr:file_mime(<<"Audio/MP4; codecs=mp4a.40.2">>)).

asr_build_request_shape_test() ->
    File = #{
        name => <<"file">>,
        filename => <<"probe.wav">>,
        content_type => <<"audio/wav">>,
        data => payload()
    },
    #{<<"model">> := <<"mimo-v2.5-asr">>, <<"messages">> := [Msg]} =
        janus_m_audio_asr:build_request(<<"mimo-v2.5-asr">>, File),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Msg)),
    [AudioPart] = maps:get(<<"content">>, Msg),
    ?assertEqual(<<"input_audio">>, maps:get(<<"type">>, AudioPart)),
    DataUrl = maps:get(<<"data">>, maps:get(<<"input_audio">>, AudioPart)),
    Expected = <<"data:audio/wav;base64,", (base64:encode(payload()))/binary>>,
    ?assertEqual(Expected, DataUrl).

asr_build_request_mpeg_mime_test() ->
    File = #{name => <<"file">>, filename => <<"a.mp3">>, content_type => <<"audio/mpeg">>, data => <<"abc">>},
    #{<<"messages">> := [Msg]} = janus_m_audio_asr:build_request(<<"m">>, File),
    [AudioPart] = maps:get(<<"content">>, Msg),
    DataUrl = maps:get(<<"data">>, maps:get(<<"input_audio">>, AudioPart)),
    ?assertMatch(
        <<"data:audio/mpeg;base64,", _/binary>>,
        DataUrl
    ).

asr_transcript_from_captured_probe_test() ->
    #{<<"response">> := Resp} = decode_fixture(<<"mimo_asr.json">>),
    ?assertEqual({ok, <<"嗯。"/utf8>>}, janus_m_audio_asr:transcript_of(Resp)).

asr_transcript_rejects_choiceless_reply_test() ->
    ?assertEqual(error, janus_m_audio_asr:transcript_of(#{"choices" => []})),
    ?assertEqual(error, janus_m_audio_asr:transcript_of(#{<<"choices">> => []})),
    ?assertEqual(
        error,
        janus_m_audio_asr:transcript_of(#{<<"choices">> => [#{<<"message">> => #{}}]})
    ).

%%%-------------------------------------------------------------------
%%% Fixture loading (captured probe JSON)
%%%-------------------------------------------------------------------

decode_fixture(Name) ->
    {ok, Bin} = read_fixture(Name),
    {ok, Map} = thoas:decode(Bin),
    Map.

read_fixture(Name) ->
    Paths = fixture_paths(Name),
    case first_readable(Paths) of
        {ok, Bin} ->
            {ok, Bin};
        error ->
            erlang:error({fixture_not_found, Paths})
    end.

fixture_paths(Name) ->
    Candidates = [
        filename:join(["apps", "janus_http", "test", "fixtures", "probes", Name]),
        filename:join(["test", "fixtures", "probes", Name]),
        filename:absname(
            filename:join(["apps", "janus_http", "test", "fixtures", "probes", Name])
        )
    ],
    case code:which(?MODULE) of
        Beam when is_list(Beam) ->
            %% _build/<profile>/lib/janus_http/ebin -> repo root
            Root = filename:dirname(filename:dirname(filename:dirname(filename:dirname(Beam)))),
            Candidates ++ [filename:join([Root, "apps", "janus_http", "test", "fixtures", "probes", Name])];
        _ ->
            Candidates
    end.

first_readable([]) ->
    error;
first_readable([P | Rest]) ->
    case file:read_file(P) of
        {ok, Bin} ->
            {ok, Bin};
        _ ->
            first_readable(Rest)
    end.
