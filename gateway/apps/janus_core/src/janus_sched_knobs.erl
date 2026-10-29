%%%-------------------------------------------------------------------
%%% @doc Hot scheduler / model-sync / fleet knob resolve
%%% (spec `2026-10-12-maintenance-hot-knobs-design.md`).
%%%
%%% Resolve order per field: settings JSON → env → code default.
%%% Master `janus_config:distribute_settings/1` stores raw maps in PT;
%%% consumers call {@link resolve_sched/0} (or injectable siblings).
%%% Workers never read these settings keys (F2).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_sched_knobs).

-export([
    resolve_sched/0,
    resolve_sched/2,
    resolve_model_sync_interval/0,
    resolve_model_sync_interval/2,
    resolve_fleet_desired/0,
    resolve_fleet_desired/2,
    fleet_boot_enabled/0,
    fleet_boot_enabled/2,
    geo_effective/2,
    mmdb_present/0,
    sched_raw/0,
    model_sync_raw/0,
    fleet_raw/0,
    put_sched_raw/1,
    put_model_sync_raw/1,
    put_fleet_raw/1,
    publish_resolved/0,
    cached_sched/0,
    bump_geo_refused/0,
    geo_refused_total/0,
    fleet_effective/0,
    put_fleet_effective/1,
    %% Test/boot seam: scrub ALL knob PT keys (settings raw leaks
    %% across eunit stacks — resolve prefers raw over env; merge fix).
    reset_cache/0
]).

-define(PT_SCHED_RAW, {janus, sched_cfg_raw}).
-define(PT_MODEL_SYNC_RAW, {janus, model_sync_cfg_raw}).
-define(PT_FLEET_RAW, {janus, fleet_cfg_raw}).
-define(PT_FLEET_DESIRED, {janus, fleet_desired}).
-define(PT_FLEET_EFFECTIVE, {janus, fleet_effective}).
-define(PT_SCHED_RESOLVED, {janus, sched_cfg_resolved}).
-define(PT_UNARY, {janus, sched_unary_fallback}).
%% atomics ref for lossless concurrent bumps (ocr: PT RMW races).
-define(PT_GEO_REFUSED_ATOMICS, {janus, sched_geo_refused_atomics}).

-define(PROBE_MAX_DEFAULT, 10).
-define(MODEL_SYNC_DEFAULT, 21600).

%%%===================================================================
%%% PT raw accessors (master distribute_settings writers)
%%%===================================================================

-spec put_sched_raw(undefined | map()) -> ok.
put_sched_raw(Raw) ->
    persistent_term:put(?PT_SCHED_RAW, Raw),
    ok = publish_resolved(),
    ok.

-spec put_model_sync_raw(undefined | map()) -> ok.
put_model_sync_raw(Raw) ->
    persistent_term:put(?PT_MODEL_SYNC_RAW, Raw),
    ok.

%% @doc Cache resolved sched Values+Sources + unary PT for hot readers
%% (pick path must stay O(1) PT get — ocr High).
-spec publish_resolved() -> ok.
publish_resolved() ->
    {Vals, Src} = resolve_sched(sched_raw(), env_map()),
    persistent_term:put(?PT_SCHED_RESOLVED, {Vals, Src}),
    persistent_term:put(?PT_UNARY, maps:get(unary_fallback, Vals, false)),
    ok.

%% @doc Hot-path read: cached resolve, or live resolve + cache on miss.
%% Scrub every knob PT (raw, resolved, unary, fleet, model-sync) —
%% eunit stack isolation (a prior cell's put_sched_raw would pin the
%% next stack's resolve; production boots are fresh VMs and settings
%% distributes re-publish, so this is test-only hygiene).
-spec reset_cache() -> ok.
reset_cache() ->
    %% Erase UNCONDITIONALLY — a present-but-false value must go too
    %% (a `false =/= get(K, false)` presence filter skips exactly the
    %% keys that pin stale-off knobs; erase/1 on a missing key raises,
    %% hence the catch).
    [
        catch persistent_term:erase(K)
     || K <- [
            ?PT_SCHED_RAW,
            ?PT_SCHED_RESOLVED,
            ?PT_UNARY,
            ?PT_MODEL_SYNC_RAW,
            ?PT_FLEET_RAW,
            ?PT_FLEET_DESIRED,
            ?PT_FLEET_EFFECTIVE
        ]
    ],
    ok.

