%%%-------------------------------------------------------------------
%%% @doc OpenTelemetry Resource: the identity of the telemetry PRODUCER.
%%%
%%% ## Why this module matters more than any single metric
%%%
%%% A Resource answers "which thing emitted this?" and applies to EVERY
%%% signal at once — traces, metrics and logs. That is the OTel way to
%%% tell a horizontally scaled service's replicas apart. Adding a `node'
%%% label to individual Prometheus series is the wrong shape: it is not
%%% what the spec prescribes, it has to be repeated per family, and it
%%% does nothing for spans.
%%%
%%% ## The identity pair, and why it is a pair
%%%
%%% Two attributes carry node identity, and they answer different
%%% questions:
%%%
%%%   * `service.instance.id' — machine-facing, MUST be globally unique
%%%     within `service.namespace,service.name' (semconv, Stability:
%%%     Stable). It is what a backend groups replicas by. An operator
%%%     never reads it.
%%%   * `janus.node.alias' — human-facing, readable ("aliyun-02"). This
%%%     is a CUSTOM attribute, which the conventions explicitly permit;
%%%     it exists because a hash tells a human nothing and observability
%%%     that nobody can read is not observability.
%%%
%%% The id is `sha256(alias)', NOT a random UUID: a UUID would change on
%%% every restart, which breaks "the same instance over time" and forces
%%% operators to maintain a separate id registry. Deriving it from the
%%% alias keeps it stable across restarts while staying unique — and
%%% because the alias carries a per-provider ordinal ("aliyun-02"), two
%%% nodes from the same cloud never collide.
%%%
%%% ## Immutability
%%%
%%% The Resource SDK spec requires Resource attributes to be stable for
%%% the lifetime of the SDK. So this is computed once and cached in
%%% persistent_term. Anything that can change at runtime (an operator's
%%% node note, for instance) must NOT live here — the dashboard's
%%% `worker_notes' table owns that, joined by alias.
%%% @end
%%%-------------------------------------------------------------------
-module(janus_otel_resource).

-export([get/0, reset/0, alias/0]).

-define(PT_KEY, {janus, otel_resource}).

%% @doc The Resource attribute map, computed once per VM.
-spec get() -> map().
get() ->
    case persistent_term:get(?PT_KEY, undefined) of
        undefined ->
            R = build(),
            persistent_term:put(?PT_KEY, R),
            R;
        R ->
            R
    end.

%% @doc Drop the cache. Used by tests and by a config reload that changes
%% a resource-affecting setting.
-spec reset() -> ok.
reset() ->
    persistent_term:erase(?PT_KEY),
    ok.

%% ------------------------------------------------------------------
%% Building
%% ------------------------------------------------------------------

build() ->
    Alias = alias(),
    Base = #{
        <<"service.namespace">> => namespace(),
        <<"service.name">> => service_name(),
        <<"service.version">> => version(),
        <<"service.instance.id">> => instance_id(Alias),
        <<"telemetry.sdk.name">> => <<"janus">>,
        <<"telemetry.sdk.language">> => <<"erlang">>,
        <<"telemetry.sdk.version">> => version(),
        <<"janus.node.alias">> => Alias,
        <<"janus.role">> => role_bin()
    },
    %% `OTEL_RESOURCE_ATTRIBUTES' is the standard override channel
    %% (comma-separated key=value), and operator values win over the
    %% computed defaults — but NOT for the identity attrs.
    %%
    %% `service.instance.id' is contractually UNIQUE per
    %% (service.namespace, service.name). Letting an env var set it means
    %% two nodes can be configured with the same id, silently merging two
    %% replicas into one series in every backend — the exact failure the
    %% attribute exists to prevent. The alias is excluded for the same
    %% reason: it is the readable half of that identity, and the id is
    %% derived from it, so they must not be able to disagree.
    Protected = [
        <<"service.instance.id">>,
        <<"service.namespace">>,
        <<"service.name">>,
        <<"janus.node.alias">>
    ],
    Overrides = maps:without(Protected, env_attrs()),
    maps:merge(Base, Overrides).

%% @doc Readable node identity: `<provider>-<ordinal>'.
%%
%% Resolution order, most explicit first:
%%   1. `JANUS_NODE_ALIAS' — deployment-injected, one per node
%%   2. `OTEL_RESOURCE_ATTRIBUTES' janus.node.alias — standard channel
%%   3. derived from the Erlang long name's host part
%%
%% The alias is what a human reads in Grafana, so it is the node's
%% operator-facing name, never an IP.
-spec alias() -> binary().
alias() ->
    case nonempty(os:getenv("JANUS_NODE_ALIAS")) of
        {ok, A} ->
            sanitize_alias(A);
        error ->
            case maps:get(<<"janus.node.alias">>, env_attrs(), undefined) of
                undefined -> derive_alias();
                A -> sanitize_alias(A)
            end
    end.

