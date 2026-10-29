"""Janus dashboard configuration from environment variables."""

import logging
import os
from urllib.parse import urlparse

logger = logging.getLogger("janus.dashboard.config")


def _int_env(name: str, default: int) -> int:
    v = os.getenv(name)
    if v and v.isdigit():
        return int(v)
    return default


def _float_env(name: str, default: float) -> float:
    v = os.getenv(name)
    try:
        return float(v) if v else default
    except ValueError:
        return default


def _bool_env(name: str, default: bool) -> bool:
    v = os.getenv(name)
    if v is None or v == "":
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


def _str_env(name: str, default: str = "") -> str:
    return os.getenv(name, default)


def _retention_days_env(name: str, default: int) -> int:
    """Retention knobs (Task 8): positive int days. Anything invalid
    (non-numeric, zero, negative) falls back to the default with a
    warning — a typo must never silently widen or zero a retention
    window."""
    v = os.getenv(name)
    if not v:
        return default
    try:
        days = int(v)
    except ValueError:
        days = 0
    if days < 1:
        logger.warning(
            "%s=%r invalid (positive int days required); using default %d",
            name,
            v,
            default,
        )
        return default
    return days


class Config:
    """Read-only config loaded once from environment."""

    def __init__(self) -> None:
        # Database (same Postgres the gateways share)
        self.db_host: str = _str_env("JANUS_DB_HOST", "localhost")
        self.db_port: int = _int_env("JANUS_DB_PORT", 5432)
        self.db_user: str = _str_env("JANUS_DB_USER", "janus")
        self.db_password: str = _str_env("JANUS_DB_PASSWORD")
        self.db_name: str = _str_env("JANUS_DB_NAME", "janus")

        # Dashboard auth
        self.dashboard_password: str = _str_env("JANUS_DASHBOARD_PASSWORD")
        self.jwt_secret: str = _str_env("JANUS_JWT_SECRET")
        self.session_ttl_sec: int = _int_env("JANUS_SESSION_TTL_SEC", 604800)  # 7 days
        self.max_login_fails: int = _int_env("JANUS_LOGIN_MAX_FAILS", 5)
        self.lockout_sec: int = _int_env("JANUS_LOGIN_LOCKOUT_SEC", 900)

        # Cloudflare Turnstile (login bot protection). Empty secret =
        # skip Siteverify (local / Vite auto-login). When set, login
        # requires a fresh token whose Siteverify hostname is in
        # TURNSTILE_HOSTNAMES (comma-separated; prod must not include
        # localhost).
        self.turnstile_secret: str = _str_env("TURNSTILE_SECRET")
        self.turnstile_hostnames: set[str] = {
            h.strip() for h in _str_env("TURNSTILE_HOSTNAMES").split(",") if h.strip()
        }

        # Secrets (must match the gateway for JSEC compat)
        self.secrets_key: str = _str_env("JANUS_SECRETS_KEY")
        self.api_key_pepper: str = _str_env("JANUS_API_KEY_PEPPER")

        # Server
        self.host: str = _str_env("JANUS_DASHBOARD_HOST", "0.0.0.0")
        self.port: int = _int_env("JANUS_DASHBOARD_PORT", 8091)

        # Node management
        self.stats_token: str = _str_env("JANUS_STATS_TOKEN")
        self.node_health_interval_sec: int = _int_env("JANUS_NODE_HEALTH_INTERVAL_SEC", 10)
        # Worker reachability probe (dashboard-side): the master's pool
        # renders workers "up" from cached hellos and only learns of a
        # silent dist-link death after the OS TCP keepalive timeout
        # (~2h). The dashboard probes each worker's dist port itself so
        # the Nodes page shows a truthful reach state within one cycle.
        self.worker_probe_interval_sec: int = _int_env("JANUS_WORKER_PROBE_INTERVAL_SEC", 30)
        self.worker_probe_timeout_sec: float = _float_env("JANUS_WORKER_PROBE_TIMEOUT_SEC", 2.0)
        self.worker_probe_port: int = _int_env("JANUS_WORKER_PROBE_PORT", 25672)

        # Model sync
        self.sync_interval_sec: int = _int_env("JANUS_MODEL_SYNC_INTERVAL_SEC", 21600)

        # Entitlement matrix (spec 2026-10-05 Part A)
        self.probe_max_calls: int = _int_env("JANUS_PROBE_MAX_CALLS", 1000)
        self.probe_daily_calls: int = _int_env("JANUS_PROBE_DAILY_CALLS", 5000)
        self.probe_timeout_sec: float = _float_env("JANUS_PROBE_TIMEOUT_SEC", 15.0)
        self.probe_spacing_ms: int = _int_env("JANUS_PROBE_SPACING_MS", 150)
        self.probe_wall_sec: int = _int_env("JANUS_PROBE_WALL_SEC", 600)
        self.entitlement_healing_interval_sec: int = _int_env(
            "JANUS_ENTITLEMENT_HEALING_INTERVAL_SEC", 900
        )
        # Periodic SYNTHETIC entitlement probing (healing_tick). Off =
        # the loop still runs refresh_from_traffic (usage-driven,
        # promote-only learning) but never re-probes providers; the
        # manual probe button and the traffic-triggered 429 canary
        # stay available either way.
        self.entitlement_synthetic_probes: bool = _bool_env(
            "JANUS_ENTITLEMENT_SYNTHETIC_PROBES", True
        )

        # Upstream TLS
        self.upstream_tls_verify: str = _str_env("JANUS_UPSTREAM_TLS_VERIFY", "peer")

        # GeoLite2-City (Maintenance refresh + deploy). Account/license
        # from MaxMind; path must match the master gateway mount.
        self.maxmind_account_id: str = _str_env("JANUS_MAXMIND_ACCOUNT_ID")
        self.maxmind_license_key: str = _str_env("JANUS_MAXMIND_LICENSE_KEY")
        self.mmdb_path: str = _str_env("JANUS_MMDB_PATH", "/var/lib/janus/geo/GeoLite2-City.mmdb")

        # Auto-router tier reorder loop (reorder spec 2026-10-11 Task 2).
        # JANUS_REORDER_LOOP=0 is the hard kill switch (A.29); the
        # leader-gateway name override picks WHICH registry node the
        # loop polls /stats from when the fleet has more than the master
        # registered (default: lowest-id enabled node).
        self.reorder_loop_enabled: bool = _str_env("JANUS_REORDER_LOOP", "1") not in (
            "0",
            "false",
            "off",
        )
        self.reorder_leader_node: str = _str_env("JANUS_REORDER_LEADER_NODE", "")

        # Trusted proxies for X-Forwarded-For. Unset means the login lockout
        # keys on the direct peer: behind the documented caddy deployment
        # every operator shares one bucket (main.py warns at startup).
        self.trusted_proxies: str = _str_env("JANUS_TRUSTED_PROXIES", "")

        # Alerting (observability-depth Task 6). The webhook URL is
        # validated once here at env load: http(s) only, no userinfo;
        # anything invalid is treated as unset (record-only mode) and
        # surfaced as a startup warning by the lifespan.
        raw_url = _str_env("JANUS_ALERT_WEBHOOK_URL", "").strip()
        self.alert_webhook_url, self.alert_webhook_host = _validate_webhook_url(raw_url)
        self.alert_webhook_invalid: bool = bool(raw_url) and not self.alert_webhook_url
        self.alert_rules_disabled: str = _str_env("JANUS_ALERT_RULES_DISABLED", "")
        self.alert_error_rate_pct: float = _float_env("JANUS_ALERT_ERROR_RATE_PCT", 20.0)
        self.alert_error_rate_min_total: int = _int_env("JANUS_ALERT_ERROR_RATE_MIN_TOTAL", 20)
        self.alert_for_cycles: int = _int_env("JANUS_ALERT_FOR_CYCLES", 2)
        self.alert_refire_cooldown_sec: int = _int_env("JANUS_ALERT_REFIRE_COOLDOWN_SEC", 1800)

        # Retention sweeper (observability-depth Task 8): nightly
        # deletes by ts cutoff — audit_events / gateway_log_events /
        # alert_events (the last only delivered or failed_permanent).
        self.audit_retention_days: int = _retention_days_env("JANUS_AUDIT_RETENTION_DAYS", 90)
        self.log_retention_days: int = _retention_days_env("JANUS_LOG_RETENTION_DAYS", 14)
        self.alert_retention_days: int = _retention_days_env("JANUS_ALERT_RETENTION_DAYS", 30)
        # Failure observability (spec 2026-10-13 sec 5): closed cool
        # episodes / finished task runs / ops events / markers older
        # than this are pruned; open episodes and unfinished runs never.
        self.ops_retention_days: int = _retention_days_env("JANUS_OPS_RETENTION_DAYS", 14)
        # Seed estimate for snapshot-seeded cool episodes: the gateway's
        # default cool window (janus_lb DEFAULT_COOLDOWN_MS, env
        # JANUS_LB_COOLDOWN_MS; v1 reads only the env, never the catalog).
        self.lb_cooldown_ms: int = max(1, _int_env("JANUS_LB_COOLDOWN_MS", 5000))

        # Portable config-backup body cap (spec 2026-10-14 §5.3). Read
        # once here; a change requires a dashboard restart. Default is
        # 4 MiB. Export still emits an over-cap document; restore
        # rejects at cap+1 bytes. Zero is a valid digit string to
        # _int_env but would reject every body, so it falls back.
        self.config_backup_max_bytes: int = _config_backup_max_bytes_env()

    @property
    def is_configured(self) -> bool:
        required = [
            self.db_password,
            self.dashboard_password,
            self.jwt_secret,
            self.secrets_key,
            self.api_key_pepper,
        ]
        return all(required)

    @property
    def trusted_proxy_list(self) -> list[str]:
        if not self.trusted_proxies:
            return []
        return [p.strip() for p in self.trusted_proxies.split(",") if p.strip()]

    @property
    def alert_webhook_configured(self) -> bool:
        return bool(self.alert_webhook_url)

    @property
    def alert_rules_disabled_set(self) -> set[str]:
        return {r.strip() for r in self.alert_rules_disabled.split(",") if r.strip()}


