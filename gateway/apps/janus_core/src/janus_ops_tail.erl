%%%-------------------------------------------------------------------
%%% @doc Drainable in-memory ring of operational events (cool edges,
%%% background task runs) for the dashboard's failure-observability
%%% puller (spec 2026-10-13-failure-observability-design.md §4.2).
%%%
%%% Unlike `janus_log_tail` (whole-ring re-read each poll) this ring is
%%% CURSOR-drainable: every event carries the identity `(boot_id, idx)`
%%% and `recent_after/3` returns only events newer than the caller's
%%% high-water mark, plus the facts the puller needs to stay correct:
%%%
%%%   * `reset`  — the caller's boot_id is not ours (gateway restarted);
%%%                events are served from idx 0 and the puller must
%%%                close open episodes / reseed its high-water mark.
%%%   * `gap`    — `after_idx + 1 < oldest_idx`: the ring overflowed
%%%                past the caller's high-water mark (events lost).
%%%   * `overflow_count` — total events evicted since boot.
%%%
%%% Failure modes guarded:
%%%   * Concurrent pushers: `push/1` is a cast and the server assigns
%%%     `idx`, so idx is dense and monotonic (ETS is written only by
%%%     this process).
%%%   * Pusher must never block or crash the hot path: `push/1` is a
%%%     cast that tolerates a missing server (worker node / not yet
%%%     started) and bad input.
%%%   * Oversized `error` strings: payloads are truncated so the JSON
%%%     encoding of the payload is ≤ 4 KiB (UTF-8-boundary safe).
%%%   * Reads are serialized through the server (call), so a read
%%%     issued after a push from the same process always observes it.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_ops_tail).

-behaviour(gen_server).