-spec cached_sched() -> {map(), map()}.
cached_sched() ->
    case pt_get(?PT_SCHED_RESOLVED, undefined) of
        {Vals, Src} when is_map(Vals), is_map(Src) ->
            {Vals, Src};
        _ ->
            ok = publish_resolved(),
            pt_get(?PT_SCHED_RESOLVED, {#{}, #{}})
    end.

%% @doc Store fleet settings raw AND the resolved `fleet_desired`
%% observability value (`null` | boolean). Computes Desired before
%% either PT write so readers never see new raw with stale desired.
-spec put_fleet_raw(undefined | map()) -> ok.
put_fleet_raw(Raw) ->
    Desired =
        case resolve_fleet_desired(Raw, env_map()) of
            null -> null;
            {Bool, _} -> Bool
        end,
    persistent_term:put(?PT_FLEET_RAW, Raw),
    persistent_term:put(?PT_FLEET_DESIRED, Desired),
    ok.

-spec sched_raw() -> undefined | map().
sched_raw() ->
    pt_get(?PT_SCHED_RAW, undefined).

-spec model_sync_raw() -> undefined | map().
model_sync_raw() ->
    pt_get(?PT_MODEL_SYNC_RAW, undefined).

-spec fleet_raw() -> undefined | map().
fleet_raw() ->
    pt_get(?PT_FLEET_RAW, undefined).

-spec put_fleet_effective(boolean()) -> ok.
put_fleet_effective(Bool) when is_boolean(Bool) ->
    persistent_term:put(?PT_FLEET_EFFECTIVE, Bool),
    ok.

-spec fleet_effective() -> boolean().
fleet_effective() ->
    pt_get(?PT_FLEET_EFFECTIVE, false).

-spec bump_geo_refused() -> non_neg_integer().
bump_geo_refused() ->
    Ref = geo_refused_atomics(),
    atomics:add(Ref, 1, 1),
    atomics:get(Ref, 1).

-spec geo_refused_total() -> non_neg_integer().
geo_refused_total() ->
    atomics:get(geo_refused_atomics(), 1).

geo_refused_atomics() ->
    case pt_get(?PT_GEO_REFUSED_ATOMICS, undefined) of
        Ref when is_reference(Ref) ->
            Ref;
        _ ->
            Ref = atomics:new(1, [{signed, false}]),
            persistent_term:put(?PT_GEO_REFUSED_ATOMICS, Ref),
            Ref
    end.

%%%===================================================================
%%% Resolve — live
%%%===================================================================

-spec resolve_sched() -> {map(), map()}.
resolve_sched() ->
    resolve_sched(sched_raw(), env_map()).

-spec resolve_model_sync_interval() -> {non_neg_integer(), atom()}.
resolve_model_sync_interval() ->
    resolve_model_sync_interval(model_sync_raw(), env_map()).

-spec resolve_fleet_desired() -> null | {boolean(), atom()}.
resolve_fleet_desired() ->
    resolve_fleet_desired(fleet_raw(), env_map()).

-spec fleet_boot_enabled() -> boolean().
fleet_boot_enabled() ->
    fleet_boot_enabled(fleet_raw(), env_map()).

%%%===================================================================
%%% Resolve — injectable (eunit)
%%%===================================================================

%% @doc Returns `{Values, Sources}` for sched knobs.
%% Values: `#{health,rtt,geo,probe,probe_max_hourly,unary_fallback}`.
%% Sources: same keys → `settings | env | default`.
-spec resolve_sched(undefined | map(), map()) -> {map(), map()}.
resolve_sched(Raw, Env) when is_map(Env) ->
    {H, Hs} = bool_field(Raw, <<"health">>, Env, <<"JANUS_SCHED_HEALTH">>, false),
    {R, Rs} = bool_field(Raw, <<"rtt">>, Env, <<"JANUS_SCHED_RTT">>, false),
    {G, Gs} = bool_field(Raw, <<"geo">>, Env, <<"JANUS_SCHED_GEO">>, false),
    {P, Ps} = bool_field(Raw, <<"probe">>, Env, <<"JANUS_SCHED_PROBE">>, false),
    {U, Us} = bool_field(Raw, <<"unary_fallback">>, Env, <<"JANUS_SCHED_UNARY_FALLBACK">>, false),
    {M, Ms} = probe_max_field(Raw, Env),
    {
        #{
            health => H,
            rtt => R,
            geo => G,
            probe => P,
            probe_max_hourly => M,
            unary_fallback => U
        },
        #{
            health => Hs,
            rtt => Rs,
            geo => Gs,
            probe => Ps,
            probe_max_hourly => Ms,
            unary_fallback => Us
        }
    }.

