// Dashboard JSON API client: cookie session + CSRF header on mutations.

const BASE = '/dashboard/api'

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
  opts: { method?: string; body?: unknown; raw?: boolean } = {},
): Promise<T> {
  const method = opts.method ?? 'GET'
  const headers: Record<string, string> = {}
  if (opts.body !== undefined) headers['content-type'] = 'application/json'
  if (method !== 'GET' && csrf) headers['x-janus-csrf'] = csrf
  const res = await fetch(BASE + path, {
    method,
    headers,
    credentials: 'same-origin',
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  })
  if (res.status === 401) {
    window.location.href = '/dashboard/login'
    throw new ApiError('unauthorized', 'unauthorized', 401)
  }
  const data = res.status === 204 ? {} : await res.json().catch(() => ({}))
  if (!res.ok) {
    const err = data?.error ?? {}
    throw new ApiError(err.message ?? res.statusText, err.code ?? 'error', res.status)
  }
  return data as T
}
