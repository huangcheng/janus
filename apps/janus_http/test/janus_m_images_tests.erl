%%%-------------------------------------------------------------------
%%% @doc eunit for the images modality plugin's PURE translators
%%% (spec M1.2; AGENTS.md rule: eunit-first on REAL captured shapes).
%%%
%%% Fixtures are the production probes under test/fixtures/probes/ —
%%% minimax_t2i_cn.json / minimax_t2i_i.json carry the REAL
%%% minimax reply: metadata counts arrive as JSON STRINGS ("0"/"1")
%%% while base_resp.status_code is an INTEGER. Every shape assertion
%%% below consumes those fixtures, never hand-idiomatic maps.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_m_images_tests).

-include_lib("eunit/include/eunit.hrl").

%%%--------------------------------------------------------------------
%%% Fixture loading (source tree; rebar3 does not copy test/fixtures
%%% into _build, so resolve relative to the project root or app dir)
%%%--------------------------------------------------------------------

fixture(Name) ->
    Candidates = [
        filename:join(["apps", "janus_http", "test", "fixtures", "probes", Name]),
        filename:join(["test", "fixtures", "probes", Name])
    ],
    read_first(Candidates, Name).

read_first([Path | Rest], Name) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        {error, _} -> read_first(Rest, Name)
    end;
read_first([], Name) ->
    erlang:error({fixture_missing, Name}).

probe_response(Name) ->
    {ok, Dec} = thoas:decode(fixture(Name)),
    maps:get(<<"response">>, Dec).

minimax_image_urls(Resp) ->
    maps:get(<<"image_urls">>, maps:get(<<"data">>, Resp)).

%%%--------------------------------------------------------------------
%%% minimax -> canonical reply normalization (real fixture)
%%%--------------------------------------------------------------------

minimax_cn_reply_normalized_test() ->
    Resp = probe_response(<<"minimax_t2i_cn.json">>),
    [FixtureUrl] = minimax_image_urls(Resp),
    {ok, Canon} = janus_m_images:normalize_minimax_reply(Resp, 200),
    ?assert(is_integer(maps:get(<<"created">>, Canon))),
    ?assertEqual([#{<<"url">> => FixtureUrl}], maps:get(<<"data">>, Canon)),
    ?assertEqual(2, maps:size(Canon)).

minimax_intl_reply_same_shape_test() ->
    Resp = probe_response(<<"minimax_t2i_i.json">>),
    [FixtureUrl] = minimax_image_urls(Resp),
    {ok, Canon} = janus_m_images:normalize_minimax_reply(Resp, 200),
    ?assertEqual([#{<<"url">> => FixtureUrl}], maps:get(<<"data">>, Canon)).

minimax_string_counts_partial_test() ->
    %% REAL fixture shape: counts are JSON strings. One of two failed.
    Resp = probe_response(<<"minimax_t2i_cn.json">>),
    Partial = Resp#{
        <<"metadata">> => #{<<"failed_count">> => <<"1">>, <<"success_count">> => <<"1">>}
    },
    {partial, Canon, 1} = janus_m_images:normalize_minimax_reply(Partial, 200),
    ?assertMatch([#{<<"url">> := _}], maps:get(<<"data">>, Canon)),
    ?assert(is_binary(maps:get(<<"note">>, Canon))).

minimax_int_counts_partial_test() ->
    %% Defensive twin: some minimax deployments emit integer counts.
    Resp = probe_response(<<"minimax_t2i_i.json">>),
    Partial = Resp#{
        <<"metadata">> => #{<<"failed_count">> => 2, <<"success_count">> => 1}
    },
    ?assertMatch(
        {partial, #{}, 2},
        janus_m_images:normalize_minimax_reply(Partial, 200)
    ).

minimax_base_resp_error_keeps_4xx_status_test() ->
    Resp = probe_response(<<"minimax_t2i_cn.json">>),
    Bad = Resp#{<<"base_resp">> => #{<<"status_code">> => 1004, <<"status_msg">> => <<"invalid api key">>}},
    ?assertEqual(
        {error, 401, <<"invalid api key">>},
        janus_m_images:normalize_minimax_reply(Bad, 401)
    ).

minimax_base_resp_error_on_2xx_is_502_test() ->
    Resp = probe_response(<<"minimax_t2i_cn.json">>),
    Bad = Resp#{<<"base_resp">> => #{<<"status_code">> => 1000, <<"status_msg">> => <<"internal error">>}},
    ?assertEqual(
        {error, 502, <<"internal error">>},
        janus_m_images:normalize_minimax_reply(Bad, 200)
    ).

minimax_zero_urls_is_error_test() ->
    Resp = probe_response(<<"minimax_t2i_cn.json">>),
    Empty = Resp#{
        <<"data">> => #{<<"image_urls">> => []},
        <<"metadata">> => #{<<"failed_count">> => <<"1">>, <<"success_count">> => <<"0">>}
    },
    ?assertMatch(
        {error, 502, _},
        janus_m_images:normalize_minimax_reply(Empty, 200)
    ).

%%%--------------------------------------------------------------------
%%% canonical -> provider request translation
%%%--------------------------------------------------------------------

build_minimax_request_test() ->
    Canonical = #{
        <<"model">> => <<"image-01">>,
        <<"prompt">> => <<"a cat">>,
        <<"n">> => 2,
        <<"size">> => <<"1024x1024">>,
        <<"quality">> => <<"hd">>,
        <<"style">> => <<"vivid">>,
        <<"user">> => <<"u1">>,
        <<"response_format">> => <<"url">>
    },
    ?assertEqual(
        #{
            <<"model">> => <<"image-01">>,
            <<"prompt">> => <<"a cat">>,
            <<"n">> => 2,
            <<"response_format">> => <<"url">>
        },
        janus_m_images:build_minimax_request(Canonical)
    ).

build_minimax_request_aspect_ratio_test() ->
    Canonical = #{
        <<"model">> => <<"image-01">>,
        <<"prompt">> => <<"a cat">>,
        <<"aspect_ratio">> => <<"16:9">>
    },
    ?assertEqual(
        #{
            <<"model">> => <<"image-01">>,
            <<"prompt">> => <<"a cat">>,
            <<"aspect_ratio">> => <<"16:9">>
        },
        janus_m_images:build_minimax_request(Canonical)
    ).

