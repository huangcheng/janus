%%%-------------------------------------------------------------------
%%% @doc Provider geography (scheduler v2 spec Part A.1): the geo-tier
%%% source and the owner of the heir'd `geo_cache` ETS table.
%%%
%%% Boot (env knobs read ONCE into persistent_term — restart to
%%% change):
%%% <ul>
%%% <li>`JANUS_SCHED_GEO=1` explicit + mmdb file absent and
%%%   `JANUS_SCHED_GEO_TEST_HOSTS` empty => boot REFUSES (CRITICAL log;
%%%   the operator asked for geo).</li>
%%% <li>NON-EMPTY `JANUS_SCHED_GEO_TEST_HOSTS` satisfies the explicit-1
%%%   check AND exempts the existence refusal (test seam counts as geo
%%%   data; loud log) — the gate boots without an mmdb.</li>
%%% <li>File present but corrupt => locus loads ASYNC; failure =>
%%%   auto-off + `geo_disabled` counter + CRITICAL log (never a
%%%   synchronous 60 MB parse in the boot path).</li>
%%% <li>Knob unset => SILENT: geo never enabled, no locus, no logs
%%%   (the default boot is no-behavior-change).</li>
%%% </ul>
%%%
%%% Resolution: `resolve_host/1` consults `JANUS_SCHED_GEO_TEST_HOSTS`
%%% FIRST (exact-binary host match; never overridden), then DNS
%%% (3 s timeout) -> locus mmdb lookup -> region-rule mapping. Private
%%% IPs / parse failures / not-found stay `unknown`; a resolved country
%%% outside the vocabulary maps to `other` (a known tag); lookup
%%% failure stays `unknown` (never matches).
%%%
%%% Population is ASYNC, never blocking catalog build: the
%%% `janus_catalog:publish` seam casts the fresh provider host set
%%% here; results fill `geo_cache` (TTL 30 d positive / 1 h negative,
%%% negative re-resolve guard <= 1 per host per 15 min via
%%% `last_attempt_mono`) and update the `persistent_term` provider-geo
%%% map (`{janus_geo, provider_geo}` — REBUILT from catalog output each
%%% generation, never merged; provider removals are automatic). A
%%% generation bump mid-fill discards stale results. The async locus
%%% load result is the ONE sanctioned runtime writer of the
%%% `geo_enabled` persistent_term key (spec Part C).
%%%
%%% The mmdb is NEVER in git or the image: it is a master-only runtime
%%% file at `JANUS_MMDB_PATH` (GeoLite2 CC BY-SA 4.0 — see the repo
%%% NOTICE file).
%%%-------------------------------------------------------------------
-module(janus_geo).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    %% Resolution
    resolve_host/1,
    resolve_async/2,
    on_catalog_publish/2,
    %% Reads (pick opts / hello typo aid)
    provider_geo/1,
    region_tags/0,
    geo_enabled/0,
    %% Maintenance
    flush/0,
    counters/0,
    %% Pure internals — eunit seams (spec Part E item 1)
    parse_regions/1,
    parse_test_hosts/1,
    injected_region/2,
    map_result/2,
    private_ip/1,
    host_from_base_url/1,
    cached_region/2,
    should_resolve/2,
    rebuild_provider_geo/3
]).
%% gen_server
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/file.hrl").

-define(SERVER, ?MODULE).

-define(PT_GEO_REQUESTED, {janus_geo, geo_requested}).
-define(PT_GEO_ENABLED, {janus_geo, geo_enabled}).
-define(PT_TEST_HOSTS, {janus_geo, test_hosts}).
-define(PT_REGIONS, {janus_geo, regions}).
%% #{ProviderId => GeoBin} — fresh positive entries only; absent key
%% reads `unknown` (provider_geo/1).
-define(PT_PROVIDER_GEO, {janus_geo, provider_geo}).

-define(CACHE, geo_cache).
-define(COUNTERS, janus_geo_counters).
-define(LOCUS_DB, janus_geo_mmdb).

-define(DNS_TIMEOUT_MS, 3000).
-define(POSITIVE_TTL_MS, 30 * 86_400_000).
-define(NEGATIVE_TTL_MS, 3_600_000).
%% Negative re-resolve guard: <= 1 attempt per host per 15 min.
-define(NEGATIVE_REGUARD_MS, 15 * 60 * 1000).
-define(MAX_FILL_CONCURRENCY, 4).
%% Corrupt-file async parse bound (a 60 MB database parses in well
%% under this; a stall counts as a load failure => auto-off).
-define(LOCUS_LOAD_TIMEOUT_MS, 60_000).

-type region_rule() :: #{
    %% Uppercase ISO country code (2 bytes).
    country := binary(),
    %% Lowercased subdivision token matched against the entry's
    %% subdivision iso_code and en name; `any` = bare-CC rule.
    subdivision := binary() | any,
    tag := binary()
}.
-type region_config() :: {[region_rule()], [binary()]}.

