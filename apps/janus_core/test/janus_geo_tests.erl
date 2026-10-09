%%% @doc Pure mapping / cache / rebuild tests for `janus_geo`
%%% (scheduler v2 spec Part A.1 / Part E item 1). No network, no mmdb:
%%% locus entry fixtures follow the documented locus `database_entry()`
%%% shape — binary JSON keys, localized names under `<<"names">>` —
%%% because field-shape drift at the locus->janus_geo boundary is the
%%% bug class these tests guard.
-module(janus_geo_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MS_DAY, 86_400_000).
-define(POS_TTL, 30 * ?MS_DAY).
-define(NEG_TTL, 3_600_000).
%% Negative re-resolve guard: <= 1 attempt per host per 15 min.
-define(REGUARD, 15 * 60 * 1000).

%%--------------------------------------------------------------------
%% Fixtures — locus GeoLite2-City entry shapes
%%--------------------------------------------------------------------

cn_shanghai_entry() ->
    #{
        <<"continent">> => #{
            <<"code">> => <<"AS">>,
            <<"names">> => #{<<"en">> => <<"Asia">>}
        },
        <<"country">> => #{
            <<"geoname_id">> => 1814991,
            <<"iso_code">> => <<"CN">>,
            <<"names">> => #{<<"en">> => <<"China">>}
        },
        <<"subdivisions">> => [
            #{
                <<"geoname_id">> => 1796236,
                <<"iso_code">> => <<"SH">>,
                <<"names">> => #{<<"en">> => <<"Shanghai">>}
            }
        ]
    }.

cn_beijing_entry() ->
    #{
        <<"country">> => #{
            <<"iso_code">> => <<"cn">>,
            <<"names">> => #{<<"en">> => <<"China">>}
        },
        <<"subdivisions">> => [
            #{
                <<"iso_code">> => <<"BJ">>,
                <<"names">> => #{<<"en">> => <<"Beijing">>}
            }
        ]
    }.

cn_no_subdivision_entry() ->
    #{
        <<"country">> => #{
            <<"iso_code">> => <<"CN">>,
            <<"names">> => #{<<"en">> => <<"China">>}
        }
    }.

us_entry() ->
    #{
        <<"country">> => #{
            <<"iso_code">> => <<"US">>,
            <<"names">> => #{<<"en">> => <<"United States">>}
        }
    }.

br_entry() ->
    #{
        <<"country">> => #{
            <<"iso_code">> => <<"BR">>,
            <<"names">> => #{<<"en">> => <<"Brazil">>}
        },
        <<"subdivisions">> => [
            #{
                <<"iso_code">> => <<"SP">>,
                <<"names">> => #{<<"en">> => <<"Sao Paulo">>}
            }
        ]
    }.

%%--------------------------------------------------------------------
%% Region vocabulary / rule parsing
%%--------------------------------------------------------------------

default_vocab_is_spec_order_test() ->
    {_Rules, Vocab} = janus_geo:parse_regions(false),
    ?assertEqual(
        [
            <<"cn-east">>,
            <<"cn-north">>,
            <<"cn-south">>,
            <<"cn-southwest">>,
            <<"apac">>,
            <<"us">>,
            <<"eu">>,
            <<"other">>
        ],
        Vocab
    ).

regions_env_replaces_vocab_wholesale_test() ->
    {_Rules, Vocab} = janus_geo:parse_regions("CN:Shanghai=cn-east;CN=cn"),
    %% A bare `cn` rule is legal under an override (operator full
    %% control) — the default vocabulary is REPLACED, not extended.
    ?assertEqual([<<"cn-east">>, <<"cn">>, <<"other">>], Vocab).

