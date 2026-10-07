%%%-------------------------------------------------------------------
%%% @doc EUnit for the video modality plugin's PURE surface (spec
%%% M3.1/M3.2, v1 scope): submit reply-mode classification (async JSON
%%% vs SSE sync, decided by the upstream RESPONSE the way the mock and
%%% OpenAI-shaped providers emit it), gateway-field stripping, jvid
%%% owner-check logic, poll passthrough mapping and jvid error
%%% mapping. Written BEFORE the implementation (AGENTS.md rule 1).
%%%
%%% Fixtures are production shapes: the SSE body is byte-identical to
%%% the E2E mock upstream's /v1/videos stream (scripts/mock_upstream.py
%%% — event/data framing, UTF-8, blank-line terminators), headers maps
%%% carry the lowercase keys gun's headers_map/1 produces, and JSON
%%% bodies are OpenAI /v1/videos-shaped with binary keys.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_video_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PT_EXP, {janus, jvid_exp_seconds}).

%%%-------------------------------------------------------------------
%%% The E2E mock's exact /v1/videos SSE payload (verbatim framing)
%%%-------------------------------------------------------------------

mock_sse_body() ->
    <<
        "event: response.created\n"
        "data: {\"type\":\"response.created\"}\n"
        "\n"
        "event: progress\n"
        "data: {\"type\":\"progress\",\"stage\":\"processing\"}\n"
        "\n"
        "event: response.completed\n"
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-mock-video\","
        "\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1},"
        "\"output\":[{\"type\":\"video\",\"url\":\"https://mock.invalid/v.mp4\"}]}}\n"
        "\n"
    >>.

sse_headers() ->
    %% gun's headers_map lowercases; FastAPI streams with a charset param.
    #{<<"content-type">> => <<"text/event-stream; charset=utf-8">>}.

json_headers() ->
    #{<<"content-type">> => <<"application/json">>}.

async_submit_body() ->
    %% OpenAI /v1/videos submit reply shape (JSON-decoded binary keys).
    thoas:encode(#{
        <<"id">> => <<"video_job.001_x">>,
        <<"object">> => <<"video">>,
        <<"status">> => <<"queued">>,
        <<"created">> => 1791300000,
        <<"model">> => <<"sora-2">>
    }).

openai_404_body() ->
    thoas:encode(#{
        <<"error">> => #{
            <<"message">> => <<"No video found with id 'video_job.001_x'.">>,
            <<"type">> => <<"invalid_request_error">>,
            <<"param">> => <<"id">>,
            <<"code">> => <<"video_not_found">>
        }
    }).

%%%-------------------------------------------------------------------
%%% Plugin contract constants
%%%-------------------------------------------------------------------

modality_and_body_cap_test() ->
    ?assertEqual(<<"video">>, janus_m_video:modality()),
    ?assertEqual(5 * 1024 * 1024, janus_m_video:max_body()).

exp_seconds_default_and_knob_test() ->
    persistent_term:erase(?PT_EXP),
    ?assertEqual(86400, janus_m_video:exp_seconds()),
    persistent_term:put(?PT_EXP, 60),
    ?assertEqual(60, janus_m_video:exp_seconds()),
    persistent_term:erase(?PT_EXP).

%%%-------------------------------------------------------------------
%%% Submit request shaping (gateway-only fields stripped)
%%%-------------------------------------------------------------------

build_submit_request_strips_stream_test() ->
    Canonical = #{
        <<"model">> => <<"sora-2">>,
        <<"prompt">> => <<"a cat surfing">>,
        <<"seconds">> => 8,
        <<"size">> => <<"1280x720">>,
        <<"stream">> => true
    },
    ?assertEqual(
        #{
            <<"model">> => <<"sora-2">>,
            <<"prompt">> => <<"a cat surfing">>,
            <<"seconds">> => 8,
            <<"size">> => <<"1280x720">>
        },
        janus_m_video:build_submit_request(Canonical)
    ).

build_submit_request_identity_test() ->
    Canonical = #{<<"model">> => <<"wan2.5-t2v">>, <<"prompt">> => <<"p">>},
    ?assertEqual(Canonical, janus_m_video:build_submit_request(Canonical)).

%%%-------------------------------------------------------------------
%%% Submit reply-mode classification
%%%-------------------------------------------------------------------

classify_sse_is_sync_test() ->
    Body = mock_sse_body(),
    ?assertEqual({sync, Body}, janus_m_video:classify_submit(sse_headers(), Body)).

classify_json_with_status_and_id_is_async_test() ->
    {async, <<"video_job.001_x">>} =
        janus_m_video:classify_submit(json_headers(), async_submit_body()).

