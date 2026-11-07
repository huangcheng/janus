%%%-------------------------------------------------------------------
%%% @doc Characterization tests for the telemetry config seam.
%%%
%%% The load-bearing invariant is "absent means OFF". An operator who
%%% deletes the settings row, or a fresh database that never had one,
%%% must not start emitting; and a malformed value must not be silently
%%% coerced into something plausible-looking.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_telemetry_cfg_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, {janus, telemetry_cfg}).

setup() -> ok.
cleanup(_) -> persistent_term:erase(?KEY).

cfg_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun absent_is_disabled/0,
        fun explicit_false_is_disabled/0,
        fun explicit_true_is_enabled/0,
        fun export_needs_an_endpoint/0,
        fun default_endpoint/0,
        fun configured_endpoint/0,
        fun default_ratio/0,
        fun configured_ratio_wins/0
    ]}.

absent_is_disabled() ->
    persistent_term:erase(?KEY),
    ?assertEqual(false, janus_telemetry:enabled()),
    ?assertEqual(#{}, janus_telemetry:config()).

explicit_false_is_disabled() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"enabled">> => false}}),
    ?assertEqual(false, janus_telemetry:enabled()).

explicit_true_is_enabled() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"enabled">> => true}}),
    ?assertEqual(true, janus_telemetry:enabled()).

%% Export requires BOTH the flag and a usable endpoint: a config that
%% says "on" while pointing nowhere would fail on every batch, so the
%% endpoint is part of the predicate rather than a separate check at the
%% call site that someone could forget.
export_needs_an_endpoint() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"enabled">> => true}}),
    ?assertEqual(true, janus_telemetry:export_enabled()),
    persistent_term:put(?KEY, #{
        <<"export">> => #{<<"enabled">> => true, <<"endpoint">> => <<>>}
    }),
    ?assertEqual(false, janus_telemetry:export_enabled()).

default_endpoint() ->
    persistent_term:erase(?KEY),
    ?assertEqual(<<"http://localhost:4318">>, janus_telemetry:export_endpoint()).

configured_endpoint() ->
    persistent_term:put(?KEY, #{<<"export">> => #{<<"endpoint">> => <<"http://collector:4318">>}}),
    ?assertEqual(<<"http://collector:4318">>, janus_telemetry:export_endpoint()).

default_ratio() ->
    persistent_term:erase(?KEY),
    ?assertEqual(0.05, janus_telemetry:default_sampling_ratio()).

configured_ratio_wins() ->
    persistent_term:put(?KEY, #{<<"sampling">> => #{<<"ratio">> => 0.42}}),
    ?assertEqual(0.42, janus_telemetry:sampling_ratio()).
