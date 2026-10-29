%%%-------------------------------------------------------------------
%%% @doc Master-side gw-echo endpoint `GET /v1/echo` (geo-affinity
%%% spec `2026-10-11-geo-affinity-and-auto-tier-reorder-design.md`
%%% §5 / D4 — the self-hosted egress-IP reflection probe workers GET
%%% on the 60 s hello cadence).
%%%
%%% UNAUTHENTICATED like /healthz — the reply discloses ONLY the
%%% caller's own observed TCP peer IP (what any whatismyip service
%%% already tells the caller; no cross-client information). IPv6 peers
%%% pass through (same mmdb mapping on the master).
%%%
%%% <ul>
%%% <li>Degraded detection (r9/r10): whenever ANY header of the
%%%   extensible `JANUS_ECHO_PROXY_HEADERS` list (default
%%%   `x-forwarded-for, x-real-ip`) is PRESENT on the request, an L7 /
%%%   CDN proxy is in front — the peer would be the proxy's public IP
%%%   and would PASS the private filter, so the reply carries
%%%   `{"ip":null,"degraded":true}` and workers fall through (no
%%%   config to forget). A header-STRIPPING proxy or L4 SNAT LB is
%%%   UNDETECTABLE (documented accepted residual).</li>
%%% <li>Rate limit: NAT-aware per-peer-IP token bucket — 1 token/min
%%%   sustained, burst `max(24, 4 x workers)` (jitter headroom above
%%%   the 60 s cadence; the fleet's own SNAT fan-in is the sizing
%%%   case). 429 => the worker treats it as `echo_fail` and falls
%%%   through.</li>
%%% <li>`JANUS_ECHO_DIRECT=0` disables the route entirely (404): the
%%%   supervisor omits the dispatch entry at boot AND the handler
%%%   answers 404 defensively.</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(janus_http_echo).

-behaviour(cowboy_handler).

-export([init/2]).
%% Knobs + pure logic (eunit).
-export([
    init_knob/0,
    bucket_cap/0,
    prune_stale/0,
    enabled/0,
    proxy_headers/0,
    parse_proxy_headers/1,
    proxy_header_present/2,
    peer_ip_bin/1,
    capacity/1,
    bucket_step/4,
    allow/1
]).

-define(PT_PROXY_HEADERS, {janus_http_echo, proxy_headers}).
-define(BUCKET, janus_echo_buckets).
-define(DEFAULT_PROXY_HEADERS, "x-forwarded-for,x-real-ip").
%% 1 token / minute sustained; capacity floor 24 / default 48 when no
%% workers are pooled yet (max(24, 4 x workers) — 4x above the 60 s
%% hello cadence so one jittered fleet hello never 429s into echo_fail).
-define(REFILL_TOKENS_PER_MS, 1.0 / 60000.0).
-define(CAPACITY_FLOOR, 24).
-define(BUCKET_CAP, 8192).
-define(BUCKET_STALE_MS, 3_600_000).
%% Sweep hysteresis: trigger the prune at cap+margin, evict down to
%% cap-slack, so the amortized sweep cost per fresh peer is one
%% full-sweep per ?SWEEP_MARGIN inserts (never per insert).
-define(SWEEP_MARGIN, 128).
-define(SWEEP_SLACK, 64).
%% Single-flight marker row: the winner of insert_new runs the sweep,
%% concurrent over-cap arrivals return at once. A sweeper killed by an
%% exit signal runs no `after` cleanup, so a marker also carries the
%% sweep start time in its 3rd element and the false branch reclaims
%% (delete_object of that exact object) any marker older than
%% ?SWEEP_TTL_MS — a dead sweeper can never block pruning permanently.
-define(SWEEP_MARKER, '__echo_sweep__').
-define(SWEEP_TTL_MS, 1_000).

%%%===================================================================
%%% Knobs (boot-time env -> persistent_term; restart to change)
%%%===================================================================

%% Called from janus_http_app:start/2 BEFORE the listeners.
-spec init_knob() -> ok.
init_knob() ->
    persistent_term:put(
        ?PT_PROXY_HEADERS,
        parse_proxy_headers(os:getenv("JANUS_ECHO_PROXY_HEADERS"))
    ),
    _ = ensure_bucket(),
    ok.

