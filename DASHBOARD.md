# Janus Dashboard console

Operator UI for the Janus LLM gateway. React SPA (TanStack Router) served by a
dedicated Cowboy listener on the dashboard plane — completely separate from the
data plane (`:8080`).

## Quick start

```bash
docker build -t janus:dashboard .
docker run -d --name janus \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8090:8090 \
  -e JANUS_SECRETS_KEY="k1:<base64 of 32 bytes>" \
  -e JANUS_API_KEY_PEPPER="<random>" \
  -e JANUS_DASHBOARD_PASSWORD="<operator password>" \
  janus:dashboard
# open http://127.0.0.1:8090/dashboard
```

On a server, pull the CI-built image instead (no local build needed):

```bash
docker pull ghcr.io/huangcheng/janus:main   # or :v0.1.0 / :sha-<commit>
```

Pushes to `main` (and `v*` tags) build multi-arch (amd64/arm64) images via
GitHub Actions and publish them to GHCR — see `.github/workflows/docker.yml`.
First published package inherits the repo's visibility (private by default).

Unset `JANUS_DASHBOARD_PASSWORD` ⇒ logins are refused (fail closed).

`JANUS_ROLE=gateway` does not start this listener (agent plane only).
`JANUS_ROLE=dashboard` starts `:8090` and skips `:8080`. Default is both.

## Behind a reverse proxy (production)

With Caddy/Nginx terminating TLS, set `JANUS_PUBLIC_URL` to the public base
URL agents use for the data plane — the console sidebar renders its copyable
endpoints from it:

```bash
-e JANUS_PUBLIC_URL="https://api.example.com"
```

Caddy can also route both planes under one domain (the console then shows
same-origin endpoints and `JANUS_PUBLIC_URL` may be omitted):

```caddy
llm.example.com {
    handle /v1/* {
        reverse_proxy 127.0.0.1:8080   # data plane
    }
    handle {
        reverse_proxy 127.0.0.1:8090   # dashboard console
    }
}
```

Resolution order in the console: `JANUS_PUBLIC_URL` → same origin (page
served on 80/443) → console host on `:8080` (local dev).

## Architecture

```
/api/*      Cowboy → janus_dashboard_api    (JSON, cookie session + CSRF)
/dashboard/*          Cowboy → janus_dashboard_assets (SPA shell + built assets)
data plane :8080  unchanged (janus_http)
```

- **Frontend**: `apps/janus_dashboard/spa` — Vite + React + TypeScript +
  TanStack Router (code-based routes, `basepath: '/dashboard'`). Built in the
  first Docker stage; `dist/` lands in `priv/www` of the release.
  Local dev: `npm run dev` proxies `/api` to `127.0.0.1:8090`.
- **Backend**: `apps/janus_dashboard/src`
  - `janus_dashboard_sup` — listener (default `0.0.0.0:8090` in Docker; env
    overrides `JANUS_DASHBOARD_BIND` / `JANUS_DASHBOARD_PORT`)
  - `janus_dashboard_session` — password login (constant-time compare), 12h
    sessions, per-IP lockout (5 fails / 15 min), CSRF tokens
  - `janus_dashboard_audit` — in-memory ring buffer (last 1000 events)
  - `janus_dashboard_store` — DB facade (SQLite + Postgres), generation bump
  - `janus_dashboard_api` — the HTTP contract (see `design/dashboard-ui/api.html`)

## Security posture

- dashboard plane never shares the data-plane listener; publish it on host
  loopback or behind Caddy (TLS + optional IP allowlist). Set
  `{secure_cookies, true}` (or app env) when serving over HTTPS.
- Mutations require the `X-Janus-CSRF` header; the SPA stores the token
  from the session response.
- Provider secrets are AES-256-GCM envelopes (`janus_secrets`) — write-only.
- Agent keys are peppered HMAC hashes; the plaintext appears exactly once,
  in the `201` response of `POST /api/keys`.
- Every mutation and login attempt is audited.

## Local development

Docker runs the *release* (no hot reload) — that build is only for preview
and deployment. For day-to-day work there is **one command**:

```bash
cd apps/janus_dashboard/spa
npm run dev
# predev hook starts the janus-dev backend container if needed, then Vite
# comes up with HMR. Open http://127.0.0.1:3000/dashboard  (password: dev)
```

- Frontend edits appear instantly via Vite HMR — Docker is untouched.
- Backend (Erlang) changes are the only thing that needs
  `docker build -t janus:dashboard .` (+ `docker rm -f janus-dev` so the
  predev hook recreates it).
- `vite.config.ts` proxies `/api/*` to the container's dashboard plane
  (`127.0.0.1:8090`); cookies and CSRF behave exactly like production.
- The `8090` container port serves the *built* SPA — use it when you want
  to preview what ships, not while iterating.

Why not `rebar3 shell` natively on this machine: the host Erlang install has
a broken `bin/erl` (multi-erts in-place upgrade mismatch — invoke
`erts-17.1/bin/erl.exe` directly if you need it) and there is no C compiler
for the esqlite NIF, so the container is the supported backend dev loop
here. On a machine with a clean OTP + gcc, `./rebar3 shell` with the same
env vars works too.

## Design references

`design/dashboard-ui/` holds the HTML blueprint (layout, modals, motion tokens)
and `api.html` documents the HTTP contract the SPA consumes.
