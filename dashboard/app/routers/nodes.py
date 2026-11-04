"""Gateway node registry and monitoring endpoints."""

import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from .. import audit, database, egress
from ..auth import require_auth
from ..config import config
from ..crypto import encrypt
from ..nodes import (
    _auth_headers,
    _tls_verify,
    assemble_nodes_payload,
    health_data,
    poll_node,
    poll_sched,
    stats_url,
)

router = APIRouter()
logger = logging.getLogger("janus.dashboard.nodes")


@router.get("")
async def list_nodes(user: dict = Depends(require_auth)):
    """List gateways with health + assembled workers/fleet from sched cache.

    Shape (contracts #7–#9, #18–#19):
    `{nodes, workers, fleet, scraped_at}` — workers carry full /stats/sched
    worker objects plus `via` (gateway name); fleet is picked from the
    cached sched with highest `members` (tie-break lowest gateway id).
    Also surfaces v2.2 Part B egress_policy + skip counter.
    """
    rows = await database.fetch(
        "SELECT id, name, data_host, data_port, stats_host, stats_port, enabled, created_at, "
        "stats_token_ciphertext, health_snapshot, health_pulled_at, ops_lagging, "
        "ops_boot_id, build_sha FROM gateway_nodes ORDER BY id"
    )
    payload = await assemble_nodes_payload(rows)
    policy_on = await egress.egress_policy_on()
    # v2.2 Part B: the knob state and the skip counter surface here
    # (the dashboard has no prometheus exposition — /api/nodes only).
    payload["egress_policy"] = "on" if policy_on else "off"
    payload["nodes_skipped_no_token_total"] = egress.skipped_no_token_total()
    return payload