%% JANUS_ECHO_DIRECT=0 (also false/no/off) disables the route; unset
%% or any other value keeps it on (default ON — the endpoint is the
%% no-required-config layer of the discovery chain).
-spec enabled() -> boolean().
enabled() ->
    case os:getenv("JANUS_ECHO_DIRECT") of
        Val when is_list(Val), Val =/= "" ->
            not lists:member(string:lowercase(Val), ["0", "false", "no", "off"]);
        _ ->
            true
    end.

%% Comma-list parse -> lowercased non-empty binaries (ordered, deduped
%% for a stable degraded check). Default list when unset/empty.
-spec parse_proxy_headers(false | string()) -> [binary()].
parse_proxy_headers(false) ->
    default_proxy_headers();
parse_proxy_headers("") ->
    default_proxy_headers();
parse_proxy_headers(Env) when is_list(Env) ->
    Bins = [
        list_to_binary(string:lowercase(string:trim(T)))
     || T <- string:split(Env, ",", all), string:trim(T) =/= ""
    ],
    case dedup(Bins) of
        [] -> default_proxy_headers();
        L -> L
    end;
parse_proxy_headers(_) ->
    default_proxy_headers().

default_proxy_headers() ->
    [<<"x-forwarded-for">>, <<"x-real-ip">>].

%% Order-preserving dedup (first occurrence wins).
dedup(L) ->
    dedup(L, []).

dedup([H | T], Seen) ->
    case lists:member(H, Seen) of
        true -> dedup(T, Seen);
        false -> [H | dedup(T, [H | Seen])]
    end;
dedup([], _Seen) ->
    [].

-spec proxy_headers() -> [binary()].
proxy_headers() ->
    try
        persistent_term:get(?PT_PROXY_HEADERS)
    catch
        error:badarg -> default_proxy_headers()
    end.

%%%===================================================================
%%% Pure logic (eunit)
%%%===================================================================

%% Degraded predicate: ANY proxy header of the list PRESENT on the
%% request (regardless of value — an empty XFF still proves an L7 hop).
-spec proxy_header_present([binary()], fun((binary()) -> term())) -> boolean().
proxy_header_present(Headers, GetHeader) when is_list(Headers), is_function(GetHeader, 1) ->
    lists:any(fun(H) -> GetHeader(H) =/= undefined end, Headers).

%% Peer tuple -> printable IP binary (IPv4 and IPv6 pass through).
-spec peer_ip_bin({inet:ip_address(), inet:port_number()}) -> binary().
peer_ip_bin({Ip, _Port}) ->
    list_to_binary(inet:ntoa(Ip)).

%% Burst capacity: max(24, 4 x live workers) — the configured pool
%% size when pooled, the floor when nothing is pooled yet.
-spec capacity(non_neg_integer()) -> pos_integer().
capacity(Workers) when is_integer(Workers), Workers >= 0 ->
    max(?CAPACITY_FLOOR, 4 * Workers);
capacity(_) ->
    ?CAPACITY_FLOOR.

%% Token bucket step (pure, time-parameterized): `Tokens` is a float
%% >= 0, `RatePerMs` the sustained refill. Refills elapsed time first
%% (capped at capacity), then consumes ONE token when available.
%% Returns {Allowed, NewState} — a refused request still keeps its
%% accrued refill (never resets the clock).
-spec bucket_step({number(), integer()}, integer(), number(), number()) ->
    {boolean(), {number(), integer()}}.
bucket_step({Tokens0, LastMono}, NowMono, Capacity, RatePerMs) when
    is_number(Tokens0), Tokens0 >= 0, is_integer(LastMono), is_integer(NowMono), NowMono >= LastMono,
    is_number(Capacity), Capacity >= 1, is_number(RatePerMs), RatePerMs > 0
->
    Refilled = min(Capacity * 1.0, Tokens0 + (NowMono - LastMono) * RatePerMs),
    case Refilled >= 1.0 of
        true ->
            {true, {Refilled - 1.0, NowMono}};
        false ->
            %% Keep the REFILLED count but advance LastMono — keeping
            %% the old timestamp double-counts the elapsed interval
            %% on the next call (ocr medium).
            {false, {Refilled, NowMono}}
    end;