build_passthrough_request_drops_gateway_only_test() ->
    Canonical = #{
        <<"model">> => <<"gpt-image-1">>,
        <<"prompt">> => <<"a cat">>,
        <<"n">> => 1,
        <<"size">> => <<"1024x1024">>,
        <<"aspect_ratio">> => <<"16:9">>
    },
    ?assertEqual(
        #{
            <<"model">> => <<"gpt-image-1">>,
            <<"prompt">> => <<"a cat">>,
            <<"n">> => 1,
            <<"size">> => <<"1024x1024">>
        },
        janus_m_images:build_passthrough_request(Canonical)
    ).

%%%--------------------------------------------------------------------
%%% Pre-flight caps (400 before spend) — per-provider predicate table
%%%--------------------------------------------------------------------

validate_minimal_defaults_test() ->
    Map = #{<<"model">> => <<"image-01">>, <<"prompt">> => <<"a cat">>},
    ?assertEqual({ok, 1}, janus_m_images:validate_for(<<"minimax">>, Map)),
    ?assertEqual({ok, 1}, janus_m_images:validate_for(<<"openai">>, Map)).

validate_n_test() ->
    Base = #{<<"prompt">> => <<"p">>},
    ?assertEqual({ok, 9}, janus_m_images:validate_for(<<"openai">>, Base#{<<"n">> => 9})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Base#{<<"n">> => 0})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Base#{<<"n">> => 10})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Base#{<<"n">> => 1.5})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Base#{<<"n">> => <<"3">>})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Base#{<<"n">> => true})).

validate_prompt_test() ->
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, #{<<"model">> => <<"m">>})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, #{<<"prompt">> => <<"">>})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, #{<<"prompt">> => 42})).

validate_response_format_test() ->
    Base = #{<<"prompt">> => <<"p">>},
    ?assertEqual({ok, 1}, janus_m_images:validate_for(<<"openai">>, Base#{<<"response_format">> => <<"url">>})),
    ?assertEqual({ok, 1}, janus_m_images:validate_for(<<"openai">>, Base#{<<"response_format">> => <<"b64_json">>})),
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Base#{<<"response_format">> => <<"png">>})).

valid_size_openai_enum_test() ->
    ?assert(janus_m_images:valid_size(<<"openai">>, <<"256x256">>)),
    ?assert(janus_m_images:valid_size(<<"openai">>, <<"512x512">>)),
    ?assert(janus_m_images:valid_size(<<"openai">>, <<"1024x1024">>)),
    ?assertNot(janus_m_images:valid_size(<<"openai">>, <<"1792x1024">>)),
    ?assertNot(janus_m_images:valid_size(<<"openai">>, <<"1024x1023">>)),
    ?assertNot(janus_m_images:valid_size(<<"openai">>, <<"big">>)),
    ?assertNot(janus_m_images:valid_size(<<"openai">>, 1024)),
    ?assertNot(janus_m_images:valid_size(<<"openai">>, <<"1024X1024">>)).

valid_size_wxh_providers_test() ->
    %% dashscope (qwen-image family) accepts free WxH, multiples of 8.
    ?assert(janus_m_images:valid_size(<<"dashscope">>, <<"1328x1328">>)),
    ?assert(janus_m_images:valid_size(<<"dashscope">>, <<"512x512">>)),
    ?assertNot(janus_m_images:valid_size(<<"dashscope">>, <<"1327x1328">>)),
    ?assertNot(janus_m_images:valid_size(<<"dashscope">>, <<"0x512">>)),
    ?assertNot(janus_m_images:valid_size(<<"dashscope">>, <<"1328">>)).

valid_size_ignored_for_minimax_test() ->
    %% minimax takes aspect_ratio, not size: never validated pre-flight.
    ?assert(janus_m_images:valid_size(<<"minimax">>, <<"wharrgarbl">>)),
    ?assert(janus_m_images:valid_size(<<"minimax">>, <<"1024x1023">>)).

validate_size_rejects_bad_for_passthrough_test() ->
    Map = #{<<"prompt">> => <<"p">>, <<"size">> => <<"2048x2048">>},
    ?assertMatch({error, _}, janus_m_images:validate_for(<<"openai">>, Map)),
    ?assertEqual({ok, 1}, janus_m_images:validate_for(<<"minimax">>, Map)).

%%%--------------------------------------------------------------------
%%% Error surfaces
%%%--------------------------------------------------------------------

pick_error_test() ->
    ?assertMatch(
        {404, <<"no_route">>, _, #{}},
        janus_m_images:pick_error(no_route)
    ),
    ?assertMatch(
        {503, <<"provider_disabled">>, _, #{}},
        janus_m_images:pick_error(provider_disabled)
    ),
    ?assertMatch(
        {503, <<"all_cooling">>, _, #{<<"retry-after">> := <<"5">>}},
        janus_m_images:pick_error({all_cooling, 5000})
    ),
    ?assertMatch(
        {503, <<"catalog_not_ready">>, _, _},
        janus_m_images:pick_error(catalog_not_ready)
    ),
    ?assertMatch(
        {404, <<"no_route">>, _, _},
        janus_m_images:pick_error(whatever)
    ).

relay_error_body_json_passthrough_test() ->
    %% REAL captured upstream error (stepfun probe): a JSON body is
    %% relayed byte-for-byte with the upstream status.
    {ok, Dec} = thoas:decode(fixture(<<"stepfun_images.json">>)),
    Body = thoas:encode(maps:get(<<"response">>, Dec)),
    ?assertEqual({json, Body}, janus_m_images:relay_error_body(Body)).

relay_error_body_empty_and_text_test() ->
    %% dashscope probe answered 404 with an EMPTY body -> envelope.
    ?assertEqual(
        {envelope, <<"upstream error">>},
        janus_m_images:relay_error_body(<<>>)
    ),
    ?assertEqual(
        {envelope, <<"Internal Server Error">>},
        janus_m_images:relay_error_body(<<"Internal Server Error">>)
    ).

relay_error_body_truncates_test() ->
    Long = binary:copy(<<"x">>, 2000),
    {envelope, Msg} = janus_m_images:relay_error_body(Long),
    %% 500 bytes of body + the "..." suffix.
    ?assertEqual(503, byte_size(Msg)),
    ?assertEqual(<<"...">>, binary:part(Msg, byte_size(Msg), -3)).

error_envelope_test() ->
    ?assertEqual(
        #{
            error =>
                #{message => <<"boom">>, type => <<"janus_error">>, code => <<"upstream_error">>}
        },
        janus_m_images:error_envelope(<<"boom">>, <<"upstream_error">>)
    ).
