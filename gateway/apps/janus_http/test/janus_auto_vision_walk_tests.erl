%% Auto-router: the same-tier walk must never pick a model that cannot
%% accept the request's images.
%%
%% Why this suite exists (2026-11-05, production):
%%
%% A client pinned `qwen3.8-max` — NOT the janus-auto virtual name — and
%% sent an image on `openai_responses` with stream=1. The first attempt
%% died on a transport error, the tier walk advanced, and the next
%% candidate it chose was `glm-5.3`, which cannot take images at all. The
%% client saw a 400 about `messages.content.type` — an upstream message
%% that names neither the model nor the image, so the real cause was
%% invisible from the outside.
%%
%% usage_events for that request (one request_ref, two attempts):
%%
%%   attempt 1  qwen3.8-max  502 transport     is_terminal=false
%%   attempt 2  glm-5.3      400 unclassified  is_terminal=true
%%
%% and the walk's own log line:
%%
%%   what=janus_auto_walk_gate_closed tier=flagship
%%   names=[qwen3.8-max, glm-5.3, kimi-k3]
%%   attempted=[qwen3.8-max, glm-5.3]
%%
%% `kimi-k3` is in the same tier and IS vision-capable, so the walk had a
%% correct next candidate available and skipped past it to the wrong one.
%%
%% The gate was never wrong; it was never ASKED, because the image never
%% reached it. `request_has_image/1` only looked inside `content` arrays
%% of `messages`/`input` items, and the shapes it missed are exactly the
%% agent ones: a standalone `input_image` item, and a tool result under
%% `function_call_output.output`.
%%
%% Three things are pinned here, matching the three ways this broke:
%%
%%   R1 — detection sees an image in every shape a client uses to carry
%%        one, including tool output, and stays false for text.
%%   R2 — the gate's decision (`vision_gate/2`) refuses a vision-incapable
%%        candidate for an image-bearing request and admits it otherwise.
%%   R3 — capability lookup agrees with the curated setting, defaulting to
%%        "cannot see" for names it does not know.
-module(janus_auto_vision_walk_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- the shapes a client actually sends -----------------------------

%% OpenAI chat: content is a list of typed parts.
chat_image_body() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"stream">> => true,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"what colour?">>},
                    #{
                        <<"type">> => <<"image_url">>,
                        <<"image_url">> => #{<<"url">> => <<"data:image/png;base64,AA">>}
                    }
                ]
            }
        ]
    }.

%% OpenAI responses: the image rides input[].content[] as `input_image`.
responses_image_body() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"stream">> => true,
        <<"input">> => [
            #{
                <<"type">> => <<"message">>,
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"input_text">>, <<"text">> => <<"what colour?">>},
                    #{
                        <<"type">> => <<"input_image">>,
                        <<"image_url">> => <<"data:image/png;base64,AA">>
                    }
                ]
            }
        ]
    }.

%% Anthropic messages: `image` with a `source` object.
anthropic_image_body() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"what colour?">>},
                    #{
                        <<"type">> => <<"image">>,
                        <<"source">> => #{
                            <<"type">> => <<"base64">>,
                            <<"media_type">> => <<"image/png">>,
                            <<"data">> => <<"AA">>
                        }
                    }
                ]
            }
        ]
    }.

text_only_body() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}]
    }.

%% A standalone `input_image` item at the top level of `input` — the
%% Responses client may hoist the image out of `content`.
%%
%% NB: the translate layer REJECTS this shape (a top-level item whose type
%% is not message/function_call/function_call_output/reasoning). That is
%% not a contradiction. Detection exists so routing avoids a blind model;
%% translation exists to refuse a shape it cannot faithfully convert. A
%% request can be correctly routed and still be refused, and being
%% blind here would instead route it to a model that cannot see — turning
%% an honest "unsupported shape" into a misleading upstream 400.
responses_standalone_input_image() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{<<"type">> => <<"input_text">>, <<"text">> => <<"look at this">>},
            #{<<"type">> => <<"input_image">>, <<"image_url">> => <<"data:image/png;base64,AA">>}
        ]
    }.