@router.post("", status_code=201)
async def register_node(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    name = body.get("name", "").strip()
    data_host = body.get("data_host", "").strip()
    data_port = body.get("data_port", 8080)
    stats_host = body.get("stats_host", data_host)
    stats_port = body.get("stats_port", 8090)
    raw_token = body.get("stats_token")
    stats_token = raw_token.strip() if isinstance(raw_token, str) else ""
    envelope = encrypt(stats_token.encode()).hex() if stats_token else None
    build_sha = (body.get("build_sha") or "").strip()[:12] or None

    if not name or not data_host:
        raise HTTPException(
            400, detail={"error": {"code": "invalid", "message": "name and data_host required"}}
        )

    # v2.2 Part B: write-time host validation is ALWAYS-ON (input
    # validation is not a policy): bare host or http(s):// origin only.
    egress.validate_node_host(data_host, "data_host")
    egress.validate_node_host(stats_host, "stats_host")

    try:
        row = await database.fetchrow(
            "INSERT INTO gateway_nodes "
            "(name, data_host, data_port, stats_host, stats_port, enabled, stats_token_ciphertext, build_sha) "
            "VALUES ($1, $2, $3, $4, $5, true, $6, $7) RETURNING id",
            name,
            data_host,
            data_port,
            stats_host,
            stats_port,
            envelope,
            build_sha,
        )
        if envelope:
            audit.log("node.stats_token", f"node:{row['id']}", "set at registration")
        return {"id": row["id"], "name": name}
    except HTTPException:
        raise
    except Exception as e:
        if "unique" in str(e).lower():
            raise HTTPException(
                409, detail={"error": {"code": "duplicate", "message": "node name exists"}}
            )
        raise HTTPException(500, detail=str(e))


@router.patch("/{node_id}")
async def update_node(node_id: int, request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    sets = []
    args = []

    if "name" in body:
        args.append(body["name"])
        sets.append(f"name = ${len(args)}")
    if "data_host" in body:
        # Part B always-on validation (same rule as register).
        egress.validate_node_host(body["data_host"], "data_host")
        args.append(body["data_host"])
        sets.append(f"data_host = ${len(args)}")
    if "data_port" in body:
        args.append(int(body["data_port"]))
        sets.append(f"data_port = ${len(args)}")
    if "stats_host" in body:
        egress.validate_node_host(body["stats_host"], "stats_host")
        args.append(body["stats_host"])
        sets.append(f"stats_host = ${len(args)}")
    if "stats_port" in body:
        args.append(int(body["stats_port"]))
        sets.append(f"stats_port = ${len(args)}")
    token_action = None
    if isinstance(body.get("stats_token"), str):
        # write-only: non-empty sets, "" clears (back to the global
        # token); absent/null leaves the stored envelope untouched.
        raw = body["stats_token"].strip()
        args.append(encrypt(raw.encode()).hex() if raw else None)
        sets.append(f"stats_token_ciphertext = ${len(args)}")
        token_action = "set" if raw else "cleared"
    if "enabled" in body:
        args.append(bool(body["enabled"]))
        sets.append(f"enabled = ${len(args)}")
    if "build_sha" in body:
        # PATCH build_sha with explicit None clears; "" is treated as None.
        sha = (body["build_sha"] or "").strip()[:12] or None
        args.append(sha)
        sets.append(f"build_sha = ${len(args)}")

    if not sets:
        raise HTTPException(
            400, detail={"error": {"code": "invalid", "message": "no fields to update"}}
        )

    args.append(node_id)
    sql = f"UPDATE gateway_nodes SET {', '.join(sets)} WHERE id = ${len(args)}"
    await database.execute(sql, *args)
    if token_action:
        # audit only after the UPDATE actually ran (ocr review).
        audit.log("node.stats_token", f"node:{node_id}", token_action)
    return {"ok": True}


@router.delete("/{node_id}")
async def delete_node(node_id: int, user: dict = Depends(require_auth)):
    await database.execute("DELETE FROM gateway_nodes WHERE id = $1", node_id)
    return {"ok": True}


async def _policy_token(row) -> str | None:
    """Resolve the token for a stored node row THROUGH the egress
    policy (v2.2 Part B): every stats_host reader is wrapped — a manual
    per-node stats/logs fetch must not bypass the poller's rule."""
    policy_on = await egress.egress_policy_on()
    return egress.stats_token_for(
        row["stats_host"],
        row["stats_token_ciphertext"],
        config.stats_token,
        policy_on=policy_on,
    )


@router.get("/runtime")
async def fleet_runtime(user: dict = Depends(require_auth)):
    """Observer-style runtime snapshot of the WHOLE fleet, via the
    gateway's `runtime_snapshot` fleet command (POST /stats/fleet/command
    on a master; the master collects every worker over erpc — workers
    expose no :8090 listener).

    Heavy by design (a supervision-tree walk on every node): triggered
    on demand from the Nodes page, never polled on a schedule. Gateways
    older than the command answer unknown_command -> 409, which the SPA
    renders as "deploy the new gateway image first".
    """
    last_status, last_body = await _issue_fleet_command("runtime_snapshot")
    return _fleet_audit_tail(
        "node.runtime_snapshot", "runtime_snapshot", None, last_status, last_body
    )


def _fleet_audit_tail(action, command, target, last_status, last_body, fail_on_error=False):
    """Shared audit + unwrap tail for fleet-command callers: audit the
    outcome (target truncated — a hostile caller must not amplify DB
    writes), then raise the house error envelope on non-200 — and, for
    mutating commands (fail_on_error), on outcome=error too: the gateway
    answers HTTP 200 with outcome=error when the command succeeded
    nowhere, and a failed fleet-wide mutation must not read as done at
    the HTTP layer. Read-only callers (runtime snapshot) keep the
    pass-through."""
    _results = last_body.get("results") if isinstance(last_body, dict) else {}
    _n = len(_results) if isinstance(_results, dict) else 0
    _outcome = last_body.get("outcome") if isinstance(last_body, dict) else "?"
    _target = json.dumps(target, sort_keys=True)[:512] if target else "none"
    audit.log(action, "fleet", f"command={command} target={_target} outcome={_outcome} nodes={_n}")
    if last_status != 200 or (fail_on_error and _outcome == "error"):
        raise HTTPException(
            502 if last_status == 200 else last_status,
            detail={"error": {"code": "gateway_error", "message": last_body}},
        )
    return last_body


# The gateway's closed command enum (janus_fleet_commands.erl). Anything
# not here is rejected before a single byte leaves the dashboard — the
# admin plane is fleet-wide power, and this endpoint is what the MCP
# `fleet_command` tool (and, later, the SPA) drives.
_FLEET_COMMANDS = frozenset(
    {
        "fleet_status",
        "pool_ping",
        "runtime_snapshot",
        "worker_geo_refresh",
        "lb_cool_clear",
        "config_reload_nudge",
        "catalog_cache_flush",
    }
)


def _fleet_target_error(message: str) -> HTTPException:
    return HTTPException(400, detail={"error": {"code": "invalid_target", "message": message}})


def _target_id(value) -> int | None:
    """Cool rows are keyed by INTEGER ids. The gateway's decoder also
    accepts binaries, but a binary id matches no row (cool_clear swallows
    the miss and answers ok), so accept an int or a numeric string and
    ALWAYS coerce to int — anything else is a display name or garbage."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, str):
        # isdecimal, not isdigit: superscripts pass isdigit but crash int();
        # positive only — row ids are positive and cool_clear swallows misses.
        if value.isdecimal():
            try:
                return int(value) if int(value) > 0 else None
            except ValueError:
                return None
    return None


def _validate_fleet_target(command: str, target) -> dict | None:
    """Mirror the gateway's target kinds (janus_http_fleet target decode).
    Returns the validated target (ids coerced to int), or None when the
    command takes none."""
    if command == "lb_cool_clear":
        if not isinstance(target, dict):
            raise _fleet_target_error("lb_cool_clear requires a target object")
        kind = target.get("kind")
        # Rebuilt from ONLY the expected keys: caller-supplied extras must
        # not ride to the gateway or into the audit trail.
        if kind == "route":
            provider = _target_id(target.get("provider"))
            if provider is None:
                raise _fleet_target_error("kind=route requires provider (row id)")
            model = target.get("model")
            if model is not None:
                model = _target_id(model)
                if model is None:
                    raise _fleet_target_error("kind=route model must be a row id or null")
            return {"kind": "route", "provider": provider, "model": model}
        if kind == "provider":
            provider = _target_id(target.get("provider"))
            if provider is None:
                raise _fleet_target_error("kind=provider requires provider (row id)")
            return {"kind": "provider", "provider": provider}
        if kind == "provider_key":
            key = _target_id(target.get("key"))
            if key is None:
                raise _fleet_target_error("kind=provider_key requires key (row id)")
            return {"kind": "provider_key", "key": key}
        if kind == "listing":
            name = target.get("name")
            if not isinstance(name, str) or not name or len(name) > 256:
                raise _fleet_target_error("kind=listing requires name (<=256 chars)")
            return {"kind": "listing", "name": name}
        raise _fleet_target_error("kind must be route | provider | provider_key | listing")
    if command == "worker_geo_refresh":
        if not isinstance(target, dict) or target.get("kind") != "worker":
            raise _fleet_target_error("worker_geo_refresh requires {kind: worker, node}")
        node = target.get("node")
        # Same shape contract as POST /{node_id}/workers/geo-refresh: a
        # long name, bounded, so a garbage value is rejected here instead
        # of being relayed to every enabled row.
        if not isinstance(node, str) or "@" not in node or len(node) > 253:
            raise _fleet_target_error("node must be a worker long name (janus@host)")
        return {"kind": "worker", "node": node}
    if target is not None:
        raise _fleet_target_error(f"{command} takes no target")
    return None


async def _issue_fleet_command(command: str, target: dict | None = None):
    """Issue a fleet command against a master-preferred enabled row, with
    the same row ordering and error envelope as the runtime snapshot."""
    rows = await database.fetch(
        "SELECT id, name, stats_host, stats_port, stats_token_ciphertext "
        "FROM gateway_nodes WHERE enabled ORDER BY id"
    )
    if not rows:
        raise HTTPException(
            409, detail={"error": {"code": "no_nodes", "message": "no enabled gateway nodes"}}
        )

    # Prefer a master row (it can reach workers via erpc; local-only
    # commands like pool_ping only work there). The persisted
    # health_snapshot column is the /stats/health body, which carries NO
    # role — the live /stats cache does (root body includes role). Before
    # the first poll cycle the cache is empty and ordering degenerates to
    # id order, same as trying rows in sequence.
    live_health = health_data()
    ordered = sorted(
        rows,
        key=lambda r: str((live_health.get(r["id"]) or {}).get("role") or "").lower() != "master",
    )

    payload = {"command": command}
    if target is not None:
        payload["target"] = target

    last_status, last_body = (
        502,
        {"error": {"code": "gateway_error", "message": "no node answered"}},
    )
    for row in ordered:
        token = await _policy_token(row)
        if token is None:
            egress.note_skipped_no_token(f"node:{row['id']}", row["stats_host"])
            continue
        url = stats_url(row["stats_host"], row["stats_port"], "/stats/fleet/command")
        try:
            async with egress.pinned_async_client(
                row["stats_host"], timeout=30.0, verify=_tls_verify()
            ) as client:
                resp = await client.post(url, json=payload, headers=_auth_headers(token))
                body = await egress.read_body_capped(resp, max_bytes=8 * 1024 * 1024)
        except Exception as e:
            logger.debug("fleet command %s via node %s failed: %s", command, row["id"], e)
            continue
        try:
            data = json.loads(body)
        except ValueError:
            data = {"raw": body[:200].decode(errors="replace")}
        last_status, last_body = resp.status_code, data
        # Break only on a REAL success: the gateway answers HTTP 200 with
        # outcome=error when the command failed on that row — a non-master
        # row first in cold-cache order (local-only commands like pool_ping
        # only work on the master) must not end the search. Keep trying;
        # the last result stands if no row succeeds.
        if resp.status_code == 200 and not (
            isinstance(data, dict) and data.get("outcome") == "error"
        ):
            break
    return last_status, last_body


@router.post("/fleet-command")
async def fleet_command(request: Request, user: dict = Depends(require_auth)):
    """POST /api/nodes/fleet-command {command, target?} — issue an
    allowlisted gateway fleet command against a master row. pool_ping and
    worker_geo_refresh execute on the master itself; the others fan out
    over erpc from it. Every invocation is audited here AND in the
    gateway's own command ring."""
    try:
        body = await request.json()
    except ValueError:
        # json()/body() raise ValueError subclasses on malformed input; the
        # global JSONDecodeError handler covers the plain-parse case too.
        body = None
    if not isinstance(body, dict):
        raise HTTPException(
            400, detail={"error": {"code": "invalid", "message": "JSON object body required"}}
        )
    command = body.get("command")
    # Type first: an unhashable command (list/dict) against the frozenset
    # would TypeError into the 500 handler instead of this 400.
    if not isinstance(command, str) or command not in _FLEET_COMMANDS:
        # Rejections are audited too — the gateway ring only sees commands
        # that were dispatched, so this is the only trace of a probe.
        # Truncated: a hostile caller must not amplify DB writes.
        audit.log(
            "node.fleet_command",
            "fleet",
            f"rejected=unknown_command command={str(command)[:64]!r}",
        )
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "unknown_command",
                    "message": f"command must be one of {sorted(_FLEET_COMMANDS)}",
                }
            },
        )
    try:
        target = _validate_fleet_target(command, body.get("target"))
    except HTTPException:
        audit.log("node.fleet_command", "fleet", f"rejected=invalid_target command={command[:64]}")
        raise

    # Audit BEFORE dispatch: a no_nodes 409 or a DB failure below would
    # otherwise leave a fleet-wide mutation attempt with no trace (the
    # gateway ring only sees dispatched commands). target is validated and
    # rebuilt from known keys here, so logging it is safe.
    audit.log(
        "node.fleet_command",
        "fleet",
        f"attempt command={command} "
        f"target={json.dumps(target, sort_keys=True)[:512] if target else 'none'}",
    )
    last_status, last_body = await _issue_fleet_command(command, target)
    return _fleet_audit_tail(
        "node.fleet_command", command, target, last_status, last_body, fail_on_error=True
    )


