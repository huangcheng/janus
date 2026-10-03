// Page components for the Janus admin console.

import { FormEvent, Fragment, useEffect, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { api, setCsrf } from './api'
import { Layout, Loading, Modal, Pill, Row, ErrorFlash, ThemeToggle, useToast } from './components'

type Provider = { id: number; name: string; base_url: string; protocol: string; enabled: boolean; keys: KeyMeta[] }
type KeyMeta = { id: number; key_id: string; weight: number; enabled: boolean }
type Model = { id: number; name: string; enabled: boolean; routes: Route[] }
type Route = { model_id: number; provider_id: number; provider_name: string | null; upstream_model_id: string | null; weight: number; priority: number; enabled: boolean }
type AgentKey = { id: number; prefix: string; enabled: boolean; created_at: string; model_ids: number[]; model_names: (string | null)[] }
type AuditEvent = { ts: string; actor: string; action: string; target: string | null; detail: string | null }

// ===================== Login =====================

export function Login() {
  const nav = useNavigate()
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError('')
    try {
      const res = await api('/session', { method: 'POST', body: { password } })
      setCsrf(res.csrf)
      nav({ to: '/' })
    } catch (err: any) {
      setError(err.message ?? 'login failed')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-wrap">
      <div className="login-theme-toggle"><ThemeToggle /></div>
      <main className="login-card">
        <div className="inner">
          <div className="logo">
            <img src={`${import.meta.env.BASE_URL}icon.png`} alt="Janus" />
            <div>
              <div className="logo-name">Janus</div>
              <div className="logo-sub">gateway console</div>
            </div>
          </div>
          <h1>Sign in</h1>
          <p className="sub">Operator access to the Janus LLM gateway.</p>
          {error && <div className="flash err">{error}</div>}
          <form onSubmit={submit}>
            <label className="f">Admin password
              <input
                type="password"
                name="password"
                autoFocus
                autoComplete="current-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </label>
            <button className="btn primary" disabled={busy || !password}>
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </form>
          <div className="login-foot">
            Single operator password — set via <code>JANUS_ADMIN_PASSWORD</code>.<br />
            5 failed attempts lock the source IP for 15&nbsp;min · sessions expire after 12&nbsp;h.
          </div>
        </div>
      </main>
    </div>
  )
}

// ===================== Dashboard =====================

export function Dashboard() {
  const [data, setData] = useState<any>(null)
  const [error, setError] = useState('')
  const toast = useToast()

  const load = () => api('/overview').then(setData).catch((e) => setError(e.message))

  useEffect(() => { load() }, [])

  const reload = async () => {
    try {
      const res = await api('/catalog/reload', { method: 'POST', body: {} })
      toast('ok', `Catalog reloaded — generation ${res.generation}`)
      await load()
    } catch (e: any) {
      toast('err', e.message)
    }
  }

  if (error) return <Layout title="Dashboard" eyebrow="Gateway · Overview"><ErrorFlash message={error} /></Layout>
  if (!data) return <Layout title="Dashboard" eyebrow="Gateway · Overview"><Loading /></Layout>

  const c = data.counts
  return (
    <Layout title="Dashboard" eyebrow="Gateway · Overview" sub="Configuration state and upstream health at a glance.">
      <div className="stat-grid">
        <div className="stat"><div className="inner">
          <div className={`value ${data.ready ? 'ok' : ''}`}>{data.ready ? 'ready' : 'cold'}</div>
          <div className="label">Catalog state</div>
        </div></div>
        <div className="stat"><div className="inner">
          <div className="value">{data.generation}</div>
          <div className="label">Serving generation</div>
        </div></div>
        <div className="stat"><div className="inner">
          <div className="value">{String(data.backend)}</div>
          <div className="label">DB backend</div>
        </div></div>
        <div className="stat"><div className="inner">
          <div className="value">{c.providers}</div><div className="label">Providers</div>
        </div></div>
        <div className="stat"><div className="inner">
          <div className="value">{c.models}</div><div className="label">Models</div>
        </div></div>
        <div className="stat"><div className="inner">
          <div className="value">{c.routes}</div><div className="label">Routes</div>
        </div></div>
        <div className="stat"><div className="inner">
          <div className="value">{c.agent_keys}</div><div className="label">Agent keys</div>
        </div></div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 20 }}>
        <button className="btn primary" onClick={reload}>Reload catalog ↻</button>
      </div>

      <div className="grid-2">
        <section className="panel">
          <div className="panel-head"><h2>Providers</h2><span className="hint">health as of last reload</span></div>
          <table className="tbl">
            <thead><tr><th>Provider</th><th>Protocol</th><th>Keys</th><th>State</th></tr></thead>
            <tbody>
              {data.providers.map((p: any, i: number) => (
                <Row key={p.id} index={i}>
                  <td className="name">{p.name}</td>
                  <td className="dim mono">{p.protocol}</td>
                  <td className="num">{p.keys}</td>
                  <td><Pill enabled={p.enabled} /></td>
                </Row>
              ))}
            </tbody>
          </table>
        </section>

        <section className="panel">
          <div className="panel-head"><h2>Recent admin actions</h2><span className="hint">last 5</span></div>
          <table className="tbl">
            <thead><tr><th>When</th><th>Action</th><th>Target</th></tr></thead>
            <tbody>
              {data.recent_audit.map((a: AuditEvent, i: number) => (
                <Row key={i} index={i}>
                  <td className="dim mono">{(a.ts ?? '').slice(11, 19)}</td>
                  <td className="mono">{a.action}</td>
                  <td className="mono dim">{a.target ?? '—'}</td>
                </Row>
              ))}
              {data.recent_audit.length === 0 && (
                <tr><td colSpan={3} className="empty">No admin actions yet.</td></tr>
              )}
            </tbody>
          </table>
        </section>
      </div>
    </Layout>
  )
}

