"""Auto-router settings (janus-auto) — dashboard-managed, hot-reloaded.

Stored in the shared `settings` table (key `auto_router`); every write
bumps the config generation so all gateway nodes pick it up on their
next poll (janus_config distributes it to janus_auto, DB keys override
sys.config defaults).

Reorder spec 2026-10-11 (Task 2): PUT /auto-router is the HUMAN write
entrypoint (D6a/D13) — it takes the reorder advisory lock (D34: busy =>
409 reorder_busy + Retry-After), stamps last_manual_edit_at, clears
pending + the reject counters, and audits actor='human'. The tiers
write paths are EXACTLY two (TF-A.22): this handler and the loop's
system_reorder_commit — no generic settings API mutates tiers. The
reorder knobs live in their OWN key (auto_router_reorder: enabled /
intervals / thresholds only, D7) so a knob flip can never smuggle a
tiers payload.
"""

import json
import logging
import re
from typing import Any
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, HTTPException, Request

from .. import audit, auto_reorder, auto_router_rules, database, egress, limits, nodes
from ..auth import require_auth
from ..config import config

router = APIRouter()
logger = logging.getLogger("janus.dashboard.settings")

LOCAL_JUDGE_DEFAULTS = {
    "endpoint": "http://127.0.0.1:8191",
    "artifact": "kev-0.8b",
    "artifact_url": None,
    "artifact_sha256": None,
    "timeout_ms": 800,
    "local_max_inflight": 8,
    "ensure_generation": 0,
}

LOCAL_JUDGE_KEYS = frozenset(LOCAL_JUDGE_DEFAULTS)
JUDGE_BACKENDS = frozenset({"off", "online", "local"})
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_ARTIFACT_URL_SUFFIXES = (
    ".aliyuncs.com",
    ".myqcloud.com",
    ".jdcloud.com",
    ".volces.com",
)

DEFAULTS = {
    "model": "janus-auto",
    "judge_backend": "off",
    "judge_model": None,
    "local_judge": dict(LOCAL_JUDGE_DEFAULTS),
    "tiers": {"fast": [], "big": [], "flagship": []},
    "default_tier": "fast",
    "fast_ctx_tokens": 8000,
    "big_ctx_tokens": 60000,
    "max_ctx_tokens": None,
    "judge_timeout_ms": 1500,
    "cache_ttl_sec": 300,
    "markers": ["ultrathink", "think harder"],
    # D11 / janus-auto same-tier next-name failover (gateway defaults off).
    "tier_failover_enabled": False,
    "tier_failover_max_names": 3,
}

# Distinct names attempted after Part C key exhaustion; matches gateway clamp.
_TIER_FAILOVER_MAX_NAMES_RANGE = (1, 8)

TIERS = ("fast", "big", "flagship")
INT_FIELDS = {
    "fast_ctx_tokens": 1,
    "big_ctx_tokens": 1,
    "max_ctx_tokens": 1,
    "judge_timeout_ms": 100,
    "cache_ttl_sec": 1,
}
LOCAL_JUDGE_INT_FIELDS = {
    # field: (minimum, maximum) — the upper bounds are deliberate (M2):
    # without them 10**15 passes validation and the generation bump pushes
    # it to every gateway.
    "timeout_ms": (100, 600_000),
    "local_max_inflight": (1, 1_024),
    "ensure_generation": (0, 2**31 - 1),
}


def _err(status: int, code: str, message: str) -> HTTPException:
    return HTTPException(status, detail={"error": {"code": code, "message": message}})


async def _stored() -> dict | None:
    """The auto_router row as a dict, or None when absent/corrupt.

    The column is JSONB, so a syntax error is impossible — the reachable
    corruption is a JSON SCALAR or ARRAY (`"x"`, `12`, `[1,2]`). That used
    to reach `{**DEFAULTS, **(stored or {})}` in `_merge_auto_config` and
    raise TypeError, i.e. a 500 on the Router page load. Treat it like the
    other corrupt settings rows: log loudly, serve defaults, and let the
    next PUT overwrite the row (the PUT path already guards with
    isinstance)."""
    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'auto_router'")
    if not row:
        return None
    stored = _parse_stored_json(row["value"], "auto_router")
    if stored is not None and not isinstance(stored, dict):
        logger.warning(
            "settings auto_router: stored value is %s, not a JSON object; "
            "serving defaults (a following PUT will overwrite the row)",
            type(stored).__name__,
        )
        return None
    return stored


def _parse_stored_json(raw, key: str):
    """Decode a settings-row blob. A corrupt row is LOGGED and treated as
    absent (defaults) instead of silently vanishing — L2: the old broad
    ``except Exception`` also swallowed driver/programming errors."""
    if not isinstance(raw, (str, bytes)):
        return raw
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError, UnicodeDecodeError):
        logger.warning(
            "settings %s: stored value is not valid JSON; serving defaults "
            "(the row is corrupt — a following PUT will overwrite it)",
            key,
        )
        return None


def _merge_auto_config(stored: dict | None) -> dict:
    """Stored row merged with defaults; compat absent judge_backend (§3)."""
    # Defence in depth for callers that hand in a non-dict by accident: the
    # merge must never raise for a stored value (see `_stored`).
    stored = stored if isinstance(stored, dict) else None
    cfg = {**DEFAULTS, **(stored or {})}
    raw_lj = (stored or {}).get("local_judge")
    if isinstance(raw_lj, dict):
        cfg["local_judge"] = {**LOCAL_JUDGE_DEFAULTS, **raw_lj}
    else:
        cfg["local_judge"] = dict(LOCAL_JUDGE_DEFAULTS)
    if stored is not None and "judge_backend" not in stored:
        cfg["judge_backend"] = "online" if cfg.get("judge_model") else "off"
    elif cfg.get("judge_backend") not in JUDGE_BACKENDS:
        cfg["judge_backend"] = "off"
    return cfg


def _canonical_loopback_endpoint(url: str) -> str | None:
    """LOCAL-JUDGE-SPEC §3: http loopback only; localhost → 127.0.0.1.

    The containerized master reaches its same-host judge (host-netns
    127.0.0.1:8191) through the compose bridge gateway (docker's
    172.16/12 private range). Same-host intent preserved: anything
    outside loopback + that range is still rejected."""
    if not isinstance(url, str) or not url.strip():
        return None
    try:
        parsed = urlparse(url.strip())
        port = parsed.port or 80
    except ValueError:
        return None
    if parsed.scheme != "http" or not parsed.hostname:
        return None
    host = parsed.hostname.lower()
    if host == "localhost":
        host = "127.0.0.1"
    bridge_gateway = False
    if host.startswith("172."):
        try:
            bridge_gateway = 16 <= int(host.split(".")[1]) <= 31
        except (IndexError, ValueError):
            bridge_gateway = False
    if host not in ("127.0.0.1", "::1") and not bridge_gateway:
        return None
    if host == "::1":
        return f"http://[::1]:{port}" if port != 80 else "http://[::1]"
    return f"http://{host}:{port}" if port != 80 else f"http://{host}"


def _artifact_url_allowed(url: str) -> bool:
    try:
        parsed = urlparse(url.strip())
    except Exception:
        return False
    if parsed.scheme != "https" or not parsed.hostname:
        return False
    host = parsed.hostname.lower()
    return any(host == suf[1:] or host.endswith(suf) for suf in _ARTIFACT_URL_SUFFIXES)