%% Fall back to the Erlang node name's host part. `janus@aliyun-02' ->
%% `aliyun-02'. A bare hostname is the last resort; it is at least what
%% the operator named the machine.
derive_alias() ->
    Node = atom_to_binary(node(), utf8),
    case binary:split(Node, <<"@">>) of
        [_Name, Host] when Host =/= <<>>, Host =/= <<"nohost">> ->
            sanitize_alias(Host);
        _ ->
            %% No usable long name (a bare `erl -noshell', or a node whose
            %% long name is missing). Returning a constant here would give
            %% two such nodes the SAME instance id, so fold in a short hash
            %% of the full node name: still unreadable, but at least not
            %% colliding, and this path is not reachable in a real
            %% deployment where every node has a long name.
            Digest = crypto:hash(sha256, Node),
            Suffix = string:lowercase(binary:encode_hex(binary:part(Digest, 0, 4))),
            <<"node-", Suffix/binary>>
    end.

%% Keep the alias label-shaped: bounded, lowercase, no whitespace. It is
%% operator-supplied, so it must not be able to inject a novel dimension
%% or an unbounded string into a metric label later.
sanitize_alias(A) when is_binary(A) ->
    Lower = string:lowercase(A),
    Safe = <<
        <<
            (case C of
                _ when C >= $a, C =< $z -> C;
                _ when C >= $0, C =< $9 -> C;
                $- -> $-;
                $. -> $-;
                _ -> $-
            end)
        >>
     || <<C>> <= Lower
    >>,
    Truncated = binary:part(Safe, 0, min(byte_size(Safe), 64)),
    case Truncated of
        <<>> -> <<"unknown">>;
        _ -> Truncated
    end.

%% Stable, globally-unique-per-alias instance id.
%%
%% Hex rather than a UUID string: shorter, still opaque, and the spec only
%% requires uniqueness, not a particular format. Derived from the alias so
%% it survives restarts; the alias's ordinal keeps same-provider nodes
%% distinct.
instance_id(Alias) ->
    Digest = crypto:hash(sha256, Alias),
    %% 16 bytes of the digest = 32 hex chars, the same length as a UUID
    %% with its dashes removed.
    string:lowercase(binary:encode_hex(binary:part(Digest, 0, 16))).

namespace() ->
    case nonempty(os:getenv("OTEL_SERVICE_NAMESPACE")) of
        {ok, N} -> N;
        error -> <<"janus">>
    end.

service_name() ->
    %% `OTEL_SERVICE_NAME' is the spec's dedicated override variable.
    case nonempty(os:getenv("OTEL_SERVICE_NAME")) of
        {ok, N} -> N;
        error -> <<"janus-gateway">>
    end.

version() ->
    case application:get_key(janus_core, vsn) of
        {ok, Vsn} when is_list(Vsn) -> list_to_binary(Vsn);
        _ -> <<"0.0.0">>
    end.

role_bin() ->
    case catch janus_role:get() of
        master -> <<"master">>;
        worker -> <<"worker">>;
        _ -> <<"unknown">>
    end.

%% Parse `OTEL_RESOURCE_ATTRIBUTES' (`k=v,k2=v2') per the spec. A
%% malformed pair is SKIPPED rather than fatal: a typo in an env var must
%% not stop the gateway from booting.
env_attrs() ->
    case nonempty(os:getenv("OTEL_RESOURCE_ATTRIBUTES")) of
        {ok, Raw} ->
            lists:foldl(
                fun(Pair, Acc) ->
                    case binary:split(Pair, <<"=">>) of
                        [K, V] when K =/= <<>>, V =/= <<>> ->
                            Acc#{trim(K) => trim(V)};
                        _ ->
                            Acc
                    end
                end,
                #{},
                [trim(P) || P <- binary:split(Raw, <<",">>, [global])]
            );
        error ->
            #{}
    end.

trim(B) ->
    string:trim(B, both, " \t").

nonempty(undefined) ->
    error;
nonempty(false) ->
    error;
nonempty("") ->
    error;
nonempty(V) when is_list(V) ->
    case trim(list_to_binary(V)) of
        <<>> -> error;
        B -> {ok, B}
    end;
nonempty(V) when is_binary(V), V =/= <<>> ->
    case trim(V) of
        <<>> -> error;
        B -> {ok, B}
    end;
nonempty(_) ->
    error.