classify_json_ct_optional_test() ->
    %% No content-type at all: the JSON shape still classifies (SSE
    %% mode is only ever decided by the content-type).
    {async, <<"video_job.001_x">>} =
        janus_m_video:classify_submit(#{}, async_submit_body()).

classify_status_without_id_is_unclassifiable_test() ->
    Body = thoas:encode(#{<<"status">> => <<"queued">>}),
    ?assertEqual(
        {error, unclassifiable},
        janus_m_video:classify_submit(json_headers(), Body)
    ).

classify_json_without_status_is_unclassifiable_test() ->
    %% A chat-shaped or partial reply cannot be treated as a job.
    Body = thoas:encode(#{<<"id">> => <<"video_job.001_x">>}),
    ?assertEqual(
        {error, unclassifiable},
        janus_m_video:classify_submit(json_headers(), Body)
    ).

classify_garbage_json_is_unclassifiable_test() ->
    ?assertEqual(
        {error, unclassifiable},
        janus_m_video:classify_submit(json_headers(), <<"[1,2,3]">>)
    ),
    ?assertEqual(
        {error, unclassifiable},
        janus_m_video:classify_submit(json_headers(), <<"not json at all">>)
    ),
    ?assertEqual(
        {error, unclassifiable},
        janus_m_video:classify_submit(json_headers(), <<>>)
    ).

classify_sse_requires_content_type_test() ->
    %% SSE-shaped body without the SSE content-type is NOT sync — it
    %% is not JSON either, so it must classify as an error, never be
    %% misrouted to the async face.
    ?assertEqual(
        {error, unclassifiable},
        janus_m_video:classify_submit(#{}, mock_sse_body())
    ).

%%%-------------------------------------------------------------------
%%% Owner check (jvid agent_key_id vs the AUTHENTICATED agent)
%%%-------------------------------------------------------------------

owner_matches_integer_id_test() ->
    Agent = #{id => 42, prefix => <<"janus-abc">>},
    ?assert(janus_m_video:owner_matches(Agent, #{agent_key_id => <<"42">>})),
    ?assertNot(janus_m_video:owner_matches(Agent, #{agent_key_id => <<"43">>})).

owner_matches_binary_id_test() ->
    ?assert(janus_m_video:owner_matches(#{id => <<"k_9">>}, #{agent_key_id => <<"k_9">>})),
    ?assertNot(janus_m_video:owner_matches(#{id => <<"k_9">>}, #{agent_key_id => <<"k_8">>})).

owner_matches_agent_without_id_test() ->
    ?assertNot(janus_m_video:owner_matches(#{prefix => <<"janus-abc">>}, #{agent_key_id => <<"42">>})).

%%%-------------------------------------------------------------------
%%% Poll passthrough mapping
%%%-------------------------------------------------------------------

poll_2xx_passes_body_through_test() ->
    Body = thoas:encode(#{
        <<"id">> => <<"video_job.001_x">>,
        <<"status">> => <<"completed">>,
        <<"output">> => [#{<<"type">> => <<"video">>, <<"url">> => <<"https://u/v.mp4">>}]
    }),
    ?assertEqual({passthrough, Body}, janus_m_video:poll_outcome(200, Body)).

poll_204_empty_passes_through_test() ->
    ?assertEqual({passthrough, <<>>}, janus_m_video:poll_outcome(204, <<>>)).

poll_404_is_job_not_found_test() ->
    ?assertEqual(job_not_found, janus_m_video:poll_outcome(404, openai_404_body())),
    ?assertEqual(job_not_found, janus_m_video:poll_outcome(404, <<>>)).

poll_other_errors_relay_test() ->
    Body = openai_404_body(),
    ?assertEqual({relay, 429, Body}, janus_m_video:poll_outcome(429, Body)),
    ?assertEqual({relay, 500, <<>>}, janus_m_video:poll_outcome(500, <<>>)).

%%%-------------------------------------------------------------------
%%% jvid error mapping
%%%-------------------------------------------------------------------

map_jvid_error_test() ->
    ?assertEqual({500, <<"jvid_no_secret">>}, janus_m_video:map_jvid_error(no_secret)),
    ?assertEqual({400, <<"bad_jvid">>}, janus_m_video:map_jvid_error(bad_format)),
    ?assertEqual({400, <<"bad_jvid">>}, janus_m_video:map_jvid_error(bad_hmac)),
    ?assertEqual({404, <<"job_unknown_key">>}, janus_m_video:map_jvid_error(unknown_keyid)),
    ?assertEqual({404, <<"job_expired">>}, janus_m_video:map_jvid_error(job_expired)).

%%%-------------------------------------------------------------------
%%% Upstream error-body relay classification (same rules as images)
%%%-------------------------------------------------------------------

relay_error_body_test() ->
    Json = openai_404_body(),
    ?assertEqual({json, Json}, janus_m_video:relay_error_body(Json)),
    ?assertEqual(
        {envelope, <<"upstream error">>},
        janus_m_video:relay_error_body(<<>>)
    ),
    ?assertEqual(
        {envelope, <<"Internal Server Error">>},
        janus_m_video:relay_error_body(<<"Internal Server Error">>)
    ).