def _normalize_local_judge(raw: dict) -> dict:
    if not isinstance(raw, dict):
        raise _err(400, "invalid", "local_judge must be an object")
    if "cache_name" in raw:
        raise _err(400, "invalid", "local_judge.cache_name is derived; do not send it")
    unknown = set(raw) - LOCAL_JUDGE_KEYS
    if unknown:
        raise _err(400, "unknown_fields", f"unknown local_judge fields: {sorted(unknown)}")
    lj = {**LOCAL_JUDGE_DEFAULTS, **raw}
    endpoint = _canonical_loopback_endpoint(lj.get("endpoint") or "")
    if endpoint is None:
        raise _err(
            400,
            "invalid",
            "local_judge.endpoint must be http://127.0.0.1 or http://[::1] (localhost accepted)",
        )
    lj["endpoint"] = endpoint
    artifact = lj.get("artifact", LOCAL_JUDGE_DEFAULTS["artifact"])
    if not isinstance(artifact, str) or not artifact.strip():
        raise _err(400, "invalid", "local_judge.artifact must be a non-empty string")
    lj["artifact"] = artifact.strip()
    url = lj.get("artifact_url")
    if url is not None and url != "":
        if not isinstance(url, str) or not url.strip():
            raise _err(400, "invalid", "local_judge.artifact_url must be a URL or null")
        url = url.strip()
        if not _artifact_url_allowed(url):
            raise _err(400, "invalid", "local_judge.artifact_url host is not allowlisted")
        lj["artifact_url"] = url
    else:
        lj["artifact_url"] = None
    sha = lj.get("artifact_sha256")
    if sha is not None and sha != "":
        if not isinstance(sha, str) or not _SHA256_RE.match(sha.strip()):
            raise _err(400, "invalid", "local_judge.artifact_sha256 must be 64 hex chars or null")
        lj["artifact_sha256"] = sha.strip().lower()
    else:
        lj["artifact_sha256"] = None
    if lj["artifact_url"] and not lj["artifact_sha256"]:
        raise _err(400, "invalid", "local_judge.artifact_url requires artifact_sha256")
    for field, (minimum, maximum) in LOCAL_JUDGE_INT_FIELDS.items():
        v = lj.get(field, LOCAL_JUDGE_DEFAULTS[field])
        if not isinstance(v, int) or isinstance(v, bool) or not (minimum <= v <= maximum):
            raise _err(
                400,
                "invalid",
                f"local_judge.{field} must be an integer in [{minimum}, {maximum}]",
            )
        lj[field] = v
    return lj


async def _auto_live_snapshot() -> dict | None:
    """Readiness from the first healthy master /stats `auto` block (8090 read-only)."""
    rows = await database.fetch(
        "SELECT id, stats_host, stats_port, stats_token_ciphertext "
        "FROM gateway_nodes WHERE enabled = true ORDER BY id"
    )
    policy_on = await egress.egress_policy_on()
    for row in rows:
        token = egress.stats_token_for(
            row["stats_host"],
            row["stats_token_ciphertext"],
            config.stats_token,
            policy_on=policy_on,
        )
        if token is None and policy_on:
            continue
        stats = await nodes.poll_node(int(row["id"]), row["stats_host"], row["stats_port"], token)
        if stats.get("status") != "healthy" or stats.get("role") != "master":
            continue
        auto = stats.get("auto")
        if isinstance(auto, dict):
            return auto
    return None


@router.get("/auto-router")
async def get_auto_router(user: dict = Depends(require_auth)):
    stored = await _stored()
    # _merge_auto_config merges defaults so older DB rows gain new knobs
    # (e.g. D11 tier failover) without requiring a re-save before the SPA
    # can edit them — it is the single source of the response shape (L1:
    # the duplicate `config` merge here was dead code and has been
    # removed rather than allowed to drift).
    return {
        "source": "db" if stored is not None else "default",
        "config": _merge_auto_config(stored),
        "defaults": DEFAULTS,
        "live_snapshot": await _auto_live_snapshot(),
    }


@router.get("/auto-router/live")
async def get_auto_router_live(user: dict = Depends(require_auth)):
    """Live local-judge readiness only (no config) — the Router page
    polls this so the readiness pill refreshes without clobbering
    in-progress form edits, and the Probe button forces an immediate
    check. The snapshot is the master /stats `auto` block, itself fed
    by the gateway's 5s sidecar /healthz poll."""
    return {"live_snapshot": await _auto_live_snapshot()}


