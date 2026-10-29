"""Shared entitlement evidence classifier (spec 2026-10-05, A.2).

ONE classifier, used by the probe runner, the healing loop and the
traffic refresher. All rules are READ from the `entitlement_codes`
table (the single source of truth — no classifier owns rules, no second
copy exists):

- match_status='exact' rows match the provider-native error *code* field
  (case-insensitive equality or containment).
- match_status='regex' rows are applied to the error code and message
  fields ONLY — never whole response bodies (echoed request/prompt text
  inside a message must not classify). Patterns are compiled with
  IGNORECASE at load; rows that fail to compile are skipped (the admin
  API rejects them at write time; this is the reader-side belt).

Outcome ordering (the production failure this spec exists for):

- 429  -> dual class: balance/rate rows, exact first then regex;
          DEFAULT 'rate' (an unlisted provider retries, no cooldown —
          never benches a healthy key).
- 400/404 -> deny/input_shape rows, exact first then regex, then
          balance rows (billing wording can arrive as 400 too);
          DEFAULT 'input_shape' — fail-open. A false ok costs one
          failover attempt; a false deny removes a good key entirely.
- The phrases "no permission" / "unsupported operation" are seeded as
  input_shape, NOT deny (they fire on input-shape and content-policy
  paths). Deny wording is explicit activation/entitlement phrasing,
  anchored — the bare `product.*not.*activate` shape is forbidden (it
  matches "activation not required").

Callers handle the statuses this module does not classify: 2xx -> ok,
5xx/timeout -> skip+retry-once. 401/403 IS classified here, deny-first:
an explicit deny rule may claim the code (e.g. DashScope 403
AccessDenied.Unpurchased is a MODEL-level "not activated" condition —
marking the whole key broken for it benches good keys); unclaimed
401/403 returns 'key', which the caller maps to key-level broken.
"""

import asyncio
import re
import time
from dataclasses import dataclass, field

from . import database

# Regex rows are length-capped at write AND at load (defense in depth).
MAX_PATTERN_LEN = 256
# Rules cache TTL: short enough that admin edits apply quickly, long
# enough that per-probe-call classification never hits the DB.
_CACHE_TTL_SEC = 15.0


@dataclass
class CodeRule:
    provider: str
    kind: str  # 'exact' | 'regex'
    keyword: str
    outcome: str  # 'deny' | 'balance' | 'rate' | 'input_shape'
    pattern: "re.Pattern | None" = None


@dataclass
class EntitlementCodes:
    exact: list[CodeRule] = field(default_factory=list)
    regex: list[CodeRule] = field(default_factory=list)
    premark: dict[str, list[str]] = field(default_factory=dict)  # provider -> keywords
    key_scoped_balance: set[str] = field(default_factory=set)  # provider names

    def rules_for(self, provider: str) -> list[CodeRule]:
        """Provider-specific rows first, then provider='' (any provider)."""
        own = [r for r in self.exact + self.regex if r.provider == provider]
        shared = [r for r in self.exact + self.regex if r.provider == ""]
        # exact rows outrank regex rows regardless of provider scope
        exact = [r for r in own + shared if r.kind == "exact"]
        regex = [r for r in own + shared if r.kind == "regex"]
        return exact + regex


_cache: EntitlementCodes | None = None
_cache_at: float = 0.0
_cache_lock = asyncio.Lock()


def invalidate_codes_cache() -> None:
    """Drop the rules cache (called after any entitlement_codes write)."""
    global _cache, _cache_at
    _cache = None
    _cache_at = 0.0


async def load_codes(force: bool = False) -> EntitlementCodes:
    """Load classification rules from the entitlement_codes table (cached)."""
    global _cache, _cache_at
    if not force and _cache is not None and time.monotonic() - _cache_at < _CACHE_TTL_SEC:
        return _cache
    async with _cache_lock:
        if not force and _cache is not None and time.monotonic() - _cache_at < _CACHE_TTL_SEC:
            return _cache
        rows = await database.fetch(
            "SELECT provider, match_status, code_keyword, outcome FROM entitlement_codes"
        )
        bundle = EntitlementCodes()
        for r in rows:
            provider, kind, keyword, outcome = (
                r["provider"] or "",
                r["match_status"],
                r["code_keyword"] or "",
                r["outcome"] or "",
            )
            if outcome == "premark_input_shape":
                bundle.premark.setdefault(provider, []).append(keyword.lower())
                continue
            if not keyword or outcome not in ("deny", "balance", "rate", "input_shape"):
                continue
            pattern = None
            if kind == "regex":
                if len(keyword) > MAX_PATTERN_LEN:
                    continue
                try:
                    pattern = re.compile(keyword, re.IGNORECASE)
                except re.error:
                    continue  # unparseable row: skip, never crash a probe batch
            rule = CodeRule(provider, kind, keyword, outcome, pattern)
            (bundle.exact if kind == "exact" else bundle.regex).append(rule)
        # Provider-level key_scoped_balance flag: TRUE on any row of the provider.
        flag_rows = await database.fetch(
            "SELECT DISTINCT provider FROM entitlement_codes WHERE key_scoped_balance"
        )
        bundle.key_scoped_balance.update(r["provider"] for r in flag_rows)
        _cache = bundle
        _cache_at = time.monotonic()
        return bundle