@router.put("/workers/note")
async def set_worker_note(request: Request, user: dict = Depends(require_auth)):
    """Set the operator remark for a worker (keyed by Erlang long name,
    e.g. janus@worker.example.internal. Empty string clears it. Workers are
    sched-scraped, not registry rows — the note lives in the
    dashboard-owned worker_notes table and rides /api/nodes."""
    body = await request.json()
    node = body.get("node")
    note = body.get("note")
    if not isinstance(node, str) or not node or "@" not in node or len(node) > 253:
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "bad_request",
                    "message": "node must be a worker long name (janus@host)",
                }
            },
        )
    if not isinstance(note, str) or len(note) > 120:
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "bad_request",
                    "message": "note must be a string of at most 120 chars",
                }
            },
        )
    await database.execute(
        """
        INSERT INTO worker_notes (node, note, updated_at)
        VALUES ($1, $2, NOW())
        ON CONFLICT (node) DO UPDATE SET note = EXCLUDED.note, updated_at = NOW()
        """,
        node,
        note,
    )
    audit.log("node.worker_note", node, note or "(cleared)")
    return {"ok": True, "node": node, "note": note}


@router.get("/{node_id}/stats")
async def node_stats(node_id: int, user: dict = Depends(require_auth)):
    """Proxy to a specific node's /stats endpoint (live, not cached)."""
    row = await database.fetchrow(
        "SELECT stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE id = $1",
        node_id,
    )
    if not row:
        raise HTTPException(
            404, detail={"error": {"code": "not_found", "message": "node not found"}}
        )

    token = await _policy_token(row)
    if token is None:
        egress.note_skipped_no_token(f"node:{node_id}", row["stats_host"])
        return {
            "status": "stale_no_token",
            "checked_at": None,
            "error": "stats poll skipped by egress policy — no per-node token",
        }

    result = await poll_node(node_id, row["stats_host"], row["stats_port"], token)
    return result