// ===================== Providers =====================

export function Providers() {
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState('')
  const [loaded, setLoaded] = useState(false)
  const [expanded, setExpanded] = useState<number | null>(null)
  const [modal, setModal] = useState<'add' | { addKey: Provider } | { del: Provider } | { delKey: [Provider, KeyMeta] } | null>(null)
  const toast = useToast()

  const load = () =>
    api('/providers').then((r) => { setProviders(r.providers); setLoaded(true) }).catch((e) => setError(e.message))

  useEffect(() => { load() }, [])

  const act = async (fn: () => Promise<any>, ok: string) => {
    try {
      await fn()
      toast('ok', ok)
      setModal(null)
      await load()
    } catch (e: any) {
      toast('err', e.message)
    }
  }

  const toggle = (p: Provider) =>
    act(() => api(`/providers/${p.id}/${p.enabled ? 'disable' : 'enable'}`, { method: 'POST', body: {} }),
      `${p.name} ${p.enabled ? 'disabled' : 'enabled'}`)

  return (
    <Layout title="Providers & keys" eyebrow="Configuration · Upstreams" sub="Upstream endpoints and their encrypted credentials.">
      {error && <ErrorFlash message={error} />}
      <section className="panel">
        <div className="panel-head">
          <h2>Providers</h2>
          <span className="hint">provider secrets are write-only — never displayed or exported</span>
          <div className="spacer" />
          <button className="btn primary small" onClick={() => setModal('add')}>+ Add provider</button>
        </div>
        {loaded && providers.length === 0 ? (
          <div className="empty">No providers yet — add one to start routing.</div>
        ) : (
          <table className="tbl">
            <thead><tr><th>Provider</th><th>Base URL</th><th>Protocol</th><th>State</th><th className="actions">Actions</th></tr></thead>
            <tbody>
              {providers.map((p, i) => (
                <Fragment key={p.id}>
                  <Row index={i}>
                    <td className="name">{p.name}</td>
                    <td className="dim mono">{p.base_url}</td>
                    <td className="dim mono">{p.protocol}</td>
                    <td><Pill enabled={p.enabled} /></td>
                    <td className="actions">
                      <button className="btn small" onClick={() => toggle(p)}>{p.enabled ? 'Disable' : 'Enable'}</button>
                      <button className="btn small" onClick={() => setExpanded(expanded === p.id ? null : p.id)}>
                        {p.keys.length} keys {expanded === p.id ? '▴' : '▾'}
                      </button>
                      <button className="btn small danger" onClick={() => setModal({ del: p })}>Delete…</button>
                    </td>
                  </Row>
                  {expanded === p.id && (
                    <tr key={`${p.id}-keys`}>
                      <td colSpan={5} style={{ padding: 0 }}>
                        <div className="subrow-detail">
                          {p.keys.map((k) => (
                            <span className="tag" key={k.id}>
                              {k.key_id} · w{k.weight} <Pill enabled={k.enabled} />
                              <button className="btn small" style={{ marginLeft: 8 }}
                                onClick={() => act(
                                  () => api(`/provider-keys/${k.id}/${k.enabled ? 'disable' : 'enable'}`, { method: 'POST', body: {} }),
                                  'key updated')}>
                                {k.enabled ? 'off' : 'on'}
                              </button>
                              <button className="btn small danger" onClick={() => setModal({ delKey: [p, k] })}>×</button>
                            </span>
                          ))}
                          {p.keys.length === 0 && <span className="dim">no keys</span>}
                          <span style={{ flex: 1 }} />
                          <button className="btn small" onClick={() => setModal({ addKey: p })}>+ Add key</button>
                        </div>
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {modal === 'add' && <AddProviderModal
        onClose={() => setModal(null)}
        onDone={(name) => act(async () => { await api('/providers', { method: 'POST', body: name }) }, 'provider added')} />}

      {modal && typeof modal === 'object' && 'addKey' in modal && <AddKeyModal
        provider={modal.addKey}
        onClose={() => setModal(null)}
        onDone={(body) => act(async () => { await api(`/providers/${modal.addKey.id}/keys`, { method: 'POST', body }) }, 'key encrypted & stored')} />}

      {modal && typeof modal === 'object' && 'del' in modal && (
        <Modal title={<>Delete provider <span className="mono">{modal.del.name}</span>?</>}
          sub={`DELETE /admin/api/providers/${modal.del.id}`} danger
          onClose={() => setModal(null)}
          footer={<>
            <button className="btn" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn primary"
              onClick={() => act(async () => { await api(`/providers/${modal.del.id}`, { method: 'DELETE' }) }, 'provider deleted')}>
              Delete provider
            </button>
          </>}>
          <div className="dim">
            This removes the provider, its <strong>{modal.del.keys.length}</strong> stored key(s) and all of its
            model routes. Agents calling routed models will get <code>no_route</code> until another provider serves them.
          </div>
        </Modal>)}

      {modal && typeof modal === 'object' && 'delKey' in modal && (() => {
        const [p, k] = modal.delKey
        return (
          <Modal title={<>Remove key <span className="mono">{k.key_id}</span> from <span className="mono">{p.name}</span>?</>}
            sub={`DELETE /admin/api/provider-keys/${k.id}`} danger
            onClose={() => setModal(null)}
            footer={<>
              <button className="btn" onClick={() => setModal(null)}>Cancel</button>
              <button className="btn primary"
                onClick={() => act(async () => { await api(`/provider-keys/${k.id}`, { method: 'DELETE' }) }, 'key removed')}>
                Remove key
              </button>
            </>}>
            <div className="dim">The encrypted credential is deleted from the database. This cannot be undone.</div>
          </Modal>
        )
      })()}
    </Layout>
  )
}

function AddProviderModal({ onClose, onDone }: { onClose: () => void; onDone: (b: any) => void }) {
  const [name, setName] = useState('')
  const [baseUrl, setBaseUrl] = useState('')
  const [protocol, setProtocol] = useState('openai_chat')
  const [err, setErr] = useState('')
  return (
    <Modal title="Add provider" sub="POST /admin/api/providers" onClose={onClose}
      footer={<>
        <button className="btn" onClick={onClose}>Cancel <span className="kbd">esc</span></button>
        <button className="btn primary" disabled={!name || !baseUrl}
          onClick={() => { if (!/^https?:\/\//.test(baseUrl)) { setErr('base_url must start with http:// or https://'); return } onDone({ name, base_url: baseUrl, protocol }) }}>
          Add provider +
        </button>
      </>}>
      {err && <div className="flash err" style={{ marginTop: 0 }}>{err}</div>}
      <form className="form-grid" onSubmit={(e) => e.preventDefault()}>
        <label className="f">Name<input value={name} onChange={(e) => setName(e.target.value)} placeholder="openrouter" autoFocus /></label>
        <label className="f">Protocol
          <select value={protocol} onChange={(e) => setProtocol(e.target.value)}>
            <option value="openai_chat">openai_chat</option>
            <option value="anthropic_messages">anthropic_messages</option>
            <option value="openai_responses">openai_responses</option>
          </select>
        </label>
        <label className="f" style={{ gridColumn: '1 / -1' }}>Base URL
          <input value={baseUrl} onChange={(e) => setBaseUrl(e.target.value)} placeholder="https://api.example.com/v1" />
        </label>
      </form>
    </Modal>
  )
}

function AddKeyModal({ provider, onClose, onDone }: { provider: Provider; onClose: () => void; onDone: (b: any) => void }) {
  const [secret, setSecret] = useState('')
  const [weight, setWeight] = useState(1)
  return (
    <Modal title={<>Add key · <span className="mono">{provider.name}</span></>}
      sub={`POST /admin/api/providers/${provider.id}/keys`} onClose={onClose}
      footer={<>
        <button className="btn" onClick={onClose}>Cancel <span className="kbd">esc</span></button>
        <button className="btn primary" disabled={!secret} onClick={() => onDone({ secret, weight })}>
          Encrypt &amp; store 🔒
        </button>
      </>}>
      <form className="form-grid" onSubmit={(e) => e.preventDefault()}>
        <label className="f" style={{ gridColumn: '1 / -1' }}>API key secret
          <textarea rows={3} value={secret} onChange={(e) => setSecret(e.target.value)} placeholder="sk-…" autoFocus />
        </label>
        <label className="f">Weight
          <input type="number" min={1} value={weight} onChange={(e) => setWeight(Number(e.target.value) || 1)} />
        </label>
      </form>
      <div className="form-note warn">
        Stored as an AES-256-GCM envelope. The plaintext is discarded after encryption and can never be shown again.
      </div>
    </Modal>
  )
}

// ===================== Models & routes =====================

export function Models() {
  const [models, setModels] = useState<Model[]>([])
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState('')
  const [modal, setModal] = useState<'add' | { route: Model } | null>(null)
  const toast = useToast()

  const load = () => Promise.all([api('/models'), api('/providers')])
    .then(([m, p]) => { setModels(m.models); setProviders(p.providers) })
    .catch((e) => setError(e.message))

  useEffect(() => { load() }, [])

  const act = async (fn: () => Promise<any>, ok: string) => {
    try {
      await fn(); toast('ok', ok); await load()
    } catch (e: any) { toast('err', e.message) }
  }

  return (
    <Layout title="Models & routes" eyebrow="Configuration · Routing" sub="Public model names and the upstream providers that serve them.">
      {error && <ErrorFlash message={error} />}
      <section className="panel">
        <div className="panel-head">
          <h2>Models</h2>
          <span className="hint">model name = the <code>model</code> field agents send to /v1/chat/completions</span>
          <div className="spacer" />
          <button className="btn primary small" onClick={() => setModal('add')}>+ Add model</button>
        </div>
        <table className="tbl">
          <thead><tr><th>Model</th><th>State</th><th>Routes</th><th className="actions">Actions</th></tr></thead>
          <tbody>
            {models.map((m, i) => (
              <Row key={m.id} index={i}>
                <td className="name mono">{m.name}</td>
                <td><Pill enabled={m.enabled} /></td>
                <td className="dim">{m.routes.length} upstream</td>
                <td className="actions">
                  <button className="btn small" onClick={() => setModal({ route: m })}>+ Route</button>
                  <button className="btn small" onClick={() =>
                    act(() => api(`/models/${m.id}/${m.enabled ? 'disable' : 'enable'}`, { method: 'POST', body: {} }), 'model updated')}>
                    {m.enabled ? 'Disable' : 'Enable'}
                  </button>
                </td>
              </Row>
            ))}
            {models.map((m) => (
              <tr key={`${m.id}-routes`}>
                <td colSpan={4} style={{ padding: 0 }}>
                  <div className="routes-nested">
                    <table className="tbl">
                      <thead><tr><th></th><th>Provider</th><th>Upstream id</th><th>Weight</th><th>Priority</th><th>State</th><th className="actions"></th></tr></thead>
                      <tbody>
                        {m.routes.map((r) => (
                          <tr key={`${r.model_id}-${r.provider_id}`}>
                            <td className="dim">↳</td>
                            <td className="mono">{r.provider_name ?? r.provider_id}</td>
                            <td className="dim mono">{r.upstream_model_id ?? '—'}</td>
                            <td className="num">{r.weight}</td>
                            <td className="num">{r.priority}</td>
                            <td><Pill enabled={r.enabled} /></td>
                            <td className="actions">
                              <button className="btn small"
                                onClick={() => act(() => api(`/models/${r.model_id}/routes/${r.provider_id}/${r.enabled ? 'disable' : 'enable'}`, { method: 'POST', body: {} }), 'route updated')}>
                                {r.enabled ? 'Off' : 'On'}
                              </button>
                              <button className="btn small danger"
                                onClick={() => act(() => api(`/models/${r.model_id}/routes/${r.provider_id}`, { method: 'DELETE' }), 'route removed')}>
                                Remove
                              </button>
                            </td>
                          </tr>
                        ))}
                        {m.routes.length === 0 && (
                          <tr><td colSpan={7} className="dim" style={{ padding: '6px 10px' }}>No routes — agents get <code>no_route</code>.</td></tr>
                        )}
                      </tbody>
                    </table>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {modal === 'add' && <AddModelModal onClose={() => setModal(null)}
        onDone={(body) => act(async () => { await api('/models', { method: 'POST', body }); setModal(null) }, 'model added')} />}

      {modal && typeof modal === 'object' && 'route' in modal && (
        <AddRouteModal model={modal.route} providers={providers} onClose={() => setModal(null)}
          onDone={(body) => act(async () => { await api(`/models/${modal.route.id}/routes`, { method: 'POST', body }); setModal(null) }, 'route added')} />)}
    </Layout>
  )
}

function AddModelModal({ onClose, onDone }: { onClose: () => void; onDone: (b: any) => void }) {
  const [name, setName] = useState('')
  return (
    <Modal title="Add model" sub="POST /admin/api/models" onClose={onClose}
      footer={<>
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={!name} onClick={() => onDone({ name })}>Add model +</button>
      </>}>
      <form onSubmit={(e) => e.preventDefault()}>
        <label className="f">Model name<input value={name} onChange={(e) => setName(e.target.value)} placeholder="qwen4-max" autoFocus /></label>
      </form>
      <div className="form-note">Created enabled; add a route next so agents can reach it.</div>
    </Modal>
  )
}

function AddRouteModal({ model, providers, onClose, onDone }: {
  model: Model; providers: Provider[]; onClose: () => void; onDone: (b: any) => void
}) {
  const [providerId, setProviderId] = useState(providers[0]?.id ?? 0)
  const [upstream, setUpstream] = useState('')
  const [weight, setWeight] = useState(1)
  const [priority, setPriority] = useState(0)
  return (
    <Modal title={<>Add route · <span className="mono">{model.name}</span></>}
      sub={`POST /admin/api/models/${model.id}/routes`} onClose={onClose}
      footer={<>
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={!providerId}
          onClick={() => onDone({ provider_id: providerId, upstream_model_id: upstream || undefined, weight, priority })}>
          Add route +
        </button>
      </>}>
      <form className="form-grid" onSubmit={(e) => e.preventDefault()}>
        <label className="f">Provider
          <select value={providerId} onChange={(e) => setProviderId(Number(e.target.value))}>
            {providers.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </label>
        <label className="f">Upstream model id
          <input value={upstream} onChange={(e) => setUpstream(e.target.value)} placeholder="optional" />
        </label>
        <label className="f">Weight<input type="number" min={1} value={weight} onChange={(e) => setWeight(Number(e.target.value) || 1)} /></label>
        <label className="f">Priority<input type="number" value={priority} onChange={(e) => setPriority(Number(e.target.value) || 0)} /></label>
      </form>
      <div className="form-note">Lower priority runs first; same priority = weighted round-robin.</div>
    </Modal>
  )
}

// ===================== Agent keys =====================

export function Keys() {
  const [keys, setKeys] = useState<AgentKey[]>([])
  const [models, setModels] = useState<Model[]>([])
  const [error, setError] = useState('')
  const [modal, setModal] = useState<'create' | { created: string } | { revoke: AgentKey } | null>(null)
  const toast = useToast()

  const load = () => Promise.all([api('/keys'), api('/models')])
    .then(([k, m]) => { setKeys(k.keys); setModels(m.models) })
    .catch((e) => setError(e.message))

  useEffect(() => { load() }, [])

  const act = async (fn: () => Promise<any>, ok: string) => {
    try { await fn(); toast('ok', ok); await load() } catch (e: any) { toast('err', e.message) }
  }

  return (
    <Layout title="Agent keys" eyebrow="Access · Data plane" sub="Bearer keys for the data plane — stored as peppered HMAC hashes.">
      {error && <ErrorFlash message={error} />}
      <section className="panel">
        <div className="panel-head">
          <h2>Keys</h2>
          <span className="hint">empty grants = key cannot call any model</span>
          <div className="spacer" />
          <button className="btn primary small" onClick={() => setModal('create')}>+ Create key</button>
        </div>
        <table className="tbl">
          <thead><tr><th>Prefix</th><th>Model grants</th><th>Created</th><th>State</th><th className="actions">Actions</th></tr></thead>
          <tbody>
            {keys.map((k, i) => (
              <Row key={k.id} index={i}>
                <td className="mono">{k.prefix}…</td>
                <td>{k.model_names.filter(Boolean).map((n) => <span className="tag" key={n as string}>{n}</span>)}</td>
                <td className="dim mono">{k.created_at}</td>
                <td><Pill enabled={k.enabled} /></td>
                <td className="actions">
                  <button className="btn small"
                    onClick={() => act(() => api(`/keys/${k.id}/${k.enabled ? 'disable' : 'enable'}`, { method: 'POST', body: {} }), 'key updated')}>
                    {k.enabled ? 'Disable' : 'Enable'}
                  </button>
                  <button className="btn small danger" onClick={() => setModal({ revoke: k })}>Revoke…</button>
                </td>
              </Row>
            ))}
            {keys.length === 0 && <tr><td colSpan={5} className="empty">No agent keys yet.</td></tr>}
          </tbody>
        </table>
      </section>

      {modal === 'create' && (
        <CreateKeyModal models={models} onClose={() => setModal(null)}
          onCreated={(key) => setModal({ created: key })} />)}

      {modal && typeof modal === 'object' && 'created' in modal && (
        <Modal title="Key created" sub="201 Created — shown only once" onClose={() => { setModal(null); load() }}
          footer={<button className="btn primary" onClick={() => { setModal(null); load() }}>Done ✓</button>}>
          <div className="key-reveal" style={{ marginBottom: 0 }}>
            <div className="inner">
              <strong style={{ color: 'var(--warn)' }}>Copy it now — shown only once</strong>
              <div className="key-row">
                <div className="key">{modal.created}</div>
                <button className="btn small"
                  onClick={() => { navigator.clipboard?.writeText(modal.created); toast('ok', 'copied to clipboard') }}>
                  ⧉ Copy
                </button>
              </div>
              <div className="note">Janus stores an HMAC-SHA256 hash and cannot recover the key.</div>
            </div>
          </div>
        </Modal>)}

      {modal && typeof modal === 'object' && 'revoke' in modal && (
        <Modal title={<>Revoke key <span className="mono">{modal.revoke.prefix}…</span>?</>}
          sub={`DELETE /admin/api/keys/${modal.revoke.id}`} danger
          onClose={() => setModal(null)}
          footer={<>
            <button className="btn" onClick={() => setModal(null)}>Cancel</button>
            <button className="btn primary"
              onClick={() => act(async () => { await api(`/keys/${modal.revoke.id}`, { method: 'DELETE' }); setModal(null) }, 'key revoked')}>
              Revoke permanently
            </button>
          </>}>
          <div className="dim">
            Agents using this key will immediately get <code>401 unauthorized</code>.
            The HMAC hash is deleted; this cannot be undone.
          </div>
        </Modal>)}
    </Layout>
  )
}

function CreateKeyModal({ models, onClose, onCreated }: {
  models: Model[]; onClose: () => void; onCreated: (key: string) => void
}) {
  const [grants, setGrants] = useState<Set<number>>(new Set(models.map((m) => m.id)))
  const [busy, setBusy] = useState(false)
  const toggle = (id: number) =>
    setGrants((g) => { const n = new Set(g); n.has(id) ? n.delete(id) : n.add(id); return n })

  const create = async () => {
    setBusy(true)
    try {
      const res = await api('/keys', { method: 'POST', body: { model_ids: [...grants] } })
      onCreated(res.key)
    } catch (e: any) {
      setBusy(false)
      alert(e.message)
    }
  }

  return (
    <Modal title="Create key" sub="POST /admin/api/keys" onClose={onClose}
      footer={<>
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn primary" disabled={grants.size === 0 || busy} onClick={create}>
          {busy ? 'Generating…' : 'Generate key ⚿'}
        </button>
      </>}>
      <label className="f">Model grants</label>
      <div className="checks">
        {models.map((m) => (
          <label key={m.id}>
            <input type="checkbox" checked={grants.has(m.id)} onChange={() => toggle(m.id)} /> {m.name}
          </label>
        ))}
      </div>
      <div className="form-note warn">The full key is generated server-side and shown once on the next screen.</div>
    </Modal>
  )
}

// ===================== Audit =====================

export function Audit() {
  const [events, setEvents] = useState<AuditEvent[]>([])
  const [error, setError] = useState('')
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    api('/audit?limit=200').then((r) => { setEvents(r.events); setLoaded(true) }).catch((e) => setError(e.message))
  }, [])

  return (
    <Layout title="Audit log" eyebrow="Security · Trace" sub="Every admin mutation, newest first. Ring buffer — last 1000 events, in-memory.">
      {error && <ErrorFlash message={error} />}
      <section className="panel">
        <div className="panel-head"><h2>Events</h2><span className="hint">in-memory; resets on restart</span></div>
        <table className="tbl">
          <thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Target</th><th>Detail</th></tr></thead>
          <tbody>
            {events.map((a, i) => (
              <Row key={i} index={i}>
                <td className="dim mono">{a.ts}</td>
                <td className="mono dim">{a.actor}</td>
                <td className="mono">{a.action}</td>
                <td className="mono dim">{a.target ?? '—'}</td>
                <td className="dim">{a.detail ?? '—'}</td>
              </Row>
            ))}
            {loaded && events.length === 0 && <tr><td colSpan={5} className="empty">No events yet.</td></tr>}
          </tbody>
        </table>
      </section>
    </Layout>
  )
}