-record(state, {
    generation = 0 :: non_neg_integer(),
    %% Host => [ProviderId] for the current catalog generation.
    providers_by_host = #{} :: #{binary() => [term()]},
    queue = [] :: [binary()],
    %% JobRef => {MonitorRef, Host} (capped-concurrency fill workers).
    inflight = #{} :: #{reference() => {reference(), binary()}}
}).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Resolve one provider host to a region tag. Test seam first
%% (exact-binary match, never overridden), then DNS (3 s timeout) ->
%% locus lookup -> rule mapping. Private IP / parse failure /
%% not-found => `unknown`. Never blocks on the catalog build (callers
%% run fill workers, not request paths).
-spec resolve_host(binary()) -> {ok, binary()} | unknown.
resolve_host(HostBin) when is_binary(HostBin) ->
    TestHosts = pt_read(?PT_TEST_HOSTS, #{}),
    case injected_region(HostBin, TestHosts) of
        {ok, Region} ->
            {ok, Region};
        unknown ->
            case pt_read(?PT_GEO_ENABLED, false) of
                false ->
                    %% Geo tier inert: knob-off never spends DNS.
                    unknown;
                true ->
                    resolve_via_dns_mmdb(HostBin)
            end
    end.

%% @doc Fill kick (spec A.1) for a catalog generation: queue DISTINCT
%% hosts for capped-concurrency async resolution. Stale generations
%% (older than the current one) are dropped.
-spec resolve_async([binary()], non_neg_integer()) -> ok.
resolve_async(Hosts, Generation) when is_list(Hosts), is_integer(Generation) ->
    _ = gen_server:cast(?SERVER, {resolve_async, Hosts, Generation}),
    ok.

%% @doc Publish seam called by `janus_catalog:publish/2` after the
%% fresh generation went live: rebuilds the PT provider-geo map from
%% catalog output (never merged) and kicks the async fill for the
%% distinct base_url hosts. Tolerant: janus_geo may not be running
%% (workers, eunit) — the cast is dropped, never an error.
-spec on_catalog_publish(non_neg_integer(), [{term(), binary() | undefined}]) -> ok.
on_catalog_publish(Generation, ProviderHosts) ->
    _ = gen_server:cast(?SERVER, {catalog_published, Generation, ProviderHosts}),
    ok.

%% @doc Region for a provider (pick opts read; lock-free persistent_term).
-spec provider_geo(term()) -> binary() | unknown.
provider_geo(ProviderId) ->
    case pt_read(?PT_PROVIDER_GEO, #{}) of
        #{ProviderId := GeoBin} when is_binary(GeoBin) ->
            GeoBin;
        _ ->
            unknown
    end.

%% @doc The region vocabulary (rule tags ++ `other`) — hello typo aid
%% (spec A.2) and worker-region validation surface.
-spec region_tags() -> [binary()].
region_tags() ->
    {_, Vocab} = regions_cfg(),
    Vocab.

%% @doc Regions config with a LAZY default: `pt_read/2` evaluates its
%% default eagerly, which would re-parse the ~100-rule default table
%% on every call when the PT key is already populated.
-spec regions_cfg() -> {list(), [binary()]}.
regions_cfg() ->
    case pt_read(?PT_REGIONS, undefined) of
        undefined -> default_regions();
        Cfg -> Cfg
    end.

%% @doc Operational geo state (test-seam activations count as enabled;
%% an explicit =1 boot stays disabled until the async locus load
%% succeeds — the load result is the one sanctioned runtime writer).
-spec geo_enabled() -> boolean().
geo_enabled() ->
    pt_read(?PT_GEO_ENABLED, false).

%% @doc Manual flush (reuses the `janus_catalog:flush` path): clear the
%% cache + PT map; the forced reload's publish re-kicks the fill
%% against an empty cache.
-spec flush() -> ok.
flush() ->
    try
        _ = ets:delete_all_objects(?CACHE),
        persistent_term:put(?PT_PROVIDER_GEO, #{})
    catch
        _:_ -> ok
    end,
    ok.

%% @doc Counters for the metrics layer (tolerant read — the table
%% lives as long as the owner).
-spec counters() -> map().
counters() ->
    try
        maps:from_list(ets:tab2list(?COUNTERS))
    catch
        _:_ -> #{}
    end.

%%--------------------------------------------------------------------
%% Pure internals (eunit seams — spec Part E item 1)
%%--------------------------------------------------------------------

%% @doc Parse `JANUS_SCHED_REGIONS` ("CC[:SUBDIVISION]=tag;..." ordered
%% rules, first match wins). `false`/empty/no-valid-rule => the default
%% vocabulary wholesale. Parse errors skip the rule with a warning
%% (never crash). `other` is ALWAYS in the vocabulary (auto-appended).
-spec parse_regions(false | string() | binary()) -> region_config().
parse_regions(false) ->
    default_regions();
parse_regions("") ->
    default_regions();
parse_regions(Env) when is_list(Env); is_binary(Env) ->
    case parse_region_rules(to_bin(Env)) of
        [] ->
            %% No rules parsed => default set (spec A.1).
            default_regions();
        Rules ->
            {Rules, vocab_of(Rules)}
    end.

%% @doc Parse `JANUS_SCHED_GEO_TEST_HOSTS` ("host=region;host2=region2")
%% into an exact-match map; malformed pieces are skipped with a
%% warning.
-spec parse_test_hosts(false | string() | binary()) -> #{binary() => binary()}.
parse_test_hosts(false) ->
    #{};
parse_test_hosts("") ->
    #{};
parse_test_hosts(Env) when is_list(Env); is_binary(Env) ->
    Pieces = binary:split(to_bin(Env), <<";">>, [global, trim_all]),
    lists:foldl(
        fun(Piece, Acc) ->
            case binary:split(Piece, <<"=">>) of
                [Host, Region] when Host =/= <<>>, Region =/= <<>> ->
                    Acc#{Host => Region};
                _ ->
                    logger:warning(#{what => janus_geo_test_host_skipped, entry => Piece}),
                    Acc
            end
        end,
        #{},
        Pieces
    ).

%% @doc TEST seam lookup: exact-binary host match, before DNS/mmdb.
-spec injected_region(binary(), #{binary() => binary()}) -> {ok, binary()} | unknown.
injected_region(Host, TestHosts) when is_map(TestHosts) ->
    case TestHosts of
        #{Host := Region} when is_binary(Region) -> {ok, Region};
        _ -> unknown
    end.

%% @doc Map a locus lookup entry to a region tag. Rule match (country +
%% optional subdivision, first match wins) => the rule tag; a resolved
%% country outside the vocabulary => `other` (a KNOWN tag — it can
%% match a worker declaring `other`); lookup failure / no country =>
%% `unknown` (never matches).
-spec map_result(map() | not_found | {error, term()}, region_config()) ->
    {ok, binary()} | unknown.
map_result(not_found, _Cfg) ->
    unknown;
map_result({error, _Reason}, _Cfg) ->
    unknown;
map_result(Lookup, {Rules, _Vocab}) when is_map(Lookup), is_list(Rules) ->
    case country_of(Lookup) of
        undefined ->
            unknown;
        Country ->
            Subs = subdivision_candidates(Lookup),
            case first_rule_match(Rules, Country, Subs) of
                {ok, Tag} ->
                    {ok, Tag};
                none ->
                    %% Resolved country outside the vocabulary.
                    {ok, <<"other">>}
            end
    end;
map_result(_Other, _Cfg) ->
    unknown.

%% @doc Private / loopback / link-local addresses never geo-resolve.
-spec private_ip(inet:ip_address()) -> boolean().
private_ip({10, _, _, _}) -> true;
private_ip({172, B, _, _}) when B >= 16, B =< 31 -> true;
private_ip({192, 168, _, _}) -> true;
private_ip({127, _, _, _}) -> true;
private_ip({169, 254, _, _}) -> true;
private_ip({0, _, _, _}) -> true;
private_ip({100, B, _, _}) when B >= 64, B =< 127 -> true;
private_ip({A, B, C, D}) when is_integer(A), is_integer(B), is_integer(C), is_integer(D) ->
    false;
%% IPv6 loopback / ULA (fc00::/7) / link-local (fe80::/10).
private_ip({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
private_ip({A, _, _, _, _, _, _, _}) when A =:= 16#fc; A =:= 16#fd -> true;
private_ip({16#fe, B, _, _, _, _, _, _}) when B band 16#c0 =:= 16#80 -> true;
private_ip(Tuple) when tuple_size(Tuple) =:= 8 -> false;
private_ip(_) -> false.

%% @doc Host component of a provider base_url (or `undefined` when the
%%% URL has no host — unparsable base_urls read geo `unknown`).
-spec host_from_base_url(undefined | binary() | string()) -> binary() | undefined.
host_from_base_url(undefined) ->
    undefined;
host_from_base_url(Bin) when is_binary(Bin) ->
    try
        case uri_string:parse(Bin) of
            #{host := Host} when is_binary(Host), Host =/= <<>> ->
                Host;
            _ ->
                undefined
        end
    catch
        _:_ -> undefined
    end;
host_from_base_url(List) when is_list(List) ->
    host_from_base_url(list_to_binary(List));
host_from_base_url(_) ->
    undefined.

%% @doc geo_cache read decision (time-parameterized): a fresh positive
%% row answers its region; expired / negative / missing answer
%% `unknown`.
-spec cached_region(
    none | {binary(), binary() | unknown, integer(), integer()},
    integer()
) -> {ok, binary()} | unknown.
cached_region(none, _Now) ->
    unknown;
cached_region({_Host, Region, ResolvedAt, _LastAttempt}, Now) when is_binary(Region) ->
    case Now - ResolvedAt < ?POSITIVE_TTL_MS of
        true -> {ok, Region};
        false -> unknown
    end;
cached_region({_Host, unknown, _ResolvedAt, _LastAttempt}, _Now) ->
    unknown.

%% @doc geo_cache fill gate (time-parameterized): no row => resolve;
%% fresh positive => never; expired positive or negative => allowed at
%% most once per `NEGATIVE_REGUARD_MS` measured from the row's LAST
%% ATTEMPT (distinct from `resolved_at` — spec A.1).
-spec should_resolve(
    none | {binary(), binary() | unknown, integer(), integer()},
    integer()
) -> boolean().
should_resolve(none, _Now) ->
    true;
should_resolve({_Host, Region, ResolvedAt, LastAttempt}, Now) ->
    %% Positive rows are fresh for POSITIVE_TTL; negative rows are
    %% fresh for NEGATIVE_TTL, and re-attempts are additionally
    %% rate-limited to one per NEGATIVE_REGUARD measured from the
    %% row's LAST ATTEMPT (both TTLs enforced, spec A.1).
    case Region of
        R when is_binary(R) ->
            Now - ResolvedAt >= ?POSITIVE_TTL_MS;
        unknown ->
            (Now - ResolvedAt >= ?NEGATIVE_TTL_MS)
                andalso (Now - LastAttempt >= ?NEGATIVE_REGUARD_MS)
    end.

%% @doc PT provider-geo map rebuild from catalog output (never merged):
%% only FRESH positive cache rows survive; providers absent from
%% `ProviderHosts` disappear automatically (removals are immediate);
%% unknown hosts / negatives / expired rows read `unknown` (absent).
-spec rebuild_provider_geo(
    [{term(), binary() | undefined}],
    [{binary(), binary() | unknown, integer(), integer()}],
    integer()
) -> #{term() => binary()}.
rebuild_provider_geo(ProviderHosts, CacheRows, Now) when is_list(ProviderHosts), is_list(CacheRows) ->
    Fresh = maps:from_list([
        {Host, Region}
     || {Host, Region, ResolvedAt, _} <- CacheRows,
        is_binary(Region),
        Now - ResolvedAt < ?POSITIVE_TTL_MS
    ]),
    lists:foldl(
        fun
            ({ProviderId, Host}, Acc) when is_binary(Host) ->
                case Fresh of
                    #{Host := Region} -> Acc#{ProviderId => Region};
                    _ -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        #{},
        ProviderHosts
    ).

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([]) ->
    TestHosts = parse_test_hosts(os:getenv("JANUS_SCHED_GEO_TEST_HOSTS")),
    Explicit = env_truthy(os:getenv("JANUS_SCHED_GEO")),
    Regions = parse_regions(os:getenv("JANUS_SCHED_REGIONS")),
    Requested = Explicit orelse map_size(TestHosts) > 0,
    persistent_term:put(?PT_TEST_HOSTS, TestHosts),
    persistent_term:put(?PT_REGIONS, Regions),
    persistent_term:put(?PT_GEO_REQUESTED, Requested),
    persistent_term:put(?PT_PROVIDER_GEO, #{}),
    ok = ensure_tables(),
    case boot_geo(TestHosts) of
        {stop, Reason} ->
            {stop, Reason};
        ok ->
            State = replay_catalog(#state{}),
            logger:info(#{
                what => janus_geo_started,
                requested => Requested,
                enabled => geo_enabled(),
                test_hosts => map_size(TestHosts)
            }),
            {ok, State}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast({catalog_published, Generation, ProviderHosts}, State) when
    is_integer(Generation), is_list(ProviderHosts)
->
    Now = now_mono(),
    CacheRows = cache_rows(),
    GeoMap = rebuild_provider_geo(ProviderHosts, CacheRows, Now),
    persistent_term:put(?PT_PROVIDER_GEO, GeoMap),
    ByHost = group_providers_by_host(ProviderHosts),
    RowMap = row_map(CacheRows),
    Need = [
        Host
     || Host <- lists:usort(maps:keys(ByHost)),
        should_resolve(row_for_map(RowMap, Host), Now)
    ],
    State1 = State#state{
        generation = Generation,
        providers_by_host = ByHost,
        queue = Need
    },
    {noreply, dispatch(State1)};
handle_cast({resolve_async, Hosts, Generation}, State) when
    is_list(Hosts), is_integer(Generation), Generation >= State#state.generation
->
    Now = now_mono(),
    CacheRows = cache_rows(),
    RowMap = row_map(CacheRows),
    New = [
        Host
     || Host <- lists:usort([H || H <- Hosts, is_binary(H)]),
        should_resolve(row_for_map(RowMap, Host), Now)
    ],
    State1 = State#state{
        generation = Generation,
        queue = (State#state.queue -- New) ++ New
    },
    {noreply, dispatch(State1)};
handle_cast({resolve_async, _Hosts, _StaleGeneration}, State) ->
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({locus_load_result, Result}, State) ->
    State1 = handle_locus_result(Result, State),
    {noreply, State1};
handle_info({geo_resolved, JobRef, Generation, Host, Result}, State) ->
    case maps:take(JobRef, State#state.inflight) of
        {{MonRef, Host}, Inflight1} ->
            _ = erlang:demonitor(MonRef, [flush]),
            State2 = State#state{inflight = Inflight1},
            State3 =
                case Generation =:= State2#state.generation of
                    true ->
                        ingest_resolution(Host, Result, State2);
                    false ->
                        %% Generation bumped mid-fill: discard the
                        %% result but RE-QUEUE the host so the new
                        %% generation still fills it (silent drop
                        %% would strand the host until the next
                        %% publish — ocr review).
                        State2#state{queue = State2#state.queue ++ [Host]}
                end,
            {noreply, dispatch(State3)};
        error ->
            %% Late duplicate result (host re-queued mid-flight): drop.
            {noreply, State}
    end;
handle_info({'DOWN', MonRef, process, _Pid, _Reason}, State) ->
    %% Worker died before reporting: drop the slot (the row's absence
    %% keeps the host re-resolvable on the next kick).
    Inflight = State#state.inflight,
    JobRefs = [JR || {JR, {M, _}} <- maps:to_list(Inflight), M =:= MonRef],
    {noreply, dispatch(State#state{inflight = maps:without(JobRefs, Inflight)})};
handle_info(_Info, State) ->
    %% Late DNS replies from timed-out resolvers land here — dropped.
    {noreply, State}.

terminate(_Reason, _State) ->
    %% geo_cache is heir'd (survives); counters die with the owner
    %% (tolerant bump pattern, janus_fleet precedent).
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Boot
%%--------------------------------------------------------------------

%% Boot decision table (spec Part 0.1):
%%   - not requested: SILENT off, no locus, no logs.
%%   - explicit =1, no test seam, mmdb absent: REFUSE boot.
%%   - test seam set: enabled immediately (seam counts as geo data),
%%     existence check exempted; locus loads only when a file exists.
%%   - file present: ASYNC locus load; the load result is the ONE
%%     sanctioned runtime writer of geo_enabled.
boot_geo(TestHosts) when is_map(TestHosts) ->
    case pt_read(?PT_GEO_REQUESTED, false) of
        false ->
            persistent_term:put(?PT_GEO_ENABLED, false),
            ok;
        true ->
            TestSeam = map_size(TestHosts) > 0,
            Path = os:getenv("JANUS_MMDB_PATH"),
            case {TestSeam, mmdb_file(Path)} of
                {false, missing} ->
                    logger:critical(#{
                        what => janus_geo_mmdb_missing_boot_refused,
                        path => format_path(Path)
                    }),
                    {stop, {janus_sched_geo_requires_mmdb, Path}};
                {false, FilePresent} ->
                    %% Explicit =1: disabled until the async load
                    %% succeeds (no v1 behavior change meanwhile).
                    persistent_term:put(?PT_GEO_ENABLED, false),
                    start_locus_async(FilePresent);
                {true, missing} ->
                    %% Test seam exempts the existence refusal (gate
                    %% 13.3b boots without an mmdb); loud log.
                    persistent_term:put(?PT_GEO_ENABLED, true),
                    logger:warning(#{
                        what => janus_geo_test_hosts_active_no_mmdb,
                        test_hosts => map_size(TestHosts)
                    }),
                    ok;
                {true, FilePresent} ->
                    persistent_term:put(?PT_GEO_ENABLED, true),
                    logger:warning(#{
                        what => janus_geo_test_hosts_active,
                        test_hosts => map_size(TestHosts)
                    }),
                    start_locus_async(FilePresent)
            end
    end.

%% `missing` or the usable path (string).
mmdb_file(false) ->
    missing;
mmdb_file("") ->
    missing;
mmdb_file(Path) when is_list(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular}} ->
            Path;
        _ ->
            missing
    end;
mmdb_file(_) ->
    missing.

start_locus_async(Path) when is_list(Path) ->
    Self = self(),
    _ = spawn(fun() ->
        Result =
            try
                {ok, _} = application:ensure_all_started(locus),
                case locus:start_loader(?LOCUS_DB, Path) of
                    ok ->
                        locus:await_loader(?LOCUS_DB, ?LOCUS_LOAD_TIMEOUT_MS);
                    {error, StartError} ->
                        {error, StartError}
                end
            catch
                Class:Reason -> {error, {Class, Reason}}
            end,
        Self ! {locus_load_result, Result}
    end),
    ok;
start_locus_async(_) ->
    ok.

%% The async locus load result is the ONE sanctioned runtime writer of
%% `geo_enabled` (spec Part C).
handle_locus_result({ok, Version}, State) ->
    logger:info(#{what => janus_geo_mmdb_loaded, version => Version}),
    persistent_term:put(?PT_GEO_ENABLED, true),
    %% The pre-load kicks were held back for non-injected hosts —
    %% requeue every current host and fill now.
    rekick(State);
handle_locus_result({error, Reason}, State) ->
    case pt_read(?PT_TEST_HOSTS, #{}) of
        TestHosts when map_size(TestHosts) > 0 ->
            %% Seam data keeps the tier alive; the mmdb path is what
            %% got disabled — still an observable disable event.
            disable_event(Reason),
            State;
        _ ->
            disable_event(Reason),
            persistent_term:put(?PT_GEO_ENABLED, false),
            State
    end.

disable_event(Reason) ->
    %% Counter + CRITICAL log fire ONLY when geo was explicitly
    %% requested (the loader never starts otherwise).
    ok = bump(geo_disabled),
    logger:critical(#{what => janus_geo_mmdb_load_failed, reason => Reason}).

%%--------------------------------------------------------------------
%% Fill
%%--------------------------------------------------------------------

%% Self-heal: the boot-time catalog publish (janus_config init) runs
%% BEFORE this child starts — its cast was dropped. Replay it from the
%% published catalog (worker nodes have no catalog: no-op).
replay_catalog(State) ->
    case catch janus_catalog:get() of
        #{generation := Gen, catalog := Tabs} ->
            ProviderHosts =
                try
                    janus_catalog:provider_hosts(Tabs)
                catch
                    _:_ -> []
                end,
            element(2, handle_cast({catalog_published, Gen, ProviderHosts}, State));
        _ ->
            State
    end.

%% Spawn capped-concurrency fill workers for ready hosts. A host is
%% ready when it is TEST-injected (instant) or geo is enabled
%% (locus-loaded / seam-activated); not-ready hosts stay queued — when
%% the async locus load lands, rekick/2 drains them.
dispatch(#state{inflight = Inflight, queue = Queue} = State) ->
    Free = ?MAX_FILL_CONCURRENCY - map_size(Inflight),
    %% Never double-spawn a host that is already in flight.
    Pending = [H || H <- Queue, not inflight_host(H, Inflight)],
    {Run, Keep} = take_ready(Pending, Free),
    lists:foldl(fun spawn_resolver/2, State#state{queue = Keep}, Run).

inflight_host(Host, Inflight) ->
    lists:any(
        fun({_JobRef, {_MonRef, H}}) -> H =:= Host end,
        maps:to_list(Inflight)
    ).

take_ready(Queue, 0) ->
    {[], Queue};
take_ready([], _Free) ->
    {[], []};
take_ready([Host | Rest], Free) ->
    case host_ready(Host) of
        true ->
            {Run, Keep} = take_ready(Rest, Free - 1),
            {[Host | Run], Keep};
        false ->
            {Run, Keep} = take_ready(Rest, Free),
            {Run, [Host | Keep]}
    end.

host_ready(Host) ->
    TestHosts = pt_read(?PT_TEST_HOSTS, #{}),
    is_map_key(Host, TestHosts) orelse geo_enabled().

spawn_resolver(Host, #state{generation = Generation, inflight = Inflight} = State) ->
    Parent = self(),
    JobRef = erlang:make_ref(),
    {_Pid, MonRef} =
        spawn_monitor(fun() ->
            Result = try resolve_host(Host) catch _:_ -> unknown end,
            Parent ! {geo_resolved, JobRef, Generation, Host, Result}
        end),
    State#state{inflight = Inflight#{JobRef => {MonRef, Host}}}.

ingest_resolution(Host, Result, #state{providers_by_host = ByHost} = State) ->
    Now = now_mono(),
    Region = region_of_result(Result),
    ets:insert(?CACHE, {Host, Region, Now, Now}),
    update_provider_geo_pt(Host, Region, ByHost),
    State.

region_of_result({ok, Bin}) when is_binary(Bin) ->
    Bin;
region_of_result(_) ->
    unknown.

%% PT provider-geo map update for every provider of this host (fresh
%% positive rows only; negatives read `unknown` via key absence).
update_provider_geo_pt(Host, Region, ByHost) ->
    case ByHost of
        #{Host := ProviderIds} ->
            Map0 = pt_read(?PT_PROVIDER_GEO, #{}),
            Map1 =
                case Region of
                    unknown ->
                        maps:without(ProviderIds, Map0);
                    TagBin ->
                        lists:foldl(fun(Id, M) -> M#{Id => TagBin} end, Map0, ProviderIds)
                end,
            persistent_term:put(?PT_PROVIDER_GEO, Map1);
        _ ->
            ok
    end.

%% After an async locus load success: requeue every current host that
%% still needs resolution (the pre-load kicks were held back).
rekick(#state{providers_by_host = ByHost} = State) ->
    Now = now_mono(),
    RowMap = row_map(cache_rows()),
    All = [
        Host
     || Host <- lists:usort(maps:keys(ByHost)),
        should_resolve(row_for_map(RowMap, Host), Now)
    ],
    dispatch(State#state{queue = (State#state.queue -- All) ++ All}).

%%--------------------------------------------------------------------
%% Resolution internals
%%--------------------------------------------------------------------

resolve_via_dns_mmdb(HostBin) ->
    HostStr = binary_to_list(HostBin),
    Addr =
        case inet:parse_address(HostStr) of
            {ok, Parsed} ->
                {ok, Parsed};
            {error, _} ->
                dns_resolve(HostStr, ?DNS_TIMEOUT_MS)
        end,
    case Addr of
        {ok, Ip} ->
            case private_ip(Ip) of
                true -> unknown;
                false -> mmdb_lookup(Ip)
            end;
        {error, _} ->
            unknown
    end.

%% inet:getaddr has no timeout variant: race it against a deadline in
%% the fill worker. A late resolver reply lands in the gen_server
%% catch-all and is dropped (the worker already answered `unknown`).
dns_resolve(HostStr, TimeoutMs) ->
    Self = self(),
    _Resolver = spawn(fun() -> Self ! {janus_geo_dns, inet:getaddr(HostStr, inet)} end),
    receive
        {janus_geo_dns, Result} -> Result
    after TimeoutMs ->
        {error, timeout}
    end.

mmdb_lookup(Ip) ->
    Regions = regions_cfg(),
    case catch locus:lookup(?LOCUS_DB, inet:ntoa(Ip)) of
        {ok, Entry} ->
            map_result(Entry, Regions);
        not_found ->
            unknown;
        {error, _Reason} ->
            %% database_not_loaded / database_unknown / invalid_address:
            %% the tier degrades to unknown, never crashes.
            unknown;
        _Other ->
            unknown
    end.

%%--------------------------------------------------------------------
%% Region rules
%%--------------------------------------------------------------------

%% Default vocabulary (spec A.1): cn-east, cn-north, cn-south,
%% cn-southwest, apac, us, eu, other — expressed as ordered rules
%% through the SAME parser (one code path). CN provinces use the
%% standard East/North/South/Southwest grouping; central, northwest
%% and northeast provinces fold into the nearest bucket so CN hosts
%% never land in `other` spuriously; the bare-CN fallback is cn-east
%% (the majority bucket for CN AI providers) — subdivision name
%% variants ("Xizang" vs "Tibet") still resolve via iso_code or the
%% fallback.
-define(DEFAULT_REGIONS_ENV,
    "CN:Shanghai=cn-east;CN:Jiangsu=cn-east;CN:Zhejiang=cn-east;CN:Anhui=cn-east;"
    "CN:Fujian=cn-east;CN:Jiangxi=cn-east;CN:Shandong=cn-east;"
    "CN:Beijing=cn-north;CN:Tianjin=cn-north;CN:Hebei=cn-north;CN:Shanxi=cn-north;"
    "CN:Inner Mongolia=cn-north;CN:Liaoning=cn-north;CN:Jilin=cn-north;"
    "CN:Heilongjiang=cn-north;"
    "CN:Guangdong=cn-south;CN:Guangxi=cn-south;CN:Hainan=cn-south;CN:Henan=cn-south;"
    "CN:Hubei=cn-south;CN:Hunan=cn-south;CN:Hong Kong=cn-south;CN:Macau=cn-south;"
    "CN:Sichuan=cn-southwest;CN:Chongqing=cn-southwest;CN:Guizhou=cn-southwest;"
    "CN:Yunnan=cn-southwest;CN:Tibet=cn-southwest;CN:Shaanxi=cn-southwest;"
    "CN:Gansu=cn-southwest;CN:Qinghai=cn-southwest;CN:Ningxia=cn-southwest;"
    "CN:Xinjiang=cn-southwest;"
    "AS=apac;AU=apac;BD=apac;BN=apac;KH=apac;CK=apac;FJ=apac;GU=apac;IN=apac;"
    "ID=apac;JP=apac;KI=apac;KR=apac;KG=apac;LA=apac;MY=apac;FM=apac;MN=apac;"
    "MM=apac;NR=apac;NP=apac;NC=apac;NZ=apac;NU=apac;NF=apac;PW=apac;PG=apac;"
    "PH=apac;PN=apac;WS=apac;SB=apac;LK=apac;TW=apac;TJ=apac;TH=apac;TL=apac;"
    "TK=apac;TO=apac;TV=apac;VU=apac;VN=apac;"
    "US=us;"
    "AL=eu;AD=eu;AT=eu;BY=eu;BE=eu;BA=eu;BG=eu;HR=eu;CY=eu;CZ=eu;DK=eu;EE=eu;"
    "FI=eu;FR=eu;DE=eu;GR=eu;HU=eu;IS=eu;IE=eu;IT=eu;LV=eu;LI=eu;LT=eu;LU=eu;"
    "MT=eu;MD=eu;MC=eu;ME=eu;NL=eu;MK=eu;NO=eu;PL=eu;PT=eu;RO=eu;RU=eu;SM=eu;"
    "RS=eu;SK=eu;SI=eu;ES=eu;SE=eu;CH=eu;UA=eu;GB=eu;VA=eu;"
    "CN=cn-east"
).

-spec default_regions() -> region_config().
default_regions() ->
    case parse_region_rules(to_bin(?DEFAULT_REGIONS_ENV)) of
        [] ->
            erlang:error(janus_geo_default_regions_broken);
        Rules ->
            {Rules, vocab_of(Rules)}
    end.

parse_region_rules(EnvBin) when is_binary(EnvBin) ->
    Pieces = binary:split(EnvBin, <<";">>, [global, trim_all]),
    lists:foldl(
        fun(Piece, Acc) ->
            case parse_region_rule(Piece) of
                {ok, Rule} -> Acc ++ [Rule];
                {error, Reason} ->
                    logger:warning(#{
                        what => janus_geo_region_rule_skipped,
                        rule => Piece,
                        reason => Reason
                    }),
                    Acc
            end
        end,
        [],
        Pieces
    ).

parse_region_rule(<<>>) ->
    {error, empty};
parse_region_rule(Piece) ->
    case binary:split(Piece, <<"=">>) of
        [Lhs, Tag] when Tag =/= <<>> ->
            case split_cc_subdivision(Lhs) of
                {ok, CC, Subdivision} ->
                    {ok, #{country => CC, subdivision => Subdivision, tag => Tag}};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            {error, bad_rule}
    end.

split_cc_subdivision(Lhs) ->
    case binary:split(Lhs, <<":">>) of
        [CC] ->
            validate_cc(CC, undefined);
        [CC, Sub] when Sub =/= <<>> ->
            validate_cc(CC, string:lowercase(Sub));
        _ ->
            {error, bad_subdivision}
    end.

%% Country must be exactly 2 ASCII letters (case-insensitive).
validate_cc(<<A, B>>, Subdivision) when
    (A >= $a andalso A =< $z) orelse (A >= $A andalso A =< $Z),
    (B >= $a andalso B =< $z) orelse (B >= $A andalso B =< $Z)
->
    CC = string:uppercase(<<A, B>>),
    {ok, CC, subdivision_of(Subdivision)};
validate_cc(_, _) ->
    {error, bad_country}.

subdivision_of(undefined) ->
    any;
subdivision_of(Sub) ->
    Sub.

%% Ordered unique tags (FIRST-APPEARANCE order — the default
%% vocabulary keeps its spec order), `other` ALWAYS appended (auto,
%% last).
vocab_of(Rules) ->
    Tags = [Tag || #{tag := Tag} <- Rules],
    Unique = dedup_preserve_order(Tags),
    case lists:member(<<"other">>, Unique) of
        true -> Unique;
        false -> Unique ++ [<<"other">>]
    end.

dedup_preserve_order(Tags) ->
    {Rev, _Seen} =
        lists:foldl(
            fun(Tag, {Acc, Seen}) ->
                case lists:member(Tag, Seen) of
                    true -> {Acc, Seen};
                    false -> {[Tag | Acc], [Tag | Seen]}
                end
            end,
            {[], []},
            Tags
        ),
    lists:reverse(Rev).

country_of(#{<<"country">> := #{<<"iso_code">> := CC}}) when is_binary(CC), byte_size(CC) =:= 2 ->
    string:uppercase(CC);
country_of(_) ->
    undefined.

%% Candidate subdivision tokens (lowercased): ISO codes and English
%% names — GeoLite2 names live under `<<"names">>.<<"en">>`.
subdivision_candidates(#{<<"subdivisions">> := Subs}) when is_list(Subs) ->
    lists:foldl(
        fun(Sub, Acc) when is_map(Sub) ->
            Acc ++ subdivision_tokens(Sub);
            (_, Acc) ->
                Acc
        end,
        [],
        Subs
    );
subdivision_candidates(_) ->
    [].

subdivision_tokens(Sub) ->
    Iso = maps:get(<<"iso_code">>, Sub, undefined),
    Names = maps:get(<<"names">>, Sub, #{}),
    En = maps:get(<<"en">>, Names, undefined),
    Direct = maps:get(<<"name">>, Sub, undefined),
    Tokens0 = [Iso, En, Direct],
    [string:lowercase(T) || T <- Tokens0, is_binary(T), T =/= <<>>].

first_rule_match([#{country := CC, subdivision := Sub, tag := Tag} | Rest], Country, Subs) ->
    Matched =
        CC =:= Country andalso
            case Sub of
                any -> true;
                Token -> lists:member(Token, Subs)
            end,
    case Matched of
        true -> {ok, Tag};
        false -> first_rule_match(Rest, Country, Subs)
    end;
first_rule_match([], _Country, _Subs) ->
    none.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

ensure_tables() ->
    %% geo_cache is heir'd (spec Part 0.5): adopt from the heir (the
    %% boot-path adopt RETRIES with backoff — the heir may not yet
    %% have processed the old owner's transfer), else create with the
    %% heir set. Counters are owner-local (tolerant bump pattern) —
    %% they died with the previous owner, so the name is free.
    %% The heir starts before this child at boot, but a RUNTIME
    %% restart can race the heir's own restart — retry briefly
    %% instead of crash-looping a permanent child into a full-node
    %% outage (ocr review). The explicit-geo-without-mmdb {stop}
    %% below is DELIBERATE and stays: the spec pins a whole-node
    %% boot refusal for that misconfiguration ("operator asked for
    %% geo; silence would be a lie").
    Heir = heir_with_retry(),
    _ = adopt_or_create(
        ?CACHE,
        [set, public, named_table, {read_concurrency, true}],
        Heir
    ),
    _ = ets:new(?COUNTERS, [set, public, named_table]),
    ok.

heir_with_retry() ->
    heir_with_retry(20).

heir_with_retry(0) ->
    erlang:error({heir_not_running, ?CACHE});
heir_with_retry(N) ->
    try
        janus_ets_heir:heir_for(?CACHE)
    catch
        _:_ ->
            timer:sleep(100),
            heir_with_retry(N - 1)
    end.

adopt_or_create(Tag, Opts, Heir) ->
    case adopt_retry(Tag, 10) of
        {ok, Tab} ->
            {ok, Tab};
        not_held ->
            Tab = ets:new(Tag, Opts ++ [{heir, Heir, {Tag, self()}}]),
            {ok, Tab}
    end.

adopt_retry(_Tag, 0) ->
    not_held;
adopt_retry(Tag, N) when N > 0 ->
    case janus_ets_heir:adopt(Tag) of
        {ok, Tab} ->
            {ok, Tab};
        not_held ->
            timer:sleep(50),
            adopt_retry(Tag, N - 1)
    end.

cache_rows() ->
    try
        ets:tab2list(?CACHE)
    catch
        _:_ -> []
    end.

row_for(CacheRows, Host) ->
    case lists:keyfind(Host, 1, CacheRows) of
        {_, Region, ResolvedAt, LastAttempt} -> {Host, Region, ResolvedAt, LastAttempt};
        false -> none
    end.

%% Host-keyed lookup map built ONCE per pass — the list-comprehension
%% callers would otherwise scan the whole snapshot per host
%% (O(hosts x rows); ocr review).
row_map(CacheRows) ->
    maps:from_list([
        {Host, {Host, Region, ResolvedAt, LastAttempt}}
     || {Host, Region, ResolvedAt, LastAttempt} <- CacheRows
    ]).

row_for_map(RowMap, Host) ->
    case maps:find(Host, RowMap) of
        {ok, Row} -> Row;
        error -> none
    end.

group_providers_by_host(ProviderHosts) ->
    lists:foldl(
        fun
            ({ProviderId, Host}, Acc) when is_binary(Host) ->
                maps:update_with(Host, fun(Ids) -> [ProviderId | Ids] end, [ProviderId], Acc);
            (_, Acc) ->
                Acc
        end,
        #{},
        ProviderHosts
    ).

%% Counter bump (tolerant — counters live as long as the owner).
bump(Key) ->
    try
        _ = ets:update_counter(?COUNTERS, Key, 1, {Key, 0}),
        ok
    catch
        _:_ -> ok
    end.

pt_read(Key, Default) ->
    try
        persistent_term:get(Key)
    catch
        error:badarg -> Default
    end.

to_bin(Val) when is_binary(Val) -> Val;
to_bin(Val) when is_list(Val) -> list_to_binary(Val).

format_path(false) -> undefined;
format_path(Path) -> Path.

env_truthy(false) ->
    false;
env_truthy("") ->
    false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) ->
    false.

now_mono() ->
    erlang:monotonic_time(millisecond).
