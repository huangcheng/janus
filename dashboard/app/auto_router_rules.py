"""Pure auto-router tier-reorder rules (reorder spec
docs/superpowers/specs/2026-10-11-geo-affinity-and-auto-tier-reorder-design.md
§2 definitions, D9 rules, D7 knobs, D10/D28/D33 cooldown math, D6
master-parity validator).

EVERYTHING in this module is pure (no I/O) so the (P)/(D)/(E) matrix,
the guards and the cooldown math are unit-testable without a DB — and
so the same code answers the loop, the two write entrypoints and the
diagnostics surface. The master-parity validator mirrors
janus_auto:validate_tiers/3 on the gateway (D6: the re-validate logic
is SINGLE-SOURCED — golden tests pin the same strings the Erlang side
normalizes so the two validators cannot silently diverge).
"""

import hashlib
import json
import math

# Tier vocabulary — same three keys janus_auto addresses by atom.
TIERS = ("fast", "big", "flagship")

# D7/D5 knob defaults (spec §5). The knob SHIPS disabled + dry_run —
# nothing auto-enables; flipping is the operator's explicit act.
KNOB_DEFAULTS = {
    "enabled": False,
    "interval_sec": 300,
    "window_sec": 3600,
    "min_samples": 30,
    "min_improve_ratio": 0.15,
    "min_success_rate": 0.85,
    "manual_hold_sec": 3600,
    # D32: boolean SIBLING of enabled — enabled AND dry_run computes +
    # audits without ever CASing the tiers.
    "dry_run": True,
}

_INT_KNOBS = {
    "interval_sec": (10, 86400),
    "window_sec": (60, 604800),
    "min_samples": (1, 100000),
    "manual_hold_sec": (0, 604800),
}
_FLOAT_KNOBS = {
    "min_improve_ratio": (0.0, 1.0),
    "min_success_rate": (0.0, 1.0),
}


def normalize_knobs(raw) -> dict:
    """Tolerant read-side normalization (the loop must never crash on a
    bad settings row): unknown keys ignored, wrong-typed/out-of-range
    values fall back to defaults. The PUT endpoint validates strictly."""
    cfg = dict(KNOB_DEFAULTS)
    if isinstance(raw, dict):
        for key in KNOB_DEFAULTS:
            if key not in raw or raw[key] is None:
                continue
            val = raw[key]
            if key in ("enabled", "dry_run"):
                if isinstance(val, bool):
                    cfg[key] = val
            elif key in _INT_KNOBS:
                lo, hi = _INT_KNOBS[key]
                if isinstance(val, int) and not isinstance(val, bool) and lo <= val <= hi:
                    cfg[key] = val
            elif key in _FLOAT_KNOBS:
                lo, hi = _FLOAT_KNOBS[key]
                if (
                    isinstance(val, (int, float))
                    and not isinstance(val, bool)
                    and lo <= float(val) <= hi
                ):
                    cfg[key] = float(val)
    return cfg


def knob_problems(body: dict) -> list[str]:
    """Strict PUT-side validation: one human-readable problem per bad
    field (the router turns these into the 400 body)."""
    problems = []
    if not isinstance(body, dict):
        return ["body must be a JSON object"]
    for key in ("enabled", "dry_run"):
        if key in body and not isinstance(body[key], bool):
            problems.append(f"{key} must be a boolean")
    for key, (lo, hi) in _INT_KNOBS.items():
        if key in body:
            val = body[key]
            if not isinstance(val, int) or isinstance(val, bool) or not (lo <= val <= hi):
                problems.append(f"{key} must be an integer in [{lo}, {hi}]")
    for key, (lo, hi) in _FLOAT_KNOBS.items():
        if key in body:
            val = body[key]
            if (
                not isinstance(val, (int, float))
                or isinstance(val, bool)
                or not (lo <= float(val) <= hi)
            ):
                problems.append(f"{key} must be a number in [{lo}, {hi}]")
    unknown = set(body) - set(KNOB_DEFAULTS)
    if unknown:
        problems.append(f"unknown knobs: {sorted(unknown)}")
    return problems


# ---------------------------------------------------------------------------
# §2 definitions — pure classification of ONE member from its SQL
# aggregates (terminal_count, success_count, p95_samples, p95_ms).
# ---------------------------------------------------------------------------


