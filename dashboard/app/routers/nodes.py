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
    rows = await database.fetch(
        "SELECT id, name, stats_host, stats_port, stats_token_ciphertext, health_snapshot "
        "FROM gateway_nodes WHERE enabled ORDER BY id"
    )
    if not rows:
        raise HTTPException(
            409, detail={"error": {"code": "no_nodes", "message": "no enabled gateway nodes"}}
        )

    # Prefer a master row (it can reach workers via erpc); a stale/absent
    # health snapshot falls through to trying every enabled row in order.
    def _is_master(row) -> bool:
        snap = row["health_snapshot"]
        if isinstance(snap, str):
            try:
                snap = json.loads(snap)
            except ValueError:
                snap = {}
        return str((snap or {}).get("role") or "").lower() == "master"

    ordered = sorted(rows, key=lambda r: not _is_master(r))

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
                resp = await client.post(
                    url, json={"command": "runtime_snapshot"}, headers=_auth_headers(token)
                )
                body = await egress.read_body_capped(resp, max_bytes=8 * 1024 * 1024)
        except Exception as e:
            logger.debug("runtime snapshot via node %s failed: %s", row["id"], e)
            continue
        try:
            data = json.loads(body)
        except ValueError:
            data = {"raw": body[:200].decode(errors="replace")}
        last_status, last_body = resp.status_code, data
        if resp.status_code == 200:
            break

    _results = last_body.get("results") if isinstance(last_body, dict) else {}
    _n = len(_results) if isinstance(_results, dict) else 0
    _outcome = last_body.get("outcome") if isinstance(last_body, dict) else "?"
    audit.log("node.runtime_snapshot", "fleet", f"outcome={_outcome} nodes={_n}")
    if last_status != 200:
        raise HTTPException(
            last_status,
            detail={"error": {"code": "gateway_error", "message": last_body}},
        )
    return last_body


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