@router.put("/auto-router")
async def put_auto_router(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")

    unknown = set(body) - set(DEFAULTS)
    if unknown:
        raise _err(400, "unknown_fields", f"unknown fields: {sorted(unknown)}")

    # H1: a PARTIAL body must never silently revert live config. Merge
    # onto the STORED row (known keys only), not onto DEFAULTS — an
    # omitted tier/marker/judge knob keeps its live value and the
    # generation bump then propagates the real config, not a truncated
    # one. A body carrying every key is still a full replace.
    stored = await _stored()
    base = {k: v for k, v in stored.items() if k in DEFAULTS} if isinstance(stored, dict) else {}
    cfg = {**DEFAULTS, **base, **body}
    if isinstance(body.get("local_judge"), dict):
        stored_lj = base.get("local_judge")
        stored_lj = stored_lj if isinstance(stored_lj, dict) else {}
        cfg["local_judge"] = {
            **LOCAL_JUDGE_DEFAULTS,
            **{k: v for k, v in stored_lj.items() if k in LOCAL_JUDGE_KEYS},
            **body["local_judge"],
        }
    if isinstance(body.get("tiers"), dict):
        stored_tiers = base.get("tiers")
        stored_tiers = stored_tiers if isinstance(stored_tiers, dict) else {}
        cfg["tiers"] = {
            **DEFAULTS["tiers"],
            **{t: stored_tiers[t] for t in TIERS if t in stored_tiers},
            **body["tiers"],
        }

    model = cfg.get("model", DEFAULTS["model"])
    if not isinstance(model, str) or not model.strip():
        raise _err(400, "invalid", "model must be a non-empty string")
    cfg["model"] = model.strip()

    jm = cfg.get("judge_model", DEFAULTS["judge_model"])
    if jm is not None and (not isinstance(jm, str) or not jm.strip()):
        raise _err(400, "invalid", "judge_model must be a model name or null")
    cfg["judge_model"] = jm.strip() if isinstance(jm, str) else None

    backend = cfg.get("judge_backend", DEFAULTS["judge_backend"])
    if not isinstance(backend, str) or backend not in JUDGE_BACKENDS:
        raise _err(400, "invalid", f"judge_backend must be one of {sorted(JUDGE_BACKENDS)}")
    cfg["judge_backend"] = backend

    if cfg["judge_model"] is not None and cfg["judge_model"] == cfg["model"]:
        raise _err(
            400,
            "invalid",
            "judge_model cannot equal the virtual auto-router model name",
        )

    cfg["local_judge"] = _normalize_local_judge(cfg.get("local_judge", LOCAL_JUDGE_DEFAULTS))

    tiers = cfg.get("tiers", DEFAULTS["tiers"])
    if not isinstance(tiers, dict) or set(tiers) - set(TIERS):
        raise _err(400, "invalid", f"tiers keys must be a subset of {list(TIERS)}")
    norm_tiers = {}
    for t in TIERS:
        names = tiers.get(t, [])
        if not isinstance(names, list) or not all(isinstance(n, str) and n.strip() for n in names):
            raise _err(400, "invalid", f"tiers.{t} must be a list of model names")
        norm_tiers[t] = [n.strip() for n in names]

    # Tier members come from the ROUTER BINDINGS (the curated pool):
    # the adjudicator's availability probe only sees bound models, so a
    # tier listing an unbound name would silently never route.
    bound_rows = await database.fetch(
        "SELECT DISTINCT m.name FROM models m "
        "JOIN model_routes mr ON mr.model_id = m.id "
        "WHERE m.enabled = 1 AND mr.enabled = 1"
    )
    bound_names = {r["name"] for r in bound_rows}
    unknown_names = sorted(
        {n for names in norm_tiers.values() for n in names if n not in bound_names}
    )
    if unknown_names:
        raise _err(
            400,
            "not_bound",
            f"tier members must be bound on the Router page: {', '.join(unknown_names)}",
        )
    # Tiers are mutually exclusive (AGENTS.md): a model appears in exactly one
    # tier. Reject an explicit duplicate instead of silently dropping it — the
    # operator has to know which tier lost a model, and the gateway otherwise
    # normalises the same input with only a warning (review 02d H1).
    dupe_names = sorted(
        {
            n
            for t in TIERS
            for n in norm_tiers[t]
            if sum(1 for other in TIERS if n in norm_tiers[other]) > 1
        }
    )
    if dupe_names:
        raise _err(
            400,
            "invalid_tiers",
            "tier members must appear in exactly one tier "
            f"(fast > big > flagship): {', '.join(dupe_names)}",
        )
    cfg["tiers"] = norm_tiers

    rows = await database.fetch("SELECT DISTINCT name FROM provider_models")
    surface = {r["name"] for r in rows} | bound_names

    if backend == "online":
        if cfg["judge_model"] is None:
            raise _err(400, "invalid", "judge_model is required when judge_backend is online")
        if cfg["judge_model"] not in surface:
            raise _err(
                400,
                "unknown_models",
                f"judge_model not in catalog: {cfg['judge_model']}",
            )
    elif cfg["judge_model"] is not None and cfg["judge_model"] not in surface:
        raise _err(
            400,
            "unknown_models",
            f"judge_model not in catalog: {cfg['judge_model']}",
        )

    dt = cfg.get("default_tier", DEFAULTS["default_tier"])
    if dt not in TIERS:
        raise _err(400, "invalid", f"default_tier must be one of {list(TIERS)}")
    cfg["default_tier"] = dt

    for field, minimum in INT_FIELDS.items():
        v = cfg.get(field, DEFAULTS[field])
        if v is not None and (not isinstance(v, int) or v < minimum):
            raise _err(400, "invalid", f"{field} must be an integer >= {minimum} or null")
        cfg[field] = v

    markers = cfg.get("markers", DEFAULTS["markers"])
    if not isinstance(markers, list) or not all(isinstance(m, str) and m.strip() for m in markers):
        raise _err(400, "invalid", "markers must be a list of strings")
    cfg["markers"] = [m.strip() for m in markers]

    # D11: same-tier next-name failover knobs (gateway clamp [1, 8]).
    tfe = cfg.get("tier_failover_enabled", DEFAULTS["tier_failover_enabled"])
    if not isinstance(tfe, bool):
        raise _err(400, "invalid", "tier_failover_enabled must be a boolean")
    cfg["tier_failover_enabled"] = tfe

    tfn = cfg.get("tier_failover_max_names", DEFAULTS["tier_failover_max_names"])
    lo, hi = _TIER_FAILOVER_MAX_NAMES_RANGE
    if type(tfn) is not int or not (lo <= tfn <= hi):
        raise _err(
            400,
            "invalid",
            f"tier_failover_max_names must be an integer in [{lo}, {hi}]",
        )
    cfg["tier_failover_max_names"] = tfn

    # D6(a) HUMAN entrypoint: the reorder-loop lock (D34 409 when the
    # system path holds it), the settings write + generation bump, the
    # audit row (actor='human'), and the D30/D35 anchors —
    # last_manual_edit_at stamped (the loop holds off manual_hold_sec),
    # pending cleared, reject counters + quarantine cleared.
    try:
        result = await auto_reorder.human_commit(cfg)
    except auto_reorder.ReorderBusy:
        raise HTTPException(
            409,
            detail={
                "error": {
                    "code": "reorder_busy",
                    "message": "the reorder system path holds the write lock; retry in a second",
                }
            },
            headers={"Retry-After": "1"},
        )
    except ValueError as exc:
        # The shared validator (master-parity) can reject payloads the
        # handler's own bound-checks accept (e.g. a model literally
        # named janus-auto) — surface as a clean 400, never a bare
        # 500 that breaks the SPA error contract (ocr medium).
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "invalid_tiers",
                    "message": str(exc),
                }
            },
        )
    gen = result["generation"]
    audit.log(
        "settings.auto_router",
        "auto_router",
        f"gen={gen} tiers={sum(len(v) for v in norm_tiers.values())}",
    )
    return {"ok": True, "generation": gen, "config": cfg}


# ---------------------------------------------------------------------------
# Reorder loop knobs (reorder spec D7/D32) — a SEPARATE settings key
# carrying enabled/intervals/thresholds only (plus the dry_run boolean
# sibling). Ships enabled=false + dry_run=true; nothing auto-enables.
# The write bumps the generation so the master ingests it — the
# gateway-side ingest guard (Task 1) refuses `enabled=true` while
# migration 018 is unapplied, knob-only, surfaced as
# reorder_enabled_refused_total in /stats.
# ---------------------------------------------------------------------------


@router.get("/auto-router-reorder")
async def get_reorder_knobs(user: dict = Depends(require_auth)):
    knobs = await auto_reorder.read_knobs()
    row = await database.fetchrow(
        "SELECT value FROM settings WHERE key = $1", auto_reorder.REORDER_KNOBS_KEY
    )
    return {
        "source": "db" if row is not None else "default",
        "config": knobs,
        "defaults": dict(auto_router_rules.KNOB_DEFAULTS),
    }


@router.put("/auto-router-reorder")
async def put_reorder_knobs(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    # `confirmed` is the break-glass control flag, not a knob: peel it
    # off before the strict knob validator (which rejects unknown keys).
    knobs = {k: v for k, v in body.items() if k != "confirmed"}
    problems = auto_router_rules.knob_problems(knobs)
    if problems:
        raise _err(400, "invalid", "; ".join(problems))
    # M1: this write arms a live-routing mutation (tiers reorder), so it
    # takes the SAME audited break-glass pair as the egress-policy knob —
    # role + reason in the query string, confirmed=true in the body.
    gate = egress.require_breakglass(request, "settings.auto_router_reorder")
    egress.require_confirmed(body, "settings.auto_router_reorder")
    async with database.transaction() as tx:
        # M3: merge inside the transaction on a locked row so two
        # concurrent knob writes cannot lose one of the updates.
        row = await tx.fetchrow(
            "SELECT value FROM settings WHERE key = $1 FOR UPDATE",
            auto_reorder.REORDER_KNOBS_KEY,
        )
        current = auto_router_rules.normalize_knobs(
            _parse_stored_json(row["value"], auto_reorder.REORDER_KNOBS_KEY) if row else None
        )
        cfg = {**current, **knobs}
        payload = json.dumps(cfg, ensure_ascii=False)
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            auto_reorder.REORDER_KNOBS_KEY,
            payload,
        )
        gen = await database.bump_generation(tx)
    audit.log(
        "settings.auto_router_reorder",
        auto_reorder.REORDER_KNOBS_KEY,
        f"role={gate['role']} reason={gate['reason']} gen={gen} {knobs}",
    )
    return {"config": cfg, "generation": gen}


@router.get("/auto-router/reorder-state")
async def get_reorder_state(user: dict = Depends(require_auth)):
    """D32 observability surface: tiers, pending (+age), lease,
    quarantine, skip_reason counters, dry-run/warm-up state, the
    leader-gateway mirror (usage_attempt_rows / refused counter / geo
    mismatch gauges passthrough) and the recent audit tail."""
    return await auto_reorder.reorder_state_payload()