def member_view(name: str, agg: dict | None, knobs: dict, has_model: bool = True) -> dict:
    """Score view for one tier member.

    - ``terminal_count``: rows with a status, excluding outcome
      'cancelled' (the SQL already excludes them; the writer pins that
      no-provider_id pre-pick rows NEVER exist, so no query-side
      either/or — D8/TF-A.0b).
    - ``success_count``: status 2xx AND (outcome NULL or ok/success).
    - ``p95_samples``/``p95``: success rows with non-null latency.
    - under-sampled: terminal_count < min_samples OR p95_samples <
      min_samples; scored = not under-sampled.
    - demotion-eligible: scored with success_rate < min_success_rate,
      OR the name is in the tier but has no `models` row (D9: treated
      as sr=-1, p95=+inf downstream).
    """
    agg = agg or {}
    terminal = int(agg.get("terminal_count") or 0)
    success = int(agg.get("success_count") or 0)
    p95_samples = int(agg.get("p95_samples") or 0)
    p95_raw = agg.get("p95_ms")
    p95 = float(p95_raw) if p95_raw is not None else None
    sr = (success / terminal) if terminal > 0 else None
    min_samples = knobs["min_samples"]
    under_sampled = terminal < min_samples or p95_samples < min_samples
    scored = (not under_sampled) and p95 is not None and sr is not None
    demotion = (scored and sr < knobs["min_success_rate"]) or not has_model
    return {
        "name": name,
        "terminal_count": terminal,
        "success_count": success,
        "success_rate": sr,
        "p95_samples": p95_samples,
        "p95_ms": p95,
        "under_sampled": under_sampled,
        "scored": scored,
        "demotion_eligible": demotion,
        "has_model": has_model,
    }


def build_views(names: list[str], aggs: dict, present_models: set, knobs: dict) -> dict:
    """Views for every tier member; members with no `models` row get the
    missing-model treatment (sr=-1, p95=+inf — D9 sentinels live in the
    rule comparison helpers, not the stored rates)."""
    views = {}
    for name in names:
        views[name] = member_view(name, aggs.get(name), knobs, has_model=name in present_models)
    return views


# Missing-model comparison sentinels (D9): sr=-1, p95=+inf.
def _sr(view: dict) -> float:
    if not view["has_model"]:
        return -1.0
    return view["success_rate"] if view["success_rate"] is not None else -1.0


def _p95(view: dict) -> float:
    if not view["has_model"] or view["p95_ms"] is None:
        return math.inf
    return view["p95_ms"]


# ---------------------------------------------------------------------------
# D9 reorder rules — one L→R pass over adjacent pairs.
# ---------------------------------------------------------------------------

# (P) success-rate tolerance: p95 alone must not silently move a 0.97
# name below a 0.86 one.
P_SR_TOLERANCE = 0.02
# (D) success-rate path margin.
D_SR_MARGIN = 0.05
# (D) p95 ceiling multiple on the sr path.
D_P95_CEILING = 2.0


def _pair_rule(left: dict, right: dict, knobs: dict, now: float, explore_until: float):
    """First matching D9 rule for one adjacent (left, right) pair, or
    None. The three rules are mutually exclusive on their guards
    ((P)/(D) differ on left demotion-eligibility, (D)/(E) differ on
    right scored vs under-sampled)."""
    # (P) promote: both scored, neither demotion-eligible,
    #     p95_right <= p95_left*(1-min_improve_ratio)
    #     AND sr_right >= sr_left - 0.02.
    if (
        left["scored"]
        and right["scored"]
        and not left["demotion_eligible"]
        and not right["demotion_eligible"]
        and _p95(right) <= _p95(left) * (1.0 - knobs["min_improve_ratio"])
        and _sr(right) >= _sr(left) - P_SR_TOLERANCE
    ):
        return "P"
    # (D) demote: left demotion-eligible, right scored and healthy,
    #     (sr_right >= sr_left + 0.05 AND p95_right <= 2*p95_left)
    #     OR (p95_right <= p95_left*(1-min_improve_ratio)
    #         AND sr_right >= min_success_rate).
    if (
        left["demotion_eligible"]
        and right["scored"]
        and not right["demotion_eligible"]
        and (
            (_sr(right) >= _sr(left) + D_SR_MARGIN and _p95(right) <= D_P95_CEILING * _p95(left))
            or (
                _p95(right) <= _p95(left) * (1.0 - knobs["min_improve_ratio"])
                and _sr(right) >= knobs["min_success_rate"]
            )
        )
    ):
        return "D"
    # (E) explore: left demotion-eligible, right under-sampled; a new
    # exploration is only allowed once the explore cooldown passed
    # (the write itself re-anchors it — D9/D28).
    if left["demotion_eligible"] and right["under_sampled"] and now >= explore_until:
        return "E"
    return None


def reorder_tier(names: list[str], views: dict, knobs: dict, now: float, explore_until: float):
    """One L→R pass over the tier's adjacent pairs. Non-overlapping
    fired swaps compose; overlapping fires keep the LEFTMOST. Returns
    (new_order, actions) where actions carry the rule kind per swap."""
    actions = []
    last_kept = None
    for i in range(len(names) - 1):
        rule = _pair_rule(views[names[i]], views[names[i + 1]], knobs, now, explore_until)
        if rule is None:
            continue
        if last_kept is not None and i < last_kept + 2:
            continue  # overlaps the kept leftmost swap — dropped
        actions.append({"i": i, "left": names[i], "right": names[i + 1], "rule": rule})
        last_kept = i
    out = list(names)
    for act in actions:
        i = act["i"]
        out[i], out[i + 1] = out[i + 1], out[i]
    return out, actions


