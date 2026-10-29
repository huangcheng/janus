%%%-------------------------------------------------------------------
%%% @doc Worker-side layered egress-geo discovery (spec
%%% `2026-10-11-geo-affinity-and-auto-tier-reorder-design.md` D4/D17/D18).
%%%
%%% Runs on the WORKER only, piggybacking the 60 s hello keepalive
%%% cadence (spawned by `janus_worker_dispatch` — discovery NEVER gates
%%% the hello itself; a fresh result rides the NEXT keepalive). The
%%% chain is ranked by copy-resistance:
%%%
%%% <ul>
%%% <li>`gw_echo' — GET `https://&lt;master-host&gt;/v1/echo'
%%%   (`JANUS_MASTER_NODE` host; `JANUS_WORKER_GEO_ECHO_URL` overrides
%%%   for internal-DNS topologies, http scheme allowed via override
%%%   ONLY). FULL TLS verification is NEVER skipped
%%%   (`JANUS_WORKER_GEO_ECHO_CA_PATH` supplies a private-CA cert);
%%%   TLS failure / 429 / degraded / private-CGNAT result ⇒
%%%   `echo_fail` fall-through.</li>
%%% <li>`metadata' — IP-LITERAL cloud endpoints only (Aliyun
%%%   `100.100.100.200`, Tencent `169.254.0.23`, AWS-style
%%%   `169.254.169.254` — the same link-local IP Baidu BCC uses; NO
%%%   DNS names — spoofable via CNI resolvers),
%%%   1 s budget each, response-format validation, per-cloud
%%%   region-&gt;SCHED_REGIONS vocab map. A vocab-map MISS falls through
%%%   (an adapter gap, not geography).</li>
%%% <li>`env' — `JANUS_WORKER_REGION` (out-of-vocab warns, still
%%%   wins — v1 verbatim region matching).</li>
%%% <li>`third_echo' — `JANUS_WORKER_GEO_IP_URL` (OPT-IN third-party
%%%   echo; the target sees worker egress IPs).</li>
%%% </ul>
%%%
%%% `JANUS_WORKER_GEO_SOURCES` is the ORDERED allowlist (default
%%% `gw_echo,metadata,env,third_echo`): the FIRST layer that wins takes
%%% it — the default order IS the precedence, and the e2e harness pins
%%% `env` so a cloud-hosted runner's metadata reply cannot steal the
%%% region from env-pinned tests (G.15). The winner rides the hello as
%%% ADDITIVE keys (`egress_ip` / `egress_region` / `egress_source` /
%%% `egress_fetched_at`); IP-bearing winners leave the mmdb mapping to
%%% the MASTER (workers have no mmdb dependency at all). Last-known
%%% retention: `max(60s, min(2*JANUS_WORKER_GEO_IP_REFRESH_SEC, 12h))`.
%%%
%%% gw-echo success/failure bumps the worker's `echo_ok_total` /
%%% `echo_fail_total` (returned to the dispatcher, surfaced on the
%%% hello) — observability ONLY: echo failure NEVER evicts from the
%%% pool (keepalive hello + pool-pid monitor + net_ticktime own
%%% liveness).
%%% @end
%%%-------------------------------------------------------------------
-module(janus_worker_geo).

-export([
    %% Knobs (env).
    enabled/0,
    parse_sources/1,
    retain_sec/0,
    retain_sec/1,
    echo_url/1,
    derive_echo_url/1,
    %% Pure chain logic (eunit).
    classify_echo_reply/1,
    public_ip_bin/1,
    validate_metadata_reply/1,
    map_cloud_region/2,
    chain/2,
    fresh/3,
    %% Impure runner (spawned by the dispatcher, never the gen_server).
    discover/2,
    http_get/3
]).

-define(DEFAULT_SOURCES, "gw_echo,metadata,env,third_echo").
-define(REFRESH_DEFAULT_SEC, 60).
-define(RETAIN_FLOOR_SEC, 60).
-define(RETAIN_CAP_SEC, 43200).
-define(ECHO_TIMEOUT_MS, 3000).
-define(METADATA_TIMEOUT_MS, 1000).
-define(METADATA_MAX_BYTES, 64).
%% gw-echo HTTP budget: the master's endpoint answers in well under a
%% second; 3 s covers a slow first TLS handshake without stalling the
%% (async) discovery past the keepalive cadence.
-define(ECHO_TOTAL_TIMEOUT_MS, 3000).

%% Cloud metadata adapters (spec D4): IP-LITERAL endpoints only (no
%% DNS names). The 1 s budget each is applied by the runner.
-define(METADATA_ENDPOINTS, [
    {<<"100.100.100.200">>, <<"/latest/meta-data/region-id">>, aliyun},
    {<<"169.254.0.23">>, <<"/latest/meta-data/placement/region">>, tencent},
    {<<"169.254.169.254">>, <<"/latest/meta-data/placement/region">>, aws},
    %% Baidu BCC metadata: the SAME link-local IP literal — documented at
    %% https://cloud.baidu.com/doc/BCC/s/jm4bbrdmn
    %% (`curl 169.254.169.254/latest/meta-data/sts-credential`). The
    %% EC2-shaped region path below is the one a prod BCC instance
    %% answered `su` (Suzhou) from; it deliberately sits AFTER the aws
    %% row: an AWS box maps on the first row (baidu never probed), a
    %% Baidu box misses the aws table and falls through to this row.
    {<<"169.254.169.254">>, <<"/latest/meta-data/placement/region">>, baidu}
]).

%%%===================================================================
%%% Knobs
%%%===================================================================

%% Worker-side chain gate (`JANUS_SCHED_WORKER_GEO`, default OFF — the
%% master-side overlay knob is read independently by janus_geo/pool).
-spec enabled() -> boolean().
enabled() ->
    env_truthy(os:getenv("JANUS_SCHED_WORKER_GEO")).

%% Ordered allowlist parse: unknown tokens dropped, order kept, empty
%% => the default precedence (spec D4). Takes os:getenv/1 shapes.
-spec parse_sources(false | string()) -> [gw_echo | metadata | env | third_echo].
parse_sources(false) ->
    default_sources();
parse_sources("") ->
    default_sources();
parse_sources(Env) when is_list(Env) ->
    Known = [gw_echo, metadata, env, third_echo],
    Toks = [string:trim(T) || T <- string:split(Env, ",", all)],
    case [S || S <- [tok_source(T) || T <- Toks, T =/= ""], lists:member(S, Known)] of
        [] ->
            default_sources();
        Sources ->
            dedup(Sources)
    end.

tok_source("gw_echo") -> gw_echo;
tok_source("metadata") -> metadata;
tok_source("env") -> env;
tok_source("third_echo") -> third_echo;
tok_source(_) -> unknown.

default_sources() ->
    [gw_echo, metadata, env, third_echo].

%% Order-preserving dedup (FIRST occurrence wins).
dedup(L) ->
    dedup(L, []).

dedup([H | T], Seen) ->
    case lists:member(H, Seen) of
        true -> dedup(T, Seen);
        false -> [H | dedup(T, [H | Seen])]
    end;
dedup([], _Seen) ->
    [].

%% Last-known retain window in SECONDS (spec D18):
%% max(60, min(2*JANUS_WORKER_GEO_IP_REFRESH_SEC, 12h)). Same shape as
%% the master-side age check (each node reads its own env).
-spec retain_sec() -> pos_integer().
retain_sec() ->
    retain_sec(env_pos_int(os:getenv("JANUS_WORKER_GEO_IP_REFRESH_SEC"), ?REFRESH_DEFAULT_SEC)).

-spec retain_sec(pos_integer()) -> pos_integer().
retain_sec(RefreshSec) when is_integer(RefreshSec), RefreshSec >= 1 ->
    max(?RETAIN_FLOOR_SEC, min(2 * RefreshSec, ?RETAIN_CAP_SEC)).

%% The gw-echo target URL: `JANUS_WORKER_GEO_ECHO_URL` override (http
%% scheme allowed via override only), else derived
%% `https://<JANUS_MASTER_NODE host>/v1/echo` (scheme https — a private
%% JANUS_MASTER_NODE host is a guaranteed echo_fail, documented).
-spec echo_url(node()) -> {ok, binary()} | {error, no_master_node}.
echo_url(MasterNode) ->
    case os:getenv("JANUS_WORKER_GEO_ECHO_URL") of
        Override when is_list(Override), Override =/= "" ->
            {ok, list_to_binary(string:trim(Override))};
        _ ->
            derive_echo_url(MasterNode)
    end.