@router.post("/{node_id}/workers/geo-refresh")
async def worker_geo_refresh(node_id: int, request: Request, user: dict = Depends(require_auth)):
    """Ask a worker to re-run its egress geo discovery NOW (fleet command
    worker_geo_refresh on the node's admin plane). The worker probes its
    layers (gw_echo / metadata / env / third_echo), then re-hellos
    immediately — the fresh region shows up in /stats/sched (and this
    page) within seconds instead of the next keepalive/discovery cycle."""
    body = await request.json()
    worker = body.get("worker")
    if not isinstance(worker, str) or "@" not in worker or len(worker) > 253:
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "bad_request",
                    "message": "worker must be a node name (janus@host)",
                }
            },
        )
    row = await database.fetchrow(
        "SELECT stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE id = $1",
        node_id,
    )
    if not row:
        raise HTTPException(
            404, detail={"error": {"code": "not_found", "message": "node not found"}}
        )
    token = await _policy_token(row)
    if token is None:
        egress.note_skipped_no_token(f"node:{node_id}", row["stats_host"])
        raise HTTPException(
            409,
            detail={"error": {"code": "no_token", "message": "egress policy: no per-node token"}},
        )
    url = stats_url(row["stats_host"], row["stats_port"], "/stats/fleet/command")
    payload = {
        "command": "worker_geo_refresh",
        "target": {"kind": "worker", "node": worker},
    }
    async with egress.pinned_async_client(
        row["stats_host"], timeout=10.0, verify=_tls_verify()
    ) as client:
        resp = await client.post(url, json=payload, headers={"authorization": f"Bearer {token}"})
    try:
        data = resp.json()
    except ValueError:
        data = {"raw": resp.text[:200]}
    audit.log("node.worker_geo_refresh", f"node:{node_id}", f"worker={worker}")
    if resp.status_code != 200:
        raise HTTPException(
            resp.status_code,
            detail={"error": {"code": "gateway_error", "message": data}},
        )
    return {"status": "requested", "worker": worker, "gateway": data}


