import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { Database, RefreshCw } from "lucide-react"
import { api } from "../api"
import { EmptyState, ErrorFlash, Layout } from "../components"
import { ExpandableText } from "../components/expandable-text"
import { Pagination, useClientPagination } from "../components/pagination"
import { Badge } from "@/components/ui/badge"
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"

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
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)

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
    setPage(1)
  }, [stream, level, nodeFilter, live, opsType])

  // The interval must call the CURRENT load: `load` is a dep so a
  // stream/level/node/source change rebuilds the timer instead of streaming
  // the stale filter. Both views refresh every 2s; the persisted view
  // itself lags emission by at most one poll cycle (~10s).
  useEffect(() => {
    const t = setInterval(load, 2000)
    return () => clearInterval(t)
  }, [load])

  const opsLines = useMemo(
    () => mergeOpsLines(opsEvents, opsMarkers),
    [opsEvents, opsMarkers],
  )
  const otpPagination = useClientPagination(events, pageSize, page)
  const opsPagination = useClientPagination(opsLines, pageSize, page)
  const pagination = stream === "ops" ? opsPagination : otpPagination
  const lineCount = pagination.total
  useEffect(() => {
    setPage((current) => Math.min(current, pagination.pageCount))
  }, [pagination.pageCount])
  let emptyTitle: string
  if (error) {
    emptyTitle = stream === "ops" ? "Ops events unavailable" : "Log events unavailable"
  } else {
    emptyTitle = stream === "ops" ? "No ops events yet" : "No log lines yet"
  }
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
      title="Logs"
      description="OTP logger stream and drained ops events (cool / task) — toggle sources; they are never merged."
    >
      {error && <ErrorFlash message={error} />}
      <Card className="flex h-fit max-h-full w-full flex-col self-start overflow-hidden animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle>Event stream</CardTitle>
          <CardDescription>
            {lineCount} lines fetched · {streamDescription}
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
        <CardContent className="min-h-0 px-0">
          {lineCount === 0 ? (
            <EmptyState
              title={emptyTitle}
              description={
                error
                  ? "The current source could not be read. Try Refresh."
                  : "New events will appear here when the gateway emits them."
              }
            />
          ) : (
            <Table flush aria-label="Log event stream" className="table-fixed">
              <TableHeader>
                <TableRow>
                  <TableHead className="w-[136px] sm:w-[144px]">Time</TableHead>
                  {!nodeFilter && <TableHead className="hidden md:table-cell">Node</TableHead>}
                  <TableHead className="w-28 px-2 sm:w-[120px] sm:px-3">
                    {stream === "ops" ? "Type" : "Level"}
                  </TableHead>
                  <TableHead>Details</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {stream === "otp"
                  ? otpPagination.slice.map((e) => (
                      <TableRow key={`${e.node ?? ""}:${e.idx}:${e.ts}`}>
                        <TableCell className="font-mono text-xs whitespace-nowrap tabular-nums">
                          <EventTime ts={e.ts} />
                          {!nodeFilter && e.node && (
                            <span className="mt-1 line-clamp-2 whitespace-normal text-muted-foreground md:hidden" title={e.node}>
                              <span className="sr-only">Node: </span>
                              {e.node}
                            </span>
                          )}
                        </TableCell>
                        {!nodeFilter && (
                          <TableCell className="hidden font-mono text-xs text-muted-foreground md:table-cell">
                            <span className="block max-w-[200px] truncate" title={e.node}>
                              {e.node ?? "—"}
                            </span>
                          </TableCell>
                        )}
                        <TableCell className="px-2 sm:px-3">
                          <Badge variant={levelBadgeVariant(e.level)} className="font-mono">
                            {e.level}
                          </Badge>
                        </TableCell>
                        <TableCell className="w-full whitespace-normal">
                          <LogDetails fields={e.fields} />
                        </TableCell>
                      </TableRow>
                    ))
                  : opsPagination.slice.map((line) => (
                      <TableRow key={line.key}>
                        <TableCell className="font-mono text-xs whitespace-nowrap tabular-nums">
                          <EventTime ts={line.ts} />
                          {!nodeFilter && line.nodeLabel && (
                            <span className="mt-1 line-clamp-2 whitespace-normal text-muted-foreground md:hidden" title={line.nodeLabel}>
                              <span className="sr-only">Node: </span>
                              {line.nodeLabel}
                            </span>
                          )}
                        </TableCell>
                        {!nodeFilter && (
                          <TableCell className="hidden font-mono text-xs text-muted-foreground md:table-cell">
                            <span className="block max-w-[200px] truncate" title={line.nodeLabel}>
                              {line.nodeLabel ?? "—"}
                            </span>
                          </TableCell>
                        )}
                        <TableCell className="px-2 sm:px-3">
                          <Badge
                            variant={line.kind === "marker" ? "warning" : "outline"}
                            className="font-mono"
                          >
                            {line.kind === "marker" ? "marker" : line.type}
                          </Badge>
                        </TableCell>
                        <TableCell className="w-full whitespace-normal">
                          <ExpandableText text={line.text} className="w-full" />
                        </TableCell>
                      </TableRow>
                    ))}
              </TableBody>
            </Table>
          )}
          <div className="px-5">
            {lineCount > 0 && (
              <Pagination
                page={pagination.page}
                pageCount={pagination.pageCount}
                total={pagination.total}
                pageSize={pageSize}
                onPageChange={setPage}
                onPageSizeChange={(n) => {
                  setPageSize(n)
                  setPage(1)
                }}
              />
            )}
            <div className="flex items-center gap-2 pt-2 pb-4 text-xs text-muted-foreground">
              {footer}
            </div>
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

function fieldEntries(fields: Record<string, unknown>) {
  return Object.entries(fields).filter(([key]) => key !== "idx")
}

function formatFields(fields: Record<string, unknown>): string {
  return fieldEntries(fields)
    .map(([key, value]) => `${key}=${formatValue(value)}`)
    .join(" ")
}

function levelBadgeVariant(level: string): "danger" | "warning" | "default" | "secondary" {
  switch (level.toLowerCase()) {
    case "error":
    case "crit":
    case "critical":
    case "alert":
    case "emerg":
    case "emergency":
      return "danger"
    case "warn":
    case "warning":
      return "warning"
    case "notice":
      return "default"
    default:
      return "secondary"
  }
}

function LogDetails({ fields }: { fields: Record<string, unknown> }) {
  const text = formatFields(fields)
  if (!text) return "—"
  return (
    <ExpandableText text={text} className="w-full">
      <LogFields fields={fields} />
    </ExpandableText>
  )
}

function LogFields({ fields }: { fields: Record<string, unknown> }) {
  return (
    <>
      {fieldEntries(fields).map(([key, value]) => (
        <span key={key}>
          <span className="text-muted-foreground">{key}=</span>
          <span className={value === null || typeof value !== "object" ? "text-primary" : undefined}>
            {formatValue(value)}
          </span>{" "}
        </span>
      ))}
    </>
  )
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