-export([start_link/0]).
-export([push/1, recent_after/3, meta/0, boot_id/0, capacity/0, payload_cap/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TAB, janus_ops_tail).
-define(CAP, 2000).
-define(PAYLOAD_CAP, 4096).
-define(SCHEMA_VERSION, 1).
-define(PT_BOOT_ID, {janus, ops_boot_id}).
-define(TRUNC_MARK, <<"...">>).
%% Keys whose binary values are shrunk FIRST when a payload is too big.
-define(ERROR_KEYS, [
    error,
    <<"error">>,
    last_error_code,
    <<"last_error_code">>
]).

-record(state, {
    boot_id :: binary(),
    next = 1 :: pos_integer(),
    overflow = 0 :: non_neg_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Append an event (`#{type := Type, payload := Map, ts => Bin}`).
%% The server stamps `boot_id`, `idx`, `schema_version` (and `ts` when
%% absent). Never raises, never blocks the caller.
-spec push(map()) -> ok.
push(Event) when is_map(Event) ->
    gen_server:cast(?MODULE, {push, Event});
push(_) ->
    ok.

%% @doc Events with idx > AfterIdx (oldest first, at most Limit).
%% See the module doc for `reset` / `gap` semantics.
-spec recent_after(binary(), non_neg_integer(), pos_integer()) ->
    {ok, map()} | {error, unavailable}.
recent_after(BootId, AfterIdx, Limit) when
    is_binary(BootId), is_integer(AfterIdx), AfterIdx >= 0, is_integer(Limit), Limit >= 1
->
    try
        gen_server:call(?MODULE, {recent_after, BootId, AfterIdx, min(Limit, ?CAP)})
    catch
        exit:_ -> {error, unavailable}
    end;
recent_after(_BootId, _AfterIdx, _Limit) ->
    {error, unavailable}.

%% @doc Ring meta for `/stats/health` (`ops_ring`): identity + cursor
%% bounds, no events.
-spec meta() -> {ok, map()} | {error, unavailable}.
meta() ->
    try
        gen_server:call(?MODULE, meta)
    catch
        exit:_ -> {error, unavailable}
    end.

%% @doc This node's boot id (minted at init; `undefined` before start).
-spec boot_id() -> binary() | undefined.
boot_id() ->
    persistent_term:get(?PT_BOOT_ID, undefined).

capacity() -> ?CAP.

payload_cap() -> ?PAYLOAD_CAP.

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    _ = catch ets:delete(?TAB),
    _ = ets:new(?TAB, [named_table, ordered_set, protected]),
    BootId = mint_boot_id(),
    persistent_term:put(?PT_BOOT_ID, BootId),
    {ok, #state{boot_id = BootId}}.

handle_call({recent_after, BootId, AfterIdx0, Limit}, _From, State) ->
    {reply, {ok, read(BootId, AfterIdx0, Limit, State)}, State};
handle_call(meta, _From, State) ->
    {reply, {ok, ring_meta(State)}, State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({push, Event0}, #state{next = Idx, overflow = Ov0} = State) ->
    try
        Event = stamp(Event0, State#state.boot_id, Idx),
        true = ets:insert(?TAB, {Idx, Event}),
        Ov =
            case Idx > ?CAP of
                true ->
                    ets:delete(?TAB, Idx - ?CAP),
                    Ov0 + 1;
                false ->
                    Ov0
            end,
        {noreply, State#state{next = Idx + 1, overflow = Ov}}
    catch
        _:_ -> {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    _ = catch persistent_term:erase(?PT_BOOT_ID),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

ring_meta(#state{boot_id = Mine, next = Next, overflow = Ov}) ->
    #{
        boot_id => Mine,
        capacity => ?CAP,
        next_idx => Next,
        oldest_idx => oldest(Next),
        overflow_count => Ov
    }.

oldest(Next) ->
    case ets:first(?TAB) of
        '$end_of_table' -> Next;
        I -> I
    end.

read(BootId, AfterIdx0, Limit, #state{boot_id = Mine, next = Next, overflow = Ov}) ->
    Reset = BootId =/= Mine,
    AfterIdx =
        case Reset of
            true -> 0;
            false -> AfterIdx0
        end,
    Oldest = oldest(Next),
    Gap = (not Reset) andalso (AfterIdx + 1 < Oldest),
    Events =
        case
            ets:select(
                ?TAB,
                [{{'$1', '$2'}, [{'>', '$1', AfterIdx}], ['$2']}],
                Limit
            )
        of
            {Matches, _Cont} -> Matches;
            '$end_of_table' -> []
        end,
    #{
        boot_id => Mine,
        events => Events,
        oldest_idx => Oldest,
        next_idx => Next,
        overflow_count => Ov,
        reset => Reset,
        gap => Gap
    }.

stamp(Event, BootId, Idx) ->
    Payload = shrink_payload(maps:get(payload, Event, #{})),
    Event#{
        boot_id => BootId,
        idx => Idx,
        schema_version => ?SCHEMA_VERSION,
        ts => maps:get(ts, Event, now_rfc3339()),
        payload => Payload
    }.

now_rfc3339() ->
    list_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(millisecond), [{unit, millisecond}, {offset, "Z"}]
        )
    ).

%% RFC 4122 v4 UUID (lowercase hex) — identity of this boot.
mint_boot_id() ->
    <<A:32, B:16, C0:16, D0:16, E:48>> = crypto:strong_rand_bytes(16),
    C = (C0 band 16#0FFF) bor 16#4000,
    D = (D0 band 16#3FFF) bor 16#8000,
    iolist_to_binary(
        io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])
    ).

%%%-------------------------------------------------------------------
%%% 4 KiB payload cap
%%%-------------------------------------------------------------------

%% Shrink binary values until the JSON encoding of the payload is at
%% most ?PAYLOAD_CAP bytes. Always shrink the largest top-level binary;
%% on equal size prefer error-ish keys. Bounded loop; last resort
%% replaces the payload with a marker (an event is NEVER dropped for size).
shrink_payload(Payload) when is_map(Payload) ->
    shrink_payload(Payload, 16);
shrink_payload(_Other) ->
    #{}.

shrink_payload(Payload, 0) ->
    fallback_payload(Payload);
shrink_payload(Payload, Budget) ->
    case encoded_size(Payload) of
        unencodable ->
            #{<<"truncated">> => true, <<"reason">> => <<"unencodable">>};
        Size when Size =< ?PAYLOAD_CAP ->
            Payload;
        Size ->
            Over = Size - ?PAYLOAD_CAP,
            case pick_shrink_key(Payload) of
                none ->
                    fallback_payload(Payload);
                {Key, Bin} ->
                    Keep = max(0, byte_size(Bin) - Over - byte_size(?TRUNC_MARK)),
                    New = <<(utf8_prefix(Bin, Keep))/binary, (?TRUNC_MARK)/binary>>,
                    shrink_payload(Payload#{Key := New}, Budget - 1)
            end
    end.

fallback_payload(_Payload) ->
    #{<<"truncated">> => true}.

encoded_size(Payload) ->
    try
        iolist_size(thoas:encode(Payload))
    catch
        _:_ -> unencodable
    end.

%% Largest binary wins; on a size tie prefer an error-ish key so we do
%% not thrash a tiny `last_error_code` while a large non-error field
%% still exceeds the cap.
pick_shrink_key(Payload) ->
    Bins = [{K, V} || {K, V} <- maps:to_list(Payload), is_binary(V), byte_size(V) > 0],
    case Bins of
        [] ->
            none;
        [First | Rest] ->
            lists:foldl(fun prefer_shrink_candidate/2, First, Rest)
    end.

prefer_shrink_candidate({K1, V1} = A, {K0, V0} = Acc) ->
    S1 = byte_size(V1),
    S0 = byte_size(V0),
    if
        S1 > S0 ->
            A;
        S1 < S0 ->
            Acc;
        true ->
            case {lists:member(K1, ?ERROR_KEYS), lists:member(K0, ?ERROR_KEYS)} of
                {true, false} -> A;
                _ -> Acc
            end
    end.

%% First Len bytes of Bin, backed off to a valid UTF-8 boundary.
utf8_prefix(Bin, Len) when Len >= byte_size(Bin) ->
    Bin;
utf8_prefix(Bin, Len) ->
    utf8_prefix_(Bin, Len, 4).

utf8_prefix_(Bin, Len, Tries) when Len > 0, Tries > 0 ->
    Part = binary:part(Bin, 0, Len),
    case unicode:characters_to_binary(Part, utf8, utf8) of
        B when is_binary(B) -> Part;
        _ -> utf8_prefix_(Bin, Len - 1, Tries - 1)
    end;
utf8_prefix_(Bin, Len, _Tries) ->
    binary:part(Bin, 0, max(0, Len)).