@router.get("/{node_id}/metrics")
async def node_metrics(node_id: int, user: dict = Depends(require_auth)):
    """Proxy a node's prometheus /metrics exposition (live) through the
    egress-policy token resolution — smoke S.8 scrapes THIS, never the
    node directly (per-node tokens are write-only; the proxy is the
    only reader path that can resolve them)."""
    row = await database.fetchrow(
        "SELECT stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE id = $1",
        node_id,
    )
    if not row:
        raise HTTPException(
            404, detail={"error": {"code": "not_found", "message": "node not found"}}
        )

    token = await _policy_token(row)
    if token is None:
        egress.note_skipped_no_token(f"node:{node_id}", row["stats_host"])
        return Response(
            status_code=503,
            content="stats poll skipped by egress policy - no per-node token",
            media_type="text/plain",
        )

    url = stats_url(row["stats_host"], row["stats_port"], "/metrics")
    # H1: classify + pin the stats host at connect time; the metrics body
    # is streamed under the outbound byte cap (H4).
    client = egress.pinned_async_client(row["stats_host"], timeout=5.0, verify=_tls_verify())
    if client is None:
        return Response(
            status_code=502,
            content="metrics proxy error: stats_host failed the connect-time egress check",
            media_type="text/plain",
        )
    try:
        async with client, client.stream("GET", url, headers=_auth_headers(token)) as resp:
            body = await egress.read_body_capped(resp)
            return Response(
                status_code=resp.status_code,
                content=body,
                media_type=resp.headers.get("content-type", "text/plain"),
            )
    except egress.OutboundBodyTooLarge as e:
        return Response(
            status_code=502, content=f"metrics proxy error: {e}", media_type="text/plain"
        )
    except Exception as e:
        return Response(
            status_code=502, content=f"metrics proxy error: {e}", media_type="text/plain"
        )


