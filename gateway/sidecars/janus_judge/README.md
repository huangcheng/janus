# janus-judge sidecar

Local decision judge for `janus-auto` (`judge_backend=local`). Implements the
loopback HTTP contract in `design/auto-router/LOCAL-JUDGE-SPEC.md` §14.

## Endpoints

| Method | Path | Auth |
|--------|------|------|
| GET | `/healthz` | none |
| POST | `/admin/ensure` | `x-janus-judge-token` |
| POST | `/v1/decide` | `x-janus-judge-token` |

If `JANUS_JUDGE_TOKEN` is unset or empty, ensure and decide **fail closed**
(401).

## Environment

| Variable | Purpose |
|----------|---------|
| `JANUS_JUDGE_TOKEN` | Shared secret with the gateway (required for ensure/decide) |
| `JANUS_JUDGE_FIXTURE=1` | CI/dev: skip real Laya weights; ensure uses `testdata/golden.json` SHA256; decide reads golden tiers |

## Run locally

```bash
cd sidecars/janus_judge
pip install -r requirements.txt
export JANUS_JUDGE_TOKEN=dev-token
export JANUS_JUDGE_FIXTURE=1
python -m janus_judge.app
```

Listens on `127.0.0.1:8191` only.

## E2E (local gate)

The dashboard harness builds and runs this image beside `janus-gw`
(`--network container:janus-gw`, fixture mode). See `TF-A.L` in
`janus-dashboard/docs/TEST-FLOWS.md` and `scripts/e2e_local.sh` step 3d.

## Tests

```bash
cd sidecars/janus_judge
pip install -r requirements-dev.txt
pytest -q
```

## Docker

```bash
docker build -t janus-judge:local sidecars/janus_judge
docker run --rm -e JANUS_JUDGE_TOKEN=dev -e JANUS_JUDGE_FIXTURE=1 janus-judge:local
```

Root `docker-compose.yml` defines `janus-judge` with
`network_mode: "service:janus"` (no host publish), `JANUS_JUDGE_CACHE` volume,
shared `JANUS_JUDGE_TOKEN` with the `janus` service, and `/healthz`
healthcheck.
