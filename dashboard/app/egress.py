"""Egress security helpers (v2.2 spec
docs/superpowers/plans/2026-10-11-v2.2-quota-egress-security.md, Parts B & C).

TWO STRICTLY SEPARATE classifiers — wiring them into each other's call
sites is an implementation error the tests guard:

- ``is_loopback_literal(host)`` — canonical string match on
  127.0.0.1 / ::1 / localhost ONLY (IPv4-mapped ``::ffff:127.0.0.1``
  normalizes first). ZERO DNS involvement: the stats-token path must
  never consult a resolver, so the mixed-record inversion ({127.0.0.1,
  public} would leak the global token to the public record) and the
  resolve-to-connect rebinding window are structurally impossible.
  This is the ONLY thing the Part B token fallback consults.

- ``is_internal_sockaddr(host)`` — resolves (bounded 3 s) and
  classifies the SOCKADDR against the full internal reject set
  (Part C ONLY): loopback, RFC1918, link-local (cloud metadata
  169.254.169.254), ULA, RFC 6598 carrier-grade NAT (Alibaba metadata
  100.100.100.200 lives in 100.64/10), 0.0.0.0/8, ::, broadcast,
  multicast (v4+v6), IPv4-compatible/IPv4-mapped v6 (normalized into
  the v4 rules), NAT64. ANY internal record rejects; resolution
  FAILURE rejects (fail-closed — an operator can retry, a flaky
  resolver must not open the gate). Deliberately the OPPOSITE
  aggregation from the token path: SSRF rejection is broader than
  token fallback because the two protect different assets.

  The SAME resolver classifies at REQUEST time: ``connect_pins()``
  re-resolves immediately before an outbound request, rejects the
  ranges a gateway can never legitimately occupy (cloud metadata,
  link-local, 100.64/10, multicast/unspecified), and returns the
  validated addresses so ``pinned_async_client()`` can CONNECT TO
  THEM instead of letting the stack resolve the name a second time.
  That closes the write-time-only / DNS-rebinding window (H1); the
  node request path therefore never connects to an address it did
  not classify at connect time. Loopback/RFC1918/ULA stay allowed
  for node hosts because gateways legitimately live on the
  operator's private network.

Stats-token egress policy (Part B, knob ``dash.egress_policy``):
with the policy ON, the global JANUS_STATS_TOKEN is sent to
loopback-literal stats origins ONLY; every other origin requires a
per-node envelope or the poll SKIPS the node (no request made),
warns, and bumps ``nodes_skipped_no_token_total``.
"""

import ipaddress
import json
import logging
import os
import re
import socket
import threading
import time
from typing import TYPE_CHECKING

from fastapi import HTTPException, Request

if TYPE_CHECKING:  # httpx is imported lazily so this module stays importable
    import httpx  # for the deploy egress-scan helper scripts

logger = logging.getLogger("janus.dashboard.egress")

# Resolution budget per host (F6: bounded, fail-closed). getaddrinfo()
# has no timeout argument, so the lookup runs on a daemon thread and the
# caller waits at most this long (see _resolve_uncached).
RESOLVE_TIMEOUT_SEC = 3.0
# Per-process resolution cache: {host: (monotonic_ts, [sockaddr, ...])}.
# Short TTL so a DNS flip cannot pin a stale answer for long (the
# write gate re-resolves on every write regardless).
_RESOLVE_TTL_SEC = 30.0
# Negative cache: {host: monotonic_ts} for names the resolver says do NOT
# exist (NXDOMAIN/EAI_NODATA). Kept far shorter than the positive TTL,
# and NEVER written for transient resolver failures (timeout/SERVFAIL) —
# one hiccup must not suppress legitimate work for the whole TTL (M3).
_RESOLVE_NEG_TTL_SEC = 2.0
_resolve_cache: dict[str, tuple[float, list[str]]] = {}
_negative_cache: dict[str, float] = {}