@router.post("/auto-router/reorder-tick")
async def post_reorder_tick(user: dict = Depends(require_auth)):
    """Drive ONE reorder tick now (same code path as the loop's own
    interval tick; every knob/gate still applies — disabled knobs make
    it a no-op). Operator/diagnostics surface; the e2e gate drives
    deterministic ticks through it."""
    return await auto_reorder.tick_once(trigger="api")


# ---------------------------------------------------------------------------
# Modality knobs (spec M1.0c): one boolean per modality, default OFF —
# flipping a knob is the operator's explicit act after gate+smoke.
# Same flow as auto-router: settings row + generation bump; gateways
# hot-reload via {janus, modality_cfg} persistent_term.
# ---------------------------------------------------------------------------
_MODALITIES = ("image", "tts", "asr", "video", "computer", "embedding")
_TRANSLATE_KEYS = ("tools", "responses")


async def _generic_settings(key: str, defaults: dict) -> dict:
    row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", key)
    stored = _parse_stored_json(row["value"], key) if row else None
    cfg = dict(defaults)
    if isinstance(stored, dict):
        for k in defaults:
            if isinstance(stored.get(k), bool):
                cfg[k] = stored[k]
    return {"source": "db" if stored is not None else "default", "config": cfg}


@router.get("/translate")
async def get_translate(user: dict = Depends(require_auth)):
    return await _generic_settings("translate", {k: False for k in _TRANSLATE_KEYS})


@router.put("/translate")
async def put_translate(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be an object of boolean knobs")
    unknown = set(body) - set(_TRANSLATE_KEYS)
    if unknown:
        raise _err(400, "invalid", f"unknown knobs: {sorted(unknown)}")
    for k, v in body.items():
        if not isinstance(v, bool):
            raise _err(400, "invalid", f"{k} must be a boolean")
    async with database.transaction() as tx:
        # M3: the merge baseline is read on the SAME connection inside the
        # transaction, under a row lock (concurrent PUTs cannot lose one).
        row = await tx.fetchrow("SELECT value FROM settings WHERE key = 'translate' FOR UPDATE")
        current = {k: False for k in _TRANSLATE_KEYS}
        stored = _parse_stored_json(row["value"], "translate") if row else None
        if isinstance(stored, dict):
            for k in _TRANSLATE_KEYS:
                if isinstance(stored.get(k), bool):
                    current[k] = stored[k]
        cfg = {**current, **body}
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ('translate', $1) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            json.dumps(cfg),
        )
        gen = await database.bump_generation(tx)
    audit.log("settings.translate", "translate", f"gen={gen} {body}")
    return {"config": cfg, "generation": gen}


_MODAL_DEFAULTS = {m: False for m in _MODALITIES}

_CAP_KEYS = frozenset({"vision", "reasoning", "tools", "file_input", "image_gen"})


@router.get("/model-capabilities")
async def get_model_capabilities(user: dict = Depends(require_auth)):
    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'model_capabilities'")
    stored = _parse_stored_json(row["value"], "model_capabilities") if row else None
    return {
        "source": "db" if isinstance(stored, dict) else "default",
        "capabilities": stored if isinstance(stored, dict) else {},
    }


@router.put("/model-capabilities")
async def put_model_capabilities(request: Request, user: dict = Depends(require_auth)):
    """Merge one public model name's capability flags into the
    model_capabilities settings map ({name: {vision: bool, ...}}). The
    janus-auto vision constraint reads this key. A name whose flags are
    all false is dropped from the map (an all-false entry is
    indistinguishable from absent but noisier)."""
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    name = body.get("name")
    caps = body.get("capabilities")
    if not isinstance(name, str) or not name.strip():
        raise _err(400, "invalid", "name required")
    name = name.strip()
    if not isinstance(caps, dict):
        raise _err(400, "invalid", "capabilities must be an object")
    unknown = set(caps) - _CAP_KEYS
    if unknown:
        raise _err(400, "unknown_fields", f"unknown capability keys: {sorted(unknown)}")
    for k, v in caps.items():
        if not isinstance(v, bool):
            raise _err(400, "invalid", f"{k} must be a boolean")

    async with database.transaction() as tx:
        row = await tx.fetchrow(
            "SELECT value FROM settings WHERE key = 'model_capabilities' FOR UPDATE"
        )
        stored = _parse_stored_json(row["value"], "model_capabilities") if row else None
        current = stored if isinstance(stored, dict) else {}
        merged = dict(current)
        if any(caps.values()):
            merged[name] = caps
        else:
            merged.pop(name, None)
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ('model_capabilities', $1) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            json.dumps(merged),
        )
        gen = await database.bump_generation(tx)
    audit.log("settings.model_capabilities", name, f"gen={gen} {caps}")
    return {"ok": True, "generation": gen, "capabilities": merged}


# Curated token-limit keys. The accepted spellings come from app/limits.py
# (LIMIT_FIELDS) — the layer definition the coverage view and the gateway
# catalog already use — so the API can never drift from what is reported.
# `context_window` is the long-open gap this closes: it was rejected before,
# so a window curations could not be expressed at all.
_LIMIT_KEYS = frozenset(limits.LIMIT_FIELDS)
_LIMIT_MAX = 100_000_000
_BULK_MODES = ("dry_run", "merge", "replace")
# Bounded name sample in the bulk audit row (never the whole paste).
_BULK_AUDIT_SAMPLE = 8


