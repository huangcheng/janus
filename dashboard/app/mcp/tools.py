"""MCP tool catalog.

One declarative table maps every tool onto an existing, audited REST
endpoint; the MCP layer is discovery and gating, never a second write
path. Tools are generated from the table below with synthetic signatures
(FastMCP builds input schemas from inspect.signature, which honors
__signature__, and finds the Context parameter through the closure's real
annotations), so adding a tool is one SPEC line, not a copied function.
"""

import inspect
import json
from dataclasses import dataclass
from typing import Annotated, Any

from mcp.server.fastmcp import Context
from mcp.server.fastmcp.exceptions import ToolError
from mcp.types import ToolAnnotations
from pydantic import Field

from . import api


@dataclass(frozen=True)
class Param:
    name: str
    type: type = str
    required: bool = True
    # "path" | "query" | "body". Break-glass role/reason are QUERY params
    # because egress.require_breakglass reads request.query_params.
    in_: str = "body"
    desc: str = ""
    # Wire key when the endpoint's name is not a valid Python identifier.
    alias: str | None = None
    # Dict payload merged into the TOP-LEVEL body instead of nested under
    # the param name — the settings PUTs validate top-level keys and
    # reject a wrapping key.
    flatten: bool = False


@dataclass(frozen=True)
class Spec:
    name: str
    desc: str
    method: str
    path: str
    params: tuple[Param, ...] = ()
    read_only: bool = False
    # destructiveHint for clients: the call mutates state.
    write: bool = False
    # 200-with-failure probe: these endpoints answer HTTP 200 with a body
    # that carries the failure (deliberate SPA contracts) — the tool must
    # read the body and raise, never report a failed call as success.
    check: str | None = None  # "test_key" | "sched" | "stats" | "logs"


_BG_ROLE = Param("role", in_="query", desc="Operator role for the break-glass log")
_BG_REASON = Param("reason", in_="query", desc="Why this break-glass write happens")
_BG_CONFIRMED = Param(
    "confirmed", type=bool, desc="Break-glass confirmation; must be explicitly true"
)