# Hard cap on an outbound response body we are willing to buffer (H4).
# /stats payloads are single-digit KB and the largest legitimate body is
# a 2000-event log drain; 8 MiB is far above both and well below an OOM.
MAX_OUTBOUND_BODY_BYTES = 8 * 1024 * 1024

# One warning per (event, subject): a per-poll skip must not flood logs.
_warned: set[tuple[str, str]] = set()

_ORIGIN_RE = re.compile(r"^https?://([^/?#]+)", re.IGNORECASE)


def host_of(origin_or_host: str) -> str:
    """Bare host from a bare host or an http(s):// origin (strips
    scheme, userinfo, port, path). Lowercased; brackets stripped from
    IPv6 literals. Empty string when nothing parseable remains."""
    raw = (origin_or_host or "").strip()
    low = raw.lower()
    if low.startswith(("http://", "https://")) and raw.split("://", 1)[1].strip("/?#") == "":
        return ""  # scheme with no authority ("https://" is not a host)
    m = _ORIGIN_RE.match(raw)
    if m:
        raw = m.group(1)
    else:
        # tolerate a scheme-less "//host" or garbage: take up to path
        raw = raw.split("/")[0]
    # drop userinfo
    if "@" in raw:
        raw = raw.rsplit("@", 1)[1]
    # drop :port — but a BARE IPv6 literal (2+ colons, no brackets)
    # must survive intact; [v6]:port uses the bracket form.
    if raw.startswith("["):
        # [v6]:port
        raw = raw.split("]")[0][1:]
    elif raw.count(":") > 1:
        pass  # bare IPv6 literal
    else:
        raw = raw.split(":")[0]
    return raw.strip("[]").strip().lower()


def _short_host(value: str, limit: int = 48) -> str:
    """Host for a log line: never the raw origin/path, never unbounded."""
    text = host_of(value) or str(value or "")
    return text if len(text) <= limit else text[: limit - 3] + "..."


