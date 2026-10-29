"""Debug driver for the alert evaluator (observability-depth Task 6 /
gate step O.4b).

Runs OUTSIDE the dashboard process (plain CLI on the app's own venv +
DB pool — the dashboard is a host uvicorn process, not a container):

    python -m app.alerts_debug --cycles-file /tmp/cycles.json
    python -m app.alerts_debug --cycles '[{"nodes": [...], "windows": {...}}, ...]'

The cycles file is a JSON list of snapshot dicts; each entry drives ONE
alerts.run_once() call (one simulated poll cycle). All cycles run inside
ONE process invocation so module-level breach streaks survive across
cycles (a for_cycles=2 rule fires only after >=2 consecutive breach
drives).

Cross-process safety vs the live evaluator (plan Step 3):
  1. set alert_control.paused=true + paused_at (try/finally — a failed
     drive can never leave the loop paused);
  2. drain: wait out any in-flight evaluation (~4s deadline + slack);
  3. briefly acquire/release pg_advisory_xact_lock(90110013) — flushes a
     live evaluation that arrived at the lock after the drain;
  4. drive run_once once per cycle, printing each transition summary;
  5. finally: clear paused + paused_at so the live evaluator resumes.

A SIGKILL between 1 and 5 is still safe: the sentinel auto-expires after
15 minutes (alerts.PAUSE_EXPIRY_SEC).
"""

import argparse
import asyncio
import json
import pathlib
import sys

from . import alerts, audit, database


async def _set_paused(paused: bool) -> None:
    if paused:
        await database.execute(
            "INSERT INTO alert_control (id, paused, paused_at) VALUES (1, TRUE, NOW()) "
            "ON CONFLICT (id) DO UPDATE SET paused = TRUE, paused_at = NOW()"
        )
    else:
        await database.execute(
            "INSERT INTO alert_control (id, paused, paused_at) VALUES (1, FALSE, NULL) "
            "ON CONFLICT (id) DO UPDATE SET paused = FALSE, paused_at = NULL"
        )


async def _flush_lock_waiters() -> None:
    """Briefly acquire/release the run_once advisory lock so a live
    evaluation that is WAITING on it flushes through before the
    deterministic drive begins."""
    async with database.transaction() as tx:
        await tx.execute("SELECT pg_advisory_xact_lock($1)", alerts.ADVISORY_LOCK_KEY)


async def _drive(cycles: list[dict], drain_sec: float) -> int:
    await database.init_pool()
    try:
        await _set_paused(True)
        print(json.dumps({"pause": "set"}), flush=True)
        try:
            # Wait out any in-flight live evaluation (~4s deadline + slack).
            await asyncio.sleep(drain_sec)
            await _flush_lock_waiters()
            for i, snapshots in enumerate(cycles):
                summary = await alerts.run_once(snapshots)
                print(json.dumps({"cycle": i, **summary}, default=str), flush=True)
        finally:
            await _set_paused(False)
            print(json.dumps({"pause": "cleared"}), flush=True)
    finally:
        # Drain fire-and-forget audit persists BEFORE the pool closes:
        # this driver is a short-lived process, and a persist task still
        # pending at close_pool dies with "pool is closing", silently
        # losing the transition's audit row.
        await audit.flush()
        await database.close_pool()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="python -m app.alerts_debug",
        description="Drive alerts.run_once with synthetic snapshots (gate O.4b).",
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--cycles-file", help="path to a JSON list of snapshot dicts")
    src.add_argument("--cycles", help="inline JSON list of snapshot dicts")
    parser.add_argument(
        "--drain-sec",
        type=float,
        default=5.0,
        help="pause-settle wait before driving (in-flight eval ~4s + slack)",
    )
    args = parser.parse_args()

    raw = (
        args.cycles
        if args.cycles is not None
        else pathlib.Path(args.cycles_file).read_text(encoding="utf-8")
    )
    cycles = json.loads(raw)
    if isinstance(cycles, dict):
        cycles = [cycles]
    if not isinstance(cycles, list):
        parser.error("cycles must be a JSON list of snapshot objects")
    return asyncio.run(_drive(cycles, args.drain_sec))


if __name__ == "__main__":
    sys.exit(main())