@router.get("/{node_id}/sched")
async def node_sched(node_id: int, user: dict = Depends(require_auth)):
    """Proxy to a gateway's full /stats/sched JSON (Maintenance live strip).

    Callers must only use this for nodes whose cached /stats reports
    role=master — worker sched bodies omit master knob fields.
    """
    row = await database.fetchrow(
        "SELECT stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE id = $1",
        node_id,
    )
    if not row:
        raise HTTPException(
            404, detail={"error": {"code": "not_found", "message": "node not found"}}
        )

    token = await _policy_token(row)
    if token is None:
        egress.note_skipped_no_token(f"node:{node_id}", row["stats_host"])
        return {
            "ok": False,
            "error": "stats poll skipped by egress policy — no per-node token",
        }

    result = await poll_sched(row["stats_host"], row["stats_port"], token)
    if not result.get("ok"):
        return {"ok": False, "error": result.get("error") or "sched scrape failed"}
    return {"ok": True, "sched": result.get("body")}


@router.get("/{node_id}/logs")
async def node_logs(node_id: int, limit: int = 100, user: dict = Depends(require_auth)):
    """Proxy to a specific node's /stats/logs endpoint."""
    row = await database.fetchrow(
        "SELECT stats_host, stats_port, stats_token_ciphertext FROM gateway_nodes WHERE id = $1",
        node_id,
    )
    if not row:
        raise HTTPException(
            404, detail={"error": {"code": "not_found", "message": "node not found"}}
        )

    token = await _policy_token(row)
    if token is None:
        egress.note_skipped_no_token(f"node:{node_id}", row["stats_host"])
        return {"events": [], "skipped": "no_per_node_token"}

    url = stats_url(row["stats_host"], row["stats_port"], f"/stats/logs?limit={limit}")
    headers = {}
    if token:
        headers["authorization"] = f"Bearer {token}"

    # H1/H4: same connect-time classification + pin as the poller, and a
    # capped streamed read so a hostile node cannot balloon this process.
    client = egress.pinned_async_client(row["stats_host"], timeout=5.0, verify=_tls_verify())
    if client is None:
        raise HTTPException(
            502,
            detail={
                "error": {
                    "code": "egress_rejected",
                    "message": "stats_host failed the connect-time egress check",
                }
            },
        )
    try:
        async with client, client.stream("GET", url, headers=headers) as resp:
            body = await egress.read_body_capped(resp)
            if resp.status_code == 200:
                try:
                    return json.loads(body)
                except ValueError:
                    raise HTTPException(
                        502,
                        detail={
                            "error": {
                                "code": "invalid_upstream",
                                "message": "node returned a non-JSON logs body",
                            }
                        },
                    )
            raise HTTPException(
                resp.status_code,
                detail={
                    "error": {
                        "code": "upstream_error",
                        "message": body[:2000].decode("utf-8", "replace"),
                    }
                },
            )
    except egress.OutboundBodyTooLarge as e:
        raise HTTPException(
            502,
            detail={"error": {"code": "response_too_large", "message": str(e)}},
        )