def _exact_match(rule: CodeRule, code: str | None) -> bool:
    """Exact rows apply to the provider-native code field only."""
    if not code or not rule.keyword:
        return False
    kw = rule.keyword.lower()
    c = code.lower()
    return c == kw or kw in c


def _regex_match(rule: CodeRule, code: str | None, message: str | None) -> bool:
    """Regex rows apply to the code and message fields separately."""
    if rule.pattern is None:
        return False
    if code and rule.pattern.search(code):
        return True
    return bool(message and rule.pattern.search(message))


def classify(
    provider: str,
    http_status: int,
    error_code: str | None,
    error_message: str | None,
    codes: EntitlementCodes,
) -> str:
    """Classify an upstream error response.

    Returns one of 'deny' | 'balance' | 'rate' | 'input_shape' | 'key'.
    2xx / 5xx / timeouts are decided by the caller (they are status-line
    facts, not classification). 401/403 returns 'key' unless a deny rule
    explicitly claims the code (model-level activation wording) — the
    caller maps 'key' to the key-level broken verdict.
    """
    rules = codes.rules_for(provider)

    if http_status in (401, 403):
        # Deny-first (production incident 2026-10-18: DashScope
        # 403 AccessDenied.Unpurchased benched two healthy keys).
        for r in rules:
            if r.outcome != "deny":
                continue
            if (r.kind == "exact" and _exact_match(r, error_code)) or (
                r.kind == "regex" and _regex_match(r, error_code, error_message)
            ):
                return "deny"
        return "key"

    if http_status == 429:
        # Dual class: balance vs rate keywords; default rate.
        for r in rules:
            if r.outcome not in ("balance", "rate"):
                continue
            if (r.kind == "exact" and _exact_match(r, error_code)) or (
                r.kind == "regex" and _regex_match(r, error_code, error_message)
            ):
                return r.outcome
        return "rate"

    if http_status in (400, 404, 402, 405, 422):
        # Deny / input-shape classes first, then billing wording that
        # arrived on a non-429 status; default input_shape (fail-open).
        for r in rules:
            if r.outcome not in ("deny", "input_shape"):
                continue
            if (r.kind == "exact" and _exact_match(r, error_code)) or (
                r.kind == "regex" and _regex_match(r, error_code, error_message)
            ):
                return r.outcome
        for r in rules:
            if r.outcome != "balance":
                continue
            if (r.kind == "exact" and _exact_match(r, error_code)) or (
                r.kind == "regex" and _regex_match(r, error_code, error_message)
            ):
                return r.outcome
        return "input_shape"

    # Anything else (odd 4xx/5xx bodies the caller did not pre-decide):
    # fail open, never deny.
    return "input_shape"


def extract_error_fields(payload) -> tuple[str | None, str | None]:
    """Pull (code, message) out of a provider error JSON body.

    Handles the common shapes: {"error": {"code", "message"}}, DashScope
    {"code", "message"/"msg"}, zhipu {"error": {"code", "message"}}.
    Numeric codes are stringified ('1113').
    """
    if not isinstance(payload, dict):
        return None, None
    err = payload.get("error")
    code = message = None
    if isinstance(err, dict):
        code = err.get("code")
        message = err.get("message") or err.get("msg")
    if code is None:
        code = payload.get("code")
    if message is None:
        message = payload.get("message") or payload.get("msg")
    return (
        str(code) if code is not None else None,
        str(message)[:2048] if message is not None else None,
    )


def premark_match(provider: str, listing_name: str, codes: EntitlementCodes) -> bool:
    """Does this listing belong to a premarked modality family?

    Substring match on the listing name against the provider's
    premark_input_shape keywords plus the provider='' (shared) ones.
    """
    lowered = listing_name.lower()
    for scope in (provider, ""):
        for kw in codes.premark.get(scope, ()):
            if kw and kw in lowered:
                return True
    return False