bucket_step({_Tokens0, LastMono}, NowMono, _Capacity, _RatePerMs) when is_integer(NowMono) ->
    %% Malformed token state (corrupt row): allow once and re-seed —
    %% never punish the peer for our own bad row.
    {true, {1.0, max(LastMono, NowMono)}}.

%%%===================================================================
%%% Cowboy handler
%%%===================================================================

init(Req0, State) ->
    Req =
        case enabled() of
            false ->
                %% Route registered but knob off (defensive — the
                %% supervisor normally omits the entry): 404.
                cowboy_req:reply(404, #{}, <<>>, Req0);
            true ->
                handle(cowboy_req:method(Req0), Req0)
        end,
    {ok, Req, State}.

handle(<<"GET">>, Req0) ->
    case allow(peer_key(Req0)) of
        true ->
            case proxy_header_present(proxy_headers(), fun(H) -> cowboy_req:header(H, Req0) end) of
                true ->
                    reply(
                        200,
                        #{<<"ip">> => null, <<"degraded">> => true},
                        Req0
                    );
                false ->
                    {Ip, _Port} = cowboy_req:peer(Req0),
                    reply(200, #{<<"ip">> => peer_ip_bin({Ip, _Port})}, Req0)
            end;
        false ->
            reply(
                429,
                #{
                    error => #{
                        message => <<"echo rate limit exceeded">>,
                        type => <<"janus_error">>,
                        code => <<"rate_limited">>
                    }
                },
                Req0,
                #{<<"retry-after">> => <<"60">>}
            )
    end;