def compute_candidate(
    current_tiers: dict, views: dict, knobs: dict, now: float, explore_until: float
):
    """Candidate tier map for the WHOLE auto-router config.

    Per D9: "Empty / no-scored proposed tier -> no write" — a tier
    with no members or no scored member is proposed UNCHANGED. Returns
    (candidate_or_None, actions, scored_anywhere); candidate is None
    when no tier would change (nothing to write / no candidate).
    """
    candidate = {}
    actions: list[dict] = []
    scored_anywhere = False
    changed = False
    for tier in TIERS:
        names = [n for n in (current_tiers.get(tier) or []) if isinstance(n, str)]
        tier_scored = any(views.get(n, {}).get("scored") for n in names)
        scored_anywhere = scored_anywhere or tier_scored
        if not names or not tier_scored:
            candidate[tier] = names
            continue
        new_names, tier_actions = reorder_tier(names, views, knobs, now, explore_until)
        candidate[tier] = new_names
        if tier_actions:
            changed = True
            actions.extend({"tier": tier, **a} for a in tier_actions)
    if not changed:
        return None, actions, scored_anywhere
    return candidate, actions, scored_anywhere


# ---------------------------------------------------------------------------
# D10/D28/D33 timing math (pure — the tests pin the default numbers).
# ---------------------------------------------------------------------------


def lease_ttl_sec(interval_sec: int) -> int:
    """D10: lease_ttl = max(60, interval_sec + 30) — 330 s at the 300 s
    default."""
    return max(60, interval_sec + 30)


def heartbeat_sec(ttl_sec: float) -> float:
    """D10: heartbeat every min(15, lease_ttl/3) DURING long ticks."""
    return min(15.0, ttl_sec / 3.0)


def query_timeout_sec(ttl_sec: float) -> float:
    """D33: the usage query timeout <= lease_ttl/3 (a slow query cannot
    self-steal via heartbeat stall); 10 s is ample for the indexed
    window scan and keeps failed ticks snappy."""
    return min(10.0, ttl_sec / 3.0)


def post_write_cooldown_sec(interval_sec: int, window_sec: int) -> float:
    """D28: max(interval_sec, window_sec/6) — 600 s at defaults, scales
    with the window."""
    return max(float(interval_sec), window_sec / 6.0)


def explore_cooldown_sec(interval_sec: int) -> float:
    """D9: a fired (E) anchors now()+3*interval_sec."""
    return 3.0 * interval_sec


def quarantine_sec(interval_sec: int) -> float:
    """D35: two consecutive rejects -> quarantined 10x interval_sec."""
    return 10.0 * interval_sec


def pending_dwell_decision(
    pending,
    pending_since: float | None,
    candidate,
    now: float,
    interval_sec: int,
    last_auto_write: float | None,
    window_sec: int,
) -> dict:
    """D27/D28 gate, pure so both the loop and the tests share it.

    - candidate != pending (or no pending) -> pending_changed: the
      caller re-anchors pending_tiers + pending_since=now() (LEASE-HELD
      only) and dwell FAILS this tick;
    - dwell passes when pending is unchanged AND
      now >= pending_since + interval_sec;
    - the D28 post-write cooldown max(interval, window/6) gates the
      write on top of dwell (checked only once dwell passed).
    """
    if pending is None or pending_since is None or canonical(pending) != canonical(candidate):
        return {"pending_changed": True, "dwell_ok": False, "cooldown_ok": None}
    dwell_ok = now >= pending_since + interval_sec
    cooldown_ok = True
    if last_auto_write is not None:
        cooldown_ok = now >= last_auto_write + post_write_cooldown_sec(interval_sec, window_sec)
    return {"pending_changed": False, "dwell_ok": dwell_ok, "cooldown_ok": cooldown_ok}


# ---------------------------------------------------------------------------
# Canonical JSON + tiers identity (the reject-marker tiers_sha
# contract: compact separators, sorted object keys, list order
# preserved, ensure_ascii=False — the gateway's marker writer must
# compute the identical hex digest).
# ---------------------------------------------------------------------------


def canonical(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def tiers_sha(tiers) -> str:
    return hashlib.sha256(canonical(tiers).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# D6 master-parity validator — mirrors janus_auto:validate_tiers/3.
# Golden tests pin these rules against the same strings the Erlang side
# normalizes (see test_auto_reorder_rules.py::TestMasterParity).
# ---------------------------------------------------------------------------


def validate_tiers_master_parity(raw_tiers, virtual_model: str = "janus-auto") -> dict:
    """The master's tier normalization, single-sourced for the
    dashboard's two write entrypoints:

    - merge over the {fast, big, flagship} defaults (unknown tier keys
      dropped);
    - per tier keep only non-empty STRING entries;
    - drop the virtual model name (a tier may not route to itself);
    - a non-list / absent tier becomes [] (fail-soft, like the master);
    - duplicates are NOT deduped here (the human dashboard layer owns
      mutual exclusivity; the master tolerates).
    """
    merged = {t: [] for t in TIERS}
    if isinstance(raw_tiers, dict):
        for tier in TIERS:
            if tier in raw_tiers:
                merged[tier] = raw_tiers[tier]
    for tier in TIERS:
        names = merged[tier]
        kept = []
        if isinstance(names, list):
            for n in names:
                if isinstance(n, str) and n != "" and n != virtual_model:
                    kept.append(n)
        merged[tier] = kept
    return merged
