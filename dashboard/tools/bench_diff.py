#!/usr/bin/env python
"""H6-D2 baseline diff (spec: Janus repo
docs/superpowers/specs/2026-10-15-maturity-hardening.md, section H6).

Compares two bench_gateway.py artifacts and prints a % delta table:

    python tools/bench_diff.py tools/baselines/2026-10-15-win-dev.json new.json

NEVER GATES: this tool ALWAYS exits 0 — even on parse errors, missing
files, or giant regressions (H6-D2: no flaky perf thresholds in CI;
problems are read by a human in the PR, not by a machine). Rows whose
median moved more than --warn-pct (default 25%) get a "!" marker as a
reading aid, nothing more.

Paste the table into PRs that touch hot paths
(proxy / session / providers_http / pool) — see
tools/baselines/README.md for the workflow.
"""

import argparse
import json
import sys


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f), None
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


def fmt_ms(v):
    return f"{v:.1f}" if isinstance(v, (int, float)) else "-"


def delta_pct(old, new):
    if not isinstance(old, (int, float)) or not isinstance(new, (int, float)):
        return None
    if old == 0:
        return None
    return (new - old) / old * 100.0


def fmt_delta(d):
    if d is None:
        return "-"
    return f"{d:+.1f}%"


def main():
    ap = argparse.ArgumentParser(
        description="Diff two bench_gateway baselines (never gates, always exit 0)"
    )
    ap.add_argument("old", help="baseline artifact JSON (e.g. tools/baselines/...)")
    ap.add_argument("new", help="fresh re-bench artifact JSON")
    ap.add_argument(
        "--warn-pct",
        type=float,
        default=25.0,
        help="annotate median moves beyond this %% with '!' (annotation only — never a failure)",
    )
    args = ap.parse_args()

    old, err_o = load(args.old)
    new, err_n = load(args.new)
    if err_o or err_n:
        # Reading aid to stderr; STILL exit 0 (never gates).
        if err_o:
            print(f"ERROR: cannot read {args.old}: {err_o}", file=sys.stderr)
        if err_n:
            print(f"ERROR: cannot read {args.new}: {err_n}", file=sys.stderr)
        return 0

    print(f"old: {args.old}  (hw={old.get('hw_class')}, ts={old.get('ts')})")
    print(f"new: {args.new}  (hw={new.get('hw_class')}, ts={new.get('ts')})")
    if old.get("hw_class") != new.get("hw_class"):
        print(
            "NOTE: different hw_class — cross-hardware deltas are NOT "
            "comparable; re-bench on the same class (H6-D2)."
        )
    po, pn = old.get("params", {}), new.get("params", {})
    if po != pn:
        print(
            f"NOTE: params differ (old={po}, new={pn}) — rerun with the "
            f"same --workers/--reqs for a fair diff."
        )

    names = sorted(set(old.get("targets", {})) | set(new.get("targets", {})))
    header = (
        f"{'target':<20} {'med old':>9} {'med new':>9} {'med d%':>9} "
        f"{'p95 old':>9} {'p95 new':>9} {'p95 d%':>9}  flags"
    )
    print()
    print(header)
    print("-" * len(header))
    for name in names:
        to = old.get("targets", {}).get(name)
        tn = new.get("targets", {}).get(name)
        if to is None or tn is None:
            side = "old" if to is None else "new"
            print(f"{name:<20} {'(missing in ' + side + ')':<60}")
            continue
        m_old, m_new = to.get("median_ms"), tn.get("median_ms")
        p_old, p_new = to.get("p95_ms"), tn.get("p95_ms")
        dm, dp = delta_pct(m_old, m_new), delta_pct(p_old, p_new)
        flags = []
        if dm is not None and abs(dm) > args.warn_pct:
            flags.append("!median")
        if dp is not None and abs(dp) > args.warn_pct:
            flags.append("!p95")
        if to.get("errors") or tn.get("errors"):
            flags.append(f"errors {to.get('errors', 0)}->{tn.get('errors', 0)}")
        print(
            f"{name:<20} {fmt_ms(m_old):>9} {fmt_ms(m_new):>9} {fmt_delta(dm):>9} "
            f"{fmt_ms(p_old):>9} {fmt_ms(p_new):>9} {fmt_delta(dp):>9}  "
            f"{','.join(flags)}"
        )
    print()
    print(
        "Never gates: exit 0 regardless of deltas (H6-D2). '!' markers are "
        f"reading aids for median/p95 moves beyond {args.warn_pct:.0f}%."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
