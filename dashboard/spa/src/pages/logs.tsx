import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { ArrowDownToLine, Database, RefreshCw } from "lucide-react"
import { api } from "../api"
import { ErrorFlash, Layout } from "../components"
import { Button } from "@/components/ui/button"
import { ComboboxSingle } from "@/components/combobox"
import { EventTime } from "./shared"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"

type LogEvent = {
  idx: number
  ts: string
  level: string
  fields: Record<string, unknown>
  node?: string
}

type OpsEvent = {
  node_id?: string
  node?: string
  boot_id?: string
  idx: number
  ts: string
  type: string
  schema_version?: number
  payload: Record<string, unknown>
}

type OpsMarker = {
  node_id?: string
  node?: string
  marker_seq: number
  ts: string
  reason: string
  prior_boot_id?: string | null
  boot_id?: string | null
  detail?: Record<string, unknown>
}

/** Stream source: OTP logger lines vs drained ops events — never merged. */
type StreamKind = "otp" | "ops"

const LEVEL_STYLE: Record<string, string> = {
  error: "text-terminal-error",
  warn: "text-terminal-warning",
  warning: "text-terminal-warning",
  info: "text-terminal-info",
  notice: "text-terminal-notice",
}

const ALL_NODES = "All nodes"
const ALL_TYPES = "All types"

