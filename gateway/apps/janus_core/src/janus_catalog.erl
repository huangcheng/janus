%%%-------------------------------------------------------------------
%%% @doc Catalog ETS builder + atomic `persistent_term` swap.
%%%
%%% Hot path reads only via {@link get/0} / table tids in the published
%%% catalog map. Config publish builds a fresh set of ETS tables, then
%%% swaps the pointer — never mutates live tables in place and never
%%% touches LB runtime ETS owned by {@link janus_lb}.
%%%
%%% Expected DB row bundle (from `janus_db_conn:fetch_catalog/0`):
%%% ```
%%% #{models => [#{id, name, enabled}],
%%%   model_routes => [#{model_id, provider_id, upstream_model_id,
%%%                      weight, priority, enabled}],
%%%   providers => [#{id, name, base_url, protocol, enabled,
%%%                   region_tag, affinity_node}],
%%%   provider_keys => [#{id, provider_id, secret_ciphertext, key_id,
%%%                       weight, enabled}],
%%%   api_keys => [#{id, prefix, key_hash, enabled, rpm_limit,
%%%                  tpm_limit, daily_token_limit}],
%%%   api_key_models => [#{api_key_id, model_name}],
%%%   provider_models => [#{id, provider_id, name, enabled, meta,
%%%                         modality}],
%%%   key_entitlements => [#{provider_key_id, model_name, status,
%%%                          provider_id}],
%%%   entitlement_codes => [#{provider, match_status, code_keyword,
%%%                           outcome}]}
%%% ```
%%% `settings` rides in the same bundle but is consumed by
%%% `janus_config`, not the catalog. Rows are normally atom-keyed maps
%%% from `row_map/2`; field reads accept the binary spelling too, and
%%% rows a parser cannot classify are skipped with a warning.
%%% Provider secrets stay as ciphertext / opaque `{KeyId, Cipher}` refs.
%%%-------------------------------------------------------------------
-module(janus_catalog).

%% Clash with pre-R14 auto-imported erlang:get/0.
-compile({no_auto_import, [get/0]}).

-export([
    pt_key/0,
    get/0,
    generation/0,
    build/1,
    publish/2,
    routes_for_model/1,
    listings_for/1,
    listing_enabled/2,
    model_modality/1,
    vision_capable/1,
    listing_names/0,
    listings_summary/0,
    lookup_model/1,
    lookup_provider/1,
    lookup_api_key/1,
    lookup_api_keys/1,
    provider_keys/1,
    %% Failure observability (cool edges): KeyId -> ProviderId index.
    key_provider_index/0,
    %% Fleet quota gossip (native-distribution spec B2): all agent-key
    %% metas (id + limits) for the heartbeat publisher.
    api_keys/0,
    %% Fleet command F.1: pinned `catalog_cache_flush` MFA.
    flush/0,
    %% Scheduler v2 geo fill seam (spec A.1): {ProviderId, Host} pairs
    %% from a published providers table, consumed by janus_geo.
    provider_hosts/1,
    %% Entitlement carrier (spec Part B)
    entitlement_denied/3,
    entitlement_codes/0
]).

-define(PT_KEY, {janus, catalog}).
%% Upper bound for `weight` (model_routes / provider_keys). The weighted
%% RR excludes nothing at 0 and crashes on a negative value; a huge
%% weight would expand the LB pick list per call (review 01b M2).
-define(MAX_WEIGHT, 1000).

-type model_id() :: term().
-type provider_id() :: term().
-type catalog_tabs() :: #{
    models := ets:tid(),
    routes_by_model := ets:tid(),
    providers := ets:tid(),
    provider_keys := ets:tid(),
    api_keys_by_prefix := ets:tid(),
    listings_by_name := ets:tid(),
    %% {{ProviderId, ListingNameBinary}, #{KeyId => deny|balance|broken}}
    deny_keys := ets:tid(),
    %% {ProviderBinary, [#{match_status, code_keyword, outcome}]}
    entitlement_codes := ets:tid()
}.
-type published() :: #{
    generation := non_neg_integer(),
    catalog := catalog_tabs()
}.

-export_type([catalog_tabs/0, published/0]).

%%--------------------------------------------------------------------
%% Public
%%--------------------------------------------------------------------

-spec pt_key() -> {janus, catalog}.
pt_key() ->
    ?PT_KEY.

-spec get() -> published() | undefined.
get() ->
    try
        persistent_term:get(?PT_KEY)
    catch
        error:badarg ->
            undefined
    end.

-spec generation() -> non_neg_integer().
generation() ->
    case get() of
        #{generation := Gen} -> Gen;
        undefined -> 0
    end.

%% @doc Build a fresh set of catalog ETS tables from a DB row bundle.
-spec build(map()) -> catalog_tabs().
build(Rows) when is_map(Rows) ->
    Models = new_tab(),
    Routes = new_tab(),
    Providers = new_tab(),
    ProvKeys = new_tab(),
    ApiKeys = new_tab(),
    insert_models(Models, bundle_rows(models, Rows)),
    insert_routes(Routes, bundle_rows(model_routes, Rows)),
    insert_providers(Providers, bundle_rows(providers, Rows)),
    insert_provider_keys(ProvKeys, bundle_rows(provider_keys, Rows)),
    Listings = new_tab(),
    insert_api_keys(ApiKeys, bundle_rows(api_keys, Rows), bundle_rows(api_key_models, Rows)),
    insert_listings(Listings, bundle_rows(provider_models, Rows)),
    Deny = new_tab(),
    insert_deny_keys(Deny, bundle_rows(key_entitlements, Rows)),
    Codes = new_tab(),
    insert_entitlement_codes(Codes, bundle_rows(entitlement_codes, Rows)),
    #{
        models => Models,
        routes_by_model => Routes,
        providers => Providers,
        provider_keys => ProvKeys,
        api_keys_by_prefix => ApiKeys,
        listings_by_name => Listings,
        deny_keys => Deny,
        entitlement_codes => Codes
    }.

%% Rows that are not maps (driver tuples, JSON scalars, a malformed
%% snapshot) carry no readable columns: every row_get/2 would answer
%% `undefined` while truthy(undefined) is true, so they used to land as
%% ENABLED entries with undefined ids/names (review 06d L6). Drop them
%% at the bundle boundary with one warning per row — the same
%% skip-and-warn discipline the listing/deny/codes parsers apply. A
%% non-list bundle value is the same drift class and ships empty.
bundle_rows(Key, Bundle) ->
    case maps:get(Key, Bundle, []) of
        Rows when is_list(Rows) ->
            [Row || Row <- Rows, keep_row(Key, Row)];
        Other ->
            warn_once({bad_bundle_rows, Key, Other}, #{
                what => janus_catalog_bad_bundle_rows,
                table => Key,
                value => Other
            }),
            []
    end.

