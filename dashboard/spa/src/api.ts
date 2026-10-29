// Dashboard JSON API client: JWT auth via Authorization header.
// The token lives in module state and survives reloads via localStorage.

const BASE = "/api"
const TOKEN_KEY = "janus_jwt"

let jwtToken = localStorage.getItem(TOKEN_KEY) ?? ""

export function setToken(token: string) {
  jwtToken = token
  localStorage.setItem(TOKEN_KEY, token)
}

export function clearToken() {
  jwtToken = ""
  localStorage.removeItem(TOKEN_KEY)
}

// `storage` fires only in the *other* tabs, so this mirrors a token written
// there: a sign-out drops this tab's in-memory JWT and returns it to /login
// instead of letting a stateless token stay usable for the rest of its TTL.
window.addEventListener("storage", (event) => {
  if (event.key !== TOKEN_KEY) return
  jwtToken = event.newValue ?? ""
  if (!jwtToken && !window.location.pathname.startsWith("/login")) {
    window.location.href = "/login"
  }
})

export class ApiError extends Error {
  code: string
  status: number
  /** Extra fields from the API error object (e.g. prefixes). */
  extra: Record<string, unknown>
  constructor(
    message: string,
    code: string,
    status: number,
    extra: Record<string, unknown> = {},
  ) {
    super(message)
    this.code = code
    this.status = status
    this.extra = extra
  }
}

function authHeaders(extra?: Record<string, string>): Record<string, string> {
  const headers: Record<string, string> = { ...extra }
  if (jwtToken) headers["authorization"] = "Bearer " + jwtToken
  return headers
}

function errorFromBody(data: { error?: { message?: string; code?: string } }, res: Response): ApiError {
  const err = data?.error ?? {}
  const { message, code, ...rest } = err as {
    message?: string
    code?: string
    [k: string]: unknown
  }
  return new ApiError(
    message ?? res.statusText ?? "HTTP " + res.status,
    code ?? "error",
    res.status,
    rest,
  )
}

async function authorizedFetch(path: string, init: RequestInit): Promise<Response> {
  let res: Response
  try {
    res = await fetch(BASE + path, {
      ...init,
      credentials: "same-origin",
    })
  } catch {
    throw new ApiError("network error — check your connection", "network_error", 0)
  }

  if (res.status === 401) {
    const data = await res.json().catch(() => ({}))
    const err = data?.error ?? {}
    const { message, code, ...rest } = err as {
      message?: string
      code?: string
      [key: string]: unknown
    }
    // Only a dead session drops the token. Endpoint-level 401s (wrong
    // password, wrong TOTP code, expired challenge) are flow errors the
    // caller shows in place — they must not sign the operator out.
    if (!code || code === "unauthorized" || code === "token_expired") {
      clearToken()
      if (!window.location.pathname.startsWith("/login")) {
        window.location.href = "/login"
      }
    }
    throw new ApiError(message ?? "unauthorized", code ?? "unauthorized", 401, rest)
  }
  return res
}

export async function api<T = any>(
  path: string,
  opts: { method?: string; body?: unknown } = {},
): Promise<T> {
  const method = opts.method ?? "GET"
  const headers: Record<string, string> = {}
  if (opts.body !== undefined) headers["content-type"] = "application/json"
  const res = await authorizedFetch(path, {
    method,
    headers: authHeaders(headers),
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  })

  const data = res.status === 204 ? {} : await res.json().catch(() => ({}))
  if (!res.ok) throw errorFromBody(data, res)
  return data as T
}

/**
 * Authenticated fetch that returns the raw response on success.
 * Config backup export needs the bytes plus `X-Janus-Backup-Warning`;
 * restore posts the file unchanged (the JSON helper would re-serialize).
 */
export async function apiFetch(
  path: string,
  init: { method?: string; headers?: Record<string, string>; body?: BodyInit } = {},
): Promise<Response> {
  const res = await authorizedFetch(path, {
    method: init.method ?? "GET",
    headers: authHeaders(init.headers),
    body: init.body,
  })
  if (!res.ok) {
    const data = await res.json().catch(() => ({}))
    throw errorFromBody(data, res)
  }
  return res
}
