"""OpenAI Decisions protocol helpers (spec 2026-10-07 §4.3, §4.4).

Shared by the providers router (write gate D-write, grant confirms
D10) and the keys router (intersecting grant-writes D10). The write
gate fails CLOSED: creating or enabling an openai_decisions provider
requires EVERY enabled node in the dashboard registry (fresh
heartbeat <= 60 s) to advertise openai_decisions on its
GET :8080/readyz within 3 s per node. Unreachable/stale nodes block
with a per-node reason. Disabling (enabled=0 / listing disable) is
never gated — that is the kill switch. A break-glass override
(?force=1&role=...&reason=...) bypasses a failed gate and is audited.
"""

import asyncio
import time

import httpx
from fastapi import HTTPException, Request

from . import audit, database, nodes, probe_urls

DECISIONS_PROTOCOL = "openai_decisions"
# Registry heartbeat freshness window (spec §4.3) and per-node readyz
# timeout. Both fixed by the spec — not configurable on purpose.
HEARTBEAT_FRESH_SEC = 60
READYZ_TIMEOUT_SEC = 3.0


def _gate_err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


async def _check_node_readyz(client: httpx.AsyncClient, name: str, url: str) -> dict:
    """One node's readyz verdict: ok only on HTTP 200 + JSON protocols
    list containing openai_decisions. Every failure carries a reason
    for the block message / audit row."""
    try:
        resp = await client.get(url)
    except Exception as e:
        return {
            "node": name,
            "url": url,
            "ok": False,
            "reason": f"readyz unreachable: {type(e).__name__}",
        }
    if resp.status_code != 200:
        return {"node": name, "url": url, "ok": False, "reason": f"readyz HTTP {resp.status_code}"}
    try:
        data = resp.json()
    except Exception:
        return {"node": name, "url": url, "ok": False, "reason": "readyz returned non-JSON"}
    protocols = data.get("protocols") if isinstance(data, dict) else None
    if not isinstance(protocols, list):
        return {
            "node": name,
            "url": url,
            "ok": False,
            "reason": "readyz response missing protocols list",
        }
    if DECISIONS_PROTOCOL not in protocols:
        return {
            "node": name,
            "url": url,
            "ok": False,
            "reason": f"protocols {protocols} lack {DECISIONS_PROTOCOL}",
        }
    return {"node": name, "url": url, "ok": True, "reason": "advertised"}


async def evaluate_write_gate() -> dict:
    """Fan out the gate check over every ENABLED node in the dashboard
    registry. Returns {"ok": bool, "nodes": [verdict per node]}.

    Fail-closed rules: an empty registry blocks (nothing verifiable),
    a node without health data blocks (stale), a node whose heartbeat
    is older than 60 s blocks (stale), and every fresh node must answer
    readyz with the protocol advertisement.
    """
    rows = await database.fetch(
        "SELECT id, name, data_host, data_port FROM gateway_nodes WHERE enabled = true"
    )
    if not rows:
        return {
            "ok": False,
            "nodes": [
                {
                    "node": "(registry)",
                    "url": "",
                    "ok": False,
                    "reason": "dashboard registry has no enabled nodes — gateway "
                    "protocol advertisement cannot be verified (fail closed)",
                }
            ],
        }

    health = nodes.health_data()
    now = time.time()
    stale: list[dict] = []
    to_probe: list[tuple[dict, str]] = []
    for row in rows:
        url = nodes.stats_url(row["data_host"], row["data_port"], "/readyz")
        h = health.get(row["id"])
        if not h or "checked_at" not in h:
            stale.append(
                {
                    "node": row["name"],
                    "url": url,
                    "ok": False,
                    "reason": "no health data (node never polled)",
                }
            )
        elif now - h["checked_at"] > HEARTBEAT_FRESH_SEC:
            stale.append(
                {
                    "node": row["name"],
                    "url": url,
                    "ok": False,
                    "reason": f"heartbeat stale ({int(now - h['checked_at'])}s old, "
                    f"limit {HEARTBEAT_FRESH_SEC}s)",
                }
            )
        else:
            to_probe.append((row, url))

    verify = probe_urls.tls_verify()
    async with httpx.AsyncClient(timeout=READYZ_TIMEOUT_SEC, verify=verify) as client:
        probed = await asyncio.gather(
            *(_check_node_readyz(client, row["name"], url) for row, url in to_probe)
        )

    verdicts = stale + list(probed)
    return {"ok": all(v["ok"] for v in verdicts), "nodes": verdicts}