def _limit_value_error(value: Any) -> str | None:
    """None for a valid curated limit (positive int <= _LIMIT_MAX) or an
    explicit ``null`` clear; otherwise the reason the value is rejected."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        return "must be a positive integer or null"
    if value <= 0 or value > _LIMIT_MAX:
        return f"must be a positive integer <= {_LIMIT_MAX}"
    return None


def _clean_limits_entry(
    name: str, entry: dict, *, strict: bool
) -> tuple[dict[str, int | None] | None, str | None]:
    """Validate one name's curated patch and canonicalize its window key.

    ``strict`` (the single-name PUT) raises a 400 naming the offending
    name+key; otherwise (bulk) the name is returned as a per-name reject so
    the valid entries of the same request still apply.
    """
    cleaned: dict[str, int | None] = {}
    for key, value in entry.items():
        reason = _limit_value_error(value)
        if reason is not None:
            if strict:
                raise _err(400, "invalid", f"{name}.{key} {reason}")
            return None, f"{key} {reason}"
        cleaned[key] = value
    return _canonical_window(cleaned), None


def _canonical_window(patch: dict) -> dict:
    """Collapse the window dimension onto its one canonical key.

    ``context_length`` and ``context_window`` are ONE dimension with ONE stored
    slot: the canonical ``context_length`` — what the gateway's
    ``canonical_ctx/1`` prefers and what its ``/v1/models`` actually emits. A
    curated ``context_window`` on its own is stored but NOT honoured by the data
    plane, so either spelling on input lands in ``context_length``; an explicit
    ``context_length`` wins when both are sent, and a ``null`` from either
    spelling clears the dimension.
    """
    out = dict(patch)
    if "context_window" in out:
        window = out.pop("context_window")
        if "context_length" not in patch:
            out["context_length"] = window
    return out


def _canonical_entry(entry: Any) -> dict:
    """The canonical stored form of one entry (positive ints, one window slot).

    Also migrates a legacy entry that carries ``context_window`` — with or
    without its twin — onto the canonical ``context_length`` slot, keeping the
    value the gateway already prefers when both were present.
    """
    out = {k: v for k, v in entry.items() if k in _LIMIT_KEYS and v is not None}
    if "context_window" in out:
        window = out.pop("context_window")
        if "context_length" not in out:
            out["context_length"] = window
    return out


def _merge_entry(cur_entry: Any, patch: dict, mode: str) -> dict:
    """The entry a name would hold after this patch, in canonical stored form.

    ``merge`` keeps the other keys of that name; ``replace`` makes the body
    the whole entry (absent/``null`` keys are cleared). ``null`` always clears.
    """
    base = dict(cur_entry) if mode == "merge" and isinstance(cur_entry, dict) else {}
    return _canonical_entry({**base, **patch})


def _limit_dims(entry: Any) -> dict:
    """One entry's effective curated window/output in the frozen diff shape.

    Uses the canonical picks (``context_length`` first for the window) so a
    ``context_length`` curation is visible under ``context_window`` — the same
    value the coverage view's curated layer reports. ``context_window`` and
    ``max_output_tokens`` are the frozen response keys.
    """
    flat = limits.limit_fields(entry or {})
    return {
        "context_window": limits.canonical_pick(flat, limits.WINDOW_CANONICAL),
        "max_output_tokens": limits.canonical_pick(flat, limits.OUTPUT_CANONICAL),
    }


async def _limit_universe(db: Any) -> set[str]:
    """The catalog universe curation may write to (``app/limits.py``).

    Same set ``GET /model-limits/coverage`` reports: ``models`` rows ∪ current
    ``model_limits`` keys ∪ enabled listing names. A name outside it is a typo
    and is refused instead of becoming a phantom entry.
    """
    model_rows = await db.fetch("SELECT name FROM models")
    listing_rows = await db.fetch("SELECT name, enabled FROM provider_models WHERE enabled = 1")
    row = await db.fetchrow("SELECT value FROM settings WHERE key = 'model_limits'")
    stored = _parse_stored_json(row["value"], "model_limits") if row else None
    return limits.universe_names(
        models=model_rows,
        listings=listing_rows,
        curated=stored if isinstance(stored, dict) else {},
    )


@router.get("/model-limits")
async def get_model_limits(user: dict = Depends(require_auth)):
    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'model_limits'")
    stored = _parse_stored_json(row["value"], "model_limits") if row else None
    return {
        "source": "db" if isinstance(stored, dict) else "default",
        "limits": stored if isinstance(stored, dict) else {},
    }


@router.get("/model-limits/coverage")
async def get_model_limits_coverage(user: dict = Depends(require_auth)):
    """Read-only coverage report: which names are compaction-ready, what is
    missing, and which layer supplied each dimension.

    Precedence curated > route_min > listing > snapshot, with the layer rules
    mirroring the gateway catalog (see ``app/limits.py``). This handler performs
    NO writes, logs NO audit row and does NOT bump the config generation — it is
    a pure projection of `models`, `model_routes`, `provider_models`,
    `providers` and the `model_limits` / `models_dev` / `auto_router` settings.
    """
    model_rows = await database.fetch("SELECT id, name FROM models")
    route_rows = await database.fetch(
        "SELECT model_id, provider_id, upstream_model_id, enabled FROM model_routes"
    )
    listing_rows = await database.fetch(
        "SELECT provider_id, name, enabled, meta FROM provider_models"
    )
    provider_rows = await database.fetch("SELECT id, name, enabled FROM providers")
    setting_rows = await database.fetch(
        "SELECT key, value FROM settings WHERE key IN ('model_limits', 'models_dev', 'auto_router')"
    )
    stored = {r["key"]: _parse_stored_json(r["value"], r["key"]) for r in setting_rows}
    auto_cfg = stored.get("auto_router")
    tiers = auto_cfg.get("tiers") if isinstance(auto_cfg, dict) else None

    return limits.build_coverage(
        models=model_rows,
        routes=route_rows,
        listings=listing_rows,
        providers=provider_rows,
        curated=stored.get("model_limits"),
        snapshot=stored.get("models_dev"),
        tiers=tiers if isinstance(tiers, dict) else {},
    )


@router.put("/model-limits")
async def put_model_limits(request: Request, user: dict = Depends(require_auth)):
    """Merge one public model name's curated token limits into the
    ``model_limits`` settings map.

    Accepted per-name keys: ``context_length`` | ``context_window`` |
    ``max_output_tokens`` (``app/limits.py`` LIMIT_FIELDS). A ``null`` value
    clears that key; a value is a positive int <= 100_000_000; any other key or
    an out-of-range value is a 400 naming the offending name+key. The name must
    exist in the catalog universe (``models`` rows ∪ current curated keys ∪
    enabled listing names), otherwise 400 — a typo must not create a phantom
    entry.

    ``context_length`` and ``context_window`` are ONE dimension held in the
    canonical ``context_length`` slot (``_canonical_window``): either spelling
    is accepted, an explicit ``context_length`` wins when both are sent, and a
    ``null`` from either spelling clears it. The response reports that dimension
    as ``context_window``.

    An empty body ``{}`` and a patch that changes nothing are both documented
    no-ops: no write, no audit row and no generation bump. Curated limits win
    over provider catalog metadata and the models.dev snapshot in the gateway
    catalog.
    """
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")

    async def _no_op() -> dict:
        """The documented no-op response: nothing written, nothing bumped."""
        row = await database.fetchrow("SELECT value FROM settings WHERE key = 'model_limits'")
        stored = _parse_stored_json(row["value"], "model_limits") if row else None
        return {
            "ok": True,
            "no_op": True,
            "generation": await database.current_generation(),
            "limits": stored if isinstance(stored, dict) else {},
        }

    if not body:
        return await _no_op()
    name = body.get("name")
    raw_limits = body.get("limits")
    if not isinstance(name, str) or not name.strip():
        raise _err(400, "invalid", "name required")
    name = name.strip()
    if not isinstance(raw_limits, dict):
        raise _err(400, "invalid", "limits must be an object")
    if not raw_limits:
        return await _no_op()
    unknown = set(raw_limits) - _LIMIT_KEYS
    if unknown:
        raise _err(400, "unknown_fields", f"{name}: unknown limit keys {sorted(unknown)}")
    cleaned, reject = _clean_limits_entry(name, raw_limits, strict=True)
    if cleaned is None:  # strict=True raises instead; kept for type narrowing
        raise _err(400, "invalid", f"{name}: {reject}")

    if name not in await _limit_universe(database):
        raise _err(400, "unknown_name", f"unknown model name: {name}")

    async with database.transaction() as tx:
        row = await tx.fetchrow("SELECT value FROM settings WHERE key = 'model_limits' FOR UPDATE")
        stored = _parse_stored_json(row["value"], "model_limits") if row else None
        current = stored if isinstance(stored, dict) else {}
        before = _limit_dims(current.get(name))
        entry = _merge_entry(current.get(name), cleaned, "merge")
        merged = dict(current)
        if entry:
            merged[name] = entry
        else:
            merged.pop(name, None)
        # Change detection is at the DIMENSION level (window/output values), so
        # a call that alters no effective value — including re-sending the same
        # number under the other window spelling — writes and bumps nothing.
        if before == _limit_dims(merged.get(name)):
            gen: int | None = None
        else:
            await tx.execute(
                "INSERT INTO settings (key, value) VALUES ('model_limits', $1) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
                json.dumps(merged),
            )
            gen = await database.bump_generation(tx)
    if gen is None:
        return await _no_op()
    audit.log("settings.model_limits", name, f"gen={gen} {cleaned}")
    return {"ok": True, "generation": gen, "limits": merged}


@router.post("/model-limits/bulk")
async def post_model_limits_bulk(request: Request, user: dict = Depends(require_auth)):
    """Preview or apply curated token limits for many names at once.

    Body: ``{"entries": {"<name>": {"context_window": int|null,
    "max_output_tokens": int|null}}, "mode": "dry_run"|"merge"|"replace"}`` —
    ``mode`` defaults to ``dry_run``. ``merge`` applies only the keys present
    per name and leaves that entry's other keys alone; ``replace`` makes the
    body fully define each named entry (absent/``null`` keys are cleared);
    ``dry_run`` writes nothing at all.

    A malformed body rejects the whole request (400, no partial write). A name
    outside the catalog universe or a value out of range is reported per name
    in ``rejected`` while the valid entries still apply. ``context_length`` and
    ``context_window`` are one dimension written to the canonical
    ``context_length`` slot (``_canonical_window``) but always reported as
    ``context_window`` in ``diff``. ``ready_before`` /
    ``ready_after`` come from ``app/limits.build_coverage`` — the same rules
    ``GET /model-limits/coverage`` reports — so a preview can never promise a
    readiness the coverage view would not show. ``diff[...].before/after`` carry
    each entry's *effective* curated window/output (the canonical pick, so a
    ``context_length`` curation is visible in ``context_window``).

    When and only when something actually changed: one settings write, exactly
    one audit row (counts plus a bounded name sample) and exactly one generation
    bump. ``dry_run`` and a no-change request write nothing and bump nothing.
    """
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    mode = body.get("mode", "dry_run")
    if not isinstance(mode, str) or mode not in _BULK_MODES:
        raise _err(400, "invalid", f"mode must be one of {list(_BULK_MODES)}")
    raw_entries = body.get("entries")
    if not isinstance(raw_entries, dict):
        raise _err(400, "invalid", "entries must be an object")

    # Structural validation first: anything not of the frozen shape rejects the
    # whole request, so a typo can never half-apply a pasted batch.
    patches: dict[str, dict] = {}
    for raw_name, raw_entry in raw_entries.items():
        if not isinstance(raw_name, str) or not raw_name.strip():
            raise _err(400, "invalid", "entry names must be non-empty strings")
        name = raw_name.strip()
        if not isinstance(raw_entry, dict):
            raise _err(400, "invalid", f"{name}: entry must be an object")
        unknown = set(raw_entry) - _LIMIT_KEYS
        if unknown:
            raise _err(400, "unknown_fields", f"{name}: unknown limit keys {sorted(unknown)}")
        patches[name] = raw_entry

    universe = await _limit_universe(database)
    rejected: list[dict] = []
    valid: dict[str, dict] = {}
    for name in sorted(patches):
        if name not in universe:
            rejected.append({"name": name, "reason": "unknown model name"})
            continue
        cleaned, reason = _clean_limits_entry(name, patches[name], strict=False)
        if cleaned is None:
            rejected.append({"name": name, "reason": reason or "invalid value"})
            continue
        valid[name] = cleaned

    async with database.transaction() as tx:
        row = await tx.fetchrow("SELECT value FROM settings WHERE key = 'model_limits' FOR UPDATE")
        stored = _parse_stored_json(row["value"], "model_limits") if row else None
        current = stored if isinstance(stored, dict) else {}

        after = dict(current)
        applied = cleared = unchanged = 0
        for name in sorted(valid):
            cur_entry = current.get(name)
            before = _limit_dims(cur_entry)
            entry = _merge_entry(cur_entry, valid[name], mode)
            if before == _limit_dims(entry):
                unchanged += 1
            elif entry:
                after[name] = entry
                applied += 1
            else:
                after.pop(name, None)
                cleared += 1

        # ready_before/ready_after via the coverage view's own rules.
        model_rows = await database.fetch("SELECT id, name FROM models")
        route_rows = await database.fetch(
            "SELECT model_id, provider_id, upstream_model_id, enabled FROM model_routes"
        )
        listing_rows = await database.fetch(
            "SELECT provider_id, name, enabled, meta FROM provider_models"
        )
        provider_rows = await database.fetch("SELECT id, name, enabled FROM providers")
        setting_rows = await database.fetch(
            "SELECT key, value FROM settings WHERE key IN ('models_dev', 'auto_router')"
        )
        other = {r["key"]: _parse_stored_json(r["value"], r["key"]) for r in setting_rows}
        auto_cfg = other.get("auto_router")
        tiers = auto_cfg.get("tiers") if isinstance(auto_cfg, dict) else None
        coverage: dict[str, dict] = {}
        for label, curated_now in (("before", current), ("after", after)):
            coverage[label] = limits.build_coverage(
                models=model_rows,
                routes=route_rows,
                listings=listing_rows,
                providers=provider_rows,
                curated=curated_now,
                snapshot=other.get("models_dev"),
                tiers=tiers if isinstance(tiers, dict) else {},
            )
        status = {
            label: {e["name"]: e["status"] for e in cov["entries"]}
            for label, cov in coverage.items()
        }
        diff = [
            {
                "name": name,
                "before": _limit_dims(current.get(name)),
                "after": _limit_dims(after.get(name)),
                "status_before": status["before"].get(name),
                "status_after": status["after"].get(name),
            }
            for name in sorted(valid)
        ]

        gen: int | None = None
        if mode != "dry_run" and (applied or cleared):
            await tx.execute(
                "INSERT INTO settings (key, value) VALUES ('model_limits', $1) "
                "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
                json.dumps(after),
            )
            gen = await database.bump_generation(tx)

    if gen is not None:
        audit.log(
            "settings.model_limits",
            "bulk",
            f"gen={gen} mode={mode} applied={applied} cleared={cleared} "
            f"unchanged={unchanged} rejected={len(rejected)} "
            f"sample={sorted(valid)[:_BULK_AUDIT_SAMPLE]}",
        )

    return {
        "ok": True,
        "mode": mode,
        "applied": applied,
        "cleared": cleared,
        "unchanged": unchanged,
        "rejected": rejected,
        "ready_before": coverage["before"]["summary"]["ready"],
        "ready_after": coverage["after"]["summary"]["ready"],
        "diff": diff,
    }


@router.get("/modality")
async def get_modality(user: dict = Depends(require_auth)):
    row = await database.fetchrow("SELECT value FROM settings WHERE key = 'modality'")
    stored = _parse_stored_json(row["value"], "modality") if row else None
    cfg = dict(_MODAL_DEFAULTS)
    if isinstance(stored, dict):
        for m in _MODALITIES:
            if isinstance(stored.get(m), bool):
                cfg[m] = stored[m]
    return {"source": "db" if stored is not None else "default", "config": cfg}


@router.put("/modality")
async def put_modality(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be an object of modality booleans")
    unknown = set(body) - set(_MODALITIES)
    if unknown:
        raise _err(400, "invalid", f"unknown modalities: {sorted(unknown)}")
    for k, v in body.items():
        if not isinstance(v, bool):
            raise _err(400, "invalid", f"{k} must be a boolean")
    async with database.transaction() as tx:
        # M3: read + merge + write on one locked row.
        row = await tx.fetchrow("SELECT value FROM settings WHERE key = 'modality' FOR UPDATE")
        current = _parse_stored_json(row["value"], "modality") if row else None
        cfg = {**_MODAL_DEFAULTS, **(current if isinstance(current, dict) else {}), **body}
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ('modality', $1) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
            json.dumps(cfg),
        )
        gen = await database.bump_generation(tx)
    audit.log("settings.modality", "modality", f"gen={gen} {body}")
    return {"config": cfg, "generation": gen}


# ---------------------------------------------------------------------------
# v2.2 Part B: the egress-token-policy knob (settings key
# `dash.egress_policy`, JSON {"enabled": bool}). DASHBOARD-ONLY — the
# gateways never consume it, so no generation bump. Env
# JANUS_DASH_EGRESS_POLICY is only the first-boot default-off seed;
# the SETTING wins. Flipping ON runs the one-time retro-audit and is
# a break-glass write (operator role + confirm + reason, like
# allow_internal). While OFF the deploy log prints the dormancy banner
# and legacy stats_hosts keep receiving the global token (deliberate,
# warned, dated in the runbook).
# ---------------------------------------------------------------------------


@router.get("/egress-policy")
async def get_egress_policy(user: dict = Depends(require_auth)):
    enabled = await egress.egress_policy_on()
    return {
        "source": "db" if await _egress_row() is not None else "env",
        "enabled": enabled,
    }


async def _egress_row():
    return await database.fetchrow(
        "SELECT value FROM settings WHERE key = $1", egress.EGRESS_POLICY_KEY
    )


@router.put("/egress-policy")
async def put_egress_policy(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict) or not isinstance(body.get("enabled"), bool):
        raise _err(400, "invalid", "body must carry {enabled: boolean}")
    gate = egress.require_breakglass(request, "dash.egress_policy")
    egress.require_confirmed(body, "dash.egress_policy")
    before = await egress.egress_policy_on()
    payload = json.dumps({"enabled": body["enabled"]})
    await database.execute(
        "INSERT INTO settings (key, value) VALUES ($1, $2) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        egress.EGRESS_POLICY_KEY,
        payload,
    )
    audit.log(
        "settings.egress_policy",
        egress.EGRESS_POLICY_KEY,
        f"role={gate['role']} reason={gate['reason']} {before} -> {body['enabled']}",
    )
    reported: list[str] = []
    if body["enabled"] and not before:
        # One-time retro-audit on enable (Part B): non-conforming nodes
        # are REPORTED (warn, never block).
        try:
            reported = await egress.egress_policy_retro_audit()
            for line in reported:
                audit.log("settings.egress_policy_audit", egress.EGRESS_POLICY_KEY, line)
        except Exception:
            audit.log(
                "settings.egress_policy_audit", egress.EGRESS_POLICY_KEY, "audit query failed"
            )
    return {
        "enabled": body["enabled"],
        "retro_audit_reported": reported,
    }


# ---------------------------------------------------------------------------
# Maintenance hot knobs (spec 2026-10-12): sched, model_sync, fleet —
# full-replace JSON blobs; generation bump like translate/modality.
# ---------------------------------------------------------------------------

_SCHED_KEYS = ("health", "rtt", "geo", "probe", "probe_max_hourly", "unary_fallback")
_SCHED_DEFAULTS = {
    "health": False,
    "rtt": False,
    "geo": False,
    "probe": False,
    "probe_max_hourly": 10,
    "unary_fallback": False,
}
_MODEL_SYNC_DEFAULTS = {"interval_sec": 21600}
_FLEET_DEFAULTS = {"enabled": False}


async def _settings_blob(key: str, defaults: dict) -> dict:
    row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", key)
    stored = _parse_stored_json(row["value"], key) if row else None
    cfg = dict(defaults)
    if isinstance(stored, dict):
        for k in defaults:
            if k in stored:
                cfg[k] = stored[k]
    return {"source": "db" if stored is not None else "default", "config": cfg}


@router.get("/sched")
async def get_sched(user: dict = Depends(require_auth)):
    return await _settings_blob("sched", _SCHED_DEFAULTS)


@router.put("/sched")
async def put_sched(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    unknown = set(body) - set(_SCHED_KEYS)
    if unknown:
        raise _err(400, "invalid", f"unknown fields: {sorted(unknown)}")
    missing = set(_SCHED_KEYS) - set(body)
    if missing:
        raise _err(400, "invalid", f"missing fields (full replace): {sorted(missing)}")
    for k in ("health", "rtt", "geo", "probe", "unary_fallback"):
        if not isinstance(body[k], bool):
            raise _err(400, "invalid", f"{k} must be a boolean")
    pmh = body["probe_max_hourly"]
    # bool is a subclass of int — reject True/False explicitly. The upper
    # bound keeps a single write from removing the probe cap fleet-wide
    # (M2: the gateway uses the value verbatim, it does not clamp).
    if type(pmh) is not int or not (1 <= pmh <= 10_000):
        raise _err(400, "invalid", "probe_max_hourly must be an integer in [1, 10000]")
    cfg = {k: body[k] for k in _SCHED_KEYS}
    payload = json.dumps(cfg, ensure_ascii=False)
    async with database.transaction() as tx:
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ('sched', $1::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            payload,
        )
        gen = await database.bump_generation(tx)
    audit.log("settings.sched", "sched", f"gen={gen} {cfg}")
    return {"config": cfg, "generation": gen}


# ---------------------------------------------------------------------------
# Worker capacity overrides (worker-capacity-override spec Part 1): one shared
# settings key holding {worker long name: integer ceiling}. The gateway
# resolves override > hello-declared > infinity on both capacity read paths,
# so this row is the operator's only no-redeploy capacity knob.
#
# The key is an OBJECT shared by every node, so the write is a locked
# read-modify-write (same shape as the reorder-knob PUT): without FOR UPDATE
# two operators editing DIFFERENT nodes would each merge over their own stale
# copy and one ceiling would vanish.
# ---------------------------------------------------------------------------
_WORKER_CAPACITY_KEY = "worker_capacity"
# Explicit ceiling (M2 convention: the gateway uses the value verbatim, it
# does not clamp). Far above any real host's in-flight jobs, so a fat-finger
# (an extra zero, a pasted 2**31) cannot turn the soft cap into no cap.
_WORKER_CAPACITY_MAX = 10_000
# Erlang long name: `name@host`. Deliberately permissive on the host part —
# the live member list is NOT a valid check (it excludes drained-sticky and
# not-yet-hello'd workers, so a pre-hello override would be wrongly refused);
# an unknown name is the gateway's to report, at read time.
_WORKER_NODE_RE = re.compile(r"^[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+$")
_WORKER_NODE_MAX_LEN = 253


def _worker_capacity_map(raw) -> dict:
    """The stored override object, or {} when absent/corrupt/not an object.

    A corrupt row is served as empty rather than raising: the gateway treats
    an unreadable value the same way (override ignored, declared applies), so
    the UI must not disagree with the data plane."""
    stored = _parse_stored_json(raw, _WORKER_CAPACITY_KEY)
    if isinstance(stored, dict):
        return stored
    if stored is not None:
        logger.warning(
            "settings %s: stored value is %s, not a JSON object; serving an empty map "
            "(a following PUT will overwrite the row)",
            _WORKER_CAPACITY_KEY,
            type(stored).__name__,
        )
    return {}


@router.get("/worker-capacity")
async def get_worker_capacity(user: dict = Depends(require_auth)):
    row = await database.fetchrow(
        "SELECT value FROM settings WHERE key = $1", _WORKER_CAPACITY_KEY
    )
    cfg = _worker_capacity_map(row["value"]) if row else {}
    return {
        "source": "db" if row is not None else "default",
        "config": cfg,
        "max": _WORKER_CAPACITY_MAX,
    }


@router.put("/worker-capacity")
async def put_worker_capacity(request: Request, user: dict = Depends(require_auth)):
    """Set or clear ONE worker's capacity ceiling inside the shared map.

    `{node, capacity}` sets; `{node, capacity: null}` (or `capacity`
    omitted) clears — clearing DELETES the key, it never stores null, so
    the gateway's `maps:find` reads it as absent.
    """
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    unknown = set(body) - {"node", "capacity"}
    if unknown:
        raise _err(400, "invalid", f"unknown fields: {sorted(unknown)}")

    node = body.get("node")
    node = node.strip() if isinstance(node, str) else ""
    if not node or len(node) > _WORKER_NODE_MAX_LEN or not _WORKER_NODE_RE.match(node):
        raise _err(
            400,
            "invalid",
            "node must be an Erlang long name (janus@host), "
            f"at most {_WORKER_NODE_MAX_LEN} chars",
        )

    raw = body.get("capacity")
    if raw is None:
        capacity = None
    else:
        # bool is a subclass of int — reject True/False explicitly, matching
        # the sibling knob validators.
        if type(raw) is not int or not (1 <= raw <= _WORKER_CAPACITY_MAX):
            raise _err(
                400,
                "invalid",
                f"capacity must be an integer in [1, {_WORKER_CAPACITY_MAX}] "
                "or null to clear the override",
            )
        capacity = raw

    async with database.transaction() as tx:
        # Seed before locking: FOR UPDATE takes NO lock when the row does not
        # exist yet, and this key is created here (no migration seeds it). Two
        # first-time PUTs for DIFFERENT nodes would both read {}, and the
        # loser's ON CONFLICT DO UPDATE would replace the whole blob — the
        # exact lost ceiling the lock above is supposed to prevent. The
        # seeding INSERT conflicts inside the transaction, so the two
        # transactions serialise and the second one locks a committed row.
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ($1, '{}'::jsonb) "
            "ON CONFLICT (key) DO NOTHING",
            _WORKER_CAPACITY_KEY,
        )
        row = await tx.fetchrow(
            "SELECT value FROM settings WHERE key = $1 FOR UPDATE",
            _WORKER_CAPACITY_KEY,
        )
        merged = _worker_capacity_map(row["value"]) if row else {}
        if capacity is None:
            merged.pop(node, None)
        else:
            merged[node] = capacity
        payload = json.dumps(merged, ensure_ascii=False)
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            _WORKER_CAPACITY_KEY,
            payload,
        )
        gen = await database.bump_generation(tx)
    audit.log(
        "settings.worker_capacity",
        node,
        f"gen={gen} capacity={'(cleared)' if capacity is None else capacity}",
    )
    return {"config": merged, "node": node, "capacity": capacity, "generation": gen}


@router.get("/model_sync")
async def get_model_sync(user: dict = Depends(require_auth)):
    return await _settings_blob("model_sync", _MODEL_SYNC_DEFAULTS)


@router.put("/model_sync")
async def put_model_sync(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    if set(body) != {"interval_sec"}:
        extra = set(body) - {"interval_sec"}
        missing = {"interval_sec"} - set(body)
        if missing:
            raise _err(400, "invalid", "body must be {interval_sec} only (full replace)")
        raise _err(400, "invalid", f"unknown fields: {sorted(extra)}")
    sec = body["interval_sec"]
    if type(sec) is not int:
        raise _err(400, "invalid", "interval_sec must be an integer")
    if sec < 0:
        raise _err(400, "invalid", "interval_sec must be 0 (manual only) or >= 60")
    if 1 <= sec <= 59:
        raise _err(400, "invalid", "interval_sec must be 0 or >= 60 (values 1–59 are rejected)")
    cfg = {"interval_sec": sec}
    payload = json.dumps(cfg, ensure_ascii=False)
    async with database.transaction() as tx:
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ('model_sync', $1::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            payload,
        )
        gen = await database.bump_generation(tx)
    audit.log("settings.model_sync", "model_sync", f"gen={gen} interval_sec={sec}")
    return {"config": cfg, "generation": gen}


# MaxMind GeoLite2 credentials (Maintenance refresh). License key is
# stored encrypted (JSEC) — GET never returns the plaintext key.
_MAXMIND_KEY = "maxmind"


@router.get("/maxmind")
async def get_maxmind(user: dict = Depends(require_auth)):
    row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", _MAXMIND_KEY)
    stored = _parse_stored_json(row["value"], _MAXMIND_KEY) if row else None
    account_id = ""
    license_set = False
    if isinstance(stored, dict):
        account_id = str(stored.get("account_id") or "")
        license_set = bool(stored.get("license_key_ciphertext"))
    # Env fallback indicator (deploy / .env) — still no plaintext leak.
    if not account_id:
        from ..config import config as _cfg

        account_id = _cfg.maxmind_account_id or ""
    if not license_set:
        from ..config import config as _cfg

        license_set = bool(_cfg.maxmind_license_key)
    return {
        "source": "db"
        if isinstance(stored, dict)
        else ("env" if license_set or account_id else "default"),
        "config": {
            "account_id": account_id,
            "license_key_set": license_set,
        },
    }


@router.put("/maxmind")
async def put_maxmind(request: Request, user: dict = Depends(require_auth)):
    """Save MaxMind AccountID + LicenseKey. License is encrypted at rest.

    Body: {account_id: string, license_key?: string}. Omit or blank
    license_key to keep the previously stored key when one exists.
    """
    from ..config import config as _cfg
    from ..crypto import encrypt

    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    unknown = set(body) - {"account_id", "license_key"}
    if unknown:
        raise _err(400, "invalid", f"unknown fields: {sorted(unknown)}")
    if "account_id" not in body or not isinstance(body["account_id"], str):
        raise _err(400, "invalid", "account_id must be a string")
    account_id = body["account_id"].strip()
    if not account_id or not account_id.isdigit():
        raise _err(400, "invalid", "account_id must be a non-empty numeric MaxMind AccountID")

    row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", _MAXMIND_KEY)
    prev_ct = None
    if row:
        prev = _parse_stored_json(row["value"], _MAXMIND_KEY)
        if isinstance(prev, dict):
            prev_ct = prev.get("license_key_ciphertext")

    license_key = body.get("license_key")
    if license_key is None:
        license_key = ""
    if not isinstance(license_key, str):
        raise _err(400, "invalid", "license_key must be a string")
    license_key = license_key.strip()

    if license_key:
        ciphertext = encrypt(license_key.encode()).hex()
    elif prev_ct:
        ciphertext = prev_ct
    elif _cfg.maxmind_license_key:
        # Promote env key into DB on first dashboard save of account only.
        ciphertext = encrypt(_cfg.maxmind_license_key.encode()).hex()
    else:
        raise _err(400, "invalid", "license_key required (none stored yet)")

    cfg = {"account_id": account_id, "license_key_ciphertext": ciphertext}
    payload = json.dumps(cfg, ensure_ascii=False)
    async with database.transaction() as tx:
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            _MAXMIND_KEY,
            payload,
        )
        # No generation bump — MaxMind creds are dashboard-only (refresh
        # path); gateways do not read this settings key.
    audit.log("settings.maxmind", _MAXMIND_KEY, f"account_id={account_id} license_set=true")
    return {"config": {"account_id": account_id, "license_key_set": True}}


@router.get("/fleet")
async def get_fleet(user: dict = Depends(require_auth)):
    return await _settings_blob("fleet", _FLEET_DEFAULTS)


@router.put("/fleet")
async def put_fleet(request: Request, user: dict = Depends(require_auth)):
    body = await request.json()
    if not isinstance(body, dict):
        raise _err(400, "invalid", "body must be a JSON object")
    if set(body) != {"enabled"}:
        extra = set(body) - {"enabled"}
        missing = {"enabled"} - set(body)
        if missing:
            raise _err(400, "invalid", "body must be {enabled} only (full replace)")
        raise _err(400, "invalid", f"unknown fields: {sorted(extra)}")
    if not isinstance(body["enabled"], bool):
        raise _err(400, "invalid", "enabled must be a boolean")
    cfg = {"enabled": body["enabled"]}
    payload = json.dumps(cfg, ensure_ascii=False)
    async with database.transaction() as tx:
        await tx.execute(
            "INSERT INTO settings (key, value) VALUES ('fleet', $1::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
            payload,
        )
        gen = await database.bump_generation(tx)
    audit.log(
        "settings.fleet",
        "fleet",
        f"gen={gen} enabled={body['enabled']}; gateway recreate required to apply",
    )
    return {"config": cfg, "generation": gen}