%% A tool result whose `output` is a LIST of parts — where a screenshot
%% from a tool lands.
responses_image_in_tool_output_list() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{<<"type">> => <<"function_call">>, <<"call_id">> => <<"c1">>, <<"name">> => <<"shot">>},
            #{
                <<"type">> => <<"function_call_output">>,
                <<"call_id">> => <<"c1">>,
                <<"output">> => [
                    #{<<"type">> => <<"input_text">>, <<"text">> => <<"screenshot:">>},
                    #{
                        <<"type">> => <<"input_image">>,
                        <<"image_url">> => <<"data:image/png;base64,AA">>
                    }
                ]
            }
        ]
    }.

%% A tool result whose `output` is a SINGLE object naming itself
%% `computer_screenshot` — the type allowlist does not contain that name,
%% so only the `image_url` field reveals it.
responses_computer_screenshot_output() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"computer_call_output">>,
                <<"call_id">> => <<"c2">>,
                <<"output">> => #{
                    <<"type">> => <<"computer_screenshot">>,
                    <<"image_url">> => <<"data:image/png;base64,AA">>
                }
            }
        ]
    }.

%% A tool result carrying only text.
responses_text_only_tool_output() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"function_call_output">>,
                <<"call_id">> => <<"c3">>,
                <<"output">> => <<"120 files">>
            }
        ]
    }.

%% An item may carry BOTH a content list and an output list. Keying the
%% walk on one of them in order inspects only the first present, which
%% hides the image in the other — the same blindness, different shape.
both_content_and_output_with_image() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"function_call_output">>,
                <<"call_id">> => <<"c4">>,
                <<"content">> => [
                    #{<<"type">> => <<"input_text">>, <<"text">> => <<"done">>}
                ],
                <<"output">> => [
                    #{<<"type">> => <<"input_image">>, <<"image_url">> => <<"data:image/png;base64,AA">>}
                ]
            }
        ]
    }.

%% An empty or malformed image_url carries no image. Counting it as one
%% would push a text-only request onto the vision pool, or exhaust an
%% all-blind tier and fail a request that had no image in it. The
%% type-bearing variants matter most: a cached history entry keeps the
%% type but loses the data, and a type-first walk would call that vision.
one_part_body(Part) ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"hello">>},
                    Part
                ]
            }
        ]
    }.

%% A part whose type name appears in no allowlist, carrying real image
%% data. It must NOT count: a tool result is free-form JSON, so any
%% browser or image-search result echoing an `image_url` field would
%% otherwise push a text-only request onto the vision pool. The type is
%% the discriminator — the same rule the translate layer applies.
unknown_type_with_image_data() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"some_future_shot">>,
                <<"image_url">> => #{<<"url">> => <<"data:image/png;base64,AA">>}
            }
        ]
    }.

%% A null `image_url` is how an SDK serializes an UNSET optional field.
%% A Responses `input_image` may carry its data by file reference instead
%% (`file_id`), which is still a genuine image — so null must mean "field
%% absent" and let the type decide, not "no data".
file_referenced_input_image() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"input_image">>,
                <<"image_url">> => null,
                <<"file_id">> => <<"file-abc">>
            }
        ]
    }.

%% A tool result whose JSON body happens to carry an `image_url` field.
%% Outside `computer_call_output` a map-valued `output` is not a part at
%% all — the translate layer rejects it as malformed — so it must not be
%% mistaken for an image-bearing one.
tool_json_body_mentioning_image_url() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"function_call_output">>,
                <<"call_id">> => <<"c5">>,
                <<"output">> => #{<<"image_url">> => <<"https://example.invalid/a.png">>}
            }
        ]
    }.

%% --- R1: detection sees the image, whatever shape carries it --------

vision_detected_in_chat_body_test() ->
    ?assert(janus_http_proxy:request_has_image(chat_image_body())).

vision_detected_in_responses_body_test() ->
    ?assert(janus_http_proxy:request_has_image(responses_image_body())).

vision_detected_in_anthropic_body_test() ->
    ?assert(janus_http_proxy:request_has_image(anthropic_image_body())).

vision_detected_standalone_input_image_test() ->
    ?assert(janus_http_proxy:request_has_image(responses_standalone_input_image())).