keep_row(_Key, Row) when is_map(Row) ->
    true;
keep_row(Key, Row) ->
    warn_once({bad_row, Key, Row}, #{
        what => janus_catalog_bad_row,
        table => Key,
        row => Row
    }),
    false.

%% @doc Atomically publish `Tabs` for `Generation`. Previous catalog
%% ETS tables are deleted after a short delay so in-flight lookups
%% (LB pick, auth) cannot `badarg` on a dropped tid. Does not touch LB ETS.
-spec publish(non_neg_integer(), catalog_tabs()) -> ok.
publish(Generation, Tabs) when is_integer(Generation), Generation >= 0, is_map(Tabs) ->
    Old = get(),
    persistent_term:put(?PT_KEY, #{generation => Generation, catalog => Tabs}),
    schedule_delete(Old),
    %% Scheduler v2 geo fill kick (spec A.1): async, never blocks the
    %% publish; janus_geo publishes nothing back into the catalog (it
    %% owns the PT provider-geo map). Tolerant: janus_geo is a
    %% master-side child and may not be running here (workers, eunit)
    %% — the cast is dropped, never an error.
    _ = (catch janus_geo:on_catalog_publish(Generation, provider_hosts(Tabs))),
    ok.

%% {ProviderId, HostBin | undefined} from a published providers table
%% (undefined = unparsable base_url — geo reads unknown). The janus_geo
%% boot replay reuses this against the already-published catalog.
-spec provider_hosts(catalog_tabs()) -> [{term(), binary() | undefined}].
provider_hosts(Tabs) when is_map(Tabs) ->
    case maps:get(providers, Tabs, undefined) of
        undefined ->
            [];
        Tid ->
            try
                [
                    {Id, janus_geo:host_from_base_url(maps:get(base_url, Meta, undefined))}
                 || {Id, Meta} <- ets:tab2list(Tid),
                    is_map(Meta)
                ]
            catch
                _:_ -> []
            end
    end;
provider_hosts(_) ->
    [].

-spec routes_for_model(model_id()) -> [map()].
routes_for_model(ModelId) ->
    case ets_lookup(table(routes_by_model), ModelId) of
        [{_, Routes}] -> Routes;
        _ -> []
    end.

%% @doc Enabled provider listings registered under `Name` — one
%% synthetic direct-call route per provider that offers it:
%% #{provider_id, model_id => null}. Provider-level enablement is
%% checked by the LB at pick time (same as bound routes).
-spec listings_for(binary()) -> [map()].
listings_for(Name) when is_binary(Name) ->
    case ets_lookup(table(listings_by_name), Name) of
        [{_, Entries}] ->
            [
                #{provider_id => P, model_id => null}
             || #{provider_id := P, enabled := true} <- Entries
            ];
        _ ->
            []
    end.

%% @doc True unless an EXPLICIT disabled provider_models row exists for
%% `{ProviderId, Name}` (the bound-route pick used to ignore
%% provider_models.enabled, so a disabled listing stayed callable through
%% every route bound to it and the dashboard had to compensate by turning
%% those routes off). A MISSING row is NOT disabled: the pick must fail open when
%% the catalog lags the DB, and `routed_limits/1` already treats an unknown
%% listing as "contributes nothing" without refusing the pick.
-spec listing_enabled(provider_id(), binary()) -> boolean().
listing_enabled(ProviderId, Name) when is_binary(Name) ->
    case ets_lookup(table(listings_by_name), Name) of
        [{_, Entries}] when is_list(Entries) ->
            not lists:any(fun(E) -> explicit_disabled(E, ProviderId) end, Entries);
        _ ->
            true
    end;
listing_enabled(_, _) ->
    true.

explicit_disabled(#{provider_id := P, enabled := E}, ProviderId) ->
    P =:= ProviderId andalso E =:= false;
explicit_disabled(_, _) ->
    false.

%% @doc Distinct listing names that are enabled on at least one
%% provider — the union of the providers' catalogs.
-spec listing_names() -> [binary()].
listing_names() ->
    case table(listings_by_name) of
        undefined ->
            [];
        Tid ->
            try
                ets:foldl(
                    fun({Name, Entries}, Acc) ->
                        case lists:any(fun(#{enabled := E}) -> E end, Entries) of
                            true -> [Name | Acc];
                            false -> Acc
                        end
                    end,
                    [],
                    Tid
                )
            catch
                error:badarg -> []
            end
    end.

%% @doc Name -> merged capability metadata across providers offering
%% it: OR-ed reasoning/vision flags and token caps. Fields are dropped
%% when no provider reports them. Caps come from the bound routes' own
%% listings (min, so every member can serve the advertised window) and,
%% for names nothing is bound to, from the max across the listings
%% sharing the name.
%% Operator curation wins over provider metadata: settings key
%% "model_capabilities" ({name => #{vision => bool, ...}}) is read at
%% boot and on each config distribution; providers' bare OpenAI-shape
%% listings report nothing, so curation is the real source (the janus-auto
%% image-routing constraint depends on it).
-spec listings_summary() -> #{binary() => map()}.
listings_summary() ->
    case table(listings_by_name) of
        undefined ->
            #{};
        Tid ->
            try
                %% Layer 2 (provider catalog): pass-through merge of every
                %% enabled listing registered under the name.
                Catalog = ets:foldl(
                    fun({Name, Entries}, Acc) ->
                        case provider_meta(Entries, #{}) of
                            Meta when map_size(Meta) > 0 -> Acc#{Name => Meta};
                            _ -> Acc
                        end
                    end,
                    #{},
                    Tid
                ),
                %% A bound name's caps must be servable by every route it
                %% picks, so its limit groups come from the routes' own
                %% listings (min) and an unrelated listing that merely
                %% shares the name cannot move them.
                Scoped = attach_routed_limits(Catalog),
                %% Names whose only known limits come from a layer that is
                %% NOT the provider catalog. A listing whose provider entry
                %% carried no usable meta never enters Catalog, yet
                %% janus_http_models:list_models/1 advertises every enabled
                %% listing name and emitted it as a bare {id,object,owned_by}
                %% entry with its curated window / ceiling silently dropped
                %% (2 such listings in prod, task-25). Seed those names with
                %% an empty layer so the curated / snapshot merge below can
                %% fill them; a name that ends up with nothing known is still
                %% filtered out, so the surface metadata shape is unchanged.
                Layers = maps:merge(known_limits_by_name(), Scoped),
                %% Precedence: curated model_limits > provider catalog meta
                %% (including the route-derived limits above) > models.dev
                %% snapshot (community-maintained, joined per provider at
                %% dashboard sync time). `#{}` as a case pattern matches
                %% EVERY map (open subset matching) — the size check is
                %% required for "nothing known", and names with nothing
                %% known stay out of the surface metadata.
                maps:filter(
                    fun(_Name, Merged) -> map_size(Merged) > 0 end,
                    maps:map(
                        fun(Name, Meta) ->
                            %% Settled entry: normalize both dimensions ONCE
                            %% here, where the four layers meet, so no layer
                            %% (current or future) can leave an alias-only
                            %% window / ceiling behind — the emit reads the
                            %% canonical names and aliases them on the wire.
                            canonical_out(
                                canonical_ctx(
                                    maps:merge(
                                        maps:merge(snapshot_entry(Name), Meta),
                                        curated_entry(Name)
                                    )
                                )
                            )
                        end,
                        Layers
                    )
                )
            catch
                error:badarg -> #{}
            end
    end.

%% Advertised listings that own a curated or models.dev value although
%% their provider meta folded to nothing (see listings_summary/0). Names
%% outside the advertised listing set are left alone: a curated typo must
%% not put anything new on the surface.
known_limits_by_name() ->
    Configured =
        maps:keys(persistent_term:get({janus, model_limits_cfg}, #{})) ++
            maps:keys(persistent_term:get({janus, models_dev_cfg}, #{})),
    Listings = listing_names(),
    maps:from_list([{Name, #{}} || Name <- Configured, lists:member(Name, Listings)]).

provider_meta([], Acc) ->
    Acc;
provider_meta([#{enabled := true, meta := Meta} | Rest], Acc) when is_map(Meta) ->
    provider_meta(Rest, merge_meta(Meta, Acc));
provider_meta([_ | Rest], Acc) ->
    provider_meta(Rest, Acc).

%% Bound model names: replace the limit groups their routes report with
%% the route-derived min, and register the name so curation and the
%% models.dev snapshot reach bound names that have no listing of their
%% own (a public name whose upstream listing name differs).
attach_routed_limits(Catalog) ->
    case table(models) of
        undefined ->
            Catalog;
        Tid ->
            try
                ets:foldl(
                    fun
                        ({Key, #{name := Name, id := Id, enabled := true}}, Acc) when
                            Key =:= Name, is_integer(Id), is_binary(Name)
                        ->
                            Entry = maps:get(Name, Acc, #{}),
                            RouteLimits = routed_limits(Id),
                            %% Normalize the route-derived layer too: a cap the
                            %% routes report owns the window group, so the
                            %% models.dev snapshot — merged later, per key — must
                            %% not re-introduce the alias with an uncapped
                            %% number (review i: context_length 8000 capped by
                            %% the routes with context_window 400000 from the
                            %% snapshot, breaking this module's own "a cap must
                            %% be servable by every route" invariant).
                            Merged = with_ctx_window(
                                maps:merge(
                                    without_reported_groups(Entry, RouteLimits),
                                    RouteLimits
                                )
                            ),
                            Acc#{Name => Merged};
                        (_, Acc) ->
                            Acc
                    end,
                    Catalog,
                    Tid
                )
            catch
                error:badarg -> Catalog
            end
    end.

%% Drop the limit groups the routes report, so a same-named listing's
%% value for that dimension cannot leak through. A group no route reports
%% keeps whatever the catalog merge produced.
without_reported_groups(Entry, RouteLimits) ->
    Keys =
        case maps:is_key(<<"context_length">>, RouteLimits) of
            true -> ctx_limit_keys();
            false -> []
        end ++
            case maps:is_key(<<"max_output_tokens">>, RouteLimits) of
                true -> out_limit_keys();
                false -> []
            end,
    maps:without(Keys, Entry).

%% Curated token limits for one name (settings key "model_limits",
%% distributed as {janus, model_limits_cfg}): only the integer limit keys,
%% validated positive at the dashboard's PUT. `context_window` is accepted
%% as the documented alias of the window, so curation (and the models.dev
%% snapshot) can set it directly.
%%
%% Normalized through with_ctx_window/1 before the layers are merged, so the
%% highest-precedence layer that reports a window owns both spellings.
curated_entry(Name) ->
    case persistent_term:get({janus, model_limits_cfg}, #{}) of
        #{Name := Entry} when is_map(Entry) -> with_ctx_window(limit_fields(Entry));
        _ -> #{}
    end.

%% models.dev snapshot entry for one name (settings key "models_dev",
%% written by the dashboard's sync): #{<<"models">> => #{Name =>
%% #{<<"context_length">> => int, <<"max_output_tokens">> => int}}}.
snapshot_entry(Name) ->
    case persistent_term:get({janus, models_dev_cfg}, #{}) of
        #{<<"models">> := Models} when is_map(Models) ->
            case Models of
                #{Name := Entry} when is_map(Entry) -> with_ctx_window(limit_fields(Entry));
                _ -> #{}
            end;
        _ ->
            #{}
    end.

%% Curated-limits keys, validated positive at the dashboard's PUT. Two
%% dimensions, and EVERY documented spelling of each is accepted —
%% `limit_fields/1` used to keep only `context_length` / `context_window`
%% / `max_output_tokens`, so a layer entry that spelled the window
%% `max_input_tokens` or the ceiling `max_completion_tokens` / `max_tokens`
%% was stored (and reported back by the dashboard) yet silently absent
%% from /v1/models, while the very same value under the canonical spelling
%% worked (task-25). The kept entry is normalized through the same
%% canonicalizers merge_meta/1 uses, so the layer owns the canonical name
%% too; reported spellings are kept verbatim, never overwritten.
limit_fields(M) ->
    Kept = maps:filter(
        fun(K, V) ->
            lists:member(K, ctx_sources() ++ out_sources()) andalso
                is_integer(V) andalso V > 0
        end,
        M
    ),
    canonical_out(canonical_ctx(Kept)).

%% @doc True when the model can accept image inputs: a curated
%% capability override (settings key "model_capabilities", distributed
%% as {janus, model_capabilities_cfg}) or, absent curation, the merged
%% provider metadata's vision flag.
-spec vision_capable(binary()) -> boolean().
vision_capable(Name) when is_binary(Name) ->
    Overrides = persistent_term:get({janus, model_capabilities_cfg}, #{}),
    case maps:get(Name, Overrides, undefined) of
        #{<<"vision">> := V} when is_boolean(V) ->
            V;
        _ ->
            case listings_summary() of
                #{Name := #{<<"vision">> := true}} -> true;
                _ -> false
            end
    end;
vision_capable(_) ->
    false.

%% Pass-through merge of raw provider catalog entries (binary JSON
%% keys): numbers take the max across providers, booleans OR, and every
%% other value keeps the first non-null under the upstream's own field
%% name — no curation. `context_length` and `max_output_tokens` are
%% additionally synthesized (first known spelling, max across providers)
%% as cross-provider conveniences for clients that want one canonical
%% key; kimi's nested `limit.{context,output}` map is promoted to the
%% top-level spellings before the fold so it participates.
merge_meta(Meta, Acc) ->
    Acc1 =
        maps:fold(
            fun
                (K, V, A) when is_integer(V), V > 0 ->
                    case A of
                        #{K := Prev} when is_integer(Prev), Prev >= V -> A;
                        _ -> A#{K => V}
                    end;
                (K, true, A) ->
                    %% boolean true ORs in (false never overrides true)
                    case A of
                        #{K := true} -> A;
                        _ -> A#{K => true}
                    end;
                (K, V, A) ->
                    case maps:is_key(K, A) of
                        true -> A;
                        false -> A#{K => V}
                    end
            end,
            Acc,
            flatten_limits(Meta)
        ),
    canonical_out(canonical_ctx(Acc1)).

%% Nested limit maps are promoted to the top-level spellings the merge
%% rule and the canonicalizers read: kimi-style
%% `limit.{context,output}` and volcengine/ark-style
%% `token_limits.{context_window,max_input_token_length,
%% max_output_token_length}`. Without the promotion the nested numbers
%% never reach the merge and the catalog entry advertises no limit at
%% all. An explicit top-level key wins over the nested one (maps:merge
%% keeps Meta's values).
flatten_limits(Meta) ->
    Add = lists:foldl(
        fun(Key, Acc) ->
            case maps:get(Key, Meta, undefined) of
                L when is_map(L) -> promote_nested(L, Acc);
                _ -> Acc
            end
        end,
        #{},
        [<<"limit">>, <<"token_limits">>]
    ),
    case map_size(Add) of
        0 -> Meta;
        _ -> maps:merge(Add, Meta)
    end.

promote_nested(L, Acc) ->
    lists:foldl(
        fun({Src, Dst}, A) ->
            case maps:get(Src, L, undefined) of
                V when is_integer(V), V > 0 -> A#{Dst => V};
                _ -> A
            end
        end,
        Acc,
        [
            {<<"context">>, <<"context_length">>},
            {<<"context_length">>, <<"context_length">>},
            {<<"context_window">>, <<"context_window">>},
            {<<"max_input_token_length">>, <<"max_input_tokens">>},
            {<<"output">>, <<"max_output_tokens">>},
            {<<"max_output_tokens">>, <<"max_output_tokens">>},
            {<<"max_output_token_length">>, <<"max_output_tokens">>}
        ]
    ).

%% Limit spellings, grouped by the dimension they cap. A name bound to
%% several routes must advertise a window EVERY route can serve, so the
%% bound-name merge takes the MIN per group. The groups are stripped
%% independently because a provider may report only one of them.
ctx_limit_keys() ->
    [
        <<"context_length">>,
        <<"context_window">>,
        <<"max_input_tokens">>,
        <<"max_input_token_length">>
    ].

out_limit_keys() ->
    [
        <<"max_output_tokens">>,
        <<"max_completion_tokens">>,
        <<"max_tokens">>,
        <<"max_output_token_length">>
    ].

%% Limits advertised by the listings a bound model actually routes to:
%% min per group across its enabled routes, in canonical spellings. A
%% route whose listing row is missing or disabled contributes nothing —
%% unknown is not small, and inventing a number would be worse than the
%% catalog / curated / models.dev layers that follow.
routed_limits(Id) when is_integer(Id) ->
    {Ctx, Out} = lists:foldl(
        fun(Route, Acc) -> route_limits(Route, Acc) end,
        {undefined, undefined},
        routes_for_model(Id)
    ),
    canonical_limit_fields(Ctx, Out);
routed_limits(_) ->
    #{}.

canonical_limit_fields(Ctx, Out) ->
    maps:merge(
        case Ctx of
            undefined -> #{};
            _ -> #{<<"context_length">> => Ctx}
        end,
        case Out of
            undefined -> #{};
            _ -> #{<<"max_output_tokens">> => Out}
        end
    ).

route_limits(#{enabled := true, provider_id := P, upstream_model_id := U}, {Ctx, Out}) when
    is_binary(U)
->
    %% A route through a disabled provider is never picked (the LB checks
    %% provider enablement at pick time), so it must not constrain the
    %% advertised window.
    case provider_enabled(P) of
        false ->
            {Ctx, Out};
        true ->
            case listing_meta(P, U) of
                undefined ->
                    {Ctx, Out};
                Meta ->
                    Flat = flatten_limits(Meta),
                    {
                        min_opt(Ctx, group_min(Flat, ctx_limit_keys())),
                        min_opt(Out, group_min(Flat, out_limit_keys()))
                    }
            end
    end;
route_limits(_Route, Acc) ->
    Acc.

provider_enabled(Id) ->
    case lookup_provider(Id) of
        {ok, #{enabled := true}} -> true;
        _ -> false
    end.

%% The provider's own row for one listing (route → upstream listing).
listing_meta(ProviderId, Name) ->
    case ets_lookup(table(listings_by_name), Name) of
        [{_, Entries}] ->
            case [
                M
             || #{provider_id := P, enabled := true, meta := M} <- Entries,
                P =:= ProviderId,
                is_map(M)
            ] of
                [M | _] -> M;
                [] -> undefined
            end;
        _ ->
            undefined
    end.

group_min(Meta, Keys) ->
    lists:foldl(
        fun(K, Acc) ->
            case maps:get(K, Meta, undefined) of
                V when is_integer(V), V > 0 -> min_opt(Acc, V);
                _ -> Acc
            end
        end,
        undefined,
        Keys
    ).

min_opt(undefined, V) -> V;
min_opt(V, undefined) -> V;
min_opt(A, B) -> min(A, B).

canonical_ctx(Acc) ->
    Sources = ctx_sources(),
    %% EVERY layer that can report a window is normalized through
    %% with_ctx_window/1 — here for the catalog listing, and in
    %% curated_entry/1 + snapshot_entry/1 for the curated limits and the
    %% models.dev snapshot — and listings_summary/0 normalizes the settled
    %% result once more. That is the invariant that keeps the two documented
    %% spellings consistent: whichever layer owns the window owns BOTH names,
    %% so a lower layer can never leave a stale window behind a higher
    %% layer's canonical value (review F1, then h2/i: a snapshot
    %% `context_window` contradicting a route-capped `context_length`).
    %% A single entry that itself reports both, disagreeing, is still kept
    %% verbatim — nothing reported is overwritten.
    with_ctx_window(canonicalize(Acc, Sources, <<"context_length">>)).

%% Mirror the context window between its two documented spellings, each
%% direction only when the other key is absent (an explicitly reported value
%% is never overwritten). `context_window` is what memoh (and other
%% compaction clients) validate; `context_length` is the canonical name.
%% Applied at the FINAL emit in listings_summary/0, never per listing.
with_ctx_window(Entry) when is_map(Entry) ->
    Ctx = maps:get(<<"context_length">>, Entry, undefined),
    Win = maps:get(<<"context_window">>, Entry, undefined),
    case {Ctx, Win} of
        {undefined, W} when is_integer(W), W > 0 -> Entry#{<<"context_length">> => W};
        {C, undefined} when is_integer(C), C > 0 -> Entry#{<<"context_window">> => C};
        _ -> Entry
    end;
with_ctx_window(Entry) ->
    Entry.

%% Window dimension, most canonical spelling first: `context_length` is
%% the name the /v1/models wire reads, `context_window` the alias memoh
%% and other compaction clients validate, `max_input_tokens` Anthropic's.
%% One list, read by the canonicalizer AND by limit_fields/1 so a layer
%% can never be filtered on a different set of spellings than the one it
%% is then canonicalized with (task-25).
ctx_sources() ->
    [<<"context_length">>, <<"context_window">>, <<"max_input_tokens">>].

%% Output ceiling: Anthropic's Models API names it max_tokens; OpenAI-
%% shape catalogs spell it max_output_tokens / max_completion_tokens.
out_sources() ->
    [<<"max_output_tokens">>, <<"max_completion_tokens">>, <<"max_tokens">>].

canonical_out(Acc) ->
    Sources = out_sources(),
    canonicalize(Acc, Sources, <<"max_output_tokens">>).

canonicalize(Acc, Sources, Dst) ->
    case first_known(Acc, Sources) of
        V when is_integer(V), V > 0 ->
            case Acc of
                #{Dst := Prev} when is_integer(Prev), Prev >= V -> Acc;
                _ -> Acc#{Dst => V}
            end;
        _ ->
            Acc
    end.

first_known(Meta, [K | Ks]) ->
    case maps:get(K, Meta, undefined) of
        undefined -> first_known(Meta, Ks);
        V -> V
    end;
first_known(_, []) ->
    undefined.

decode_meta(null) ->
    null;
decode_meta(Bin) when is_binary(Bin) ->
    case thoas:decode(Bin) of
        {ok, M} when is_map(M) -> M;
        _ -> null
    end;
decode_meta(M) when is_map(M) ->
    M;
decode_meta(_) ->
    null.

-spec lookup_model(binary() | model_id()) -> {ok, map()} | error.
lookup_model(Key) ->
    case ets_lookup(table(models), Key) of
        [{_, Meta}] -> {ok, Meta};
        _ -> error
    end.

-spec lookup_provider(provider_id()) -> {ok, map()} | error.
lookup_provider(ProviderId) ->
    case ets_lookup(table(providers), ProviderId) of
        [{_, Meta}] -> {ok, Meta};
        _ -> error
    end.

-spec lookup_api_key(binary()) -> {ok, map()} | error.
lookup_api_key(Prefix) when is_binary(Prefix) ->
    case lookup_api_keys(Prefix) of
        [Meta | _] -> {ok, Meta};
        [] -> error
    end.

%% All catalog rows sharing an 8-byte prefix (collisions are rare but
%% must not silently drop a valid key). Auth verifies the HMAC of each.
-spec lookup_api_keys(binary()) -> [map()].
lookup_api_keys(Prefix) when is_binary(Prefix) ->
    case ets_lookup(table(api_keys_by_prefix), Prefix) of
        [{_, Metas}] when is_list(Metas) -> Metas;
        [{_, Meta}] when is_map(Meta) -> [Meta];
        _ -> []
    end.

-spec provider_keys(provider_id()) -> [map()].
provider_keys(ProviderId) ->
    case ets_lookup(table(provider_keys), ProviderId) of
        [{_, Keys}] -> Keys;
        _ -> []
    end.

%% @doc `#{KeyId => ProviderId}` for every provider key in the published
%% catalog (`#{}` when no catalog is published). LB cool rows carry only
%% the key id; the failure-observability cool edges/snapshot need the
%% owning provider.
-spec key_provider_index() -> #{term() => provider_id()}.
key_provider_index() ->
    try
        ets:foldl(
            fun
                ({ProviderId, Keys}, Acc) when is_list(Keys) ->
                    lists:foldl(
                        fun
                            (#{id := Id}, A) -> A#{Id => ProviderId};
                            (_, A) -> A
                        end,
                        Acc,
                        Keys
                    );
                (_, Acc) ->
                    Acc
            end,
            #{},
            table(provider_keys)
        )
    catch
        _:_ -> #{}
    end.

%% All agent-key metas across every prefix (fleet quota heartbeat:
%% limits live in these rows; per-prefix lookup is auth-shaped and
%% cannot enumerate).
-spec api_keys() -> [map()].
api_keys() ->
    try
        ets:foldl(
            fun
                ({_Prefix, Metas}, Acc) when is_list(Metas) -> Metas ++ Acc;
                ({_Prefix, Meta}, Acc) when is_map(Meta) -> [Meta | Acc];
                (_, Acc) -> Acc
            end,
            [],
            table(api_keys_by_prefix)
        )
    catch
        _:_ -> []
    end.

%% Fleet command `catalog_cache_flush` (spec F.1): pure-local
%% idempotent cache clear. Drops the published catalog pointer (picks
%% answer catalog_not_ready, exactly like a cold boot) and nudges an
%% immediate FORCE reload so the poll's same-generation skip cannot
%% leave the node cold — the tables are reaped on their normal delayed
%% schedule so in-flight lookups never badarg.
-spec flush() -> ok.
flush() ->
    try
        case get() of
            undefined ->
                ok;
            Pub = #{catalog := _Tabs} ->
                _ = persistent_term:erase(?PT_KEY),
                _ = schedule_delete(Pub),
                logger:info(#{what => janus_catalog_flushed})
        end
    catch
        Class:Reason ->
            logger:warning(#{what => janus_catalog_flush_failed, class => Class, reason => Reason})
    end,
    %% Scheduler v2 (spec A.1): manual flush clears geo_cache too — the
    %% forced reload's publish re-kicks the fill against an empty cache.
    _ = (catch janus_geo:flush()),
    %% Detached: the reload is a gen_server call with a 30 s DB budget
    %% and must never block the erpc executor.
    _ = spawn(fun() -> catch janus_config:reload() end),
    ok.

%%--------------------------------------------------------------------
%% Entitlement carrier (spec Part B)
%%--------------------------------------------------------------------

%% deny | balance | broken when the carrier marks this
%% (provider, listing, key); false otherwise. ModelName is the
%% UPSTREAM-sent listing name (binary match — the binary-vs-atom bug
%% class); ok rows never ship, so absence = eligible.
-spec entitlement_denied(provider_id(), binary(), term()) ->
    deny | balance | broken | false.
entitlement_denied(ProviderId, ModelName, KeyId) when is_binary(ModelName) ->
    %% Key-level '__key__' rows (probe-abort broken keys) apply to
    %% EVERY listing and outrank listing-scoped marks; broken keys are
    %% never fail-open candidates (spec A.2/C.1).
    case denied_key_status(ProviderId, <<"__key__">>, KeyId) of
        false -> denied_key_status(ProviderId, ModelName, KeyId);
        Status -> Status
    end;
entitlement_denied(_, _, _) ->
    false.

denied_key_status(ProviderId, ModelName, KeyId) ->
    case ets_lookup(table(deny_keys), {ProviderId, ModelName}) of
        [{_, Map}] when is_map(Map) ->
            case maps:get(KeyId, Map, false) of
                Status when Status =:= deny; Status =:= balance; Status =:= broken -> Status;
                _ -> false
            end;
        _ ->
            false
    end.

%% Classification rows for the retry-time classifier, grouped per
%% provider name (binary). Missing table = [] = fully fail-open.
-spec entitlement_codes() -> #{binary() => [map()]}.
entitlement_codes() ->
    case table(entitlement_codes) of
        undefined ->
            #{};
        Tid ->
            try
                maps:from_list(ets:tab2list(Tid))
            catch
                error:badarg -> #{}
            end
    end.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

new_tab() ->
    ets:new(janus_catalog_tab, [set, public, {read_concurrency, true}] ++ heir_opt()).

%% Catalog tables are heir'd (review 01b H0): when the owning
%% `janus_config` process crashes, OTP hands the live generation to
%% `janus_ets_heir` instead of deleting it, so the published
%% `persistent_term` pointer keeps resolving to real tables until the
%% restarted owner publishes the next generation (no "catalog not ready"
%% window, no empty-read masquerade). eunit calls `build/1` without the
%% heir process, so a missing heir falls back to a plain table — exactly
%% the pre-fix behavior (cold on owner death).
heir_opt() ->
    case whereis(janus_ets_heir) of
        undefined ->
            [];
        _ ->
            try
                Heir = janus_ets_heir:heir_for(janus_catalog_tab),
                [{heir, Heir, {janus_catalog_tab, self()}}]
            catch
                _:_ -> []
            end
    end.

%% Adopt-and-delete every catalog table the heir is still holding for a
%% previous owner. Runs from the delayed publish cleanup, i.e. AFTER the
%% pointer swap and the 2s in-flight grace: every live generation is in
%% `persistent_term`, so a held table is necessarily stale (a crashed
%% owner's generation or a half-built set that never published) and
%% would otherwise sit in the heir for the life of the node.
discard_held() ->
    case catch janus_ets_heir:adopt(janus_catalog_tab) of
        {ok, Tid} ->
            _ = (catch ets:delete(Tid)),
            discard_held();
        _ ->
            ok
    end.

ets_lookup(undefined, _Key) ->
    [];
ets_lookup(Tid, Key) ->
    try
        ets:lookup(Tid, Key)
    catch
        error:badarg -> []
    end.

table(Name) ->
    case get() of
        #{catalog := Tabs} -> maps:get(Name, Tabs, undefined);
        undefined -> undefined
    end.

schedule_delete(undefined) ->
    ok;
schedule_delete(Old) ->
    spawn(fun() ->
        receive
        after 2000 ->
            delete_tabs(Old),
            discard_held()
        end
    end),
    ok.

delete_tabs(undefined) ->
    ok;
delete_tabs(#{catalog := Tabs}) when is_map(Tabs) ->
    maps:foreach(
        fun(_K, Tid) ->
            try
                ets:delete(Tid)
            catch
                error:badarg -> ok
            end
        end,
        Tabs
    );
delete_tabs(_) ->
    ok.

insert_models(Tid, Rows) ->
    lists:foreach(
        fun(Row) ->
            Id = row_get(Row, id),
            Name = row_get(Row, name),
            Enabled = truthy(row_get(Row, enabled, true)),
            Meta = #{id => Id, name => Name, enabled => Enabled},
            ets:insert(Tid, {Id, Meta}),
            case Name of
                undefined -> ok;
                _ -> ets:insert(Tid, {Name, Meta})
            end
        end,
        Rows
    ).

insert_routes(Tid, Rows) ->
    Grouped = lists:foldl(
        fun(Row, Acc) ->
            ModelId = row_get(Row, model_id),
            Route = #{
                model_id => ModelId,
                provider_id => row_get(Row, provider_id),
                upstream_model_id => row_get(Row, upstream_model_id),
                weight => weight_or_1(row_get(Row, weight, 1)),
                priority => to_int(row_get(Row, priority, 0), 0),
                enabled => truthy(row_get(Row, enabled, true))
            },
            maps:update_with(ModelId, fun(Rs) -> [Route | Rs] end, [Route], Acc)
        end,
        #{},
        Rows
    ),
    maps:foreach(
        fun(ModelId, Routes) ->
            Sorted = lists:sort(
                fun(A, B) ->
                    maps:get(priority, A) =< maps:get(priority, B)
                end,
                lists:reverse(Routes)
            ),
            ets:insert(Tid, {ModelId, Sorted})
        end,
        Grouped
    ).

insert_providers(Tid, Rows) ->
    lists:foreach(
        fun(Row) ->
            Id = row_get(Row, id),
            Meta = #{
                id => Id,
                name => row_get(Row, name),
                base_url => row_get(Row, base_url),
                protocol => row_get(Row, protocol),
                enabled => truthy(row_get(Row, enabled, true)),
                region_tag => row_get(Row, region_tag),
                affinity_node => row_get(Row, affinity_node)
            },
            ets:insert(Tid, {Id, Meta})
        end,
        Rows
    ).

insert_provider_keys(Tid, Rows) ->
    Grouped = lists:foldl(
        fun(Row, Acc) ->
            ProviderId = row_get(Row, provider_id),
            %% Opaque secret ref only — never plaintext in catalog ETS.
            SecretRef = opaque_secret_ref(Row),
            Key = #{
                id => row_get(Row, id),
                provider_id => ProviderId,
                secret_ref => SecretRef,
                weight => weight_or_1(row_get(Row, weight, 1)),
                enabled => truthy(row_get(Row, enabled, true))
            },
            maps:update_with(ProviderId, fun(Ks) -> [Key | Ks] end, [Key], Acc)
        end,
        #{},
        Rows
    ),
    maps:foreach(
        fun(ProviderId, Keys) ->
            ets:insert(Tid, {ProviderId, lists:reverse(Keys)})
        end,
        Grouped
    ).

insert_listings(Tid, Rows) ->
    Grouped = lists:foldl(
        fun(Row, Acc) ->
            P = row_get(Row, provider_id),
            N = row_get(Row, name),
            E = row_get(Row, enabled),
            case P =/= undefined andalso is_binary(N) andalso E =/= undefined of
                true ->
                    %% Same normalization as every other enabled column
                    %% (truthy/1 handles SMALLINT 0/1, atoms and the text
                    %% forms; unrecognized values fail closed) — the listing
                    %% path used to hardcode this check and missed the
                    %% binary spellings (review 01b H2/M3).
                    Enabled = truthy(E),
                    %% meta is JSONB/TEXT — decode defensively (bad JSON or
                    %% a driver-encoded value must never break a reload).
                    Entry = #{
                        provider_id => P,
                        enabled => Enabled,
                        meta => decode_meta(row_get(Row, meta, null)),
                        modality => modality_bin(row_get(Row, modality, <<"chat">>))
                    },
                    maps:update_with(N, fun(Entries) -> [Entry | Entries] end, [Entry], Acc);
                false ->
                    %% A partial row used to raise function_clause AFTER
                    %% build/1 had created its tables, so janus_config
                    %% crash-looped and leaked a table set per restart. Skip
                    %% like the deny/codes parsers do (review 06d M1); dedupe
                    %% so one permanent bad row warns once per build process.
                    warn_once({bad_listing_row, Row}, #{
                        what => janus_catalog_bad_row,
                        table => provider_models,
                        row => Row
                    }),
                    Acc
            end
        end,
        #{},
        Rows
    ),
    maps:foreach(
        fun(N, Entries) ->
            ets:insert(Tid, {N, lists:reverse(Entries)})
        end,
        Grouped
    ).

%% Modality tag from the DB — anything unexpected (incl. the
%% undefined atom from a missing key) reads as chat.
modality_bin(M) when
    M =:= <<"image">>;
    M =:= <<"tts">>;
    M =:= <<"asr">>;
    M =:= <<"video">>;
    M =:= <<"computer">>;
    M =:= <<"embedding">>
->
    M;
modality_bin(_) ->
    <<"chat">>.

%% The modality of a listing name (first enabled entry wins). <<"chat">>
%% when unknown — the wrong_modality guard is advisory, not load-bearing.
-spec model_modality(binary()) -> binary().
model_modality(Name) when is_binary(Name) ->
    case ets_lookup(table(listings_by_name), Name) of
        [{_, Entries}] when is_list(Entries) ->
            case [M || #{modality := M, enabled := true} <- Entries] of
                [M | _] -> M;
                [] -> modality_bin(undefined)
            end;
        _ ->
            modality_bin(undefined)
    end.

%% Carrier rows: #{provider_key_id, model_name, status, provider_id}.
%% Stored as {{ProviderId, ListingName}, #{KeyId => Status}} — keyed
%% by provider AND model (listing names collide across providers; the
%% exclusion must not leak across a name collision). 'ok' rows never
%% ship (absence = eligible, matching the LB convention).
insert_deny_keys(Tid, Rows) ->
    Grouped = lists:foldl(
        fun(#{provider_key_id := Kid, model_name := Name, status := Status, provider_id := P}, Acc)
                when is_binary(Name), Status =:= <<"deny">> orelse Status =:= <<"balance">> orelse
                Status =:= <<"broken">> ->
                StatusA = binary_to_existing_atom(Status, utf8),
                maps:update_with(
                    {P, Name},
                    fun(Map) -> Map#{Kid => StatusA} end,
                    #{Kid => StatusA},
                    Acc
                );
            (_, Acc) ->
                Acc
        end,
        #{},
        Rows
    ),
    maps:foreach(
        fun(Key, KeyMap) ->
            ets:insert(Tid, {Key, KeyMap})
        end,
        Grouped
    ).

insert_entitlement_codes(Tid, Rows) ->
    lists:foreach(
        fun(#{provider := P, match_status := MS, code_keyword := KW, outcome := Outcome})
                when is_binary(P) ->
                Entry = #{match_status => MS, code_keyword => KW, outcome => Outcome},
                case ets:lookup(Tid, P) of
                    [{_, Existing}] -> ets:insert(Tid, {P, Existing ++ [Entry]});
                    [] -> ets:insert(Tid, {P, [Entry]})
                end;
            (_) ->
                ok
        end,
        Rows
    ).

insert_api_keys(Tid, Keys, AllowRows) ->
    Allow = lists:foldl(
        fun(Row, Acc) ->
            ApiKeyId = row_get(Row, api_key_id),
            ModelName = row_get(Row, model_name),
            maps:update_with(ApiKeyId, fun(Ms) -> [ModelName | Ms] end, [ModelName], Acc)
        end,
        #{},
        AllowRows
    ),
    lists:foreach(
        fun(Row) ->
            Id = row_get(Row, id),
            Prefix = row_get(Row, prefix),
            Meta = #{
                id => Id,
                prefix => Prefix,
                key_hash => row_get(Row, key_hash),
                enabled => truthy(row_get(Row, enabled, true)),
                rpm_limit => null_int(row_get(Row, rpm_limit, null)),
                tpm_limit => null_int(row_get(Row, tpm_limit, null)),
                daily_token_limit => null_int(row_get(Row, daily_token_limit, null)),
                model_names =>
                    case maps:find(Id, Allow) of
                        {ok, Ms} -> lists:reverse(Ms);
                        error -> all
                    end
            },
            case Prefix of
                undefined ->
                    ok;
                _ ->
                    Prev =
                        case ets:lookup(Tid, Prefix) of
                            [{_, Existing}] when is_list(Existing) -> Existing;
                            [{_, One}] when is_map(One) -> [One];
                            _ -> []
                        end,
                    ets:insert(Tid, {Prefix, Prev ++ [Meta]})
            end
        end,
        Keys
    ).

opaque_secret_ref(Row) when is_map(Row) ->
    Cipher = row_get(Row, secret_ciphertext, row_get(Row, ciphertext, undefined)),
    KeyId = row_get(Row, key_id),
    {KeyId, Cipher};
opaque_secret_ref(Row) when is_tuple(Row) ->
    %% Soft support for positional DB tuples if integrator prefers them.
    case Row of
        {_Id, _ProviderId, Cipher, KeyId, _Weight, _Enabled} ->
            {KeyId, Cipher};
        _ ->
            {undefined, Row}
    end.

%% Fields are atom-keyed by `janus_db_conn:row_map/2`, but a
%% snapshot/fleet/JSON-decoded bundle may carry binary keys — try both
%% spellings before the absent-column default (review 06d L6: the
%% binary-vs-atom trap). Non-map rows never reach a parser
%% (`bundle_rows/2` drops them).
row_get(Row, Key) when is_map(Row) ->
    row_get(Row, Key, undefined);
row_get(_Row, _Key) ->
    undefined.

row_get(Row, Key, Default) when is_map(Row), is_atom(Key) ->
    case maps:find(Key, Row) of
        {ok, Value} ->
            Value;
        error ->
            case maps:find(atom_to_binary(Key, utf8), Row) of
                {ok, Value} -> Value;
                error -> Default
            end
    end;
row_get(_Row, _Key, Default) ->
    Default.

%% `enabled` is a SMALLINT 0/1 in SQL, but it reaches the catalog in
%% whatever the driver/JSON layer produced. Only the RECOGNIZED enabled
%% spellings answer true: anything unrecognized fails CLOSED so a
%% revoked provider/key/model/listing can never be picked because its
%% "disabled" was spelled differently (review 01b H2/M3 — the old
%% catch-all returned true, i.e. failed open). `undefined` stays
%% enabled: it is `row_get/2`'s absent-column sentinel, and the catalog
%% contract defaults a missing `enabled` to enabled.
truthy(true) -> true;
truthy(1) -> true;
truthy(<<"1">>) -> true;
truthy(<<"t">>) -> true;
truthy(<<"true">>) -> true;
truthy(false) -> false;
truthy(0) -> false;
truthy(<<"0">>) -> false;
truthy(<<"f">>) -> false;
truthy(<<"false">>) -> false;
truthy(undefined) -> true;
truthy(Other) ->
    warn_once({enabled_unrecognized, Other}, #{
        what => janus_catalog_enabled_unrecognized,
        value => Other,
        used => false
    }),
    false.

%% Route/provider-key weight, normalized on the way IN (review 01b M2):
%% a sane weight is a positive integer no larger than ?MAX_WEIGHT.
%% Anything else is data corruption from the dashboard/import path —
%% 0 silently starves the route, a negative value crashes the LB pick,
%% and an oversized one expands its weighted-RR list per call. Positive
%% overflow clamps to ?MAX_WEIGHT, every other bad shape becomes 1; one
%% warning per distinct raw value.
weight_or_1(W) ->
    case to_pos_int(W, invalid) of
        N when is_integer(N), N =< ?MAX_WEIGHT ->
            N;
        N when is_integer(N) ->
            warn_weight(W, ?MAX_WEIGHT),
            ?MAX_WEIGHT;
        invalid ->
            warn_weight(W, 1),
            1
    end.

warn_weight(W, Used) ->
    warn_once({weight_invalid, W}, #{
        what => janus_catalog_weight_invalid,
        weight => W,
        used => Used,
        max_weight => ?MAX_WEIGHT
    }).

%% One warning per distinct bad value per process: the config poller is
%% long-lived, and a repeated defect must not flood the log on every
%% generation bump.
warn_once(Key, LogMap) ->
    Full = {janus_catalog_warned, Key},
    case get(Full) of
        undefined ->
            put(Full, true),
            logger:warning(LogMap);
        _ ->
            ok
    end.

%% Quota columns: SQL NULL / missing → atom null (unlimited).
%% 0 is preserved (hard block — never map to unlimited).
%% Negatives clamp to 0 (fail closed) — never become unlimited.
%% Binary spellings are parsed like to_int/2; any other shape is a
%% hard block (0), never unlimited: a quota is an entitlement control,
%% so a driver/JSON shape drift must fail closed (review 06d L5).
null_int(null) -> null;
null_int(undefined) -> null;
null_int(N) when is_integer(N), N >= 0 -> N;
null_int(N) when is_integer(N) -> 0;
null_int(N) when is_binary(N) ->
    case to_int(N, invalid) of
        I when is_integer(I), I >= 0 -> I;
        _ -> 0
    end;
null_int(_) -> 0.

to_pos_int(N, _Default) when is_integer(N), N > 0 -> N;
to_pos_int(N, Default) when is_binary(N) ->
    try
        case binary_to_integer(N) of
            I when I > 0 -> I;
            _ -> Default
        end
    catch
        _:_ -> Default
    end;
to_pos_int(_, Default) ->
    Default.

to_int(N, _Default) when is_integer(N) -> N;
to_int(N, Default) when is_binary(N) ->
    try
        binary_to_integer(N)
    catch
        _:_ -> Default
    end;
to_int(_, Default) ->
    Default.
