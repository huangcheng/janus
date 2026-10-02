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
%%%   api_keys => [#{id, prefix, key_hash, enabled}],
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
    lookup_model/1,
    lookup_provider/1,
    lookup_api_key/1,
    provider_keys/1
]).

-define(PT_KEY, {janus, catalog}).

-type model_id() :: term().
-type provider_id() :: term().
-type catalog_tabs() :: #{
    models := ets:tid(),
    routes_by_model := ets:tid(),
    providers := ets:tid(),
    provider_keys := ets:tid(),
    api_keys_by_prefix := ets:tid()
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
    insert_api_keys(
        ApiKeys,
        maps:get(api_keys, Rows, []),
        maps:get(api_key_models, Rows, [])
    ),
    #{
        models => Models,
        routes_by_model => Routes,
        providers => Providers,
        provider_keys => ProvKeys,
        api_keys_by_prefix => ApiKeys
    }.

%% @doc Atomically publish `Tabs` for `Generation`. Deletes previous
%% catalog ETS tables after the pointer swap. Does not touch LB ETS.
-spec publish(non_neg_integer(), catalog_tabs()) -> ok.
publish(Generation, Tabs) when is_integer(Generation), Generation >= 0, is_map(Tabs) ->
    Old = get(),
    persistent_term:put(?PT_KEY, #{generation => Generation, catalog => Tabs}),
    delete_tabs(Old),
    ok.

-spec routes_for_model(model_id()) -> [map()].
routes_for_model(ModelId) ->
    case table(routes_by_model) of
        undefined -> [];
        Tid ->
            case ets:lookup(Tid, ModelId) of
                [{_, Routes}] -> Routes;
                [] -> []
            end
    end.

-spec lookup_model(binary() | model_id()) -> {ok, map()} | error.
lookup_model(Key) ->
    case table(models) of
        undefined -> error;
        Tid ->
            case ets:lookup(Tid, Key) of
                [{_, Meta}] -> {ok, Meta};
                [] -> error
            end
    end.

-spec lookup_provider(provider_id()) -> {ok, map()} | error.
lookup_provider(ProviderId) ->
    case table(providers) of
        undefined -> error;
        Tid ->
            case ets:lookup(Tid, ProviderId) of
                [{_, Meta}] -> {ok, Meta};
                [] -> error
            end
    end.

-spec lookup_api_key(binary()) -> {ok, map()} | error.
lookup_api_key(Prefix) when is_binary(Prefix) ->
    case table(api_keys_by_prefix) of
        undefined -> error;
        Tid ->
            case ets:lookup(Tid, Prefix) of
                [{_, Meta}] -> {ok, Meta};
                [] -> error
            end
    end.

-spec provider_keys(provider_id()) -> [map()].
provider_keys(ProviderId) ->
    case table(provider_keys) of
        undefined -> [];
        Tid ->
            case ets:lookup(Tid, ProviderId) of
                [{_, Keys}] -> Keys;
                [] -> []
            end
    end.

%%--------------------------------------------------------------------
%% Internals
%%--------------------------------------------------------------------

new_tab() ->
    ets:new(janus_catalog_tab, [set, public, {read_concurrency, true}]).

table(Name) ->
    case get() of
        #{catalog := Tabs} -> maps:get(Name, Tabs, undefined);
        undefined -> undefined
    end.

delete_tabs(undefined) ->
    ok;
delete_tabs(#{catalog := Tabs}) when is_map(Tabs) ->
    maps:foreach(
        fun(_K, Tid) ->
            try ets:delete(Tid) catch error:badarg -> ok end
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
                model_ids =>
                    case maps:find(Id, Allow) of
                        {ok, Ms} -> lists:reverse(Ms);
                        error -> all
                    end
            },
            case Prefix of
                undefined -> ok;
                _ -> ets:insert(Tid, {Prefix, Meta})
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
    try binary_to_integer(N) catch _:_ -> Default end;
to_int(_, Default) ->
    Default.
