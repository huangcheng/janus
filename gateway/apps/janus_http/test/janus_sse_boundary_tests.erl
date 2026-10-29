%% SSE event-boundary detection for keepalive injection (2026-10-29).
%%
%% On the native stream path the gateway forwards upstream bytes
%% verbatim, so a chunk can end anywhere. A keepalive frame is
%% ": comment\n\n" and its trailing BLANK LINE DISPATCHES a pending
%% event, so it may only be written at an EVENT boundary — the last two
%% bytes are \n\n. A line boundary is NOT enough: injecting after
%% "event: message_start\n" would fire that event with no data and the
%% remaining data: lines would land in a fresh event-less event.
-module(janus_sse_boundary_tests).

-include_lib("eunit/include/eunit.hrl").

%% A complete event ends with a blank line.
complete_event_test() ->
    ?assert(janus_http_proxy:sse_at_event_boundary(undefined, <<"data: {}\n\n">>)).

%% A chunk ending on a FIELD line is mid-event, even though it ends in
%% \n. This is the corruption case: Prev is \n but the stream position
%% is not an event boundary.
field_line_only_test() ->
    ?assertNot(janus_http_proxy:sse_at_event_boundary(undefined, <<"event: message_start\n">>)).

multi_line_mid_event_test() ->
    ?assertNot(janus_http_proxy:sse_at_event_boundary($\n, <<"data: {\"a\":1}\n">>)).

%% A chunk of exactly one \n is a boundary ONLY if the previous byte was
%% also \n — the pair straddles the chunk boundary.
straddled_pair_test() ->
    ?assert(janus_http_proxy:sse_at_event_boundary($\n, <<"\n">>)),
    ?assertNot(janus_http_proxy:sse_at_event_boundary($x, <<"\n">>)),
    ?assertNot(janus_http_proxy:sse_at_event_boundary(undefined, <<"\n">>)).

%% CRLF stream: a blank line is "\r\n\r\n", whose tail is "\r\n" — NOT
%% "\n\n". The rule is conservative here and skips the tick. That is
%% safe (a keepalive is deferred one tick), whereas a false positive
%% would corrupt an event.
crlf_blank_line_conservative_test() ->
    ?assertNot(janus_http_proxy:sse_at_event_boundary(undefined, <<"data: {}\r\n\r\n">>)),
    %% an LF blank line in a CRLF stream is still detected
    ?assert(janus_http_proxy:sse_at_event_boundary(undefined, <<"data: {}\r\n\n">>)).

%% A size>=2 chunk never consults Prev — a stale value cannot flip it.
stale_prev_ignored_test() ->
    ?assert(janus_http_proxy:sse_at_event_boundary($\n, <<"data: {}\n">>) =:= false),
    ?assert(janus_http_proxy:sse_at_event_boundary($x, <<"data: {}\n\n">>) =:= true).

%% Empty chunks carry no position information.
empty_chunk_test() ->
    ?assertNot(janus_http_proxy:sse_at_event_boundary($\n, <<>>)).