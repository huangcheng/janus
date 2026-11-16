"""Model sync endpoints (manual trigger + status + interval config)."""

import asyncio
import json
import logging
import time
from datetime import datetime

import httpx
from fastapi import APIRouter, Depends, HTTPException

from .. import audit, dashscope_models, database, egress, entitlements, modelsdev, probe_urls
from ..auth import require_auth
from ..config import config
from ..crypto import decrypt
from ..decisions import DECISIONS_PROTOCOL

logger = logging.getLogger("janus.dashboard.sync")

router = APIRouter()

_sync_lock = asyncio.Lock()
_last_run: dict | None = None
_sync_task: asyncio.Task | None = None

# Boot catch-up (task-27). The scheduled loop used to sleep a full interval
# before its first run, so every restart reset the clock and a fleet that
# deploys more often than the interval never refreshed the listings or the
# models.dev snapshot (prod: snapshot 01:04:23Z while the container restarted
# at 13:21 and 13:40). Mirroring janus_model_sync:maybe_boot_sync/0 +
# catch_up_due/0: a process that boots with a stale or missing last run
# catches up shortly after start, and the decision is durable in `settings`
# so a healthy restart stays a no-op.
_SYNC_STATE_KEY = "sync_state"
_SYNC_CATCHUP_DELAY_SEC = 10.0


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _as_epoch(value) -> float | None:
    """Epoch seconds from a persisted stamp (number or ISO 8601 string)."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value) if value > 0 else None
    if isinstance(value, str) and value:
        try:
            return datetime.fromisoformat(value).timestamp()
        except ValueError:
            return None
    return None


def _state_epoch(state: dict, key: str) -> float | None:
    """Read `<key>_at` (epoch) or `<key>_iso` out of a persisted state dict."""
    return _as_epoch(state.get(f"{key}_at")) or _as_epoch(state.get(f"{key}_iso"))


def _age(now: float, at: float | None) -> float | None:
    return None if at is None else max(0.0, now - at)


def _state_iso(state: dict, key: str) -> str | None:
    """Human-readable stamp for `<key>`, from the ISO field or the epoch."""
    iso = state.get(f"{key}_iso")
    if isinstance(iso, str) and iso:
        return iso
    at = _state_epoch(state, key)
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)) if at else None


def _count(state: dict, key: str) -> int:
    value = state.get(key)
    return value if isinstance(value, int) and value >= 0 else 0


async def _read_sync_state() -> dict:
    """Persisted sync state; {} when absent or unreadable.

    Unreadable history biases to "no successful run", so the catch-up runs:
    a restart must never leave the task dormant (gateway: the
    `history_unavailable` branch).
    """
    try:
        row = await database.fetchrow("SELECT value FROM settings WHERE key = $1", _SYNC_STATE_KEY)
    except Exception as e:
        logger.warning("sync state read failed: %s", e)
        return {}
    value = (row or {}).get("value")
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            logger.warning("sync state is not valid JSON; treating it as absent")
            return {}
    return value if isinstance(value, dict) else {}


async def _write_sync_state(state: dict) -> None:
    """Upsert the durable sync state. No generation bump: this is scheduler
    bookkeeping, not gateway config."""
    try:
        await database.execute(
            "INSERT INTO settings (key, value) VALUES ($1, $2::jsonb) "
            "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
            _SYNC_STATE_KEY,
            json.dumps(state),
        )
    except Exception as e:
        logger.warning("sync state write failed: %s", e)


async def _record_attempt(source: str) -> None:
    """Stamp the attempt BEFORE the pass runs (the gateway's task_runs row is
    created at start), so a pass interrupted mid-way still counts as an
    attempt and cannot turn every restart into a sync."""
    state = await _read_sync_state()
    state.update(
        {
            "last_attempt_at": time.time(),
            "last_attempt_iso": _iso_now(),
            "last_source": source,
            "attempts": _count(state, "attempts") + 1,
        }
    )
    await _write_sync_state(state)


async def _record_success(source: str) -> None:
    """Stamp the completed pass. A pass that completed counts even when
    individual providers failed — otherwise one dead provider would make
    every restart sync again."""
    state = await _read_sync_state()
    state.update(
        {
            "last_ok_at": time.time(),
            "last_ok_iso": _iso_now(),
            "last_source": source,
            "runs": _count(state, "runs") + 1,
        }
    )
    await _write_sync_state(state)


async def catch_up_due() -> tuple[bool, dict]:
    """Should this process catch up? Mirror of janus_model_sync:catch_up_due/0.

    Due when there is no SUCCESSFUL pass inside the interval AND no attempt
    either. A manual-only interval (<= 0) is an explicit operator choice:
    never. Written as (due, detail) with the reason and the observed ages.
    """
    interval = config.sync_interval_sec
    if interval <= 0:
        return False, {"reason": "manual_only"}
    state = await _read_sync_state()
    now = time.time()
    ok_age = _age(now, _state_epoch(state, "last_ok"))
    attempt_age = _age(now, _state_epoch(state, "last_attempt"))
    detail = {
        "ok_age_sec": None if ok_age is None else round(ok_age),
        "last_attempt_age_sec": None if attempt_age is None else round(attempt_age),
    }
    stale = ok_age is None or ok_age >= interval
    attempted = attempt_age is not None and attempt_age < interval
    if stale and not attempted:
        return True, {"reason": "stale_success", **detail}
    return False, {"reason": "fresh", **detail}


def normalize_meta(item: dict) -> str | None:
    """Capture the provider's /models entry verbatim as listing meta.

    Pass-through, not curation: every field the upstream catalog
    reports (context windows, effort levels, modalities, protocols,
    display names, status, …) is kept under its own name. Only the
    identity keys are dropped. Returns None for bare catalogs.
    """
    meta = {k: v for k, v in item.items() if k not in ("id", "object")}
    return json.dumps(meta, ensure_ascii=False) if meta else None


async def _fetch_listing_items(
    client: httpx.AsyncClient,
    *,
    base_url: str,
    protocol: str,
    secret: str,
) -> tuple[list[dict], str]:
    """Return (OpenAI-shaped listing items, source) for one provider.

    DashScope / Model Studio: prefer the native paginated catalog
    (``/api/v1/models``), which includes callable ids the OpenAI-compatible
    ``/models`` list still omits. On native failure, fall back to the
    OpenAI-shaped list so a Bailian outage on one face cannot blank the
    whole provider. Every other vendor stays on ``models_request``.
    """
    url, headers = probe_urls.models_request(base_url, protocol, secret)
    if dashscope_models.is_dashscope_base(base_url):
        try:
            items = await dashscope_models.fetch_native_listings(client, base_url, headers)
            if items:
                return items, "dashscope_native"
            logger.warning(
                "dashscope native catalog empty for %s; falling back to OpenAI /models",
                base_url,
            )
        except Exception as e:
            logger.warning(
                "dashscope native catalog failed for %s (%s); falling back to OpenAI /models",
                base_url,
                e,
            )

    async with client.stream("GET", url, headers=headers) as resp:
        if resp.status_code != 200:
            raise RuntimeError(f"http_{resp.status_code}")
        raw = await egress.read_body_capped(resp)
    try:
        data = json.loads(raw)
    except Exception as e:
        raise RuntimeError("bad_json") from e
    if not isinstance(data, dict):
        raise RuntimeError("bad_json")
    items = [item for item in data.get("data", []) if isinstance(item, dict) and item.get("id")]
    return items, "openai_models"


async def _run_sync() -> dict:
    """Sync model lists from all enabled providers."""
    started = time.time()
    providers = await database.fetch(
        "SELECT id, name, base_url, protocol FROM providers WHERE enabled = 1"
    )

    results = {}
    total_added = 0
    total_errors = 0

    for p in providers:
        # D14 (spec 2026-10-07): Decisions providers take MANUAL listings
        # only — never auto-stamp the upstream /models catalog onto them.
        if p["protocol"] == DECISIONS_PROTOCOL:
            results[p["name"]] = {"skipped": "openai_decisions — manual listings only", "added": 0}
            continue
        try:
            # Get the first active key for this provider
            key_row = await database.fetchrow(
                "SELECT secret_ciphertext FROM provider_keys "
                "WHERE provider_id = $1 AND enabled = 1 ORDER BY id LIMIT 1",
                p["id"],
            )
            if not key_row:
                results[p["name"]] = {"error": "no_keys", "added": 0}
                total_errors += 1
                continue

            ciphertext = bytes(key_row["secret_ciphertext"])
            plaintext_key = decrypt(ciphertext).decode()

            # Fetch listings through the shared URL helper (OpenAI-shaped)
            # or, for DashScope, the native paginated catalog — see
            # `_fetch_listing_items`. Version segment lives in base_url
            # (gateway convention); Anthropic uses x-api-key (review
            # 2026-10-17 H1).
            verify = probe_urls.tls_verify()
            # Connect-time pin (security audit run-2): secret-bearing
            # catalog fetch must refuse DNS rebind to never-gateway.
            client = egress.pinned_async_client(p["base_url"], timeout=30.0, verify=verify)
            if client is None:
                results[p["name"]] = {"error": "egress_refused", "added": 0}
                total_errors += 1
                continue
            async with client:
                items, catalog_source = await _fetch_listing_items(
                    client,
                    base_url=p["base_url"],
                    protocol=p["protocol"],
                    secret=plaintext_key,
                )

            # Upsert names + capability metadata as inventory listings
            # (provider_models). meta is re-captured on every sync so
            # providers' evolving catalogs stay current.
            added = 0
            meta_changed = 0
            async with database.transaction() as tx:
                for item in items:
                    name = item["id"]
                    meta = normalize_meta(item)
                    existing = await tx.fetchrow(
                        "SELECT meta FROM provider_models WHERE provider_id = $1 AND name = $2",
                        p["id"],
                        name,
                    )
                    if not existing:
                        await tx.execute(
                            "INSERT INTO provider_models (provider_id, name, enabled, meta) "
                            "VALUES ($1, $2, 1, $3)",
                            p["id"],
                            name,
                            meta,
                        )
                        added += 1
                    else:
                        # backfill / refresh metadata without touching enabled
                        status = await tx.execute(
                            "UPDATE provider_models SET meta = $3 "
                            "WHERE provider_id = $1 AND name = $2 AND meta IS DISTINCT FROM $3",
                            p["id"],
                            name,
                            meta,
                        )
                        if status == "UPDATE 1":
                            meta_changed += 1

            if added > 0 or meta_changed > 0:
                await database.bump_generation()

            # Entitlement integration (spec A.4): drop matrix rows whose
            # listing vanished upstream (bumping the generation when rows
            # were dropped) and queue a bootstrap for keys that still
            # miss rows for the new catalog.
            entitlement_result = await entitlements.on_model_sync(
                p["id"], {item["id"] for item in items}
            )

            results[p["name"]] = {
                "added": added,
                "seen": len(items),
                "error": None,
                "catalog": catalog_source,
                "entitlement": entitlement_result,
            }
            total_added += added

        except Exception as e:
            logger.warning("sync failed for %s: %s", p["name"], e)
            results[p["name"]] = {"error": str(e), "added": 0}
            total_errors += 1

    # models.dev snapshot (layer 3 of the token-limit precedence chain):
    # fills providers whose catalogs publish no limits. Failures never
    # fail the sync — the previous snapshot stays in settings.
    try:
        models_dev = await modelsdev.refresh_snapshot()
    except Exception as e:
        logger.warning("models.dev snapshot refresh failed: %s", e)
        models_dev = {"changed": False, "models": 0, "note": "exception"}

    elapsed_ms = int((time.time() - started) * 1000)
    return {
        "ran_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elapsed_ms": elapsed_ms,
        "providers": results,
        "models_added": total_added,
        "errors": total_errors,
        "models_dev": models_dev,
    }


async def run_model_sync(source: str) -> dict:
    """One pass under the single-flight lock, with durable bookkeeping.

    The manual POST, the scheduled tick, the boot catch-up, and the Temporal
    activity all run through here, so they can never overlap and the
    persisted stamps always describe the same sequence.
    """
    async with _sync_lock:
        global _last_run
        await _record_attempt(source)
        result = await _run_sync()
        _last_run = result
        await _record_success(source)
        models_dev = result.get("models_dev")
        models_dev = models_dev if isinstance(models_dev, dict) else {}
        logger.info(
            "model sync (%s) finished in %sms: added=%s errors=%s models.dev=%s(%s)",
            source,
            result.get("elapsed_ms"),
            result.get("models_added"),
            result.get("errors"),
            models_dev.get("models"),
            models_dev.get("note"),
        )
        return result


# Back-compat alias for callers that still name the private helper.
_sync_locked = run_model_sync


async def _scheduled_sync_loop():
    """Background sync at the configured interval, plus a boot catch-up.

    `interval <= 0` keeps its manual-only meaning: no loop, no catch-up. The
    catch-up is never on the startup path — this is a background task and the
    lifespan does not await it.
    """
    interval = config.sync_interval_sec
    if interval <= 0:
        return
    try:
        due, detail = await catch_up_due()
        if due:
            # Bounded delay: lets the rest of the lifespan settle and gives a
            # manual POST the chance to win; the re-check then sees its success
            # stamp and stands down.
            await asyncio.sleep(_SYNC_CATCHUP_DELAY_SEC)
            due, detail = await catch_up_due()
        if due:
            if _sync_lock.locked():
                logger.info("model sync (catch_up) skipped: another sync is in progress")
            else:
                logger.info("model sync (catch_up) starting: %s", detail)
                await run_model_sync("catch_up")
        else:
            logger.info("model sync (catch_up) not needed: %s", detail)
    except Exception:
        logger.exception("model sync catch-up failed; the scheduled loop continues")
    while True:
        await asyncio.sleep(interval)
        try:
            if _sync_lock.locked():
                logger.info("model sync (scheduled) skipped: another sync is in progress")
                continue
            await run_model_sync("scheduled")
        except Exception:
            logger.exception("scheduled model sync failed; retried at the next interval")


async def start_sync_scheduler():
    global _sync_task
    if _sync_task is None or _sync_task.done():
        _sync_task = asyncio.create_task(_scheduled_sync_loop())
        logger.info("model sync scheduler started (interval=%ss)", config.sync_interval_sec)


async def stop_sync_scheduler():
    global _sync_task
    if _sync_task is not None:
        _sync_task.cancel()
        try:
            await _sync_task
        except asyncio.CancelledError:
            pass
        _sync_task = None
        logger.info("model sync scheduler stopped")


@router.post("")
async def sync_now(user: dict = Depends(require_auth)):
    """POST /api/sync — run a manual sync (single-flight).

    When TEMPORAL_HOST is set, starts ModelSyncWorkflow and waits for the
    result so the Workflows console records the run. Otherwise falls back
    to the in-process path.
    """
    from ..temporal.settings import temporal_enabled

    if temporal_enabled():
        try:
            from ..temporal.client import start_model_sync

            result = await start_model_sync(source="manual", wait=True)
            audit.log(
                "model.sync",
                None,
                f"added={result.get('models_added')} errors={result.get('errors')} "
                f"via=temporal wid={result.get('workflow_id')}",
            )
            return result
        except Exception as e:
            logger.exception("Temporal model sync failed; falling back in-process")
            # Soft fallback keeps the button useful if the worker is down.
            if _sync_lock.locked():
                raise HTTPException(
                    409,
                    detail={
                        "error": {
                            "code": "already_running",
                            "message": f"temporal sync failed ({e}); in-process sync busy",
                        }
                    },
                ) from e

    if _sync_lock.locked():
        raise HTTPException(
            409,
            detail={"error": {"code": "already_running", "message": "sync is already in progress"}},
        )
    result = await run_model_sync("manual")
    audit.log("model.sync", None, f"added={result['models_added']} errors={result['errors']}")
    return result


@router.get("/status")
async def sync_status(user: dict = Depends(require_auth)):
    """GET /api/sync/status — last sync info + current interval.

    `persisted` reports the durable attempt/success stamps that decide the
    boot catch-up, so a restart does not hide when the last pass ran.
    """
    state = await _read_sync_state()
    return {
        **(_last_run or {"last_run": None}),
        "interval_sec": config.sync_interval_sec,
        "persisted": {
            "last_ok_at": _state_iso(state, "last_ok"),
            "last_attempt_at": _state_iso(state, "last_attempt"),
            "last_source": state.get("last_source"),
            "runs": _count(state, "runs"),
            "attempts": _count(state, "attempts"),
        },
    }