regions_parse_errors_skip_rule_test() ->
    {Rules, Vocab} = janus_geo:parse_regions("CN:Shanghai=cn-east;GARBAGE;=nope;US;CN:"),
    %% Only the first rule parses; the malformed pieces are skipped
    %% with a warning, never crash.
    ?assertMatch([#{country := <<"CN">>, tag := <<"cn-east">>}], Rules),
    ?assertEqual([<<"cn-east">>, <<"other">>], Vocab).

regions_no_rules_parsed_falls_back_to_default_test() ->
    Default = janus_geo:parse_regions(false),
    ?assertEqual(Default, janus_geo:parse_regions("")),
    ?assertEqual(Default, janus_geo:parse_regions(";;;no-equals-sign")),
    %% `other` is ALWAYS auto-appended, even by an override that never
    %% mentions it (fallback for resolved-outside-vocab countries).
    ?assert(lists:member(<<"other">>, element(2, janus_geo:parse_regions("US=us")))).

region_tags_default_test() ->
    %% PT read with the boot default when janus_geo never started.
    ?assertEqual(element(2, janus_geo:parse_regions(false)), janus_geo:region_tags()).

%%--------------------------------------------------------------------
%% map_result mapping matrix (injected lookups, ordered rules)
%%--------------------------------------------------------------------

map_subdivision_name_match_test() ->
    Cfg = janus_geo:parse_regions("CN:Shanghai=cn-east;CN=cn"),
    ?assertEqual({ok, <<"cn-east">>}, janus_geo:map_result(cn_shanghai_entry(), Cfg)).

map_subdivision_iso_code_match_test() ->
    %% The rule token matches either the subdivision name or its
    %% ISO code (GeoLite2 names vary by edition).
    Cfg = janus_geo:parse_regions("CN:SH=cn-east;CN=cn"),
    ?assertEqual({ok, <<"cn-east">>}, janus_geo:map_result(cn_shanghai_entry(), Cfg)).

map_rule_order_first_match_wins_test() ->
    Cfg = janus_geo:parse_regions("CN:Shanghai=cn-north;CN:Shanghai=cn-east"),
    ?assertEqual({ok, <<"cn-north">>}, janus_geo:map_result(cn_shanghai_entry(), Cfg)).

map_bare_cc_fallback_test() ->
    Cfg = janus_geo:parse_regions("CN:Shanghai=cn-east;CN=cn"),
    %% Country-only lookup (no subdivisions in the entry) falls to the
    %% bare-CC rule.
    ?assertEqual({ok, <<"cn">>}, janus_geo:map_result(cn_no_subdivision_entry(), Cfg)).

map_case_insensitive_country_and_subdivision_test() ->
    %% Operator writes lowercase; the mmdb entry may carry a lowercase
    %% country code — both normalize.
    Cfg = janus_geo:parse_regions("cn:shanghai=cn-east;cn=cn"),
    ?assertEqual({ok, <<"cn-east">>}, janus_geo:map_result(cn_shanghai_entry(), Cfg)),
    %% Lowercase entry iso_code `cn` + bare-CC fallback.
    ?assertEqual({ok, <<"cn">>}, janus_geo:map_result(cn_beijing_entry(), Cfg)).

map_country_rule_test() ->
    Cfg = janus_geo:parse_regions("CN:Shanghai=cn-east;US=us"),
    ?assertEqual({ok, <<"us">>}, janus_geo:map_result(us_entry(), Cfg)).

map_outside_vocab_is_other_test() ->
    Cfg = janus_geo:parse_regions("CN:Shanghai=cn-east;CN=cn;US=us"),
    %% A resolved country outside the vocabulary maps to `other` — a
    %% KNOWN tag that can still match a worker declaring `other`.
    ?assertEqual({ok, <<"other">>}, janus_geo:map_result(br_entry(), Cfg)).

map_lookup_failure_is_unknown_test() ->
    Cfg = janus_geo:parse_regions("CN=cn"),
    %% Lookup failure stays `unknown` — never `other`, never a match.
    ?assertEqual(unknown, janus_geo:map_result(not_found, Cfg)),
    ?assertEqual(unknown, janus_geo:map_result({error, database_not_loaded}, Cfg)),
    %% Successful entry without a country iso_code cannot be mapped.
    ?assertEqual(unknown, janus_geo:map_result(#{<<"continent">> => #{}}, Cfg)).

%%--------------------------------------------------------------------
%% TEST_HOSTS parsing + exact-match seam
%%--------------------------------------------------------------------

test_hosts_parse_test() ->
    ?assertEqual(#{}, janus_geo:parse_test_hosts(false)),
    ?assertEqual(#{}, janus_geo:parse_test_hosts("")),
    ?assertEqual(
        #{<<"h1">> => <<"cn-east">>, <<"h2">> => <<"us">>},
        janus_geo:parse_test_hosts("h1=cn-east;h2=us")
    ),
    %% Malformed pieces are skipped, valid ones survive.
    ?assertEqual(
        #{<<"ok">> => <<"eu">>},
        janus_geo:parse_test_hosts("nope;ok=eu;=x;=;h3=")
    ).

injected_region_exact_match_test() ->
    Map = janus_geo:parse_test_hosts("api.mock.local=cn-east"),
    ?assertEqual({ok, <<"cn-east">>}, janus_geo:injected_region(<<"api.mock.local">>, Map)),
    %% Exact-binary host match only — no prefix, no case folding.
    ?assertEqual(unknown, janus_geo:injected_region(<<"api.mock.local.x">>, Map)),
    ?assertEqual(unknown, janus_geo:injected_region(<<"API.MOCK.LOCAL">>, Map)),
    ?assertEqual(unknown, janus_geo:injected_region(<<"other.host">>, Map)).

%%--------------------------------------------------------------------
%% geo_cache TTL + negative re-resolve guard (time-parameterized)
%%--------------------------------------------------------------------

cached_region_positive_ttl_test() ->
    Now = 1_000_000,
    Row = {<<"h">>, <<"cn-east">>, Now, Now},
    ?assertEqual({ok, <<"cn-east">>}, janus_geo:cached_region(Row, Now + ?POS_TTL - 1)),
    ?assertEqual(unknown, janus_geo:cached_region(Row, Now + ?POS_TTL)),
    ?assertEqual(unknown, janus_geo:cached_region(none, Now)).

cached_region_negative_ttl_test() ->
    Now = 1_000_000,
    %% A fresh negative row answers `unknown` (never a region).
    Row = {<<"h">>, unknown, Now, Now},
    ?assertEqual(unknown, janus_geo:cached_region(Row, Now + ?NEG_TTL - 1)),
    ?assertEqual(unknown, janus_geo:cached_region(Row, Now + ?NEG_TTL)).

should_resolve_guard_test() ->
    Now = 1_000_000,
    %% No row: always resolvable.
    ?assert(janus_geo:should_resolve(none, Now)),
    %% Fresh positive: no re-resolve.
    ?assertNot(janus_geo:should_resolve({<<"h">>, <<"us">>, Now, Now}, Now + ?POS_TTL - 1)),
    %% Negative rows need BOTH the 1 h negative TTL to elapse AND the
    %% 15 min attempt-rate guard (TTL enforced, ocr review).
    ?assertNot(
        janus_geo:should_resolve({<<"h">>, unknown, Now, Now}, Now + ?REGUARD)
    ),
    ?assertNot(
        janus_geo:should_resolve(
            {<<"h">>, unknown, Now - ?NEG_TTL, Now}, Now + ?REGUARD - 1
        )
    ),
    ?assert(
        janus_geo:should_resolve(
            {<<"h">>, unknown, Now - ?NEG_TTL, Now}, Now + ?REGUARD
        )
    ),
    %% Expired positive: re-resolve allowed (guard measured from the
    %% last ATTEMPT, not resolved_at).
    ?assert(
        janus_geo:should_resolve({<<"h">>, <<"us">>, Now, Now}, Now + ?POS_TTL)
    ).

%%--------------------------------------------------------------------
%% PT provider-geo map rebuild semantics
%%--------------------------------------------------------------------

rebuild_provider_geo_removes_stale_and_keeps_fresh_test() ->
    Now = 500_000,
    Cache = [
        {<<"a.host">>, <<"cn-east">>, Now, Now},
        {<<"neg.host">>, unknown, Now, Now},
        {<<"exp.host">>, <<"us">>, Now - 31 * ?MS_DAY, Now - 31 * ?MS_DAY},
        {<<"gone.host">>, <<"eu">>, Now, Now}
    ],
    Providers = [
        {1, <<"a.host">>},
        {2, <<"neg.host">>},
        {3, <<"exp.host">>},
        {4, <<"brand.new.host">>},
        {5, undefined}
    ],
    %% REBUILT from catalog output (never merged): only fresh positive
    %% rows survive; the stale provider id (gone.host) disappears
    %% automatically; unparsable base_url (undefined host) reads unknown.
    ?assertEqual(#{1 => <<"cn-east">>}, janus_geo:rebuild_provider_geo(Providers, Cache, Now)).

%%--------------------------------------------------------------------
%% Private-IP guard
%%--------------------------------------------------------------------

private_ip_test() ->
    ?assert(janus_geo:private_ip({10, 0, 0, 1})),
    ?assert(janus_geo:private_ip({172, 16, 0, 1})),
    ?assert(janus_geo:private_ip({172, 31, 255, 255})),
    ?assertNot(janus_geo:private_ip({172, 32, 0, 1})),
    ?assertNot(janus_geo:private_ip({172, 15, 0, 1})),
    ?assert(janus_geo:private_ip({192, 168, 1, 1})),
    ?assert(janus_geo:private_ip({127, 0, 0, 1})),
    ?assert(janus_geo:private_ip({169, 254, 1, 1})),
    ?assertNot(janus_geo:private_ip({93, 184, 216, 34})),
    ?assertNot(janus_geo:private_ip({8, 8, 8, 8})),
    ?assert(janus_geo:private_ip({0, 0, 0, 0, 0, 0, 0, 1})),
    ?assert(janus_geo:private_ip({16#fc, 0, 0, 0, 0, 0, 0, 0})),
    ?assert(janus_geo:private_ip({16#fd, 12, 0, 0, 0, 0, 0, 0})),
    ?assert(janus_geo:private_ip({16#fe, 16#80, 0, 0, 0, 0, 0, 1})),
    ?assertNot(
        janus_geo:private_ip({16#2606, 16#2800, 16#220, 1, 16#248, 16#1893, 16#25c8, 16#1946})
    ).

%%--------------------------------------------------------------------
%% base_url host extraction
%%--------------------------------------------------------------------

host_from_base_url_test() ->
    ?assertEqual(
        <<"api.example.com">>,
        janus_geo:host_from_base_url(<<"https://api.example.com/v1">>)
    ),
    ?assertEqual(
        <<"api.example.com">>,
        janus_geo:host_from_base_url(<<"http://api.example.com">>)
    ),
    ?assertEqual(undefined, janus_geo:host_from_base_url(undefined)),
    ?assertEqual(undefined, janus_geo:host_from_base_url(<<"not a url">>)),
    ?assertEqual(undefined, janus_geo:host_from_base_url(<<"">>)).