-spec resolve_model_sync_interval(undefined | map(), map()) ->
    {non_neg_integer(), settings | env | default}.
resolve_model_sync_interval(Raw, Env) when is_map(Env) ->
    case settings_int(Raw, <<"interval_sec">>) of
        {ok, N} when N >= 0 ->
            {normalize_sync_interval(N), settings};
        {ok, _} ->
            %% Negative settings are invalid — fall through to env → default.
            resolve_model_sync_interval_env(Env);
        missing ->
            resolve_model_sync_interval_env(Env)
    end.

resolve_model_sync_interval_env(Env) ->
    case maps:get(<<"JANUS_MODEL_SYNC_INTERVAL_SEC">>, Env, undefined) of
        undefined ->
            {?MODEL_SYNC_DEFAULT, default};
        Val when is_list(Val); is_binary(Val) ->
            case parse_int(Val) of
                {ok, N} when N >= 0 ->
                    {normalize_sync_interval(N), env};
                {ok, _} ->
                    {?MODEL_SYNC_DEFAULT, default};
                error ->
                    {?MODEL_SYNC_DEFAULT, default}
            end;
        _ ->
            {?MODEL_SYNC_DEFAULT, default}
    end.

%% @doc `null` when no fleet settings row; else `{Bool, Source}`.
-spec resolve_fleet_desired(undefined | map(), map()) ->
    null | {boolean(), settings | env | default}.
resolve_fleet_desired(undefined, _Env) ->
    null;
resolve_fleet_desired(Raw, Env) when is_map(Raw), is_map(Env) ->
    case maps:find(<<"enabled">>, Raw) of
        {ok, V} when is_boolean(V) ->
            {V, settings};
        {ok, _} ->
            %% malformed field → env → default
            bool_from_env(Env, <<"JANUS_FLEET_ENABLED">>, false);
        error ->
            bool_from_env(Env, <<"JANUS_FLEET_ENABLED">>, false)
    end.

-spec fleet_boot_enabled(undefined | map(), map()) -> boolean().
fleet_boot_enabled(undefined, Env) ->
    {B, _} = bool_from_env(Env, <<"JANUS_FLEET_ENABLED">>, false),
    B;
fleet_boot_enabled(Raw, Env) when is_map(Raw) ->
    case resolve_fleet_desired(Raw, Env) of
        null ->
            fleet_boot_enabled(undefined, Env);
        {B, _} ->
            B
    end.

-spec geo_effective(boolean(), boolean()) -> boolean().
geo_effective(Desired, MmdbPresent) when is_boolean(Desired), is_boolean(MmdbPresent) ->
    Desired andalso MmdbPresent.

%% @doc Same helper as pick path /stats: file at JANUS_MMDB_PATH, or
%% non-empty JANUS_SCHED_GEO_TEST_HOSTS satisfies (test seam).
-spec mmdb_present() -> boolean().
mmdb_present() ->
    case os:getenv("JANUS_SCHED_GEO_TEST_HOSTS") of
        Val when is_list(Val), Val =/= "" ->
            true;
        _ ->
            case os:getenv("JANUS_MMDB_PATH") of
                Path when is_list(Path), Path =/= "" ->
                    filelib:is_regular(Path);
                _ ->
                    false
            end
    end.

