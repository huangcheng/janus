%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the span primitive and the semconv
%%% mapping table.
%%%
%%% These pin the things that are expensive to get wrong and cheap to
%%% assert: identity shape, the one-way clock, attribute omission vs
%%% zero, the cap with COUNTED drops, and the status rule (which differs
%%% by span kind in a way that is easy to invert).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_span_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TID, <<"4bf92f3577b34da6a3ce929d0e0e4736">>).

span_test_() ->
    [
        {"identity", fun identity/0},
        {"ids are distinct per span", fun distinct_ids/0},
        {"parent link", fun parent_link/0},
        {"duration is monotonic", fun duration_monotonic/0},
        {"wall clock anchor", fun wall_anchor/0},
        {"attribute omission", fun attr_omission/0},
        {"attribute cap counts drops", fun attr_cap/0},
        {"value clamped at utf8", fun value_clamp/0},
        {"status by kind", fun status_by_kind/0},
        {"error type low cardinality", fun error_type/0},
        {"finish is idempotent", fun finish_twice/0}
    ].

start(Kind) -> janus_otel_span:start(Kind, <<"test">>, undefined, ?TID).
start(Kind, Name) -> janus_otel_span:start(Kind, Name, undefined, ?TID).

identity() ->
    S = start(server),
    ?assert(janus_otel_span:is_span(S)),
    ?assertEqual(?TID, janus_otel_span:trace_id(S)),
    Id = janus_otel_span:id(S),
    ?assertEqual(16, byte_size(Id)),
    ?assert(lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
                      binary_to_list(Id))).

distinct_ids() ->
    %% One attempt == one span id; retry legs must not collide.
    A = start(client),
    B = start(client),
    ?assertNotEqual(janus_otel_span:id(A), janus_otel_span:id(B)).

parent_link() ->
    P = janus_otel_span:id(start(server)),
    Child = janus_otel_span:start(client, <<"chat m">>, P, ?TID),
    ?assertEqual(P, maps:get(parent_span_id, Child)).

duration_monotonic() ->
    S = start(server),
    timer:sleep(5),
    F = janus_otel_span:finish(S),
    ?assert(janus_otel_span:duration_us(F) >= 4000),
    %% Never negative, even if the wall clock steps.
    ?assert(janus_otel_span:duration_us(F) >= 0).

wall_anchor() ->
    %% End nanoseconds = start nanoseconds + duration, so a clock step
    %% between start and finish cannot produce a negative span.
    S = start(server),
    F = janus_otel_span:finish(S),
    StartNs = maps:get(start_wall_ns, F),
    EndNs = maps:get(end_wall_ns, F),
    ?assertEqual(EndNs - StartNs, janus_otel_span:duration_us(F) * 1000).

attr_omission() ->
    %% A missing value must be OMITTED, never defaulted to 0 — a real
    %% zero and "provider said nothing" are different facts.
    S0 = start(client),
    S1 = janus_otel_span:set_attr(S0, <<"gen_ai.usage.input_tokens">>, undefined),
    S2 = janus_otel_span:set_attr(S1, <<"gen_ai.usage.output_tokens">>, null),
    ?assertEqual(#{}, maps:get(attributes, S2)),
    S3 = janus_otel_span:set_attr(S2, <<"gen_ai.usage.input_tokens">>, 0),
    ?assertEqual(0, maps:get(<<"gen_ai.usage.input_tokens">>, maps:get(attributes, S3))).

attr_cap() ->
    Attrs = maps:from_list([{<<"k", (integer_to_binary(I))/binary>>, I} || I <- lists:seq(1, 200)]),
    S = janus_otel_span:set_attrs(start(client), Attrs),
    ?assertEqual(128, map_size(maps:get(attributes, S))),
    %% The overflow is COUNTED, not silently lost.
    ?assertEqual(72, maps:get(dropped_attributes, S)).

value_clamp() ->
    Big = binary:copy(<<"a">>, 5000),
    S = janus_otel_span:set_attr(start(client), <<"x">>, Big),
    ?assertEqual(1024, byte_size(maps:get(<<"x">>, maps:get(attributes, S)))),
    %% Multi-byte characters are not cut mid-codepoint. `/utf8' is
    %% required: a bare <<"é">> literal encodes the LATIN-1 byte 233,
    %% which is not valid UTF-8 at all and would make this test assert
    %% nonsense.
    Multi = binary:copy(<<"é"/utf8>>, 2000),
    S2 = janus_otel_span:set_attr(start(client), <<"y">>, Multi),
    V = maps:get(<<"y">>, maps:get(attributes, S2)),
    ?assert(byte_size(V) =< 1024),
    ?assertEqual(V, unicode:characters_to_binary(V)).

status_by_kind() ->
    %% 5xx is an error on either kind.
    ?assertMatch({<<"ERROR">>, _}, maps:get(status, janus_otel_span:finish(start(server), 500))),
    ?assertMatch({<<"ERROR">>, _}, maps:get(status, janus_otel_span:finish(start(client), 502))),
    %% 4xx differs: the CLIENT asked wrong (its error), the SERVER was
    %% not at fault (UNSET). Inverting this mislabels every client bug.
    ?assertMatch({<<"UNSET">>, _}, maps:get(status, janus_otel_span:finish(start(server), 400))),
    ?assertMatch({<<"ERROR">>, _}, maps:get(status, janus_otel_span:finish(start(client), 400))),
    %% 2xx is never an error.
    ?assertMatch({<<"UNSET">>, _}, maps:get(status, janus_otel_span:finish(start(client), 200))).

error_type() ->
    A = janus_otel_attr:error_type(502),
    ?assertEqual(<<"502">>, A),
    %% A sentence must never become a metric dimension.
    ?assertEqual(undefined, janus_otel_attr:error_type(<<"the model rejected your request">>)),
    ?assertEqual(<<"rate_limit">>, janus_otel_attr:error_type(<<"rate_limit">>)).

finish_twice() ->
    %% Closing twice restamps rather than crashing; callers close once,
    %% but a double-close on an error path must not take the request down.
    F1 = janus_otel_span:finish(start(server)),
    F2 = janus_otel_span:finish(F1),
    ?assert(janus_otel_span:duration_us(F2) >= janus_otel_span:duration_us(F1)).
