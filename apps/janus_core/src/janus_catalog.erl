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
%%%   providers => [#{id, name, base_url, protocol, enabled}],
%%%   provider_keys => [#{id, provider_id, secret_ciphertext, key_id,
%%%                       weight, enabled}],
%%%   api_keys => [#{id, prefix, key_hash, enabled, rpm_limit, tpm_limit, daily_token_limit}],
%%%   api_key_models => [#{api_key_id, model_id}]}
%%% ```
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
    model_modality/1,
    listing_names/0,
    listings_summary/0,
    lookup_model/1,
    lookup_provider/1,
    lookup_api_key/1,
    lookup_api_keys/1,
    provider_keys/1,
    %% Entitlement carrier (spec Part B)
    entitlement_denied/3,
    entitlement_codes/0
]).

-define(PT_KEY, {janus, catalog}).

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
    insert_models(Models, maps:get(models, Rows, [])),
    insert_routes(Routes, maps:get(model_routes, Rows, [])),
    insert_providers(Providers, maps:get(providers, Rows, [])),
    insert_provider_keys(ProvKeys, maps:get(provider_keys, Rows, [])),
    Listings = new_tab(),
    insert_api_keys(
        ApiKeys,
        maps:get(api_keys, Rows, []),
        maps:get(api_key_models, Rows, [])
    ),
    insert_listings(Listings, maps:get(provider_models, Rows, [])),
    Deny = new_tab(),
    insert_deny_keys(Deny, maps:get(key_entitlements, Rows, [])),
    Codes = new_tab(),
    insert_entitlement_codes(Codes, maps:get(entitlement_codes, Rows, [])),
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

%% @doc Atomically publish `Tabs` for `Generation`. Previous catalog
%% ETS tables are deleted after a short delay so in-flight lookups
%% (LB pick, auth) cannot `badarg` on a dropped tid. Does not touch LB ETS.
-spec publish(non_neg_integer(), catalog_tabs()) -> ok.
publish(Generation, Tabs) when is_integer(Generation), Generation >= 0, is_map(Tabs) ->
    Old = get(),
    persistent_term:put(?PT_KEY, #{generation => Generation, catalog => Tabs}),
    schedule_delete(Old),
    ok.

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
%% it: max context/output caps, OR-ed reasoning/vision flags. Fields
%% are dropped when no provider reports them.
-spec listings_summary() -> #{binary() => map()}.
listings_summary() ->
    case table(listings_by_name) of
        undefined ->
            #{};
        Tid ->
            try
            ets:foldl(
                fun({Name, Entries}, Acc) ->
                    Merged = lists:foldl(
                        fun
                            (#{enabled := true, meta := Meta}, AccM) when is_map(Meta) ->
                                merge_meta(Meta, AccM);
                            (_, AccM) ->
                                AccM
                        end,
                        #{},
                        Entries
                    ),
                    %% `#{}` as a case pattern matches EVERY map (open
                    %% subset matching) — size check is required for
                    %% "nothing known". Names disabled on every provider
                    %% stay out of the surface metadata.
                    case map_size(Merged) of
                        0 -> Acc;
                        _ -> Acc#{Name => Merged}
                    end
                end,
                #{},
                Tid
            )
            catch
                error:badarg -> #{}
            end
    end.

%% Pass-through merge of raw provider catalog entries (binary JSON
%% keys): numbers take the max across providers, booleans OR, and every
%% other value keeps the first non-null under the upstream's own field
%% name — no curation. `context_length` is additionally synthesized
%% (max of the upstream context-field spellings) as a cross-provider
%% convenience for clients that want one canonical key.
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
            Meta
        ),
    canonical_ctx(Acc1).

canonical_ctx(Acc) ->
    Sources = [<<"context_length">>, <<"context_window">>, <<"max_input_tokens">>],
    case first_known(Acc, Sources) of
        V when is_integer(V), V > 0 ->
            case Acc of
                #{<<"context_length">> := Prev} when is_integer(Prev), Prev >= V -> Acc;
                _ -> Acc#{<<"context_length">> => V}
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
    ets:new(janus_catalog_tab, [set, public, {read_concurrency, true}]).

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
            delete_tabs(Old)
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
                weight => to_pos_int(row_get(Row, weight, 1), 1),
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
                enabled => truthy(row_get(Row, enabled, true))
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
                weight => to_pos_int(row_get(Row, weight, 1), 1),
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
        fun(#{provider_id := P, name := N, enabled := E} = Row, Acc) ->
                %% Postgres SMALLINT arrives as 0/1 — normalize to
                %% booleans so pattern matches downstream see true/false.
                Enabled = E =:= 1 orelse E =:= true,
                %% meta is JSONB/TEXT — decode defensively (bad JSON or
                %% a driver-encoded value must never break a reload).
                Entry = #{
                    provider_id => P,
                    enabled => Enabled,
                    meta => decode_meta(maps:get(meta, Row, null)),
                    modality => modality_bin(maps:get(modality, Row, <<"chat">>))
                },
                maps:update_with(N, fun(Entries) -> [Entry | Entries] end, [Entry], Acc)
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
modality_bin(M) when M =:= <<"image">>; M =:= <<"tts">>; M =:= <<"asr">>; M =:= <<"video">>; M =:= <<"computer">> ->
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
            ModelId = row_get(Row, model_id),
            maps:update_with(ApiKeyId, fun(Ms) -> [ModelId | Ms] end, [ModelId], Acc)
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
                model_ids =>
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
    Cipher =
        case maps:find(secret_ciphertext, Row) of
            {ok, C} -> C;
            error -> maps:get(ciphertext, Row, undefined)
        end,
    KeyId = maps:get(key_id, Row, undefined),
    {KeyId, Cipher};
opaque_secret_ref(Row) when is_tuple(Row) ->
    %% Soft support for positional DB tuples if integrator prefers them.
    case Row of
        {_Id, _ProviderId, Cipher, KeyId, _Weight, _Enabled} ->
            {KeyId, Cipher};
        _ ->
            {undefined, Row}
    end.

row_get(Row, Key) when is_map(Row) ->
    maps:get(Key, Row, undefined);
row_get(_Row, _Key) ->
    undefined.

row_get(Row, Key, Default) when is_map(Row) ->
    maps:get(Key, Row, Default);
row_get(_Row, _Key, Default) ->
    Default.

truthy(true) -> true;
truthy(1) -> true;
truthy(<<"t">>) -> true;
truthy(<<"true">>) -> true;
truthy(false) -> false;
truthy(0) -> false;
truthy(<<"f">>) -> false;
truthy(<<"false">>) -> false;
truthy(undefined) -> true;
truthy(_) -> true.

%% Quota columns: SQL NULL / missing → atom null for janus_quota.
null_int(null) -> null;
null_int(undefined) -> null;
null_int(N) when is_integer(N), N > 0 -> N;
null_int(_) -> null.

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