vision_detected_image_in_tool_output_list_test() ->
    ?assert(janus_http_proxy:request_has_image(responses_image_in_tool_output_list())).

vision_detected_computer_screenshot_test() ->
    ?assert(janus_http_proxy:request_has_image(responses_computer_screenshot_output())).

vision_detected_with_both_messages_and_input_test() ->
    ?assert(janus_http_proxy:request_has_image(messages_and_input_with_image())).

vision_absent_for_text_part_with_file_id_test() ->
    ?assertNot(janus_http_proxy:request_has_image(text_part_with_file_id())).

vision_detected_for_file_referenced_image_test() ->
    ?assert(janus_http_proxy:request_has_image(file_referenced_input_image())).

vision_absent_for_map_tool_output_test() ->
    ?assertNot(janus_http_proxy:request_has_image(tool_json_body_mentioning_image_url())).

vision_detected_when_content_and_output_both_present_test() ->
    ?assert(janus_http_proxy:request_has_image(both_content_and_output_with_image())).

%% A base64 source with no data, or a url source with an empty url,
%% carries nothing — image_block_to_chat_part/1 calls both an error.
%% Accepting them would route a request onto the vision pool over an
%% image it does not have.
%% The three data fields are independent. A part carrying BOTH a null
%% `image_url` (an SDK serializing an unset optional field) and a valid
%% `source` is still an image; keying on `image_url` first and stopping
%% there is the blindness this change removes.
null_image_url_with_valid_source() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"input_image">>,
                <<"image_url">> => null,
                <<"source">> => #{
                    <<"type">> => <<"base64">>,
                    <<"media_type">> => <<"image/png">>,
                    <<"data">> => <<"AA">>
                }
            }
        ]
    }.

vision_detected_for_null_url_with_source_test() ->
    ?assert(janus_http_proxy:request_has_image(null_image_url_with_valid_source())).

%% Empty is the same shape as null: it must not decide alone either.
empty_image_url_with_valid_source() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{
                <<"type">> => <<"input_image">>,
                <<"image_url">> => <<>>,
                <<"source">> => #{
                    <<"type">> => <<"base64">>,
                    <<"media_type">> => <<"image/png">>,
                    <<"data">> => <<"AA">>
                }
            }
        ]
    }.

vision_detected_for_empty_url_with_source_test() ->
    ?assert(janus_http_proxy:request_has_image(empty_image_url_with_valid_source())).