def _normalize_addr(text: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    """Parse an IP literal; IPv4-mapped IPv6 (::ffff:0:0/96) and
    IPv4-compatible forms normalize into the v4 rules BEFORE
    classification (dual-stack getaddrinfo returns these)."""
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return None
    if isinstance(addr, ipaddress.IPv6Address):
        if addr.ipv4_mapped is not None:
            return addr.ipv4_mapped
        # ::a.b.c.d (IPv4-compatible, deprecated) — treat like mapped:
        # the low 32 bits classify under the v4 rules.
        try:
            six_to_four = addr.sixtofour
        except Exception:
            six_to_four = None  # not a 6to4 address
        if six_to_four is not None:
            # 6to4 embedded IPv4: classify the embedded public-ish v4
            # (stated residual: full 6to4/Teredo extraction is Part H).
            return six_to_four
        try:
            teredo = addr.teredo
        except Exception:
            teredo = None
        if teredo is not None:
            return teredo[0]
    return addr


LOOPBACK_LITERALS = frozenset({"127.0.0.1", "::1", "localhost"})


def is_loopback_literal(origin_or_host: str) -> bool:
    """Part B token-path classifier: canonical loopback literals only,
    ZERO DNS. ``::ffff:127.0.0.1`` normalizes to 127.0.0.1 first. Any
    other form — RFC1918, 100.64, a hostname that HAPPENS to resolve
    to loopback — is NOT loopback here (fail-safe: no fallback)."""
    host = host_of(origin_or_host)
    if host in LOOPBACK_LITERALS:
        return True
    addr = _normalize_addr(host)
    return addr is not None and addr in (
        ipaddress.ip_address("127.0.0.1"),
        ipaddress.ip_address("::1"),
    )


def _resolve_uncached(host: str, timeout: float) -> tuple[list[str] | None, bool]:
    """One bounded getaddrinfo call. Returns (addresses, transient):
    ``(None, True)`` = the resolver failed transiently (timeout, SERVFAIL,
    EAI_AGAIN) and the caller must NOT negative-cache the name;
    ``(None, False)`` = the name genuinely has no answer (NXDOMAIN /
    EAI_NODATA). A thread that outlives the budget is abandoned — daemon,
    one per hung lookup, never reused."""
    addrs: list[str] = []
    err: BaseException | None = None
    done = threading.Event()

    def _run() -> None:
        nonlocal err
        try:
            infos = socket.getaddrinfo(host, None, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM)
            addrs.extend(info[4][0] for info in infos)
        except BaseException as exc:  # reported to the caller, never swallowed
            err = exc
        finally:
            done.set()

    threading.Thread(target=_run, name="egress-resolve", daemon=True).start()
    if not done.wait(timeout):
        return None, True
    if err is not None:
        no_data = getattr(socket, "EAI_NODATA", None)
        permanent = isinstance(err, socket.gaierror) and err.errno in (
            socket.EAI_NONAME,
            no_data,
        )
        return None, not permanent
    return sorted({a for a in addrs if a}), False


def resolve_host(host: str, *, timeout: float = RESOLVE_TIMEOUT_SEC) -> list[str] | None:
    """Resolve a hostname to address strings (cached, TTL-bounded).
    Returns None on failure/timeouts — callers fail CLOSED on None.
    IP literals classify without any resolver call (a resolver outage
    cannot break literal classification). The `timeout` budget is
    actually enforced (M2); a resolver failure is not negative-cached
    while a genuinely absent name is, for a short TTL (M3)."""
    now = time.monotonic()
    hit = _resolve_cache.get(host)
    if hit and now - hit[0] < _RESOLVE_TTL_SEC:
        return hit[1]
    neg = _negative_cache.get(host)
    if neg is not None and now - neg < _RESOLVE_NEG_TTL_SEC:
        return None
    try:
        addr = ipaddress.ip_address(host)
        addrs = [str(addr)]
        _resolve_cache[host] = (now, addrs)
        return addrs
    except ValueError:
        pass
    addrs, transient = _resolve_uncached(host, timeout)
    if addrs is None:
        if not transient:
            _negative_cache[host] = now
        return None
    _negative_cache.pop(host, None)
    _resolve_cache[host] = (now, addrs)
    return addrs or None


def _v4_internal_nets() -> list[ipaddress.IPv4Network]:
    return [
        ipaddress.ip_network("127.0.0.0/8"),  # loopback
        ipaddress.ip_network("10.0.0.0/8"),  # RFC1918
        ipaddress.ip_network("172.16.0.0/12"),  # RFC1918
        ipaddress.ip_network("192.168.0.0/16"),  # RFC1918
        ipaddress.ip_network("169.254.0.0/16"),  # link-local (cloud metadata)
        ipaddress.ip_network("100.64.0.0/10"),  # RFC 6598 CGN (Alibaba metadata)
        ipaddress.ip_network("0.0.0.0/8"),  # "this" network
        ipaddress.ip_network("255.255.255.255/32"),  # broadcast
        ipaddress.ip_network("224.0.0.0/4"),  # multicast
    ]


def _v6_internal_nets() -> list[ipaddress.IPv6Network]:
    return [
        ipaddress.ip_network("::1/128"),  # loopback
        ipaddress.ip_network("::/128"),  # unspecified
        ipaddress.ip_network("fe80::/10"),  # link-local
        ipaddress.ip_network("fc00::/7"),  # ULA (fd00:ec2::/80 covered)
        ipaddress.ip_network("ff00::/8"),  # multicast
        ipaddress.ip_network("64:ff9b::/96"),  # NAT64 (well-known)
        ipaddress.ip_network("64:ff9b:1::/48"),  # NAT64 (local-use)
        ipaddress.ip_network("::ffff:0:0/96"),  # v4-mapped (pre-normalized anyway)
    ]


def _addr_internal(addr: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    nets = _v4_internal_nets() if addr.version == 4 else _v6_internal_nets()
    return any(addr in net for net in nets)


def is_internal_sockaddr(origin_or_host: str) -> bool | None:
    """Part C classifier: True when ANY resolved address is internal,
    False when every address is external, None when the host cannot be
    resolved (the WRITE GATE treats None as REJECT — fail-closed F6).

    Reject set: loopback, RFC1918, link-local, ULA, RFC 6598 100.64/10,
    0.0.0.0/8, ::, broadcast, multicast (224/4 and ff00::/8),
    IPv4-compatible/mapped v6 (normalized into the v4 rules), NAT64
    64:ff9b::/96 and 64:ff9b:1::/48. ANY internal record rejects."""
    host = host_of(origin_or_host)
    if not host:
        return None
    addrs = resolve_host(host)
    if not addrs:
        return None
    for text in addrs:
        addr = _normalize_addr(text)
        if addr is None:
            return None  # unparseable resolver output: fail closed
        if _addr_internal(addr):
            return True
    return False


# Ranges a gateway node can NEVER legitimately occupy. Everything the
# internal classifier rejects EXCEPT the operator's own private network
# (loopback, RFC1918, ULA) — nodes legitimately live there, so a node
# request path cannot demand an allow_internal break-glass (H3). Cloud
# metadata (169.254.169.254, 100.100.100.200), multicast/unspecified and
# "this network" are never gateways, on any deployment.
_NODE_PRIVATE_V4 = (
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
_NODE_PRIVATE_V6 = (
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),  # ULA
)


def _addr_never_gateway(addr: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """True for internal classes that are never a gateway destination.
    Reuses _addr_internal, so the reject set has one definition."""
    if not _addr_internal(addr):
        return False
    allowed = _NODE_PRIVATE_V4 if addr.version == 4 else _NODE_PRIVATE_V6
    return not any(addr in net for net in allowed)


def connect_pins(origin_or_host: str) -> list[str] | None:
    """REQUEST-TIME SSRF gate + DNS pin (H1).

    Resolve NOW, classify EVERY returned address, and return the
    validated address list the caller must connect to. ``None`` means DO
    NOT CONNECT: resolution failed (fail-closed) or an address is in a
    range a gateway can never occupy. Loopback / RFC1918 / ULA are
    allowed here (private-network nodes are the product); an attacker
    flipping a public name to a private address gains nothing they did
    not already have by registering the private address directly, while
    the metadata ranges stay shut."""
    host = host_of(origin_or_host)
    if not host:
        return None
    addrs = resolve_host(host)
    if not addrs:
        return None
    validated: list[str] = []
    for text in addrs:
        addr = _normalize_addr(text)
        if addr is None:
            return None  # unparseable resolver output: fail closed
        if _addr_never_gateway(addr):
            logger.warning(
                "egress: refusing to connect to %s — %s is a non-routable/"
                "metadata address class (never a gateway)",
                _short_host(origin_or_host),
                addr,
            )
            return None
        validated.append(str(addr))
    return validated or None


class _PinNetworkBackend:
    """httpcore network backend that connects to the addresses validated
    by ``connect_pins`` instead of resolving the hostname again. The
    request still uses the original hostname, so Host, TLS SNI and
    certificate verification are unchanged — only the socket target is
    pinned, which removes the check-vs-connect TOCTOU window (H1)."""

    def __init__(self, inner, pins: dict[str, list[str]]):
        self._inner = inner
        self._pins = {h.strip().lower(): v for h, v in pins.items()}

    async def connect_tcp(self, host, port, timeout=None, local_address=None, socket_options=None):
        targets = self._pins.get((host or "").strip().lower())
        if not targets:
            return await self._inner.connect_tcp(
                host,
                port,
                timeout=timeout,
                local_address=local_address,
                socket_options=socket_options,
            )
        last: Exception | None = None
        for ip in targets:
            try:
                return await self._inner.connect_tcp(
                    ip,
                    port,
                    timeout=timeout,
                    local_address=local_address,
                    socket_options=socket_options,
                )
            except Exception as exc:  # try the next validated family
                last = exc
        raise last if last is not None else RuntimeError("no validated address")

    async def connect_unix_socket(self, *args, **kwargs):
        return await self._inner.connect_unix_socket(*args, **kwargs)

    async def sleep(self, seconds):
        return await self._inner.sleep(seconds)


def pinned_async_client(
    origin_or_host: str,
    *,
    timeout: float,
    verify: bool = True,
    trust_env: bool = True,
) -> "httpx.AsyncClient | None":
    """Build an httpx.AsyncClient whose TCP connects go to the addresses
    ``connect_pins`` just validated. Returns None when the host must not
    be contacted — callers MUST NOT connect in that case.

    The pin is installed on httpcore's network backend; if a future httpx
    release moves that seam the client is still built, but the request is
    only pre-validated (degraded, warned once)."""
    import httpx

    targets = connect_pins(origin_or_host)
    if targets is None:
        return None
    transport = httpx.AsyncHTTPTransport(verify=verify, trust_env=trust_env)
    host = host_of(origin_or_host)
    pool = getattr(transport, "_pool", None)
    backend = getattr(pool, "_network_backend", None)
    if host and backend is not None:
        try:
            pool._network_backend = _PinNetworkBackend(backend, {host: targets})
        except Exception:
            logger.warning(
                "egress: could not pin %s to validated addresses; connect-time classification only",
                _short_host(host),
                exc_info=True,
            )
    else:
        key = ("pin_unavailable", "")
        if key not in _warned:
            _warned.add(key)
            logger.warning(
                "egress: DNS pinning unavailable on this httpx/httpcore; "
                "outbound requests are validated but not pinned"
            )
    return httpx.AsyncClient(timeout=timeout, transport=transport)


class OutboundBodyTooLarge(RuntimeError):
    """An outbound response exceeded MAX_OUTBOUND_BODY_BYTES (H4)."""


async def read_body_capped(resp, *, max_bytes: int = MAX_OUTBOUND_BODY_BYTES) -> bytes:
    """Stream a response body, aborting as soon as it exceeds the cap
    (H4). Requires a streaming response (``client.stream``/``send`` with
    ``stream=True``); a buffered response defeats the cap."""
    buf = bytearray()
    async for chunk in resp.aiter_bytes():
        if len(buf) + len(chunk) > max_bytes:
            raise OutboundBodyTooLarge(f"response body exceeds {max_bytes} bytes")
        buf.extend(chunk)
    return bytes(buf)


def clear_resolve_cache() -> None:
    """Test hook — the matrix suite drives fresh resolutions."""
    _resolve_cache.clear()
    _negative_cache.clear()


# ---------------------------------------------------------------------------
# Part B: stats-token egress policy
# ---------------------------------------------------------------------------

_skipped_total = 0


def note_skipped_no_token(node: str, stats_host: str) -> None:
    """Bump nodes_skipped_no_token_total + loud warning (Part B/F3).
    Exposed in /api/nodes ONLY (the dashboard has no prometheus
    exposition — no new surface).

    The counter increments on every skip; the LOG LINE is emitted once
    per node per process and carries a truncated host, not the raw
    stats_host (L3: poll-cadence warnings leaked internal topology)."""
    global _skipped_total
    _skipped_total += 1
    key = ("skipped_no_token", node)
    if key in _warned:
        return
    _warned.add(key)
    logger.warning(
        "egress policy: skipped node %s — non-loopback stats_host %r has no "
        "per-node token; the global stats token never leaves this box",
        node,
        _short_host(stats_host),
    )


def note_global_token_offbox(node: str, stats_host: str) -> None:
    """M1 dormancy warning: with ``dash.egress_policy`` OFF the global
    JANUS_STATS_TOKEN still reaches every non-loopback stats origin —
    kept for compatibility with the documented legacy roll-out (the
    deploy script prints the same banner and per-node warning). This
    makes that known fail-open observable at runtime too, once per
    host, without changing token routing."""
    key = ("global_token_offbox", node)
    if key in _warned:
        return
    _warned.add(key)
    logger.warning(
        "egress policy OFF: node %s — the global JANUS_STATS_TOKEN is sent "
        "to non-loopback stats_host %r (legacy dormancy; enable "
        "dash.egress_policy and register per-node tokens to stop it)",
        node,
        _short_host(stats_host),
    )


def skipped_no_token_total() -> int:
    return _skipped_total


def stats_token_for(
    stats_host: str, ciphertext: str | None, global_token: str | None, *, policy_on: bool
) -> str | None:
    """The ONE policy helper every config.stats_token reader goes
    through (health poller, /stats proxy endpoints, merged logs, the
    fleet-command relay, test-connection paths).

    Returns the token to send, or None = DO NOT SEND ANY REQUEST for
    this node (poll skipped). Policy ON: the global token goes to
    loopback-literal origins ONLY; every other origin needs a per-node
    envelope. Policy OFF: legacy behavior (undecryptable/absent
    per-node token falls back to the global one) byte-preserved, but
    the off-box fallback now warns once per host (M1)."""
    if ciphertext:
        try:
            from .crypto import decrypt

            return decrypt(bytes.fromhex(ciphertext)).decode()
        except Exception:
            logger.warning("node stats token undecryptable")
            # fall through to the fallback decision below
    if not policy_on:
        host = host_of(stats_host)
        if global_token and host and not is_loopback_literal(host):
            note_global_token_offbox(host, stats_host)
        return global_token
    if is_loopback_literal(stats_host):
        return global_token
    return None


# ---------------------------------------------------------------------------
# Part B: the egress-policy knob (settings-table key `dash.egress_policy`)
# ---------------------------------------------------------------------------

EGRESS_POLICY_KEY = "dash.egress_policy"


def _env_seed_on() -> bool:
    """JANUS_DASH_EGRESS_POLICY is ONLY the first-boot default-off seed
    (settings win; the deploy assert reads the SETTING)."""
    import os

    return (os.getenv("JANUS_DASH_EGRESS_POLICY") or "").strip().lower() == "on"


async def egress_policy_on() -> bool:
    """Read the dash.egress_policy setting (JSON {"enabled": bool};
    a raw "on"/"off" string is tolerated). Missing/unreadable row falls
    back to the env seed — never fails the caller."""
    try:
        from . import database

        row = await database.fetchrow(
            "SELECT value FROM settings WHERE key = $1", EGRESS_POLICY_KEY
        )
        if row:
            raw = row["value"]
            try:
                val = json.loads(raw) if isinstance(raw, (str, bytes)) else raw
            except Exception:
                val = None
            if isinstance(val, dict) and isinstance(val.get("enabled"), bool):
                return val["enabled"]
            if isinstance(val, str) and val.strip().lower() in ("on", "off"):
                return val.strip().lower() == "on"
    except Exception:
        logger.warning("egress policy read failed; falling back to env seed", exc_info=True)
    return _env_seed_on()


async def egress_policy_retro_audit() -> list[str]:
    """One-time audit when the policy flips ON (Part B): nodes with a
    NON-loopback-literal stats_host and no per-node token envelope are
    REPORTED (warn, never block)."""
    from . import database

    rows = await database.fetch(
        "SELECT name, stats_host, stats_token_ciphertext FROM gateway_nodes WHERE enabled = true"
    )
    return [
        f"{r['name']} (stats_host={r['stats_host']!r} has no per-node token — "
        "its poll will be skipped until one is registered)"
        for r in rows
        if r["stats_token_ciphertext"] is None and not is_loopback_literal(r["stats_host"])
    ]


# ---------------------------------------------------------------------------
# Shared break-glass (operator role + confirm + reason) for the v2.2
# admin gates: allow_internal set/clear and the egress-policy knob.
# Same audited machinery as the Decisions write gate's force override.
# ---------------------------------------------------------------------------


def require_breakglass(request: Request, action: str) -> dict:
    """403 unless ?role=<non-empty>&reason=<non-empty> rides the
    request. Returns the pair for the audit line."""
    q = request.query_params
    role = (q.get("role") or "").strip()
    reason = (q.get("reason") or "").strip()
    if not role or not reason:
        raise HTTPException(
            403,
            detail={
                "error": {
                    "code": "role_reason_required",
                    "message": (
                        f"{action} is a break-glass admin gate: add non-empty "
                        "?role=<operator role>&reason=<why> (audited)"
                    ),
                }
            },
        )
    return {"role": role, "reason": reason}


def require_confirmed(body: dict, action: str) -> None:
    """The `confirm` leg of role + confirm + reason. Accepts either
    `confirmed` (generic, e.g. the egress-policy knob) or
    `allow_internal_confirmed` (the providers flag, matching the field
    the create body already names)."""
    if not (body.get("confirmed") is True or body.get("allow_internal_confirmed") is True):
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "confirm_required",
                    "message": f"{action}: send confirmed=true (audited break-glass)",
                }
            },
        )