-spec derive_echo_url(node() | binary() | string()) -> {ok, binary()} | {error, no_master_node}.
derive_echo_url(MasterNode) when is_atom(MasterNode) ->
    derive_echo_url(atom_to_list(MasterNode));
derive_echo_url(NodeStr) when is_list(NodeStr) ->
    derive_echo_url(list_to_binary(NodeStr));
derive_echo_url(NodeBin) when is_binary(NodeBin) ->
    Host =
        case binary:split(NodeBin, <<"@">>) of
            [_Name, H] when H =/= <<>> -> H;
            _ -> <<>>
        end,
    case Host of
        <<>> ->
            {error, no_master_node};
        _ ->
            {ok, <<"https://", Host/binary, "/v1/echo">>}
    end;
derive_echo_url(_) ->
    {error, no_master_node}.

%%%===================================================================
%%% Pure chain logic (eunit)
%%%===================================================================

%% Classify a gw-echo / third-echo reply body (decoded JSON map):
%%   {win, IpBin}   — well-formed reply with a PUBLIC ip (usable egress)
%%   {fail, Reason} — degraded (proxy headers present at the master),
%%                    private/CGNAT/ULA result (discard, fall through),
%%                    or a malformed body (ip missing/null/unparseable).
%% A 429 never reaches here (the runner counts it echo_fail directly).
-spec classify_echo_reply(map() | bad_json) -> {win, binary()} | {fail, degraded | private | bad_ip}.
classify_echo_reply(#{<<"degraded">> := true}) ->
    {fail, degraded};
classify_echo_reply(#{<<"ip">> := IpBin}) when is_binary(IpBin), IpBin =/= <<>> ->
    case inet:parse_address(binary_to_list(IpBin)) of
        {ok, Addr} ->
            case janus_geo:private_ip(Addr) of
                true -> {fail, private};
                false -> {win, IpBin}
            end;
        _ ->
            {fail, bad_ip}
    end;
classify_echo_reply(_) ->
    {fail, bad_ip}.

%% PUBLIC check on a binary IP (worker-side discard rule; mirrors
%% janus_geo:private_ip/1 through a parse).
-spec public_ip_bin(binary()) -> boolean().
public_ip_bin(IpBin) when is_binary(IpBin) ->
    case inet:parse_address(binary_to_list(IpBin)) of
        {ok, Addr} -> not janus_geo:private_ip(Addr);
        _ -> false
    end.

%% Cloud metadata reply validation (format-level, adapter-agnostic):
%% a SHORT lowercase token like `cn-hangzhou` / `ap-guangzhou` /
%% `us-east-1`, or a bare 3-letter region code like Baidu's `hkg` /
%% `fwh` (codes per the BCC service-domain table,
%% https://cloud.baidu.com/doc/BCC/s/0jwvyo603). Rejects anything that
%% is not a plain region token (HTML error pages, empty, oversized).
%% Widening to a bare 3-letter code is honest and safe: the token still
%% has to hit an exact / prefix map table to win, so an unmapped word
%% keeps falling through exactly like the old `bad_region` rejection
%% (never a wrong bucket, never `other`).
-spec validate_metadata_reply(binary()) -> {ok, binary()} | {error, bad_region}.
validate_metadata_reply(Bin) when is_binary(Bin), byte_size(Bin) =< ?METADATA_MAX_BYTES ->
    Tok = string:trim(Bin),
    case re:run(Tok, <<"^[a-z][a-z0-9](-[a-z0-9]+)*$|^[a-z]{3}$">>, [{capture, none}]) of
        match when byte_size(Tok) >= 2, byte_size(Tok) =< 32 ->
            {ok, Tok};
        _ ->
            {error, bad_region}
    end;
validate_metadata_reply(_) ->
    {error, bad_region}.

%% Cloud-region -> SCHED_REGIONS vocab map per adapter (spec D4):
%% EXACT table first, then ordered PREFIX rules. A MISS is an adapter
%% gap (the cloud added a region we never mapped) — the caller falls
%% through to the next layer, NEVER inventing `other` (asymmetry: an
%% mmdb result outside the vocab is POSITIVE geography; a map-miss is
%% not). Province grouping follows the janus_geo default vocabulary
%% (CN East/North/South/Southwest; Hong Kong -> cn-south; Ningxia ->
%% cn-southwest).
%%
%% VOCABULARY CONFLICT (operator-visible, NOT resolved here): this
%% table emits MACRO tags, while the master compares on EXACT binary
%% equality (`geo_region =:= comparator`, janus_worker_pool:geo_tier/2)
%% and prod overrides the rule table with CITY codes via
%% `JANUS_SCHED_REGIONS` (`CN:Beijing=cn-beijing; CN:Jiangsu=cn-east;
%% CN:Shanghai=cn-shanghai; CN:Hubei=cn-wuhan`). A discovered macro tag
%% therefore equals such a comparator ONLY where the deployed rule kept
%% the macro tag (Jiangsu=cn-east); elsewhere the geo tier silently
%% no-ops (it is a narrowing tier, never an exclusion). The
%% comparator-compatible path is the IP-bearing gw_echo layer: its mmdb
%% tag is derived with the SAME deployed rules.
-spec map_cloud_region(aliyun | tencent | aws | baidu, binary()) -> {ok, binary()} | miss.
map_cloud_region(Adapter, Region) when is_atom(Adapter), is_binary(Region) ->
    case exact_region(Adapter, Region) of
        {ok, _} = Hit ->
            Hit;
        miss ->
            prefix_region(Adapter, Region)
    end.

%% ---- exact tables (common CN regions + a few pinned others) ----
exact_region(aliyun, <<"cn-hangzhou">>) -> {ok, <<"cn-east">>};
exact_region(aliyun, <<"cn-shanghai">>) -> {ok, <<"cn-east">>};
exact_region(aliyun, <<"cn-qingdao">>) -> {ok, <<"cn-east">>};
exact_region(aliyun, <<"cn-beijing">>) -> {ok, <<"cn-north">>};
exact_region(aliyun, <<"cn-zhangjiakou">>) -> {ok, <<"cn-north">>};
exact_region(aliyun, <<"cn-huhehaote">>) -> {ok, <<"cn-north">>};
exact_region(aliyun, <<"cn-wulanchabu">>) -> {ok, <<"cn-north">>};
exact_region(aliyun, <<"cn-shenzhen">>) -> {ok, <<"cn-south">>};
exact_region(aliyun, <<"cn-guangzhou">>) -> {ok, <<"cn-south">>};
exact_region(aliyun, <<"cn-heyuan">>) -> {ok, <<"cn-south">>};
exact_region(aliyun, <<"cn-hongkong">>) -> {ok, <<"cn-south">>};
exact_region(aliyun, <<"cn-chengdu">>) -> {ok, <<"cn-southwest">>};
exact_region(aliyun, <<"cn-chongqing">>) -> {ok, <<"cn-southwest">>};
exact_region(tencent, <<"ap-shanghai">>) -> {ok, <<"cn-east">>};
exact_region(tencent, <<"ap-shanghai-fsi">>) -> {ok, <<"cn-east">>};
exact_region(tencent, <<"ap-nanjing">>) -> {ok, <<"cn-east">>};
exact_region(tencent, <<"ap-beijing">>) -> {ok, <<"cn-north">>};
exact_region(tencent, <<"ap-beijing-fsi">>) -> {ok, <<"cn-north">>};
exact_region(tencent, <<"ap-guangzhou">>) -> {ok, <<"cn-south">>};
exact_region(tencent, <<"ap-guangzhou-open">>) -> {ok, <<"cn-south">>};
exact_region(tencent, <<"ap-shenzhen">>) -> {ok, <<"cn-south">>};
exact_region(tencent, <<"ap-shenzhen-fsi">>) -> {ok, <<"cn-south">>};
exact_region(tencent, <<"ap-hongkong">>) -> {ok, <<"cn-south">>};
exact_region(tencent, <<"ap-chengdu">>) -> {ok, <<"cn-southwest">>};
exact_region(tencent, <<"ap-chongqing">>) -> {ok, <<"cn-southwest">>};
exact_region(aws, <<"cn-north-1">>) -> {ok, <<"cn-north">>};
exact_region(aws, <<"cn-north">>) -> {ok, <<"cn-north">>};
exact_region(aws, <<"cn-northwest-1">>) -> {ok, <<"cn-southwest">>};
%% ---- Baidu BCC (Baidu AI Cloud) ----
%% Codes are the `{region}` label of `bcc.{region}.baidubce.com`, per
%% the BCC service-domain table (updated 2025-10-22):
%% https://cloud.baidu.com/doc/BCC/s/0jwvyo603
%%   北京 bj | 保定 bd | 广州 gz | 苏州 su | 香港 hkg | 武汉 fwh | 成都 cd
%% Province -> macro tag follows the janus_geo DEFAULT table above
%% (Beijing/Hebei -> cn-north, Jiangsu -> cn-east, Guangdong/Hong Kong/
%% Hubei -> cn-south, Sichuan -> cn-southwest). Only codes from that
%% table are listed — no guessed regions.
exact_region(baidu, <<"bj">>) -> {ok, <<"cn-north">>};
exact_region(baidu, <<"bd">>) -> {ok, <<"cn-north">>};
exact_region(baidu, <<"su">>) -> {ok, <<"cn-east">>};
exact_region(baidu, <<"gz">>) -> {ok, <<"cn-south">>};
exact_region(baidu, <<"hkg">>) -> {ok, <<"cn-south">>};
exact_region(baidu, <<"fwh">>) -> {ok, <<"cn-south">>};
exact_region(baidu, <<"cd">>) -> {ok, <<"cn-southwest">>};
exact_region(_, _) -> miss.

%% ---- ordered PREFIX rules (first hit wins; binary prefix match —
%% function-head binary patterns would be EXACT matches). CN-anchored
%% UNKNOWN regions deliberately MISS (never a wrong CN bucket) — the
%% same fall-through honesty as a vocab-map gap. Baidu BCC is
%% deliberately EXACT-ONLY: its codes are bare 2/3-letter tokens
%% (`bj`, `su`, `hkg`), and a 2-letter prefix rule would swallow
%% unrelated regions; the documented region set is fully enumerated in
%% the exact table, so no prefix rule is needed. ----
prefix_region(Adapter, Region) ->
    prefix_match(Region, prefix_rules(Adapter)).

prefix_rules(_) ->
    [
        {<<"cn-hongkong">>, <<"cn-south">>},
        {<<"ap-hongkong">>, <<"cn-south">>},
        %% Tencent city names without an ap-southeast/-north bucket.
        {<<"ap-tokyo">>, <<"apac">>},
        {<<"ap-seoul">>, <<"apac">>},
        {<<"ap-singapore">>, <<"apac">>},
        {<<"ap-bangkok">>, <<"apac">>},
        {<<"ap-jakarta">>, <<"apac">>},
        {<<"ap-southeast-">>, <<"apac">>},
        {<<"ap-northeast-">>, <<"apac">>},
        {<<"ap-south-">>, <<"apac">>},
        {<<"ap-east-">>, <<"apac">>},
        {<<"us-">>, <<"us">>},
        {<<"na-">>, <<"us">>},
        {<<"eu-">>, <<"eu">>},
        {<<"me-">>, <<"eu">>}
    ].

prefix_match(_Region, []) ->
    miss;
prefix_match(Region, [{Prefix, Tag} | Rest]) ->
    PrefixLen = byte_size(Prefix),
    case
        byte_size(Region) >= PrefixLen andalso
            binary:part(Region, 0, PrefixLen) =:= Prefix
    of
        true -> {ok, Tag};
        false -> prefix_match(Region, Rest)
    end.

%% Compose precomputed layer results in ALLOWLIST order: the FIRST
%% winning layer takes it (the default order IS the precedence, D4).
%% Results: #{Layer => {win, Value} | miss} where an IP-bearing layer
%% (gw_echo / third_echo) wins with a binary IP and metadata / env
%% with a vocab region binary.
-spec chain([atom()], map()) -> {win, map()} | no_layer.
chain(Sources, Results) when is_list(Sources), is_map(Results) ->
    chain_walk([S || S <- Sources, is_atom(S)], Results).

chain_walk([], _Results) ->
    no_layer;
chain_walk([Source | Rest], Results) ->
    case maps:get(Source, Results, miss) of
        {win, Value} when is_binary(Value), Value =/= <<>> ->
            {win, #{source => Source, value => Value}};
        _ ->
            chain_walk(Rest, Results)
    end.

%% Retain-window freshness (spec D18): a discovery entry fetched at
%% `FetchedAtSec` (unix, wall clock — crosses nodes) is usable while
%% younger than the retain window; older reads UNKNOWN.
-spec fresh(integer(), integer(), pos_integer()) -> boolean().
fresh(FetchedAtSec, NowSec, RetainSec) when
    is_integer(FetchedAtSec), is_integer(NowSec), is_integer(RetainSec), RetainSec >= 1
->
    NowSec - FetchedAtSec < RetainSec;
fresh(_, _, _) ->
    false.

%%%===================================================================
%%% Impure runner (spawned; NEVER the dispatcher gen_server)
%%%===================================================================

%% Run the chain once. Counters0/Counters1 are the dispatcher's
%% `#{echo_ok => N, echo_fail => N}` — ONLY gw-echo outcomes bump them
%% (the one data-plane-path probe; other layers' transport failures do
%% not). Returns {Result, Counters1} with Result =
%% `{ok, #{source, ip|region, fetched_at}} | no_layer`.
-spec discover(node(), map()) -> {{ok, map()} | no_layer, map()}.
discover(MasterNode, Counters0) when is_map(Counters0) ->
    Sources = parse_sources(os:getenv("JANUS_WORKER_GEO_SOURCES")),
    {Results, Counters1} =
        lists:foldl(
            fun(Source, {Acc, Cnt}) -> layer(Source, MasterNode, Acc, Cnt) end,
            {#{}, Counters0},
            Sources
        ),
    case chain(Sources, Results) of
        {win, #{source := Source, value := Value}} ->
            Entry =
                case is_ip_layer(Source) of
                    true -> #{source => Source, ip => Value};
                    false -> #{source => Source, region => Value}
                end,
            {{ok, Entry#{fetched_at => erlang:system_time(second)}}, Counters1};
        no_layer ->
            {no_layer, Counters1}
    end.

is_ip_layer(gw_echo) -> true;
is_ip_layer(third_echo) -> true;
is_ip_layer(_) -> false.

layer(gw_echo, MasterNode, Acc, Counters) ->
    case echo_url(MasterNode) of
        {error, _} ->
            {Acc#{gw_echo => miss}, Counters};
        {ok, Url} ->
            %% The one data-plane-path probe: ANY non-usable outcome
            %% (transport / TLS — never skipped / timeout / non-200
            %% incl. 429 / degraded / private result / bad body) is an
            %% echo_fail fall-through (spec D4/D18).
            case http_get(Url, ?ECHO_TOTAL_TIMEOUT_MS, #{}) of
                {ok, 200, Body} ->
                    case classify_echo_reply(thoas_decode(Body)) of
                        {win, Ip} ->
                            {Acc#{gw_echo => {win, Ip}}, echo_bump(ok, Counters)};
                        {fail, _Reason} ->
                            {Acc#{gw_echo => miss}, echo_bump(fail, Counters)}
                    end;
                _Other ->
                    {Acc#{gw_echo => miss}, echo_bump(fail, Counters)}
            end
    end;
layer(metadata, _MasterNode, Acc, Counters) ->
    {Acc#{metadata => metadata_probe()}, Counters};
layer(env, _MasterNode, Acc, Counters) ->
    {Acc#{env => env_layer()}, Counters};
layer(third_echo, _MasterNode, Acc, Counters) ->
    case os:getenv("JANUS_WORKER_GEO_IP_URL") of
        Url when is_list(Url), Url =/= "" ->
            case http_get(list_to_binary(Url), ?ECHO_TOTAL_TIMEOUT_MS, #{}) of
                {ok, 200, Body} ->
                    case classify_echo_reply(thoas_decode(Body)) of
                        {win, Ip} -> {Acc#{third_echo => {win, Ip}}, Counters};
                        {fail, _} -> {Acc#{third_echo => miss}, Counters}
                    end;
                _ ->
                    {Acc#{third_echo => miss}, Counters}
            end;
        _ ->
            {Acc#{third_echo => miss}, Counters}
    end;
layer(_, _MasterNode, Acc, Counters) ->
    {Acc, Counters}.

echo_bump(ok, #{echo_ok := N} = C) -> C#{echo_ok => N + 1};
echo_bump(ok, C) -> C#{echo_ok => 1};
echo_bump(fail, #{echo_fail := N} = C) -> C#{echo_fail => N + 1};
echo_bump(fail, C) -> C#{echo_fail => 1}.

%% env layer: JANUS_WORKER_REGION wins verbatim (v1 matching); an
%% out-of-vocab value warns (D20) but still wins.
env_layer() ->
    case os:getenv("JANUS_WORKER_REGION") of
        Val when is_list(Val), Val =/= "" ->
            Region = list_to_binary(Val),
            case catch janus_geo:region_tags() of
                Tags when is_list(Tags) ->
                    case lists:member(Region, Tags) of
                        true ->
                            ok;
                        false ->
                            logger:warning(#{
                                what => janus_worker_region_out_of_vocab, region => Region
                            })
                    end;
                _ ->
                    ok
            end,
            {win, Region};
        _ ->
            miss
    end.

%% Metadata layer: probe each IP-LITERAL endpoint with a 1 s budget;
%% the first VALID reply that maps into the vocab wins. A vocab-map
%% MISS falls through to the next endpoint/layer (spec D4 asymmetry —
%% an adapter gap is not geography). The JANUS_WORKER_GEO_METADATA_URL
%% TEST SEAM replaces the endpoint list (one URL, generic validation,
%% all adapter tables tried in order) — harness-only, never prod.
metadata_probe() ->
    case os:getenv("JANUS_WORKER_GEO_METADATA_URL") of
        Seam when is_list(Seam), Seam =/= "" ->
            metadata_try([{list_to_binary(Seam), all}]);
        _ ->
            metadata_try(metadata_urls())
    end.

metadata_urls() ->
    [
        {<<"http://", Ip/binary, Path/binary>>, Adapter}
     || {Ip, Path, Adapter} <- ?METADATA_ENDPOINTS
    ].

metadata_try([]) ->
    miss;
metadata_try([{Url, Adapter} | Rest]) ->
    case http_get(Url, ?METADATA_TIMEOUT_MS, #{}) of
        {ok, 200, Body} ->
            case validate_metadata_reply(Body) of
                {ok, Region} ->
                    case metadata_map(Adapter, Region) of
                        {ok, Vocab} ->
                            {win, Vocab};
                        miss ->
                            metadata_try(Rest)
                    end;
                {error, _} ->
                    metadata_try(Rest)
            end;
        _ ->
            metadata_try(Rest)
    end.

%% Map a validated cloud region: a specific adapter table first, then
%% (seam `all`) every adapter table in order — first hit wins.
metadata_map(all, Region) ->
    metadata_map_any([aliyun, tencent, aws, baidu], Region);
metadata_map(Adapter, Region) ->
    map_cloud_region(Adapter, Region).

metadata_map_any([], _Region) ->
    miss;
metadata_map_any([A | Rest], Region) ->
    case map_cloud_region(A, Region) of
        {ok, _} = Hit -> Hit;
        miss -> metadata_map_any(Rest, Region)
    end.

thoas_decode(Body) when is_binary(Body) ->
    try
        {ok, Map} = thoas:decode(Body),
        case is_map(Map) of
            true -> Map;
            false -> bad_json
        end
    catch
        _:_ -> bad_json
    end;
thoas_decode(_) ->
    bad_json.

%%%===================================================================
%%% HTTP GET (gun) — full TLS verification, NEVER skipped
%%%===================================================================

%% One-shot GET with a hard total budget. TLS: verify_peer + system
%% roots (public_key:cacerts_get/0) + SNI + hostname match; the
%% JANUS_WORKER_GEO_ECHO_CA_PATH override REPLACES the root set for
%% private-CA deployments. A configured-but-unreadable CA file FAILS
%% the GET (an honest TLS failure — never a verification bypass).
%% gun is ensured started (idempotent): the worker may never have made
%% a provider call when the first keepalive discovery runs (eunit and
%% idle workers alike).
-spec http_get(binary(), pos_integer(), map()) ->
    {ok, pos_integer(), binary()} | {error, term()}.
http_get(UrlBin, TimeoutMs, Opts) when is_binary(UrlBin), is_integer(TimeoutMs), TimeoutMs > 0 ->
    try
        {ok, _} = application:ensure_all_started(gun),
        #{scheme := Scheme, host := Host} = Uri = uri_string:parse(UrlBin),
        HostStr = binary_to_list(Host),
        case ca_certs(Opts) of
            {error, _} = CaErr ->
                CaErr;
            Ca ->
                %% uri_string:parse on a binary returns BINARY scheme
                %% values — an atom comparison silently forces tcp
                %% (ocr high): TLS was never negotiated.
                Tls = (Scheme =:= <<"https">>) orelse (Scheme =:= "https"),
                Port =
                    case maps:get(port, Uri, undefined) of
                        P when is_integer(P) -> P;
                        _ -> uri_default_port(Scheme)
                    end,
                PathBin =
                    case Uri of
                        #{path := Path} when Path =/= <<>> -> Path;
                        _ -> <<"/">>
                    end,
                Transport =
                    case Tls of
                        true -> tls;
                        false -> tcp
                    end,
                GunOpts = #{
                    transport => Transport,
                    tls_opts => tls_opts(HostStr, Ca),
                    connect_timeout => TimeoutMs
                },
                case gun:open(HostStr, Port, GunOpts) of
                    {ok, Conn} ->
                        try
                            await_get(Conn, PathBin, TimeoutMs)
                        after
                            gun:close(Conn)
                        end;
                    {error, OpenErr} ->
                        {error, {open, OpenErr}}
                end
        end
    catch
        C:R -> {error, {C, R}}
    end;
http_get(_, _, _) ->
    {error, bad_url}.

await_get(Conn, PathBin, TimeoutMs) ->
    case gun:await_up(Conn, TimeoutMs) of
        {ok, _} ->
            Stream = gun:get(Conn, PathBin, []),
            case gun:await(Conn, Stream, TimeoutMs) of
                {response, fin, Status, _H} ->
                    {ok, Status, <<>>};
                {response, nofin, Status, _H} ->
                    case gun:await_body(Conn, Stream, TimeoutMs) of
                        {ok, Body} -> {ok, Status, Body};
                        {error, Reason} -> {error, {body, Reason}}
                    end;
                {error, Reason} ->
                    {error, {await, Reason}};
                Other ->
                    {error, {unexpected_await, Other}}
            end;
        {error, Reason} ->
            {error, {await_up, Reason}}
    end.

uri_default_port(<<"https">>) -> 443;
uri_default_port("https") -> 443;
uri_default_port(_) -> 80.

%% Root set: explicit CA path (opts override, else the env) as a
%% {cacerts, Ders} entry, else undefined = system roots at tls_opts/2.
ca_certs(Opts) when is_map(Opts) ->
    Path =
        case maps:get(ca_path, Opts, undefined) of
            undefined ->
                case os:getenv("JANUS_WORKER_GEO_ECHO_CA_PATH") of
                    P when is_list(P), P =/= "" -> P;
                    _ -> undefined
                end;
            P ->
                P
        end,
    case Path of
        undefined ->
            undefined;
        _ ->
            load_ca(Path)
    end.

%% PEM bundle -> {cacerts, [Der]} (decoded certificates only; a bundle
%% with zero certs fails the GET — an empty trust store would verify
%% nothing).
load_ca(Path) ->
    case file:read_file(Path) of
        {ok, Pem} ->
            case public_key:pem_decode(Pem) of
                [] ->
                    {error, {empty_ca, Path}};
                Entries ->
                    %% pem_decode returns {'Certificate', Der, _}
                    %% directly — pem_entry_decode yields a record
                    %% that never matches (ocr high): CA override
                    %% always failed.
                    Ders = [
                        Der
                     || {'Certificate', Der, _} <- Entries
                    ],
                    case Ders of
                        [] -> {error, {no_certificates, Path}};
                        _ -> {cacerts, Ders}
                    end
            end;
        {error, Reason} ->
            {error, {read_ca_failed, Reason}}
    end.

tls_opts(HostStr, undefined) ->
    full_verify_opts(HostStr, []);
tls_opts(HostStr, CaEntry) ->
    full_verify_opts(HostStr, [CaEntry]).

%% verify_peer + roots + SNI + hostname match. There is deliberately
%% NO verify_none path (spec D4: verification is never skipped;
%% MITM-faked egress = preference-only harm, accepted).
full_verify_opts(HostStr, []) ->
    %% No CA override: the system root set.
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {depth, 3},
        {server_name_indication, HostStr},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ];
full_verify_opts(_HostStr, [CaEntry]) ->
    %% CA override REPLACES the root set — appending alongside the
    %% system roots leaves two cacerts entries and ssl resolves
    %% them ambiguously (ocr medium).
    [
        {verify, verify_peer},
        CaEntry,
        {depth, 3},
        {server_name_indication, _HostStr},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ].

%%%===================================================================
%%% Internals
%%%===================================================================

env_pos_int(false, Default) -> Default;
env_pos_int("", Default) -> Default;
env_pos_int(Val, Default) when is_list(Val) ->
    try
        max(1, list_to_integer(Val))
    catch
        _:_ -> Default
    end;
env_pos_int(_, Default) -> Default.

env_truthy(false) -> false;
env_truthy("") -> false;
env_truthy(Val) when is_list(Val) ->
    lists:member(string:lowercase(Val), ["1", "true", "yes", "on"]);
env_truthy(_) -> false.
