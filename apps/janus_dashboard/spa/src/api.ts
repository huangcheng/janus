// Dashboard JSON API client: cookie session + CSRF header on mutations.

const BASE = '/api'

let csrf = ''

export function setCsrf(token: string) {
  csrf = token
}

export class ApiError extends Error {
  code: string
  status: number
  constructor(message: string, code: string, status: number) {
    super(message)
    this.code = code
    this.status = status
  }
}

export async function api<T = any>(
  path: string,
  opts: { method?: string; body?: unknown } = {},
): Promise<T> {
  const method = opts.method ?? 'GET'
  const headers: Record<string, string> = {}
  if (opts.body !== undefined) headers['content-type'] = 'application/json'
  if (method !== 'GET' && csrf) headers['x-janus-csrf'] = csrf

  let res: Response
  try {
    res = await fetch(BASE + path, {
      method,
      headers,
      credentials: 'same-origin',
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    })
  } catch {
    // Network failure / CORS / DNS — surface as a normal ApiError
    throw new ApiError('network error — check your connection', 'network_error', 0)
  }

  if (res.status === 401) {
    // Don't redirect when already on /login (the login POST itself
    // returns 401 on wrong password — same-URL assignment would
    // reload the page and wipe the inline error message).
    if (!window.location.pathname.startsWith('/login')) {
      window.location.href = '/login'
    }
    const data = await res.json().catch(() => ({}))
    const err = data?.error ?? {}
    throw new ApiError(err.message ?? 'unauthorized', err.code ?? 'unauthorized', 401)
  }

  const data = res.status === 204 ? {} : await res.json().catch(() => ({}))
  if (!res.ok) {
    const err = data?.error ?? {}
    throw new ApiError(
      err.message ?? res.statusText ?? `HTTP ${res.status}`,
      err.code ?? 'error',
      res.status,
    )
  }
  return data as T
}