async def enforce_write_gate(request: Request, action: str) -> None:
    """Run the Decisions write gate for `action` ("provider.create:<name>"
    / "provider.enable:<id>:<name>"). Audits every decision (pass,
    block, break-glass override). Raises 409 decisions_gate_blocked on
    failure unless ?force=1&role=…&reason=… is supplied (audited
    override); a malformed override request is a 400, never a pass."""
    result = await evaluate_write_gate()
    if result["ok"]:
        audit.log(
            "decisions.gate",
            action,
            "pass nodes=" + ", ".join(f"{v['node']}:{v['reason']}" for v in result["nodes"]),
        )
        return

    blocked = "; ".join(f"{v['node']}: {v['reason']}" for v in result["nodes"] if not v["ok"])
    q = request.query_params
    force = (q.get("force") or "").lower() in ("1", "true", "yes")
    if force:
        role = (q.get("role") or "").strip()
        reason = (q.get("reason") or "").strip()
        if not role or not reason:
            raise _gate_err(
                400,
                "invalid",
                "force=1 requires non-empty role and reason query params "
                "(audited break-glass override)",
            )
        audit.log(
            "decisions.gate_override",
            action,
            f"role={role} reason={reason} blocked=[{blocked}]",
        )
        return

    audit.log("decisions.gate", action, f"blocked: {blocked}")
    raise _gate_err(
        409,
        "decisions_gate_blocked",
        "openai_decisions write gate failed (fail closed): " + blocked,
    )


def require_confirm(body: dict, what: str) -> None:
    """D10 grant-confirm flag: the request body must carry
    decisions_confirmed=true. Raises 409 decisions_confirm_required
    with the operator-facing billable warning."""
    if body.get("decisions_confirmed") is not True:
        raise _gate_err(
            409,
            "decisions_confirm_required",
            f"{what}: confirm the Decisions grant first — Decisions calls are "
            f"billed per decision by the upstream and are NOT covered by chat "
            f"token grants (send decisions_confirmed=true)",
        )


async def intersecting_decisions_models(model_names: list[str]) -> list[dict]:
    """Granted names that reach a Decisions provider: either a
    model_routes binding onto an openai_decisions provider, or a name
    shared with a listing on one (dual-face / unbound listing — spec
    §4.4 says the confirm may fire even when chat was already granted)."""
    if not model_names:
        return []
    rows = await database.fetch(
        """
        SELECT DISTINCT name, via FROM (
            SELECT m.name AS name, 'route'::text AS via
            FROM models m
            JOIN model_routes mr ON mr.model_id = m.id
            JOIN providers dp ON dp.id = mr.provider_id
            WHERE m.name = ANY($1::text[]) AND dp.protocol = $2
            UNION
            SELECT pm.name AS name, 'dual-face listing'::text AS via
            FROM provider_models pm
            JOIN providers dp ON dp.id = pm.provider_id
            WHERE pm.name = ANY($1::text[]) AND dp.protocol = $2
        ) t
        ORDER BY name, via
        """,
        model_names,
        DECISIONS_PROTOCOL,
    )
    # Prefer route over dual-face when both match the same name.
    by_name: dict[str, str] = {}
    for r in rows:
        prev = by_name.get(r["name"])
        if prev is None or (prev != "route" and r["via"] == "route"):
            by_name[r["name"]] = r["via"]
    return [{"name": n, "via": by_name[n]} for n in sorted(by_name)]
