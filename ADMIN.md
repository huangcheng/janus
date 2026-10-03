# Janus Admin Console

Operator UI for the Janus LLM gateway. React SPA (TanStack Router) served by a
dedicated Cowboy listener on the admin plane — completely separate from the
data plane (`:8080`).

## Quick start

```bash
docker build -t janus:admin-ui .
docker run -d --name janus \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8090:8090 \
  -e JANUS_SECRETS_KEY="k1:<base64 of 32 bytes>" \
  -e JANUS_API_KEY_PEPPER="<random>" \
  -e JANUS_ADMIN_PASSWORD="<operator password>" \
  janus:admin-ui
# open http://127.0.0.1:8090/admin
```

Unset `JANUS_ADMIN_PASSWORD` ⇒ logins are refused (fail closed).

## Architecture

```
/admin/api/*      Cowboy → janus_admin_api    (JSON, cookie session + CSRF)
/admin/*          Cowboy → janus_admin_assets (SPA shell + built assets)
data plane :8080  unchanged (janus_http)
```

- **Frontend**: `apps/janus_admin/spa` — Vite + React + TypeScript +
  TanStack Router (code-based routes, `basepath: '/admin'`). Built in the
  first Docker stage; `dist/` lands in `priv/www` of the release.
  Local dev: `npm run dev` proxies `/admin/api` to `127.0.0.1:8090`.
- **Backend**: `apps/janus_admin/src`
  - `janus_admin_sup` — listener (default `0.0.0.0:8090` in Docker; env
    overrides `JANUS_ADMIN_BIND` / `JANUS_ADMIN_PORT`)
  - `janus_admin_session` — password login (constant-time compare), 12h
    sessions, per-IP lockout (5 fails / 15 min), CSRF tokens
  - `janus_admin_audit` — in-memory ring buffer (last 1000 events)
  - `janus_admin_store` — DB facade (SQLite + Postgres), generation bump
  - `janus_admin_api` — the HTTP contract (see `design/admin-ui/api.html`)

## Security posture

- Admin plane never shares the data-plane listener; publish it on host
  loopback or behind Caddy (TLS + optional IP allowlist). Set
  `{secure_cookies, true}` (or app env) when serving over HTTPS.
- Mutations require the `X-Janus-CSRF` header; the SPA stores the token
  from the session response.
- Provider secrets are AES-256-GCM envelopes (`janus_secrets`) — write-only.
- Agent keys are peppered HMAC hashes; the plaintext appears exactly once,
  in the `201` response of `POST /admin/api/keys`.
- Every mutation and login attempt is audited.

## Local development

Docker runs the *release* (no hot reload). For day-to-day dev, split the two
planes: SPA on Vite (full HMR), backend stays in a container and only
restarts when Erlang code changes.

```bash
# terminal 1 — backend (rebuild only when Erlang changes; SPA stage is cached)
docker run -d --name janus-dev \
  -p 127.0.0.1:8080:8080 -p 127.0.0.1:8090:8090 \
  -e JANUS_SECRETS_KEY="k1:$(node -e "console.log(require('crypto').randomBytes(32).toString('base64'))")" \
  -e JANUS_API_KEY_PEPPER=dev-pepper \
  -e JANUS_ADMIN_PASSWORD=dev \
  janus:admin-ui

# terminal 2 — SPA with hot reload
cd apps/janus_admin/spa
npm install
npm run dev
# open http://127.0.0.1:3000/admin
```

How it fits together:

- Vite serves the SPA at `127.0.0.1:3000/admin` (router `basepath:
  '/admin'`; port pinned to 3000 because Windows often reserves the 5xxx
  range for Hyper-V) with HMR — edits appear instantly, no rebuild.
- `vite.config.ts` proxies `/admin/api/*` to `127.0.0.1:8090` (the
  container's admin plane). Cookies and CSRF flow through the proxy, so
  login works exactly like production.
- Erlang changes: `docker build -t janus:admin-ui . && docker rm -f janus-dev`
  + rerun the command above (the Erlang compile layer is what rebuilds;
  it's a couple of minutes, the SPA stage stays cached).
- Need a fresh DB? `docker rm -f janus-dev` wipes the container's SQLite.

Why not `rebar3 shell` natively on this machine: the host Erlang install has
a broken `bin/erl` (multi-erts in-place upgrade mismatch — invoke
`erts-17.1/bin/erl.exe` directly if you need it) and there is no C compiler
for the esqlite NIF, so the container is the supported backend dev loop
here. On a machine with a clean OTP + gcc, `./rebar3 shell` with the same
env vars works too.

## Design references

`design/admin-ui/` holds the HTML blueprint (layout, modals, motion tokens)
and `api.html` documents the HTTP contract the SPA consumes.
