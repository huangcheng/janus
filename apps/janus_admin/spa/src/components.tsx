// Shared UI components: layout chrome, modal (with mirrored exit),
// toasts, pills, small bits.

import { ReactNode, useEffect, useRef, useState, createContext, useContext, useCallback } from 'react'
import { Link, useNavigate } from '@tanstack/react-router'
import { api } from './api'

// ---------- theme ----------

export function useTheme() {
  const [theme, setTheme] = useState<string>(
    () => document.documentElement.dataset.theme || 'light',
  )
  const toggle = useCallback(() => {
    setTheme((cur) => {
      const next = cur === 'light' ? 'dark' : 'light'
      document.documentElement.dataset.theme = next
      try { localStorage.setItem('janus-theme', next) } catch { /* ignore */ }
      return next
    })
  }, [])
  return { theme, toggle }
}

export function ThemeToggle() {
  const { theme, toggle } = useTheme()
  return (
    <button className="btn small" onClick={toggle} title="Switch theme">
      {theme === 'light' ? '🌙 Dark' : '☀ Light'}
    </button>
  )
}

const NAV = [
  { to: '/', ico: '▦', label: 'Dashboard' },
  { to: '/providers', ico: '⇉', label: 'Providers & keys' },
  { to: '/models', ico: '⌗', label: 'Models & routes' },
  { to: '/keys', ico: '⚿', label: 'Agent keys' },
  { to: '/audit', ico: '☰', label: 'Audit log' },
]

export function Layout({ children, title, eyebrow, sub }: {
  children: ReactNode
  title: string
  eyebrow: string
  sub?: string
}) {
  const nav = useNavigate()
  const [gen, setGen] = useState<number | null>(null)

  useEffect(() => {
    api('/overview').then((o) => setGen(o.generation)).catch(() => {})
  }, [])

  const signOut = async () => {
    try { await api('/session', { method: 'DELETE' }) } catch { /* ignore */ }
    nav({ to: '/login' })
  }

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="logo">
          <img src={`${import.meta.env.BASE_URL}icon.png`} alt="Janus" />
          <div>
            <div className="logo-name">Janus</div>
            <div className="logo-sub">gateway console</div>
          </div>
        </div>
        <nav className="nav">
          <span className="nav-label">Console</span>
          {NAV.map((n) => (
            <Link key={n.to} to={n.to} activeProps={{ className: 'active' }}>
              <span className="ico">{n.ico}</span> {n.label}
            </Link>
          ))}
        </nav>
        <div className="sidebar-footer">
          <div className="row"><span>data plane</span><span className="val">:8080</span></div>
          <div className="row"><span>admin plane</span><span className="val">:8090</span></div>
          <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
            <ThemeToggle />
            <button className="btn small danger" onClick={signOut}>Sign out</button>
          </div>
        </div>
      </aside>
      <main className="main">
        <div className="topbar">
          <div>
            <span className="eyebrow">{eyebrow}</span>
            <h1>{title}</h1>
            {sub && <div className="sub">{sub}</div>}
          </div>
          <div className="spacer" />
          {gen !== null && (
            <span className="gen-badge"><span className="dot" />gen {gen}</span>
          )}
        </div>
        {children}
      </main>
    </div>
  )
}

// ---------- modal with mirrored exit ----------

export function Modal({ title, sub, danger, onClose, children, footer }: {
  title: ReactNode
  sub?: ReactNode
  danger?: boolean
  onClose: () => void
  children: ReactNode
  footer: ReactNode
}) {
  const [closing, setClosing] = useState(false)

  const close = useCallback(() => {
    setClosing(true)
    setTimeout(onClose, 190)
  }, [onClose])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') close() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [close])

  return (
    <div className={`overlay${closing ? ' closing' : ''}`} onMouseDown={(e) => { if (e.target === e.currentTarget) close() }}>
      <div className={`modal${danger ? ' danger' : ''}`} role="dialog" aria-modal="true">
        <div className="inner">
          <div className="modal-head">
            {danger && <div className="warn-ico">⚠</div>}
            <div className="titles">
              <h3>{title}</h3>
              {sub && <div className="sub">{sub}</div>}
            </div>
            <button className="modal-close" onClick={close} aria-label="Close">×</button>
          </div>
          <div className="modal-body">{children}</div>
          <div className="modal-foot">{footer}</div>
        </div>
      </div>
    </div>
  )
}

// ---------- toasts ----------

type Toast = { id: number; kind: 'ok' | 'err'; text: string; closing?: boolean }

const ToastCtx = createContext<(kind: 'ok' | 'err', text: string) => void>(() => {})

export function useToast() {
  return useContext(ToastCtx)
}

export function ToastHost({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const idRef = useRef(0)

  const push = useCallback((kind: 'ok' | 'err', text: string) => {
    const id = ++idRef.current
    setToasts((t) => [...t, { id, kind, text }])
    setTimeout(() => {
      // mirror the entrance: fade out first, then drop
      setToasts((t) => t.map((x) => (x.id === id ? { ...x, closing: true } : x)))
      setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 190)
    }, 3400)
  }, [])

  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="toasts">
        {toasts.map((t) => (
          <div key={t.id} className={`toast ${t.kind}${t.closing ? ' closing' : ''}`}>{t.text}</div>
        ))}
      </div>
    </ToastCtx.Provider>
  )
}

// ---------- bits ----------

export function Pill({ enabled, warn }: { enabled: boolean; warn?: string }) {
  if (warn) return <span className="pill warn">{warn}</span>
  return enabled
    ? <span className="pill ok">enabled</span>
    : <span className="pill off">disabled</span>
}

export function Loading() {
  return <div style={{ display: 'grid', placeItems: 'center', padding: 60 }}><div className="spin" /></div>
}

export function ErrorFlash({ message }: { message: string }) {
  return <div className="flash err">{message}</div>
}

export function Row({ index, children }: { index: number; children: ReactNode }) {
  const ref = useRef<HTMLTableRowElement>(null)
  // staggered mount; delay is cleared afterwards so hover stays instant
  useEffect(() => {
    const t = setTimeout(() => {
      if (ref.current) ref.current.style.transitionDelay = '0ms'
    }, 500 + Math.min(index, 10) * 40)
    return () => clearTimeout(t)
  }, [index])
  return <tr ref={ref} style={{ transitionDelay: `${Math.min(index, 10) * 40}ms` }}>{children}</tr>
}
