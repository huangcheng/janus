"""Single source of truth for outbound upstream URLs and TLS policy.

The gateway builds every upstream request by joining a fixed suffix onto
the stored ``providers.base_url`` (``janus_providers_http:join_path/2``);
it never inserts a version segment. The catalog convention is therefore
"the version belongs to base_url": ``https://api.anthropic.com/v1`` plus
``/messages``. The dashboard must build the same URL for entitlement
probes, the key/listing test, and model sync. Review 2026-10-17 H1 found
three mutually exclusive conventions in this repo (``/v1/messages``,
``/models``, ``/v1/models``), so at most one of them could be right for
any given stored value — and the wrong one fabricates ``ok`` evidence.

``versioned_base()`` accepts a legacy host-only base (the old SPA preset
for Anthropic) by appending ``/v1`` exactly once, so an already-versioned
base can never double-stack ``/v1/v1`` while a host-only base still
probes the real API. Protocol dispatch lives here too, including
``openai_decisions`` (whose native face is ``/decisions``, not the chat
completions path — review 2026-10-17 H2).

TLS verification is parsed against the gateway's vocabulary
(``JANUS_UPSTREAM_TLS_VERIFY``: ``peer`` = verify, ``none`` = do not
verify). Any other spelling verifies and warns once, instead of silently
changing meaning (review L1).
"""

import logging
import re

from .config import config

logger = logging.getLogger("janus.dashboard.probe_urls")

ANTHROPIC_PROTOCOL = "anthropic_messages"

# Protocol -> suffix the gateway joins onto base_url. The fallback is the
# OpenAI chat path, matching the gateway's catch-all probe clause.
_PROBE_PATHS: dict[str, str] = {
    ANTHROPIC_PROTOCOL: "/messages",
    "openai_chat": "/chat/completions",
    "openai_responses": "/responses",
    "openai_decisions": "/decisions",
}
_CHAT_PATH = "/chat/completions"

# A version segment already present in the stored base ("/v1", "/v1beta",
# "/v4", …) is kept as-is. Bases without one are legacy host-only values:
# they get exactly one "/v1", never "/v1/v1".
_VERSION_SEGMENT = re.compile(r"/v\d+[a-z0-9.]*$", re.IGNORECASE)


def versioned_base(base_url: str) -> str:
    """Return the catalog base with its API version segment, once."""
    base = (base_url or "").strip().rstrip("/")
    if not base:
        return base
    if _VERSION_SEGMENT.search(base):
        return base
    return base + "/v1"


def probe_url(base_url: str, protocol: str) -> str:
    """The protocol-correct upstream URL for a one-shot probe."""
    return versioned_base(base_url) + _PROBE_PATHS.get(protocol, _CHAT_PATH)


def models_url(base_url: str) -> str:
    """The upstream model-list URL used by sync and the key test."""
    return versioned_base(base_url) + "/models"


def canonical_base(base_url: str, protocol: str) -> str:
    """The base_url to STORE for a protocol.

    The gateway joins a fixed suffix onto the stored value and never inserts a
    version segment of its own, so a host-only Anthropic base produces
    ``/messages`` where the vendor serves ``/v1/messages``. Normalising on write
    means a hand-typed value, or one from an older SPA preset, still works on the
    data plane. ``versioned_base/1`` is idempotent, so an already-versioned base
    is returned unchanged and ``/v1/v1`` stays impossible.
    """
    base = (base_url or "").strip().rstrip("/")
    return versioned_base(base) if protocol == ANTHROPIC_PROTOCOL else base


def models_request(base_url: str, protocol: str, secret: str) -> tuple[str, dict]:
    """(url, headers) for GET {base}/{models} with the provider's auth.

    Anthropic uses ``x-api-key`` + ``anthropic-version`` (a Bearer header
    there answers 401), every OpenAI-compatible protocol uses Bearer.
    """
    url = models_url(base_url)
    if protocol == ANTHROPIC_PROTOCOL:
        return url, {
            "x-api-key": secret,
            "anthropic-version": "2023-06-01",
            "accept": "application/json",
        }
    return url, {"authorization": f"Bearer {secret}", "accept": "application/json"}


_warned_modes: set[str] = set()


def tls_verify() -> bool:
    """httpx ``verify`` value from JANUS_UPSTREAM_TLS_VERIFY.

    Mirrors the gateway exactly: only ``none`` disables verification.
    Unrecognised spellings fail closed to verification and warn once, so
    a typo cannot silently change the security posture.
    """
    raw = config.upstream_tls_verify
    mode = (raw or "").strip().lower()
    if mode == "none":
        return False
    if mode == "peer":
        return True
    if mode not in _warned_modes:
        _warned_modes.add(mode)
        logger.warning(
            "unrecognised JANUS_UPSTREAM_TLS_VERIFY=%r — verifying peer "
            "certificates (gateway vocabulary: 'peer' | 'none')",
            raw,
        )
    return True