handle(_Method, Req0) ->
    reply(405, #{error => #{code => <<"method_not_allowed">>}}, Req0).

reply(Status, Map, Req0) ->
    reply(Status, Map, Req0, #{}).

reply(Status, Map, Req0, ExtraHeaders) ->
    Headers = maps:merge(#{
        <<"content-type">> => <<"application/json">>,
        %% The body is caller-specific (their own peer IP) — a
        %% shared cache must not replay it to another client
        %% (ocr medium).
        <<"cache-control">> => <<"no-store">>
    }, ExtraHeaders),
    cowboy_req:reply(Status, Headers, thoas:encode(Map), Req0).

peer_key(Req) ->
    {Ip, _Port} = cowboy_req:peer(Req),
    peer_ip_bin({Ip, _Port}).

%%%===================================================================
%%% Bucket table (per-peer-IP state)
%%%===================================================================

%% ETS row {IpBin, Tokens, LastMono}; read-compute-write from the
%% handler process. The guard is best-effort abuse protection (not
%% billing): a same-IP race at the burst boundary may admit one extra
%% request — the 4x headroom absorbs it. Tolerant of a missing table
%% (handler before init_knob in tests): allow-through, never a 500 on
%% the liveness-adjacent surface.
-spec allow(binary()) -> boolean().
allow(IpBin) when is_binary(IpBin) ->
    Now = now_ms(),
    Cap = capacity(live_worker_count()),
    try
        _ = ensure_bucket(),
        case ets:lookup(?BUCKET, IpBin) of
            [{IpBin, Tokens, Last}] when is_number(Tokens), is_integer(Last) ->
                bucket_write(IpBin, bucket_step({Tokens, Last}, Now, Cap, ?REFILL_TOKENS_PER_MS));
            _ ->
                bucket_write(IpBin, bucket_step({Cap * 1.0, Now}, Now, Cap, ?REFILL_TOKENS_PER_MS))
        end
    catch
        Class:Reason ->
            %% Never fail the (unauthenticated) request on rate-limit
            %% bookkeeping — but say so: this silent swallow is exactly
            %% what hid the dead prune for so long.
            logger:warning(
                "~p: bucket bookkeeping failed (~p:~p); request admitted anyway",
                [?MODULE, Class, Reason]
            ),
            true
    end.

bucket_write(IpBin, {Allowed, {Tokens, Last}}) ->
    _ = ets:insert(?BUCKET, {IpBin, Tokens, Last}),
    %% The endpoint is unauthenticated and keyed by raw peer IP:
    %% address rotation could insert one permanent row per address
    %% (ocr security high). Insert-time cap with hysteresis: past
    %% cap+margin, sweep once down to cap-slack (a full-bucket
    %% attacker row is the youngest refill-freshest, honest peers
    %% survive); the margin amortizes the sweep so a rotating-source
    %% attacker pays at most one full sweep per margin fresh peers,
    %% never O(table) work per request. Idempotent on races.
    case ets:info(?BUCKET, size) > ?BUCKET_CAP + ?SWEEP_MARGIN of
        true -> prune_once();
        false -> ok
    end,
    Allowed.

prune_once() ->
    StartedAt = now_ms(),
    case ets:insert_new(?BUCKET, {?SWEEP_MARKER, 0, StartedAt}) of
        true ->
            try
                prune_stale()
            after
                %% delete_object of OUR exact marker: a plain key
                %% delete could remove a fresher marker planted by a
                %% TTL reclaimer while this sweep ran past the TTL.
                _ = ets:delete_object(?BUCKET, {?SWEEP_MARKER, 0, StartedAt})
            end;
        false ->
            reclaim_stale_marker()
    end.

reclaim_stale_marker() ->
    %% try..after does not run when a sweeper dies on an exit signal;
    %% a marker older than the sweep TTL belongs to no live sweep, so
    %% take it over. delete_object removes only that exact object — a
    %% concurrently refreshed marker survives untouched.
    case ets:lookup(?BUCKET, ?SWEEP_MARKER) of
        [{?SWEEP_MARKER, 0, StartedAt}] when is_integer(StartedAt) ->
            case now_ms() - StartedAt > ?SWEEP_TTL_MS of
                true ->
                    _ = ets:delete_object(?BUCKET, {?SWEEP_MARKER, 0, StartedAt}),
                    prune_once();
                false ->
                    ok
            end;
        _ ->
            ok
    end.

%% eunit-visible alias for the ?BUCKET_CAP regression test (the
%% macro lives in this module; the test derives the invariant from
%% here so a cap change cannot silently desync the assertion).
-spec bucket_cap() -> pos_integer().
bucket_cap() ->
    ?BUCKET_CAP.

prune_stale() ->
    %% Two passes: stale rows first (Last older than 1 h), then
    %% oldest-Last rows down to cap-slack (hysteresis — see
    %% bucket_write/2). Both bounded per sweep.
    Now = now_ms(),
    _ = ets:select_delete(?BUCKET, [
        {
            {'$1', '$2', '$3'},
            [
                %% Binary keys only: peer-IP rows. Excludes the
                %% single-flight marker (an atom key) so a live sweep
                %% never deletes its own or a peer's marker here.
                {'is_binary', '$1'},
                {'is_integer', '$3'},
                {'<', '$3', Now - ?BUCKET_STALE_MS}
            ],
            %% A match-spec body must be a LIST of return expressions;
            %% a bare `true` is an invalid match program, so
            %% ets:select_delete/2 raised badarg on every call and
            %% allow/1's catch-all silently disabled this whole prune.
            [true]
        }
    ]),
    case ets:info(?BUCKET, size) > ?BUCKET_CAP - ?SWEEP_SLACK of
        true ->
            Keep = ?BUCKET_CAP - ?SWEEP_SLACK,
            %% Binary (peer-IP) keys only — never evict a sweep marker.
            Candidates = [R || {K, _, _} = R <- ets:tab2list(?BUCKET), is_binary(K)],
            Oldest = lists:sort(
                fun({_, _, L1}, {_, _, L2}) -> L1 =< L2 end,
                Candidates
            ),
            %% Count relative to the snapshot actually iterated: a
            %% second live size read races concurrent sweeps (diff can
            %% go negative -> sublist function_clause -> allow/1's
            %% catch-all swallows it -> pruning stops again).
            ToDrop = erlang:max(0, length(Oldest) - Keep),
            _ = [ets:delete(?BUCKET, K) || {K, _, _} <- lists:sublist(Oldest, ToDrop)],
            ok;
        false ->
            ok
    end.

now_ms() ->
    erlang:monotonic_time(millisecond).

ensure_bucket() ->
    case table_exists(?BUCKET) of
        true ->
            ok;
        false ->
            _ = ets:new(?BUCKET, [set, public, named_table, {write_concurrency, true}]),
            ok
    end.

table_exists(Tag) ->
    ets:info(Tag) =/= undefined.

%% Live pooled worker count for the burst sizing (sched_workers is the
%% pool's public live drain table; a missing table = 0 => the floor).
live_worker_count() ->
    try
        ets:info(sched_workers, size)
    catch
        _:_ -> 0
    end.