export function Logs() {
  const [stream, setStream] = useState<StreamKind>("otp")
  const [events, setEvents] = useState<LogEvent[]>([])
  const [opsEvents, setOpsEvents] = useState<OpsEvent[]>([])
  const [opsMarkers, setOpsMarkers] = useState<OpsMarker[]>([])
  const [error, setError] = useState("")
  const [level, setLevel] = useState("info")
  const [live, setLive] = useState(false)
  const [nodeFilter, setNodeFilter] = useState<string | null>(null)
  const [opsType, setOpsType] = useState<string | null>(null)
  const [nodeOptions, setNodeOptions] = useState<string[]>([])
  const [autoScroll, setAutoScroll] = useState(true)
  const paneRef = useRef<HTMLDivElement>(null)

  // Node filter options come from the registry; a failure here only
  // leaves the filter at "All nodes", never blocks the stream.
  useEffect(() => {
    api("/nodes")
      .then((r) => {
        const names = (((r as any)?.nodes ?? []) as { name: string }[]).map((n) => n.name)
        setNodeOptions(names)
      })
      .catch(() => {})
  }, [])

  // Monotonic request id: the 2s poll and the Refresh button can overlap, and
  // an older response must not overwrite a newer one.
  const loadGen = useRef(0)
  const otpPayloadRef = useRef("")
  const opsPayloadRef = useRef("")

  const fetchOtp = useCallback(async () => {
    const params = new URLSearchParams()
    params.set("limit", "300")
    if (level !== "info") params.set("level", level)
    if (nodeFilter) params.set("node", nodeFilter)
    if (live) params.set("source", "live")
    return await api(`/logs?${params.toString()}`)
  }, [level, nodeFilter, live])

  const fetchOps = useCallback(async () => {
    const params = new URLSearchParams()
    params.set("limit", "300")
    if (nodeFilter) params.set("node", nodeFilter)
    if (opsType) params.set("type", opsType)
    return await api(`/ops-events?${params.toString()}`)
  }, [nodeFilter, opsType])

  const load = useCallback(async () => {
    const gen = ++loadGen.current
    try {
      if (stream === "ops") {
        const r = await fetchOps()
        if (gen !== loadGen.current) return
        const nextPayload = JSON.stringify([r.events ?? [], r.markers ?? []])
        if (nextPayload !== opsPayloadRef.current) {
          opsPayloadRef.current = nextPayload
          setOpsEvents((r.events ?? []) as OpsEvent[])
          setOpsMarkers((r.markers ?? []) as OpsMarker[])
        }
        setEvents([])
      } else {
        const r = await fetchOtp()
        if (gen !== loadGen.current) return
        const nextPayload = JSON.stringify(r.events ?? [])
        if (nextPayload !== otpPayloadRef.current) {
          otpPayloadRef.current = nextPayload
          setEvents(r.events)
        }
        setOpsEvents([])
        setOpsMarkers([])
      }
      setError("")
    } catch (e: any) {
      if (gen !== loadGen.current) return
      setError(e.message)
    }
  }, [stream, fetchOtp, fetchOps])

  useEffect(() => {
    load()
  }, [load])

  // A filter/source change must force a fresh payload comparison even if the
  // previous view had been emptied by the other stream.
  useEffect(() => {
    otpPayloadRef.current = ""
    opsPayloadRef.current = ""
  }, [stream, level, nodeFilter, live, opsType])

  // The interval must call the CURRENT load: `load` is a dep so a
  // stream/level/node/source change rebuilds the timer instead of streaming
  // the stale filter. Both views refresh every 2s; the persisted view
  // itself lags emission by at most one poll cycle (~10s).
  useEffect(() => {
    const t = setInterval(load, 2000)
    return () => clearInterval(t)
  }, [load])

  useEffect(() => {
    // Scroll only the pane — scrollIntoView would drag the window along,
    // pushing the card header off-screen in the fill-height layout.
    const pane = paneRef.current
    if (autoScroll && pane) {
      const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
      pane.scrollTo({ top: pane.scrollHeight, behavior: reduceMotion ? "auto" : "smooth" })
    }
  }, [events, opsEvents, opsMarkers, autoScroll])

  const opsLines = useMemo(
    () => mergeOpsLines(opsEvents, opsMarkers),
    [opsEvents, opsMarkers],
  )
  const lineCount = stream === "ops" ? opsLines.length : events.length
  let streamDescription: string
  if (stream === "ops") {
    streamDescription = "ops events from Postgres (cool_edge / task_run + markers)"
  } else if (live) {
    streamDescription = "OTP live ring buffer (2000, in-memory)"
  } else {
    streamDescription =
      "OTP persisted in Postgres · lines land within one poll cycle (~10s)"
  }
  let footer: ReactNode
  if (stream === "ops") {
    footer = (
      <>
        <Database className="size-3" />
        Ops events · refreshing every 2 seconds · drained by the dashboard puller
      </>
    )
  } else if (live) {
    footer = (
      <>
        <span className="relative flex size-1.5">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-60" />
          <span className="relative inline-flex size-1.5 rounded-full bg-success" />
        </span>
        Live ring buffer · refreshing every 2 seconds
      </>
    )
  } else {
    footer = (
      <>
        <Database className="size-3" />
        Persisted view · refreshing every 2 seconds · new lines land within ~10s
      </>
    )
  }

  return (
    <Layout
      fill
      title="Logs"
      description="OTP logger stream and drained ops events (cool / task) — toggle sources; they are never merged."
    >
      {error && <ErrorFlash message={error} />}
      <Card className="flex max-h-full min-h-0 flex-1 flex-col overflow-hidden">
        <CardHeader className="border-b">
          <CardTitle>Event stream</CardTitle>
          <CardDescription>
            Last {lineCount} lines · {streamDescription}
          </CardDescription>
          <CardAction className="flex flex-wrap items-center gap-2">
            <Select
              value={stream}
              onValueChange={(v) => setStream(v as StreamKind)}
            >
              <SelectTrigger size="sm" aria-label="Stream source" style={{ width: 144 }}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="otp">OTP logs</SelectItem>
                <SelectItem value="ops">Ops events</SelectItem>
              </SelectContent>
            </Select>
            {stream === "otp" ? (
              <Button
                variant="outline"
                size="sm"
                onClick={() => setLive(!live)}
                aria-pressed={live}
                title={
                  live
                    ? "Switch to the persisted view"
                    : "Switch to the live ring buffer"
                }
              >
                {live ? (
                  <span className="relative flex size-2">
                    <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-60" />
                    <span className="relative inline-flex size-2 rounded-full bg-success" />
                  </span>
                ) : (
                  <Database />
                )}
                {live ? "Live" : "Persisted"}
              </Button>
            ) : (
              <Select
                value={opsType ?? ALL_TYPES}
                onValueChange={(v) => setOpsType(!v || v === ALL_TYPES ? null : v)}
              >
                <SelectTrigger size="sm" aria-label="Ops event type" style={{ width: 144 }}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL_TYPES}>All types</SelectItem>
                  <SelectItem value="cool_edge">cool_edge</SelectItem>
                  <SelectItem value="task_run">task_run</SelectItem>
                </SelectContent>
              </Select>
            )}
            <ComboboxSingle
              value={nodeFilter ?? ALL_NODES}
              options={[ALL_NODES, ...nodeOptions]}
              onChange={(v) => setNodeFilter(!v || v === ALL_NODES ? null : v)}
              placeholder={ALL_NODES}
              className="w-44"
            />
            <Button
              variant={autoScroll ? "secondary" : "outline"}
              size="sm"
              aria-pressed={autoScroll}
              onClick={() => setAutoScroll(!autoScroll)}
            >
              <ArrowDownToLine />
              Follow
            </Button>
            {stream === "otp" ? (
              <Select
                value={level}
                onValueChange={setLevel}
              >
                <SelectTrigger size="sm" aria-label="Minimum log level" style={{ width: 112 }}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="info">All levels</SelectItem>
                  <SelectItem value="warn">Warn and above</SelectItem>
                  <SelectItem value="error">Errors only</SelectItem>
                </SelectContent>
              </Select>
            ) : null}
            <Button variant="outline" size="sm" onClick={load} aria-label="Refresh logs">
              <RefreshCw />
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="flex min-h-0 flex-1 flex-col">
          <div
            ref={paneRef}
            tabIndex={0}
            role="region"
            aria-label="Log event stream"
            className="min-h-0 flex-1 overflow-y-auto rounded-lg bg-terminal-bg p-3 font-mono text-[13px] leading-6 ring-1 ring-terminal-border scrollbar-thin focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
          >
            {stream === "otp" ? (
              <>
                {events.length === 0 && (
                  <div className="flex min-h-full items-center justify-center">
                    <p className={error ? "text-terminal-error" : "text-terminal-muted"}>
                      {error ? `Could not load logs — ${error}` : "No log lines yet"}
                    </p>
                  </div>
                )}
                {events.map((e) => (
                  <div
                    key={`${e.node ?? ""}:${e.idx}:${e.ts}`}
                    className="flex max-sm:flex-wrap gap-3 whitespace-pre-wrap break-words [overflow-wrap:anywhere]"
                  >
                    <span className="shrink-0 text-terminal-muted tabular-nums">
                      <EventTime ts={e.ts} />
                    </span>
                    {!nodeFilter && e.node && (
                      <span className="shrink-0 text-terminal-dim">{e.node}</span>
                    )}
                    <span
                      className={`inline-flex w-16 shrink-0 items-center gap-1.5 font-medium ${LEVEL_STYLE[e.level] ?? "text-terminal-info"}`}
                    >
                      <span className="size-1.5 shrink-0 rounded-full bg-current" />
                      {e.level}
                    </span>
                    <span className="min-w-0 max-sm:basis-full flex-1 text-terminal-text">{formatFields(e.fields)}</span>
                  </div>
                ))}
              </>
            ) : (
              <>
                {opsLines.length === 0 && (
                  <div className="flex min-h-full items-center justify-center">
                    <p className={error ? "text-terminal-error" : "text-terminal-muted"}>
                      {error ? `Could not load ops events — ${error}` : "No ops events yet"}
                    </p>
                  </div>
                )}
                {opsLines.map((line) =>
                  line.kind === "marker" ? (
                    <div
                      key={line.key}
                      className="flex max-sm:flex-wrap gap-3 whitespace-pre-wrap break-words [overflow-wrap:anywhere]"
                    >
                      <span className="shrink-0 text-terminal-muted tabular-nums">
                        <EventTime ts={line.ts} />
                      </span>
                      {!nodeFilter && line.nodeLabel && (
                        <span className="shrink-0 text-terminal-dim">{line.nodeLabel}</span>
                      )}
                      <span className="inline-flex w-20 shrink-0 items-center gap-1.5 font-medium text-terminal-warning">
                        <span className="size-1.5 shrink-0 rounded-full bg-current" />
                        marker
                      </span>
                      <span className="min-w-0 max-sm:basis-full flex-1 text-terminal-text">{line.text}</span>
                    </div>
                  ) : (
                    <div
                      key={line.key}
                      className="flex max-sm:flex-wrap gap-3 whitespace-pre-wrap break-words [overflow-wrap:anywhere]"
                    >
                      <span className="shrink-0 text-terminal-muted tabular-nums">
                        <EventTime ts={line.ts} />
                      </span>
                      {!nodeFilter && line.nodeLabel && (
                        <span className="shrink-0 text-terminal-dim">{line.nodeLabel}</span>
                      )}
                      <span className="inline-flex w-20 shrink-0 items-center gap-1.5 font-medium text-terminal-notice">
                        <span className="size-1.5 shrink-0 rounded-full bg-current" />
                        {line.type}
                      </span>
                      <span className="min-w-0 max-sm:basis-full flex-1 text-terminal-text">{line.text}</span>
                    </div>
                  ),
                )}
              </>
            )}
          </div>
          <div className="mt-2 flex shrink-0 items-center gap-2 text-xs text-muted-foreground">
            {footer}
          </div>
        </CardContent>
      </Card>
    </Layout>
  )
}