%%%===================================================================
%%% Internals
%%%===================================================================

bool_field(Raw, Key, Env, EnvKey, Default) ->
    case settings_bool(Raw, Key) of
        {ok, B} ->
            {B, settings};
        missing ->
            bool_from_env(Env, EnvKey, Default)
    end.

settings_bool(undefined, _) ->
    missing;
settings_bool(Raw, Key) when is_map(Raw) ->
    case maps:find(Key, Raw) of
        {ok, B} when is_boolean(B) -> {ok, B};
        _ -> missing
    end.

settings_int(undefined, _) ->
    missing;
settings_int(Raw, Key) when is_map(Raw) ->
    case maps:find(Key, Raw) of
        {ok, N} when is_integer(N) -> {ok, N};
        _ -> missing
    end.

probe_max_field(Raw, Env) ->
    %% 0 is LEGAL and means HARD OFF (probe_cap: length >= 0 always —
    %% every probe attempt counts skip{cap}; the cap-skip eunit pins
    %% it). Only negative/garbage values floor to 1.
    case settings_int(Raw, <<"probe_max_hourly">>) of
        {ok, N} when N >= 0 ->
            {N, settings};
        {ok, _} ->
            {1, settings};
        missing ->
            case maps:get(<<"JANUS_SCHED_PROBE_MAX_HOURLY">>, Env, undefined) of
                undefined ->
                    {?PROBE_MAX_DEFAULT, default};
                Val ->
                    case parse_int(Val) of
                        {ok, N} when N >= 0 -> {N, env};
                        {ok, _} -> {1, env};
                        error -> {?PROBE_MAX_DEFAULT, default}
                    end
            end
    end.

bool_from_env(Env, EnvKey, Default) ->
    case maps:get(EnvKey, Env, undefined) of
        undefined ->
            {Default, default};
        Val ->
            case truthy(Val) of
                true -> {true, env};
                false ->
                    case unset_or_falsey(Val) of
                        true -> {false, env};
                        false -> {Default, default}
                    end
            end
    end.

%% 0 stays 0; 1..59 → 60; >=60 kept; negative → default
normalize_sync_interval(0) ->
    0;
normalize_sync_interval(N) when is_integer(N), N > 0, N < 60 ->
    60;
normalize_sync_interval(N) when is_integer(N), N >= 60 ->
    N;
normalize_sync_interval(_) ->
    ?MODEL_SYNC_DEFAULT.

parse_int(Val) when is_binary(Val) ->
    parse_int(binary_to_list(Val));
parse_int(Val) when is_list(Val) ->
    try
        {ok, list_to_integer(Val)}
    catch
        _:_ -> error
    end;
parse_int(N) when is_integer(N) ->
    {ok, N};
parse_int(_) ->
    error.

truthy(true) ->
    true;
truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
truthy(Val) when is_binary(Val) ->
    truthy(binary_to_list(Val));
truthy(_) ->
    false.

unset_or_falsey(false) ->
    true;
unset_or_falsey(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["0", "false", "no", "off", ""]);
unset_or_falsey(Val) when is_binary(Val) ->
    unset_or_falsey(binary_to_list(Val));
unset_or_falsey(_) ->
    false.

env_map() ->
    Keys = [
        "JANUS_SCHED_HEALTH",
        "JANUS_SCHED_RTT",
        "JANUS_SCHED_GEO",
        "JANUS_SCHED_PROBE",
        "JANUS_SCHED_PROBE_MAX_HOURLY",
        "JANUS_SCHED_UNARY_FALLBACK",
        "JANUS_MODEL_SYNC_INTERVAL_SEC",
        "JANUS_FLEET_ENABLED"
    ],
    maps:from_list(
        [
            {list_to_binary(K), V}
         || K <- Keys,
            (V = os:getenv(K)) =/= false
        ]
    ).

pt_get(Key, Default) ->
    try
        persistent_term:get(Key)
    catch
        error:badarg ->
            Default
    end.
