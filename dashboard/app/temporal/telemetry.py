"""OpenTelemetry for Temporal client + worker.

Opt-in via ``OTEL_EXPORTER_OTLP_ENDPOINT`` (same knob as the gateway).
``OTEL_SDK_DISABLED=true`` wins and skips setup entirely.

Uses Temporal's replay-safe ``create_tracer_provider`` + ``OpenTelemetryPlugin``
so workflow spans survive history replay. Soft-fails if the optional
``opentelemetry-*`` packages are missing so a stripped image still boots.
"""

from __future__ import annotations

import logging
import os
from typing import Any

log = logging.getLogger("janus.dashboard.temporal.telemetry")

_configured = False
_plugin_ready = False


def _sdk_disabled() -> bool:
    return (os.environ.get("OTEL_SDK_DISABLED") or "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )


def _endpoint() -> str:
    return (os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT") or "").strip()


def _service_name(default: str) -> str:
    return (os.environ.get("OTEL_SERVICE_NAME") or "").strip() or default


def setup_telemetry(*, service_name: str = "janus-temporal") -> None:
    """Install a global TracerProvider. Idempotent. Safe when export unset."""
    global _configured, _plugin_ready
    if _configured:
        return
    _configured = True

    if _sdk_disabled():
        log.info("OTEL_SDK_DISABLED set; Temporal OTEL skipped")
        return

    endpoint = _endpoint()
    if not endpoint:
        log.debug("OTEL_EXPORTER_OTLP_ENDPOINT unset; Temporal OTEL export off")
        return

    try:
        from opentelemetry import trace
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from temporalio.contrib.opentelemetry import create_tracer_provider
    except ImportError:
        log.warning(
            "opentelemetry packages missing; Temporal OTEL export skipped",
            exc_info=True,
        )
        return

    attrs: dict[str, str] = {"service.name": _service_name(service_name)}
    extra = (os.environ.get("OTEL_RESOURCE_ATTRIBUTES") or "").strip()
    if extra:
        for part in extra.split(","):
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            k, v = k.strip(), v.strip()
            if k and v:
                attrs[k] = v

    try:
        provider = create_tracer_provider(resource=Resource.create(attrs))
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )

        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
        trace.set_tracer_provider(provider)
        _plugin_ready = True
        host = endpoint.split("?")[0]
        if "@" in host:
            host = host.split("@", 1)[-1]
        log.info(
            "Temporal OTLP export enabled endpoint=%s service=%s",
            host,
            attrs["service.name"],
        )
    except Exception:
        log.warning("Temporal OTLP setup failed; continuing without export", exc_info=True)
        _plugin_ready = False


def connect_kwargs() -> dict[str, Any]:
    """Extra ``Client.connect`` kwargs: OpenTelemetryPlugin when export is live."""
    if not _plugin_ready and not _configured:
        # Caller may connect before setup_telemetry; try once with a generic name.
        setup_telemetry()
    if not _plugin_ready:
        return {}
    try:
        from temporalio.contrib.opentelemetry import OpenTelemetryPlugin

        return {"plugins": [OpenTelemetryPlugin()]}
    except Exception:
        log.warning("OpenTelemetryPlugin unavailable; Temporal spans off", exc_info=True)
        return {}


async def connect_client(*, host: str, namespace: str, service_name: str):
    """``Client.connect`` with Temporal OTEL plugin when configured."""
    setup_telemetry(service_name=service_name)
    from temporalio.client import Client

    return await Client.connect(host, namespace=namespace, **connect_kwargs())
