"""Alert API (observability-depth Task 6 Step 5).

GET /api/alerts       — active (firing) states + last 100 events +
                        webhook_configured.
POST /api/alerts/test — insert a state=test event (record-only mode
                        inserts delivered=true; the response notes
                        webhook_configured). Audit-logged.

Both endpoints are JWT-gated via require_auth (house router pattern).
"""

import json
from typing import Any

from fastapi import APIRouter, Depends, Request

from .. import audit, database
from ..alerts import RULE_SEVERITY, jsonb_value
from ..auth import require_auth
from ..config import config

router = APIRouter()


def _event_out(r: Any) -> dict:
    return {
        "id": r["id"],
        "ts": r["ts"].isoformat() if r["ts"] is not None else None,
        "rule": r["rule"],
        "scope": r["scope"],
        "severity": r["severity"],
        "state": r["state"],
        "message": r["message"],
        "detail": jsonb_value(r["detail"]),
        "delivered": bool(r["delivered"]),
        "attempts": r["attempts"],
    }


@router.get("")
async def get_alerts(user: dict = Depends(require_auth)):
    # Active (firing) states; the message/severity come from the latest
    # firing event of the episode (alert_state itself carries neither).
    states = await database.fetch(
        "SELECT s.rule, s.scope, s.cycles, s.first_fired_at, s.last_eval_at, "
        "e.severity, e.message "
        "FROM alert_state s "
        "LEFT JOIN LATERAL ("
        "  SELECT severity, message FROM alert_events e "
        "  WHERE e.rule = s.rule AND e.scope = s.scope AND e.state = 'firing' "
        "  ORDER BY e.id DESC LIMIT 1"
        ") e ON TRUE "
        "WHERE s.state = 'firing' ORDER BY s.first_fired_at"
    )
    events = await database.fetch(
        "SELECT id, ts, rule, scope, severity, state, message, detail, "
        "delivered, attempts FROM alert_events ORDER BY id DESC LIMIT 100"
    )
    return {
        "states": [
            {
                "rule": r["rule"],
                "scope": r["scope"],
                "severity": r["severity"] or RULE_SEVERITY.get(r["rule"], "warning"),
                "message": r["message"] or "",
                "cycles": r["cycles"],
                "since": r["first_fired_at"].isoformat()
                if r["first_fired_at"] is not None
                else None,
                "last_eval_at": r["last_eval_at"].isoformat()
                if r["last_eval_at"] is not None
                else None,
            }
            for r in states
        ],
        "events": [_event_out(r) for r in events],
        "webhook_configured": config.alert_webhook_configured,
    }


@router.post("/test")
async def post_test_alert(request: Request, user: dict = Depends(require_auth)):
    message = "test alert from the dashboard"
    try:
        body = await request.json()
    except Exception:
        body = None
    if isinstance(body, dict) and isinstance(body.get("message"), str):
        candidate = body["message"].strip()
        if candidate:
            message = candidate

    configured = config.alert_webhook_configured
    row = await database.fetchrow(
        "INSERT INTO alert_events "
        "(rule, scope, severity, state, message, detail, delivered, next_retry_at) "
        "VALUES ('test', 'test', 'info', 'test', $1, $2::jsonb, $3, "
        "        CASE WHEN $3 THEN NULL ELSE NOW() END) "
        "RETURNING id, ts",
        message,
        json.dumps({"source": "api/alerts/test"}),
        not configured,
    )
    audit.log(
        "alerts.test",
        "test",
        f"event_id={row['id']} webhook_configured={configured}",
    )
    return {
        "ok": True,
        "event_id": row["id"],
        "webhook_configured": configured,
    }
