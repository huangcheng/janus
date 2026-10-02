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

## Design references

`design/admin-ui/` holds the HTML blueprint (layout, modals, motion tokens)
and `api.html` documents the HTTP contract the SPA consumes.
