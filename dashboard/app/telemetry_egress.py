"""The telemetry exporter's egress posture (design §11.2 / item 29).

WHY THIS MODULE EXISTS
======================
The design requires a *decision* about how the dashboard's telemetry exporter
reaches its collector, and says explicitly that silence is not acceptable:

    either give the exporter a transport that pins (`_PinNetworkBackend`) and
    caps (`read_body_capped`), or record the bypass explicitly. Both are
    acceptable; silence is not.

This module records it, and provides the one function the exporter must use so
the decision is enforced rather than merely written down.

THE DECISION: the exporter is EXEMPT from egress pinning, and this is safe
--------------------------------------------------------------------------
Pinning defends against SSRF and DNS rebinding on paths whose target is
attacker-influenced DATA — a node's stats host, an alert webhook URL, a log
fan-out address. The exporter is the opposite shape:

* **Its endpoint is boot configuration, not data.** It comes from
  `OTEL_EXPORTER_OTLP_ENDPOINT` in the process environment — the same trust
  level as `JANUS_DB_HOST`. Nothing a node, a user, or an alert webhook says can
  change it for the lifetime of the process.
* **There is no name to rebind.** The operator configures a collector address;
  there is no second resolution between a check and a connect, because there is
  no untrusted check to begin with.
* **Its body is not attacker-influenced in either direction.** The request is
  telemetry the dashboard produced; the response is an OTLP status envelope
  that the client reads and discards.

So pinning the exporter would defend a threat that does not exist on this path,
while adding a resolver call and a socket-pinning layer to a component whose
whole job is to be cheap enough never to disturb the poll cadence.

WHAT IS *NOT* EXEMPT
--------------------
The exemption is narrow and must not spread, and this module exists partly so
it is greppable. It does NOT claim that every data-derived path is already
pinned — the design records that pinning is a poll-path convention with known
bypasses, not a chokepoint. What this module fixes is only the question that
must be answered for the exporter, so that adding it is not a silent fourth
bypass: `must_use_pinned_client/1` states the rule a new egress path has to
apply.

The remaining obligations are NOT discharged here, because nothing here can
discharge them — they bind whoever ADDS the exporter:

* The exporter **must not use the DB pool** and must not hold a transaction
  (§11.2): statement timeouts are 2 s (alerts) / 5 s (ops) against a
  `min 2 / max 10` pool, and a telemetry export that borrowed a connection
  could starve the pollers it is trying to observe.
* Span creation must never be awaited on the hot path. Export is fire-and-
  forget: a failing collector loses telemetry and nothing else.
"""

from __future__ import annotations

# Recorded so a grep finds the decision, not just the code that relies on it.
EGRESS_POSTURE = "exempt: boot-configured endpoint, no attacker-influenced target"


def exporter_egress_posture() -> str:
    """The recorded decision, for a startup log line and for tests.

    Emitted once at boot rather than per export: an operator should be able to
    see WHICH posture is in force without reading this module, and a test pins
    that the string exists so the decision cannot be quietly deleted.
    """
    return EGRESS_POSTURE


def must_use_pinned_client(target_source: str) -> bool:
    """Whether an egress path must route through the pinned client.

    Keyed on WHERE the target came from, not on which module is fetching: an
    address the operator configured at boot is not attacker-influenced, while
    an address that arrived as data can be. `target_source` is `"boot-config"`
    or `"data"`; anything unrecognised is treated as `"data"`, because failing
    towards the stricter path is the safe default for an SSRF guard.
    """
    return target_source != "boot-config"