// L3: JSON.stringify returns undefined for undefined/function values (which
// rendered the literal string "undefined" in the row) and throws on circular
// structures. Both cases now fall back to String().
function formatValue(v: unknown): string {
  if (typeof v === "string") return v
  try {
    return JSON.stringify(v) ?? String(v)
  } catch {
    return String(v)
  }
}

function formatFields(fields: Record<string, unknown>): string {
  const parts = Object.entries(fields)
    .filter(([k]) => k !== "idx")
    .map(([k, v]) => `${k}=${formatValue(v)}`)
  return parts.join(" ")
}

type OpsLine =
  | {
      kind: "marker"
      key: string
      ts: string
      nodeLabel: string | undefined
      text: string
    }
  | {
      kind: "event"
      key: string
      ts: string
      nodeLabel: string | undefined
      type: string
      text: string
    }

/** Merge markers + events by ts (newest first). OTP vs ops stay separate. */
function mergeOpsLines(events: OpsEvent[], markers: OpsMarker[]): OpsLine[] {
  const lines: OpsLine[] = []
  for (const m of markers) {
    const detail = m.detail && Object.keys(m.detail).length > 0
      ? ` ${formatFields(m.detail)}`
      : ""
    lines.push({
      kind: "marker",
      key: `m:${m.node ?? m.node_id ?? ""}:${m.marker_seq}:${m.ts}`,
      ts: m.ts,
      nodeLabel: m.node ?? m.node_id,
      text:
        `reason=${m.reason}` +
        (m.boot_id ? ` boot=${m.boot_id}` : "") +
        (m.prior_boot_id ? ` prior=${m.prior_boot_id}` : "") +
        detail,
    })
  }
  for (const e of events) {
    lines.push({
      kind: "event",
      key: `${e.node ?? e.node_id ?? ""}:${e.boot_id ?? ""}:${e.idx}:${e.ts}`,
      ts: e.ts,
      nodeLabel: e.node ?? e.node_id,
      type: e.type,
      text: `idx=${e.idx} ${formatFields(e.payload ?? {})}`,
    })
  }
  lines.sort((a, b) => b.ts.localeCompare(a.ts))
  return lines
}
