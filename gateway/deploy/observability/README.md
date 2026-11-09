# Observability stack (example)

A minimal Prometheus + Tempo + Grafana stack for a Janus deployment.
Nothing here is specific to any one fleet: the files are templates, and
the real values live in the operator's own environment.

## What is here

| File | Purpose |
|---|---|
| `docker-compose.yml.example` | Prometheus + Tempo + Grafana, all bound to `127.0.0.1` on high ports |
| `prometheus.yml.example` | Scrape config; the gateway target arrives over a tunnel |
| `tempo.yaml.example` | OTLP/HTTP receiver + local trace storage |
| `janus-overview.json` | Grafana dashboard, provisions from this file |

## Why the gateway target is a localhost port

The gateway's admin plane (`/metrics`, `/stats`) binds only to docker
bridge addresses on its own host — never to a public interface. So the
scrape target is a **tunnel endpoint**, not the gateway's address:

```
gateway host: 127.0.0.1:8090  --ssh -L-->  observability host: <bridge>:38945
```

An outbound-initiated tunnel means no inbound port is opened on the
gateway, and the admin bearer token never crosses the public internet in
clear. `prometheus.yml.example` points at `<docker-bridge-gateway>:38945`
because Prometheus runs in a container and cannot reach the *host's*
loopback; publish the tunnel on the docker bridge gateway address instead.

## Dashboard

Provision `janus-overview.json` or import it through the UI. Its panels
depend on:

- gateway series (`janus_requests_total`, `janus_request_duration_seconds`,
  `janus_upstream_requests_total`, scheduler and LB series)
- the OTLP exporter series (`janus_otel_export_*`), which are absent until
  the exporter has actually run

A panel showing "No data" for an exporter series is meaningful: it means
nothing has been exported yet. The exporter deliberately omits
`last_success_age_seconds` and `last_error` until they have a real value,
rather than reporting a fabricated 0.
