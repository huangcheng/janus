%%%-------------------------------------------------------------------
%%% @doc C-2 regression (audit 2026-10-07): SSE delivered in mid-line
%%% TCP fragments must parse to the SAME events as delivered whole.
%%% The parser dropped the pending event's parsed lines at chunk
%%% boundaries — real upstreams split on TLS records routinely.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_sse_fragmentation_tests).

-include_lib("eunit/include/eunit.hrl").

-define(FIXTURE, "apps/janus_http/test/fixtures/sse/kimi-anthropic-tools.sse").

fixture_events() ->
    {ok, Bin} = file:read_file(?FIXTURE),
    {ok, Evs, _Rest} = janus_protocol_translate:sse_events(<<>>, Bin),
    Evs.

frag_events(Bin, N) ->
    frag_loop(Bin, N, <<>>, []).

frag_loop(<<>>, _N, _Buf, Acc) ->
    Acc;
frag_loop(Bin, N, Buf, Acc) ->
    Take = min(N, byte_size(Bin)),
    Chunk = binary:part(Bin, 0, Take),
    Rest = binary:part(Bin, Take, byte_size(Bin) - Take),
    {ok, Evs, RestBuf} = janus_protocol_translate:sse_events(Buf, Chunk),
    frag_loop(Rest, N, RestBuf, Acc ++ Evs).

fragmented_equals_whole_at_size_7_test() ->
    {ok, Bin} = file:read_file(?FIXTURE),
    ?assertEqual(fixture_events(), frag_events(Bin, 7)).

fragmented_equals_whole_byte_at_a_time_test() ->
    {ok, Bin} = file:read_file(?FIXTURE),
    ?assertEqual(fixture_events(), frag_events(Bin, 1)).