_CONFIG_BACKUP_MAX_BYTES_DEFAULT = 4194304


def _config_backup_max_bytes_env() -> int:
    """Positive JANUS_CONFIG_BACKUP_MAX_BYTES, else the 4 MiB default."""
    raw = os.getenv("JANUS_CONFIG_BACKUP_MAX_BYTES")
    cap = _int_env("JANUS_CONFIG_BACKUP_MAX_BYTES", _CONFIG_BACKUP_MAX_BYTES_DEFAULT)
    if cap < 1:
        logger.warning(
            "JANUS_CONFIG_BACKUP_MAX_BYTES=%r invalid (positive byte cap required); "
            "using default %d",
            raw,
            _CONFIG_BACKUP_MAX_BYTES_DEFAULT,
        )
        return _CONFIG_BACKUP_MAX_BYTES_DEFAULT
    return cap


def _validate_webhook_url(raw: str) -> tuple[str, str]:
    """Validate JANUS_ALERT_WEBHOOK_URL once at env load.

    Returns (url, host); ("", "") when unset or invalid. http(s) only,
    no userinfo (credentials must not ride the webhook URL into logs).
    """
    if not raw:
        return "", ""
    try:
        parsed = urlparse(raw)
    except ValueError:
        return "", ""
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return "", ""
    if parsed.username is not None or parsed.password is not None:
        return "", ""
    return raw, parsed.hostname


config = Config()
