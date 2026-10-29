%%%-------------------------------------------------------------------
%%% @doc Shared agent-key model allowlist.
%%%
%%% Chat-family and modality faces call this one clause. Semantics
%%% match design
%%% `docs/superpowers/specs/2026-10-12-agent-key-model-allowlist-design.md`:
%%%
%%% * `model_names = all` allows every name (incl. janus-auto and
%%%   unbound listings). The catalog writes `all` when
%%%   `api_key_models` has no rows. An empty list is not that signal —
%%%   membership fails, so the name is denied.
%%% * a list allows the client name only when it is an exact member.
%%%   Unbound listing names are grantable. `janus-auto` is never a
%%%   legal grant (dashboard rejects; migration strips) — so scoped
%%%   keys cannot call the virtual router.
%%% * any other agent shape allows (historical fail-open clause).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_model_acl).

-export([model_allowed/2]).

-spec model_allowed(map(), term()) -> boolean().
model_allowed(#{model_names := all}, _) ->
    true;
model_allowed(#{model_names := Names}, ModelName) when is_list(Names) ->
    lists:member(ModelName, Names);
%% Legacy catalog field (pre-022 beams / eunit fixtures).
model_allowed(#{model_ids := all}, _) ->
    true;
model_allowed(#{model_ids := Ids}, ModelName) when is_list(Ids) ->
    case janus_catalog:lookup_model(ModelName) of
        {ok, #{id := Id}} -> lists:member(Id, Ids);
        error -> false
    end;
model_allowed(_, _) ->
    true.