%% Null with no other source at all carries no bytes — same rule as an
%% empty url, and the counterpart to the case above. Pinned so the two
%% readings ("null delegates to the type" vs "null carries no data")
%% cannot drift apart silently.
vision_absent_for_null_url_alone_test() ->
    ?assertNot(
        janus_http_proxy:request_has_image(
            one_part_body(#{<<"type">> => <<"input_image">>, <<"image_url">> => null})
        )
    ).

vision_absent_for_dataless_anthropic_source_test() ->
    Absent = [
        #{<<"type">> => <<"image">>,
            <<"source">> => #{<<"type">> => <<"base64">>, <<"media_type">> => <<"image/png">>}},
        #{<<"type">> => <<"image">>,
            <<"source">> => #{<<"type">> => <<"url">>, <<"url">> => <<>>}},
        #{<<"type">> => <<"image">>, <<"source">> => #{}}
    ],
    [?assertNot(janus_http_proxy:request_has_image(one_part_body(P))) || P <- Absent].

vision_absent_for_empty_image_url_test() ->
    %% One assertion per variant: a bundled ?assertNot tells you "some
    %% variant is wrong" and nothing about which, and this is a list that
    %% grows every time a client invents a new placeholder.
    ?assertNot(janus_http_proxy:request_has_image(one_part_body(#{<<"type">> => <<"text">>, <<"image_url">> => <<>>}))),
    ?assertNot(janus_http_proxy:request_has_image(one_part_body(#{<<"type">> => <<"input_image">>, <<"image_url">> => <<>>}))),
    ?assertNot(janus_http_proxy:request_has_image(one_part_body(#{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => <<>>}}))),
    ?assertNot(janus_http_proxy:request_has_image(one_part_body(#{<<"type">> => <<"computer_screenshot">>, <<"image_url">> => #{}}))).

vision_absent_for_unknown_type_carrying_data_test() ->
    ?assertNot(janus_http_proxy:request_has_image(unknown_type_with_image_data())).

%% The negative direction, on the same shapes: a detector that answers
%% true too eagerly is the opposite failure — it would restrict the
%% failover pool to vision models for plain text requests.
vision_absent_for_text_only_test() ->
    ?assertNot(janus_http_proxy:request_has_image(text_only_body())).

vision_absent_for_text_only_tool_output_test() ->
    ?assertNot(janus_http_proxy:request_has_image(responses_text_only_tool_output())).

%% `input` may also arrive as a map or a number from a malformed client.
%% Detector runs before validation, so it must answer, not crash.
vision_detector_survives_non_list_input_test() ->
    ?assertNot(janus_http_proxy:request_has_image(#{<<"input">> => #{<<"a">> => 1}})),
    ?assertNot(janus_http_proxy:request_has_image(#{<<"input">> => 42})),
    ?assertNot(janus_http_proxy:request_has_image(#{<<"messages">> => #{}})).

%% A responses request whose input is a bare binary (the shorthand a
%% client may use for a text-only turn) must not crash the detector.
vision_detector_survives_string_input_test() ->
    ?assertNot(
        janus_http_proxy:request_has_image(#{
            <<"model">> => <<"qwen3.8-max">>,
            <<"input">> => <<"just text">>
        })
    ).

%% A body may carry BOTH `messages` and `input`. Keying on one in order
%% inspects only that one, so the image in the other is invisible.
messages_and_input_with_image() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"messages">> => [
            #{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}
        ],
        <<"input">> => [
            #{<<"type">> => <<"input_image">>, <<"image_url">> => <<"data:image/png;base64,AA">>}
        ]
    }.

%% A plain text part that happens to attach a file is still text. A
%% `file_id` alone must not make it an image, or a text-only request
%% gets pushed onto the vision pool.
text_part_with_file_id() ->
    #{
        <<"model">> => <<"qwen3.8-max">>,
        <<"input">> => [
            #{<<"type">> => <<"input_text">>, <<"text">> => <<"attached">>, <<"file_id">> => <<"file-x">>}
        ]
    }.

%% --- R2: the gate decides correctly ---------------------------------

%% The production case: an image-bearing request must not be routed to a
%% candidate that cannot read images, even when that candidate is next in
%% the tier and healthy. This is the assertion whose absence let the bug
%% ship.
vision_gate_skips_blind_candidate_test() ->
    with_capabilities(
        #{
            <<"blind-model">> => #{<<"vision">> => false},
            <<"eye-model">> => #{<<"vision">> => true}
        },
        fun() ->
            Constraint = #{vision => true},
            ?assertEqual(skip, janus_http_proxy:vision_gate(<<"blind-model">>, Constraint)),
            ?assertEqual(ok, janus_http_proxy:vision_gate(<<"eye-model">>, Constraint))
        end
    ).

%% No image in the request: prefer the model up, not only the ones that
%% can see, or a text-only fleet collapses onto its vision models.
vision_gate_admits_blind_candidate_for_text_test() ->
    with_capabilities(
        #{<<"blind-model">> => #{<<"vision">> => false}},
        fun() ->
            ?assertEqual(ok, janus_http_proxy:vision_gate(<<"blind-model">>, #{vision => false}))
        end
    ).

%% Every candidate in the tier is blind: the gate still refuses all of
%% them. The walk then exhausts and the request fails loudly, which is
%% the correct outcome — forwarding the image would produce an unrelated
%% upstream error that names neither the model nor the image.
vision_gate_refuses_every_blind_candidate_test() ->
    with_capabilities(
        #{
            <<"blind-a">> => #{<<"vision">> => false},
            <<"blind-b">> => #{<<"vision">> => false}
        },
        fun() ->
            Constraint = #{vision => true},
            ?assertEqual(skip, janus_http_proxy:vision_gate(<<"blind-a">>, Constraint)),
            ?assertEqual(skip, janus_http_proxy:vision_gate(<<"blind-b">>, Constraint))
        end
    ).

%% --- R2b: the join — the actual production shape ---------------------
%%
%% R1 and R2 above are each pinned alone. The incident lived in the
%% join: a request whose image is in TOOL OUTPUT, and a tier whose next
%% candidate cannot see. Assert the composed contract — for each real
%% image-bearing body, the gate refuses every curated-blind model in the
%% tier and admits the one that can see. If either half regresses, the
%% pair stops agreeing and this fails.

image_bearing_bodies() ->
    [
        {<<"chat user message">>, chat_image_body()},
        {<<"responses user message">>, responses_image_body()},
        {<<"anthropic message">>, anthropic_image_body()},
        {<<"standalone input item">>, responses_standalone_input_image()},
        {<<"tool output list">>, responses_image_in_tool_output_list()},
        {<<"computer screenshot">>, responses_computer_screenshot_output()},
        {<<"file reference">>, file_referenced_input_image()}
    ].

%% captured is what the walk feeds the gate; the gate must then refuse
%% the blind candidate and admit the seeing one, for every shape.
walk_feeds_gate_the_image_test_() ->
    [
        {Label, fun() -> assert_gate_split(Body) end}
     || {Label, Body} <- image_bearing_bodies()
    ].

assert_gate_split(Body) ->
    with_capabilities(
        #{
            <<"blind-model">> => #{<<"vision">> => false},
            <<"eye-model">> => #{<<"vision">> => true}
        },
        fun() ->
            Constraint = #{vision => janus_http_proxy:request_has_image(Body)},
            ?assertEqual(true, maps:get(vision, Constraint)),
            ?assertEqual(skip, janus_http_proxy:vision_gate(<<"blind-model">>, Constraint)),
            ?assertEqual(ok, janus_http_proxy:vision_gate(<<"eye-model">>, Constraint))
        end
    ).

%% The mirror: a text-only body must not restrict the pool, or a text
%% fleet collapses onto its vision models.
text_bodies_do_not_restrict_the_pool_test_() ->
    [
        {Label,
            fun() ->
                with_capabilities(
                    #{<<"blind-model">> => #{<<"vision">> => false}},
                    fun() ->
                        Constraint = #{vision => janus_http_proxy:request_has_image(Body)},
                        ?assertEqual(false, maps:get(vision, Constraint)),
                        ?assertEqual(
                            ok, janus_http_proxy:vision_gate(<<"blind-model">>, Constraint)
                        )
                    end
                )
            end}
     || {Label, Body} <- [
            {<<"chat text">>, text_only_body()},
            {<<"text tool output">>, responses_text_only_tool_output()},
            {<<"map tool result">>, tool_json_body_mentioning_image_url()}
        ]
    ].

%% --- R3: capability lookup agrees with the curation -----------------

%% The gate reads `model_capabilities` out of persistent_term, keyed by
%% public model name. JSON decode gives BINARY keys, so the map it gets
%% is #{<<"vision">> => false}. If the read disagrees with the setting,
%% every gate downstream is decorative.
vision_capable_follows_curation_test() ->
    with_capabilities(
        #{
            <<"blind-model">> => #{<<"vision">> => false},
            <<"eye-model">> => #{<<"vision">> => true}
        },
        fun() ->
            ?assertNot(janus_catalog:vision_capable(<<"blind-model">>)),
            ?assert(janus_catalog:vision_capable(<<"eye-model">>)),
            %% Unknown name, no curation: not vision-capable. Dropping
            %% the image silently would be worse than refusing.
            ?assertNot(janus_catalog:vision_capable(<<"never-heard-of-it">>))
        end
    ).

%% --- helpers --------------------------------------------------------

%% Install a model_capabilities map for the duration of Fun and restore
%% whatever was there. persistent_term is global, so a leaked entry would
%% make an unrelated suite order-dependent.
with_capabilities(Caps, Fun) ->
    Key = {janus, model_capabilities_cfg},
    Prev = persistent_term:get(Key, undefined),
    try
        persistent_term:put(Key, Caps),
        Fun()
    after
        case Prev of
            undefined -> persistent_term:erase(Key);
            _ -> persistent_term:put(Key, Prev)
        end
    end.
