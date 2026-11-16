%% Soft domestic/overseas geo dispatch (geo_tier).
%%
%% Zone preference narrows when ≥1 worker matches; otherwise the full
%% healthy set is kept (mono-country / single-worker fail-open).
-module(janus_worker_pool_geo_zone_tests).

-include_lib("eunit/include/eunit.hrl").

cand(Node, GeoRegion) ->
    {Node, #{
        inflight => 0,
        rtt_map => #{},
        capacity => 100,
        draining => false,
        can_sample => true,
        geo_region => GeoRegion
    }}.

order(Candidates, Opts) ->
    {Order, Decisions} = janus_worker_pool:select_v2(Candidates, Opts),
    {Order, maps:get(geo_source, Decisions)}.

%% ---- geo_zone/1 -------------------------------------------------------

geo_zone_cn_prefix_is_domestic_test() ->
    ?assertEqual(domestic, janus_worker_pool:geo_zone(<<"cn-east">>)),
    ?assertEqual(domestic, janus_worker_pool:geo_zone(<<"cn-south">>)),
    ?assertEqual(domestic, janus_worker_pool:geo_zone(<<"cn-beijing">>)),
    ?assertEqual(domestic, janus_worker_pool:geo_zone(<<"domestic">>)).

geo_zone_non_cn_is_overseas_test() ->
    ?assertEqual(overseas, janus_worker_pool:geo_zone(<<"us">>)),
    ?assertEqual(overseas, janus_worker_pool:geo_zone(<<"eu">>)),
    ?assertEqual(overseas, janus_worker_pool:geo_zone(<<"apac">>)),
    ?assertEqual(overseas, janus_worker_pool:geo_zone(<<"other">>)),
    ?assertEqual(overseas, janus_worker_pool:geo_zone(<<"overseas">>)).

geo_zone_unknown_test() ->
    ?assertEqual(unknown, janus_worker_pool:geo_zone(<<>>)),
    ?assertEqual(unknown, janus_worker_pool:geo_zone(undefined)),
    ?assertEqual(unknown, janus_worker_pool:geo_zone(unknown)).

%% ---- region_tag=domestic prefers any cn-* -----------------------------

region_tag_domestic_prefers_all_cn_test() ->
    Cands = [
        cand(eu1, <<"eu">>),
        cand(cn_east, <<"cn-east">>),
        cand(cn_south, <<"cn-south">>)
    ],
    {Order, Source} = order(Cands, #{region_tag => <<"domestic">>}),
    ?assertEqual(region_tag, Source),
    ?assertEqual([cn_east, cn_south], lists:sort(Order)).

%% ---- fine region_tag stays exact --------------------------------------

fine_region_tag_exact_only_test() ->
    Cands = [
        cand(cn_east, <<"cn-east">>),
        cand(cn_south, <<"cn-south">>),
        cand(eu1, <<"eu">>)
    ],
    {Order, Source} = order(Cands, #{region_tag => <<"cn-east">>}),
    ?assertEqual(region_tag, Source),
    ?assertEqual([cn_east], Order).

%% ---- auto provider_geo compares by zone -------------------------------

auto_provider_geo_zone_prefers_all_cn_test() ->
    Cands = [
        cand(eu1, <<"eu">>),
        cand(cn_east, <<"cn-east">>),
        cand(cn_south, <<"cn-south">>)
    ],
    Opts = #{
        geo_enabled => true,
        %% Hangzhou-class fine tag from GeoIP of DashScope host.
        provider_geo => <<"cn-east">>
    },
    {Order, Source} = order(Cands, Opts),
    ?assertEqual(auto, Source),
    ?assertEqual([cn_east, cn_south], lists:sort(Order)).

%% ---- mono-country fail-open (overseas pref, only CN workers) ----------

overseas_pref_mono_cn_fleet_keeps_all_test() ->
    Cands = [
        cand(cn_east, <<"cn-east">>),
        cand(cn_south, <<"cn-south">>)
    ],
    {Order, Source} = order(Cands, #{region_tag => <<"overseas">>}),
    %% No overseas hit → soft fail-open; geo_source resets to none.
    ?assertEqual(none, Source),
    ?assertEqual([cn_east, cn_south], lists:sort(Order)).

%% ---- single worker ----------------------------------------------------

single_worker_any_country_picked_test() ->
    Cands = [cand(only, <<"eu">>)],
    {Order, Source} = order(Cands, #{region_tag => <<"domestic">>}),
    ?assertEqual(none, Source),
    ?assertEqual([only], Order).

%% ---- region_tag outranks auto when both present -----------------------

region_tag_outranks_auto_provider_geo_test() ->
    Cands = [
        cand(cn_east, <<"cn-east">>),
        cand(cn_south, <<"cn-south">>),
        cand(us1, <<"us">>)
    ],
    Opts = #{
        geo_enabled => true,
        provider_geo => <<"cn-east">>,
        %% Explicit fine tag wins: only cn-east, not all domestic.
        region_tag => <<"cn-east">>
    },
    {Order, Source} = order(Cands, Opts),
    ?assertEqual(region_tag, Source),
    ?assertEqual([cn_east], Order).

%% ---- member_geo_region: env fallback when overlay empty ---------------

member_geo_region_falls_back_to_env_test() ->
    ?assertEqual(
        <<"cn-shanghai">>,
        janus_worker_pool:member_geo_region(#{region => <<"cn-shanghai">>})
    ),
    ?assertEqual(
        <<"cn-shanghai">>,
        janus_worker_pool:member_geo_region(#{
            region => <<"cn-shanghai">>,
            geo_source => unset,
            geo_region => undefined
        })
    ),
    ?assertEqual(
        <<"cn-east">>,
        janus_worker_pool:member_geo_region(#{
            region => <<"cn-shanghai">>,
            geo_source => gw_echo,
            geo_region => <<"cn-east">>
        })
    ),
    %% IP layer won but mmdb miss: do not undo ranking with env.
    ?assertEqual(
        undefined,
        janus_worker_pool:member_geo_region(#{
            region => <<"cn-shanghai">>,
            geo_source => gw_echo,
            geo_region => undefined
        })
    ).

%% Fleet-shaped env tags (city codes) drive zone prefer via geo_region.
env_city_tags_domestic_prefers_cn_test() ->
    Cands = [
        cand(tencent, <<"cn-shanghai">>),
        cand(jdcloud, <<"cn-beijing">>),
        cand(contabo, <<"nl-amsterdam">>),
        cand(vultr, <<"fr-lauterbourg">>)
    ],
    {Order, Source} = order(Cands, #{region_tag => <<"domestic">>}),
    ?assertEqual(region_tag, Source),
    ?assertEqual([jdcloud, tencent], lists:sort(Order)).
