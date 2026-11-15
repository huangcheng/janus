"""Telemetry setup stays quiet when OTEL is unset / disabled."""

from __future__ import annotations

from app.temporal import telemetry as tel


def test_setup_noop_without_endpoint(monkeypatch):
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_ENDPOINT", raising=False)
    monkeypatch.delenv("OTEL_SDK_DISABLED", raising=False)
    tel._configured = False
    tel._plugin_ready = False
    tel.setup_telemetry(service_name="janus-worker")
    assert tel._configured is True
    assert tel._plugin_ready is False
    assert tel.connect_kwargs() == {}


def test_setup_skipped_when_sdk_disabled(monkeypatch):
    monkeypatch.setenv("OTEL_SDK_DISABLED", "true")
    monkeypatch.setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://example.invalid:4318")
    tel._configured = False
    tel._plugin_ready = False
    tel.setup_telemetry(service_name="janus-worker")
    assert tel._configured is True
    assert tel._plugin_ready is False