SPECS: tuple[Spec, ...] = (
    # --- Fleet / nodes (the plug-a-worker-in workflow) ---
    Spec(
        "nodes_list",
        "List gateway node rows, sched-scraped workers (status up/sticky, region,"
        " capacity, draining), fleet state and egress policy.",
        "GET",
        "/api/nodes",
        read_only=True,
    ),
    Spec(
        "node_register",
        "Register a gateway (master) row. Workers are never registered — they join"
        " the Erlang mesh at boot and surface via sched scrape. stats_token is"
        " encrypted at rest and write-only.",
        "POST",
        "/api/nodes",
        params=(
            Param("name", desc="Row name, unique"),
            Param("data_host", desc="Agent-plane host (bare host or https:// origin)"),
            Param("data_port", type=int, required=False, desc="Default 8080"),
            Param("stats_host", required=False, desc="Admin-plane host; defaults to data_host"),
            Param("stats_port", type=int, required=False, desc="Default 8090"),
            Param("stats_token", required=False, desc="Per-node admin bearer; write-only"),
            Param("build_sha", required=False, desc="At most 12 chars"),
        ),
        write=True,
    ),
    Spec(
        "node_update",
        "Update a gateway row (name/hosts/ports/token/enabled/build_sha).",
        "PATCH",
        "/api/nodes/{node_id}",
        params=(
            Param("node_id", type=int, in_="path"),
            Param("name", required=False, desc="Row name"),
            Param("data_host", required=False, desc="Agent-plane host"),
            Param("data_port", type=int, required=False, desc="Agent-plane port"),
            Param("stats_host", required=False, desc="Admin-plane host"),
            Param("stats_port", type=int, required=False, desc="Admin-plane port"),
            Param("stats_token", required=False, desc="Write-only; empty string clears"),
            Param("build_sha", required=False, desc="At most 12 chars"),
            Param("enabled", type=bool, required=False, desc="Row enabled"),
        ),
        write=True,
    ),
    Spec(
        "node_delete",
        "Remove a gateway row. Does not touch the node itself.",
        "DELETE",
        "/api/nodes/{node_id}",
        params=(Param("node_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "node_stats",
        "Proxy a gateway node's /stats snapshot (usage, lb, generation, role).",
        "GET",
        "/api/nodes/{node_id}/stats",
        params=(Param("node_id", type=int, in_="path"),),
        read_only=True,
        check="stats",
    ),
    Spec(
        "node_sched",
        "Proxy a gateway node's /stats/sched — workers[] is the membership truth"
        " (node, status up|sticky, draining, region, git_sha).",
        "GET",
        "/api/nodes/{node_id}/sched",
        params=(Param("node_id", type=int, in_="path"),),
        read_only=True,
        check="sched",
    ),
    Spec(
        "node_logs",
        "Tail a gateway node's recent log events.",
        "GET",
        "/api/nodes/{node_id}/logs",
        params=(
            Param("node_id", type=int, in_="path"),
            Param("limit", type=int, required=False, desc="Default per endpoint"),
        ),
        read_only=True,
        check="logs",
    ),
    Spec(
        "node_metrics",
        "Proxy a gateway node's Prometheus /metrics exposition. Answers"
        " text/plain verbatim; 503 text means the egress policy skipped the"
        " scrape (no per-node token).",
        "GET",
        "/api/nodes/{node_id}/metrics",
        params=(Param("node_id", type=int, in_="path"),),
        read_only=True,
    ),
    Spec(
        "node_runtime",
        "Fleet-wide runtime snapshot (supervision tree, memory, run queues) via"
        " the runtime_snapshot fleet command. Heavy: on demand, never polled.",
        "GET",
        "/api/nodes/runtime",
        read_only=True,
        check="fleet",
    ),
    Spec(
        "worker_geo_refresh",
        "Ask a worker to re-resolve its geo (refreshed geo rides the next hello).",
        "POST",
        "/api/nodes/{node_id}/workers/geo-refresh",
        params=(
            Param("node_id", type=int, in_="path"),
            Param("worker", desc="Worker long name, e.g. janus@worker.internal"),
        ),
        write=True,
    ),
    Spec(
        "worker_note_set",
        "Set or clear (empty string) the operator remark for a worker.",
        "PUT",
        "/api/nodes/workers/note",
        params=(
            Param("node", desc="Worker long name (janus@host)"),
            Param("note", desc="At most 120 chars; empty clears"),
        ),
        write=True,
    ),
    Spec(
        "fleet_command",
        "Issue an allowlisted gateway fleet command against a master row:"
        " fleet_status | pool_ping | runtime_snapshot | worker_geo_refresh |"
        " lb_cool_clear | config_reload_nudge | catalog_cache_flush."
        " pool_ping/worker_geo_refresh run on the master itself; the rest fan"
        " out over erpc. target: lb_cool_clear needs one of"
        " {kind: route,model?,provider} | {kind: provider,provider} |"
        " {kind: provider_key,key} | {kind: listing,name}; worker_geo_refresh"
        " needs {kind: worker,node}.",
        "POST",
        "/api/nodes/fleet-command",
        params=(
            Param("command", desc="One of the seven allowlisted commands"),
            Param(
                "target", type=dict[str, Any], required=False, desc="Command target, if required"
            ),
        ),
        write=True,
        # Gateway answers HTTP 200 with {"outcome": "error"} when every peer
        # failed — outcome=error must surface as a tool error, not success.
        check="fleet",
    ),
    # --- Providers ---
    Spec(
        "providers_list",
        "List providers with their (redacted) keys and model listings.",
        "GET",
        "/api/providers",
        read_only=True,
    ),
    Spec(
        "provider_create",
        "Create a provider. allow_internal is deliberately NOT offered here —"
        " flipping a provider internal is the separate break-glass tool.",
        "POST",
        "/api/providers",
        params=(
            Param("name", desc="Provider name"),
            Param("base_url", desc="Upstream base URL"),
            Param(
                "protocol",
                required=False,
                desc="openai_chat | anthropic_messages | openai_responses | openai_decisions"
                " (decisions additionally requires decisions_confirmed=true,"
                " a billable grant)",
            ),
            Param(
                "decisions_confirmed",
                type=bool,
                required=False,
                desc="Billable-grant confirmation; must be true when" " protocol=openai_decisions",
            ),
            Param(
                "key",
                type=dict[str, Any],
                required=False,
                desc="Initial key object {secret, weight} (write-only, encrypted at rest)",
            ),
            Param("region_tag", required=False, desc="Geo region tag"),
            Param("affinity_node", required=False, desc="Worker long name to pin egress"),
        ),
        write=True,
    ),
    Spec(
        "provider_update",
        "Narrow update: affinity_node and region_tag only (the PATCH endpoint"
        " rejects every other field).",
        "PATCH",
        "/api/providers/{provider_id}",
        params=(
            Param("provider_id", type=int, in_="path"),
            Param("affinity_node", required=False, desc="Worker long name to pin egress"),
            Param("region_tag", required=False, desc="Geo region tag"),
        ),
        write=True,
    ),
    Spec(
        "provider_delete",
        "Delete a provider. CASCADES: routes are snapshotted to the journal,"
        " models losing their last route are retired, tier memberships pruned.",
        "DELETE",
        "/api/providers/{provider_id}",
        params=(Param("provider_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "provider_enable",
        "Enable a provider.",
        "POST",
        "/api/providers/{provider_id}/enable",
        params=(Param("provider_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "provider_disable",
        "Disable a provider.",
        "POST",
        "/api/providers/{provider_id}/disable",
        params=(Param("provider_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "provider_allow_internal",
        "Break-glass both directions: allow (or disallow) a provider to route"
        " to internal/loopback targets.",
        "POST",
        "/api/providers/{provider_id}/allow-internal",
        params=(
            Param("provider_id", type=int, in_="path"),
            Param(
                "allow",
                alias="allow_internal",
                type=bool,
                desc="true allows internal targets, false revokes",
            ),
            _BG_ROLE,
            _BG_REASON,
            _BG_CONFIRMED,
        ),
        write=True,
    ),
    Spec(
        "provider_probe",
        "Fire-and-forget connectivity probe: answers 202 {queued}. The outcome"
        " surfaces asynchronously on the entitlements surface — poll it, do not"
        " expect a verdict from this call.",
        "POST",
        "/api/providers/{provider_id}/probe",
        params=(Param("provider_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "provider_test_key",
        "Validate a provider key/URL combination. Answers HTTP 200 with"
        " {ok,error,detail} by design — a false ok is raised as a tool error.",
        "POST",
        "/api/providers/test-key",
        params=(
            Param("base_url", desc="Upstream base URL"),
            Param("key", alias="secret", desc="API key to test"),
            Param(
                "protocol",
                desc="openai_chat | anthropic_messages | openai_responses | openai_decisions"
                " (no default server-side)",
            ),
        ),
        # DB-read-only upstream probe — not a state mutation, so no
        # destructiveHint (clients must not confirm-gate a validation call).
        read_only=True,
        check="test_key",
    ),
    # --- Models & routes ---
    Spec(
        "models_list",
        "List models with their provider routes (weight/priority/enabled).",
        "GET",
        "/api/models",
        read_only=True,
    ),
    Spec(
        "model_create",
        "Create a model (name only; bind routes afterwards).",
        "POST",
        "/api/models",
        params=(Param("name", desc="Model name"),),
        write=True,
    ),
    Spec(
        "model_enable",
        "Enable a model.",
        "POST",
        "/api/models/{model_id}/enable",
        params=(Param("model_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "model_disable",
        "Disable a model.",
        "POST",
        "/api/models/{model_id}/disable",
        params=(Param("model_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "model_delete",
        "Delete a model (route restore info is journaled).",
        "DELETE",
        "/api/models/{model_id}",
        params=(Param("model_id", type=int, in_="path"),),
        write=True,
    ),
    Spec(
        "models_sync",
        "Sync provider model listings.",
        "POST",
        "/api/models/sync",
        write=True,
    ),
    Spec(
        "route_add",
        "Bind a provider route to a model (upsert on (model, provider)).",
        "POST",
        "/api/models/{model_id}/routes",
        params=(
            Param("model_id", type=int, in_="path"),
            Param("provider_id", type=int, desc="Provider row id"),
            Param("upstream_model_id", required=False, desc="Upstream model name if it differs"),
            Param("weight", type=int, required=False, desc="1..1000000, default 1"),
            Param("priority", type=int, required=False, desc="Default 0"),
        ),
        write=True,
    ),
    Spec(
        "route_enable",
        "Enable a (model, provider) route.",
        "POST",
        "/api/models/{model_id}/routes/{provider_id}/enable",
        params=(
            Param("model_id", type=int, in_="path"),
            Param("provider_id", type=int, in_="path"),
        ),
        write=True,
    ),
    Spec(
        "route_disable",
        "Disable a (model, provider) route.",
        "POST",
        "/api/models/{model_id}/routes/{provider_id}/disable",
        params=(
            Param("model_id", type=int, in_="path"),
            Param("provider_id", type=int, in_="path"),
        ),
        write=True,
    ),
    Spec(
        "route_rebalance",
        "Rebalance a (model, provider) route (weight and/or priority).",
        "POST",
        "/api/models/{model_id}/routes/{provider_id}/rebalance",
        params=(
            Param("model_id", type=int, in_="path"),
            Param("provider_id", type=int, in_="path"),
            Param("weight", type=int, required=False, desc="1..1000000"),
            Param("priority", type=int, required=False),
        ),
        write=True,
    ),
    Spec(
        "route_delete",
        "Remove a (model, provider) route.",
        "DELETE",
        "/api/models/{model_id}/routes/{provider_id}",
        params=(
            Param("model_id", type=int, in_="path"),
            Param("provider_id", type=int, in_="path"),
        ),
        write=True,
    ),
    # --- Auto-router ---
    Spec(
        "auto_router_get",
        "Read the auto-router config (tiers, judge, failover) plus live snapshot.",
        "GET",
        "/api/settings/auto-router",
        read_only=True,
    ),
    Spec(
        "auto_router_put",
        "Partial-merge update of the auto-router config. Tier members must be"
        " bound models unless enabled is false.",
        "PUT",
        "/api/settings/auto-router",
        params=(
            Param(
                "config",
                type=dict[str, Any],
                flatten=True,
                desc="Partial config: enabled, model, judge_backend, judge_model,"
                " tiers, default_tier, tier_failover_enabled, ...",
            ),
        ),
        write=True,
    ),
    Spec(
        "auto_router_live",
        "Local-judge readiness snapshot.",
        "GET",
        "/api/settings/auto-router/live",
        read_only=True,
    ),
    Spec(
        "auto_reorder_get",
        "Read the auto-reorder knobs (default dry_run).",
        "GET",
        "/api/settings/auto-router-reorder",
        read_only=True,
    ),
    Spec(
        "auto_reorder_put",
        "Break-glass update of the auto-reorder knobs. This one DOES bump the"
        " config generation (its own semantics).",
        "PUT",
        "/api/settings/auto-router-reorder",
        params=(
            Param(
                "knobs",
                type=dict[str, Any],
                flatten=True,
                desc="Knob subset: enabled, interval_sec, window_sec, min_samples,"
                " min_improve_ratio, min_success_rate, manual_hold_sec, dry_run",
            ),
            _BG_ROLE,
            _BG_REASON,
            _BG_CONFIRMED,
        ),
        write=True,
    ),
    Spec(
        "auto_reorder_state",
        "Current reorder state payload.",
        "GET",
        "/api/settings/auto-router/reorder-state",
        read_only=True,
    ),
    Spec(
        "auto_reorder_tick",
        "Run one reorder pass immediately.",
        "POST",
        "/api/settings/auto-router/reorder-tick",
        write=True,
    ),
    # --- Observability ---
    Spec(
        "usage_summary",
        "Usage summary for a range (24h | 7d | 30d).",
        "GET",
        "/api/usage/summary",
        params=(Param("range", required=False, desc="24h | 7d | 30d"),),
        read_only=True,
    ),
    Spec(
        "usage_spend",
        "Spend report grouped by key | model | day.",
        "GET",
        "/api/usage/spend",
        params=(
            Param(
                "from_",
                alias="from",
                type=int,
                required=False,
                desc="Unix seconds, default to-86400",
            ),
            Param("to", type=int, required=False, desc="Unix seconds, default now"),
            Param("group_by", required=False, desc="key | model | day"),
        ),
        read_only=True,
    ),
    Spec(
        "usage_events",
        "Usage events, newest first.",
        "GET",
        "/api/usage/events",
        params=(
            Param("limit", type=int, required=False, desc="1..200, default 50"),
            Param("offset", type=int, required=False),
            Param("key_id", type=int, required=False),
            Param("model_id", type=int, required=False),
            Param("provider_id", type=int, required=False),
            Param("status", required=False, desc="ok | error | empty"),
        ),
        read_only=True,
    ),
    Spec(
        "usage_timeline",
        "Per-request timeline; exactly one of request_ref or trace_id.",
        "GET",
        "/api/usage/timeline",
        params=(
            Param("request_ref", required=False),
            Param("trace_id", required=False, desc="32 lowercase hex chars"),
        ),
        read_only=True,
    ),
    Spec(
        "failures_summary",
        "Failure summary for a range (24h | 7d | 30d).",
        "GET",
        "/api/failures/summary",
        params=(Param("range", required=False, desc="24h | 7d | 30d"),),
        read_only=True,
    ),
    Spec(
        "failures_events",
        "Failure events (upstream + reject), newest first.",
        "GET",
        "/api/failures/events",
        params=(
            Param("range", required=False, desc="24h | 7d | 30d"),
            Param("kind", required=False, desc="upstream | reject | empty"),
            Param("limit", type=int, required=False, desc="1..200, default 50"),
            Param("offset", type=int, required=False),
        ),
        read_only=True,
    ),
    Spec(
        "logs_tail",
        "Dashboard-side log tail; source=live merges node in-memory rings.",
        "GET",
        "/api/logs",
        params=(
            Param("limit", type=int, required=False, desc="Default 300"),
            Param("level", required=False, desc="info | warning | error"),
            Param("node", required=False),
            Param("since", required=False),
            Param("source", required=False, desc="db | live"),
        ),
        read_only=True,
    ),
    Spec(
        "ops_events",
        "Windowed ops-event tail (since/until are ISO-8601 bounds). The ring"
        " is drained by the ops puller — this is a windowed read, not a"
        " cursor page.",
        "GET",
        "/api/ops-events",
        params=(
            Param("node", required=False, desc="Filter by gateway node name"),
            Param("type", required=False, desc="Filter by event type"),
            Param("boot_id", required=False),
            Param("since", required=False, desc="ISO-8601 lower bound"),
            Param("until", required=False, desc="ISO-8601 upper bound"),
            Param("limit", type=int, required=False),
        ),
        read_only=True,
    ),
    Spec(
        "alerts_list",
        "Configured alerts.",
        "GET",
        "/api/alerts",
        read_only=True,
    ),
    Spec(
        "alerts_test",
        "Send a test alert.",
        "POST",
        "/api/alerts/test",
        write=True,
    ),
    Spec(
        "audit_recent",
        "Dashboard mutation trail, newest first.",
        "GET",
        "/api/audit",
        params=(Param("limit", type=int, required=False, desc="Default 200"),),
        read_only=True,
    ),
)


def _render(data: Any) -> str:
    if isinstance(data, (dict, list)):
        return json.dumps(data, indent=2, default=str, ensure_ascii=False)
    return str(data)


def _token(ctx: Context) -> str:
    request = ctx.request_context.request
    header = getattr(request, "headers", None)
    if header is None:
        raise ToolError("no HTTP request context on this call")
    value = header.get("authorization")
    if not value:
        # The mount gate already enforced the bearer; reaching here means the
        # header vanished between gate and tool — fail loud, never silent.
        raise ToolError("missing bearer token in MCP request context")
    # Strip the scheme here, not in call_api: the gate validated this exact
    # header, and the REST call rebuilds "Bearer <token>". Case-insensitive
    # like HTTPBearer, so a lowercase "bearer" passes the gate and works.
    return value[7:] if value[:7].lower() == "bearer " else value


def _signature_for(spec: Spec) -> inspect.Signature:
    params = [inspect.Parameter("ctx", inspect.Parameter.POSITIONAL_OR_KEYWORD, annotation=Context)]
    for p in spec.params:
        # Optional params are nullable: the schema advertises default null,
        # and a client sending an explicit null must validate — _runner
        # already treats None as absent.
        base: Any = p.type if p.required else p.type | None
        annotation: Any = base
        if p.desc:
            annotation = Annotated[base, Field(description=p.desc)]
        params.append(
            inspect.Parameter(
                p.name,
                inspect.Parameter.POSITIONAL_OR_KEYWORD,
                annotation=annotation,
                default=inspect.Parameter.empty if p.required else None,
            )
        )
    return inspect.Signature(params)


def _runner(spec: Spec):
    async def run(ctx: Context, **kwargs: Any) -> str:
        token = _token(ctx)
        path = spec.path.format(**{p.name: kwargs[p.name] for p in spec.params if p.in_ == "path"})
        query: dict[str, Any] = {}
        body: dict[str, Any] = {}
        for p in spec.params:
            if p.in_ == "path":
                continue
            value = kwargs.get(p.name)
            if value is None:
                continue
            # GET endpoints bind filters from the query string — a JSON body
            # on a GET is silently dropped, so route every non-path GET
            # param to the query centrally (specs need no in_ for filters).
            if p.in_ == "query" or (spec.method == "GET" and p.in_ != "path"):
                query[p.alias or p.name] = value
            elif p.flatten and isinstance(value, dict):
                # Settings PUTs validate top-level keys; nest = 400 unknown_fields.
                body.update(value)
            else:
                body[p.alias or p.name] = value
        # An empty object is still a body: auto_router_put(config={}) is a
        # valid no-op merge. Omit the body only when the spec cannot carry one.
        has_body = spec.method != "GET" and any(p.in_ not in ("path", "query") for p in spec.params)
        status, data = await api.call_api(
            spec.method, path, token, query or None, body if has_body else None
        )
        # >= 300, not >= 400: the bridge never follows redirects, so a 3xx
        # (a spec path drifting from the router path) must fail loud — an
        # unfollowed redirect body would masquerade as success.
        if status >= 300:
            raise ToolError(f"HTTP {status} {spec.method} {path}: {_render(data)}")
        # Deliberate 200-with-failure SPA contracts — raise, never pass.
        if spec.check == "test_key" and isinstance(data, dict) and data.get("ok") is False:
            raise ToolError(f"test-key rejected: {data.get('error')}: {data.get('detail')}")
        if spec.check == "sched" and isinstance(data, dict) and data.get("ok") is False:
            raise ToolError(f"sched scrape failed: {_render(data.get('error'))}")
        # node_stats answers 200 with status healthy | unhealthy |
        # unreachable | stale_no_token — only healthy is success, so invert
        # against it rather than enumerating the failure values.
        if spec.check == "stats" and isinstance(data, dict) and data.get("status") != "healthy":
            raise ToolError(f"stats not healthy: {_render(data)}")
        if spec.check == "logs" and isinstance(data, dict) and data.get("skipped"):
            raise ToolError(f"logs skipped: {data.get('skipped')}")
        # Fleet envelopes answer HTTP 200 with outcome error (every peer
        # failed) or partial — error is a tool error; partial passes with
        # its per-node results visible in the payload.
        if spec.check == "fleet" and isinstance(data, dict) and data.get("outcome") == "error":
            raise ToolError(f"fleet command failed: {_render(data)}")
        return _render(data)

    return run


def register_all(mcp_server) -> None:
    for spec in SPECS:
        runner = _runner(spec)
        runner.__name__ = spec.name
        runner.__doc__ = spec.desc
        runner.__signature__ = _signature_for(spec)
        mcp_server.add_tool(
            runner,
            name=spec.name,
            description=spec.desc,
            annotations=ToolAnnotations(
                readOnlyHint=spec.read_only,
                destructiveHint=spec.write and not spec.read_only,
            ),
        )
