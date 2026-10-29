%%%-------------------------------------------------------------------
%%% @doc W3C trace context (`traceparent') for the gateway
%%% (observability-depth plan, Task 3): honor a well-formed inbound
%%% `traceparent' header, else generate; mint one fresh parent-id PER
%%% upstream attempt (retry/failover legs must not share a span id).
%%%
%%% v1 scope: version 00 only; outbound flags are always `01' (the
%%% inbound sampling decision is NOT carried upstream); only the
%%% trace-id crosses the master->worker wire — the parent-id is minted
%%% at the executing node.
%%%
%%% The context is an opaque `#trace{}'; `trace_id(undefined) ->
%%% undefined' so pdict readers need no guard. `header/0' is the single
%%% pdict-read convention for upstream call sites: it reads
%%% `get(janus_trace)' and never crashes (a missing context mints a
%%% fresh trace on the spot). All parsing is
%%% fixed-shape byte matching — no regexes in this module (the regexes
%%% in janus_trace_tests are test-side shape assertions only).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_trace).

-export([ensure/1, from_trace_id/1, header/0, trace_id/1, upstream_header/1]).

-export_type([t/0]).

-record(trace, {tid :: binary()}).

-opaque t() :: #trace{}.

%% Once-per-boot flag for the malformed wire-map trace-id warning.
-define(PT_WARNED, {?MODULE, malformed_wire_trace_id_warned}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Trace context for a request: honor a well-formed inbound
%% `traceparent' header binary (exact 55-byte version-00 shape,
%% lowercase hex, non-zero ids), else generate a fresh trace-id.
%% `undefined' (non-proxy read paths) generates — never crashes.
-spec ensure(binary() | undefined) -> t().
ensure(In) when is_binary(In) ->
    case parse(In) of
        {ok, Tid} -> #trace{tid = Tid};
        error -> #trace{tid = new_trace_id()}
    end;
ensure(_) ->
    #trace{tid = new_trace_id()}.

%% @doc Worker-side constructor from the bare 32-hex trace-id carried
%% by the dispatch wire map. `undefined' (old master, rolling deploy)
%% generates silently; a malformed value generates + one rate-limited
%% warning per boot — a divergent trace-id is preferable to a killed
%% request (never rejects, never crashes).
-spec from_trace_id(binary() | undefined) -> t().
from_trace_id(undefined) ->
    #trace{tid = new_trace_id()};
from_trace_id(Tid) when is_binary(Tid) ->
    case is_lc_hex(Tid, 32) andalso Tid =/= zero(32) of
        true ->
            #trace{tid = Tid};
        false ->
            warn_once(Tid),
            #trace{tid = new_trace_id()}
    end;
from_trace_id(Other) ->
    warn_once(Other),
    #trace{tid = new_trace_id()}.

%% @doc The outbound `traceparent' header for ONE upstream attempt,
%% reading the pdict trace context (`get(janus_trace)' — module-named
%% key, house convention) stashed by the handler entry / worker
%% session. A missing context (non-request callers: eunit, the spawned
%% janus-auto judge worker) mints a fresh trace on the spot — never
%% crashes. Invoke once per attempt: retry/failover legs get distinct
%% parent-ids. THE single pdict-read convention — adapters call this,
%% never their own get/1 case.
-spec header() -> {binary(), binary()}.
header() ->
    case get(?MODULE) of
        undefined -> upstream_header(ensure(undefined));
        Trace -> upstream_header(Trace)
    end.

%% @doc The 32-hex trace-id, or `undefined' when no context is stashed
%% (pdict readers need no guard; the usage writer's bin_or_null maps
%% it to null).
-spec trace_id(t() | undefined) -> binary() | undefined.
trace_id(undefined) ->
    undefined;
trace_id(#trace{tid = Tid}) ->
    Tid.

%% @doc The outbound `traceparent' header for ONE upstream attempt:
%% stable trace-id, freshly minted parent-id, flags always `01'.
%% Invoke once per attempt — retry/failover legs get distinct spans.
-spec upstream_header(t()) -> {binary(), binary()}.
upstream_header(#trace{tid = Tid}) ->
    Pid = new_parent_id(),
    {<<"traceparent">>, <<"00-", Tid/binary, "-", Pid/binary, "-01">>}.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

%% Exact version-00 wire shape: 2 + 1 + 32 + 1 + 16 + 1 + 2 = 55 bytes
%% (dashes at byte offsets 2, 35, 52). Anything else — future versions,
%% uppercase hex, wrong lengths, all-zero ids — is rejected by shape.
parse(<<"00-", Tid:32/binary, "-", Pid:16/binary, "-", F:2/binary>>) ->
    case
        is_lc_hex(Tid, 32) andalso is_lc_hex(Pid, 16) andalso is_lc_hex(F, 2) andalso
            Tid =/= zero(32) andalso Pid =/= zero(16)
    of
        true -> {ok, Tid};
        false -> error
    end;
parse(_) ->
    error.

is_lc_hex(Bin, N) ->
    byte_size(Bin) =:= N andalso
        lists:all(
            fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
            binary_to_list(Bin)
        ).

zero(N) -> binary:copy(<<"0">>, N).

%% Fresh 32-hex trace-id; redraw on the (2^-128) all-zero draw — W3C
%% forbids all-zero ids.
new_trace_id() ->
    Tid = rand_hex(16),
    case Tid =:= zero(32) of
        true -> new_trace_id();
        false -> Tid
    end.

%% Fresh 16-hex parent-id; redraw on the (2^-64) all-zero draw.
new_parent_id() ->
    Pid = rand_hex(8),
    case Pid =:= zero(16) of
        true -> new_parent_id();
        false -> Pid
    end.

%% encode_hex is uppercase; lowercase for the W3C all-lowercase shape.
%% crypto:strong_rand_bytes is guarded (janus_request_id:generate/0
%% precedent): trace ids must never 500 a request — fall back to a
%% unique_integer draw PADDED to the full width (the N-hex shape holds
%% either way; binary:encode_unsigned/2's second arg is the
%% ENDIANNESS, not a pad size — pad via a binary pattern).
rand_hex(N) ->
    try
        string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(N)))
    catch
        _:_ ->
            I = erlang:unique_integer([positive]),
            string:lowercase(binary:encode_hex(<<I:(N * 8)/big>>))
    end.

%% One warning per boot for malformed wire-map trace-ids (a bad value
%% here means a peer bug, not a client fault — loud once, then silent
%% divergence). Concurrent first hits may log a handful of lines; the
%% flag bounds it per boot.
warn_once(Value) ->
    case persistent_term:get(?PT_WARNED, false) of
        true ->
            ok;
        false ->
            persistent_term:put(?PT_WARNED, true),
            logger:warning(#{
                what => janus_trace_malformed_wire_trace_id,
                value => Value
            })
    end.