# ---------------------------------------------------------------------------
# Part B: write-time stats_host/data_host validation (ALWAYS-ON —
# input validation is not a policy)
# ---------------------------------------------------------------------------


def _node_host_reject(field: str, host: str, addr: str) -> HTTPException:
    return HTTPException(
        400,
        detail={
            "error": {
                "code": "internal_host",
                "message": (
                    f"{field} resolves to {addr}, a non-routable/metadata "
                    "address class a gateway node can never occupy"
                ),
            }
        },
    )


def validate_node_host(value, field: str) -> str:
    """A node host field must be a bare host or an http(s):// origin
    (any path is stripped by the poller anyway); other schemes, empty
    values, and bare hosts containing paths are rejected.

    H3: the host is ALSO classified. Gateway nodes legitimately live on
    loopback/RFC1918/ULA, so those stay allowed (no allow_internal
    column exists on gateway_nodes — a full internal gate needs one);
    the classes that are never a gateway — cloud metadata link-local,
    100.64/10, 0.0.0.0/8, multicast, broadcast, unspecified — are
    rejected at write time, and again at every connect by
    ``connect_pins``. An unresolvable name is accepted here (a node may
    simply not be up yet); the request path re-checks each connect."""
    raw = (value or "").strip() if isinstance(value, str) else ""
    if not raw:
        raise HTTPException(
            400, detail={"error": {"code": "invalid", "message": f"{field} required"}}
        )
    if "://" in raw and not raw.lower().startswith(("http://", "https://")):
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "invalid_scheme",
                    "message": f"{field} must be a bare host or http(s):// origin",
                }
            },
        )
    if "://" not in raw and "/" in raw:
        raise HTTPException(
            400,
            detail={
                "error": {
                    "code": "invalid",
                    "message": f"{field} must be a bare host or a full http(s):// origin",
                }
            },
        )
    host = host_of(raw)
    if not host:
        raise HTTPException(
            400, detail={"error": {"code": "invalid", "message": f"{field} has no parseable host"}}
        )
    literal = _normalize_addr(host)
    if literal is not None:
        if _addr_never_gateway(literal):
            raise _node_host_reject(field, host, str(literal))
    else:
        for text in resolve_host(host) or []:
            addr = _normalize_addr(text)
            if addr is None or _addr_never_gateway(addr):
                raise _node_host_reject(field, host, text)
    return raw


# ---------------------------------------------------------------------------
# L2: the global TLS-verify opt-out is loud at import (boot) time. The
# env var still governs every outbound client; scope-narrowing it to the
# probe paths is owned by the modules that construct those clients.
# ---------------------------------------------------------------------------

try:
    from .config import config as _config

    _TLS_VERIFY_MODE = _config.upstream_tls_verify
except Exception:  # config unreadable at import: fall back to the env var
    _TLS_VERIFY_MODE = os.getenv("JANUS_UPSTREAM_TLS_VERIFY", "peer")

if (_TLS_VERIFY_MODE or "").strip().lower() == "none":
    logger.warning(
        "JANUS_UPSTREAM_TLS_VERIFY=none — certificate verification is "
        "DISABLED for every outbound dashboard client (node polling, "
        "decisions probes, entitlement sync, provider test-connection); "
        "a MITM of the management plane (including the stats token over "
        "https) will not be detected"
    )
