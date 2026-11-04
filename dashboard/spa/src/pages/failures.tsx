import { useEffect, useRef, useState } from "react"
import { Ban, CircleAlert, History, OctagonX, RefreshCw } from "lucide-react"
import { api } from "../api"
import { EmptyState, ErrorFlash, IconAction, Layout, Loading } from "../components"
import { ExpandableText } from "../components/expandable-text"
import { Pagination } from "../components/pagination"
import { StatCard, StatCardSkeleton } from "@/components/stat-card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
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
import {
  CopyMono,
  EventTime,
  fmtNum,
  statusClass,
  TimelineDialog,
  type FailureEvent,
  type FailureGroup,
  type FailureSummary,
} from "./shared"

function KindBadge({ kind }: { kind: FailureEvent["kind"] }) {
  return (
    <Badge variant={kind === "upstream" ? "warning" : "secondary"} className="font-mono">
      {kind}
    </Badge>
  )
}

/** The one-line error signature: native/provider code when known, else the
 * failover classification, else an honest em dash (terminal-first errors
 * pre-021 record neither). */
function ErrorCell({
  code,
  reason,
  detail,
}: {
  code: string | null
  reason: string | null
  detail?: string | null
}) {
  if (!code && !reason && !detail) return <span className="text-muted-foreground">—</span>
  return (
    <div className="flex min-w-0 max-w-[320px] flex-wrap items-center gap-1">
      {code && (
        <span className="truncate font-mono text-xs" title={code}>
          {code}
        </span>
      )}
      {reason && (
        <Badge variant="outline" className="font-mono text-[11px] font-normal">
          {reason}
        </Badge>
      )}
      {detail && <ExpandableText text={detail} className="w-full min-w-0" />}
    </div>
  )
}

/** Requested name → resolved listing when they differ (janus-auto rows). */
function modelLabel(e: FailureEvent): string {
  if (e.requested_model && e.model && e.requested_model !== e.model)
    return `${e.requested_model} → ${e.model}`
  return e.model ?? (e.kind === "upstream" ? "(deleted)" : "—")
}

function ByErrorCard({ rows }: { rows: FailureGroup[] }) {
  return (
    <Card className="animate-fade-up overflow-hidden" style={{ animationDelay: "160ms" }}>
      <CardHeader className="border-b">
        <CardTitle>By error</CardTitle>
        <CardDescription>
          Failure shapes in window, most frequent first — the code is the provider-native
          error_code for upstream rows and the gateway reject code for pre-pick rows
        </CardDescription>
      </CardHeader>
      <CardContent className="px-0">
        {rows.length === 0 ? (
          <EmptyState
            compact
            title="No failures in this window"
            description="Nothing has failed — widen the time range if you expected rows here."
          />
        ) : (
          <Table flush className="table-fixed">
            <TableHeader>
              <TableRow>
                <TableHead className="w-24">Kind</TableHead>
                <TableHead>Error</TableHead>
                <TableHead className="hidden lg:table-cell lg:w-44">Model</TableHead>
                <TableHead className="hidden lg:table-cell lg:w-32">Provider</TableHead>
                <TableHead className="w-16 text-right">Count</TableHead>
                <TableHead className="hidden text-right lg:table-cell lg:w-32">Last seen</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((g, i) => (
                <TableRow key={`${g.kind}:${g.code}:${g.model}:${g.provider}:${i}`}>
                  <TableCell>
                    <KindBadge kind={g.kind} />
                  </TableCell>
                  <TableCell className="max-w-0">
                    <ErrorCell code={g.code} reason={g.reason} />
                    <div className="mt-1 truncate font-mono text-[11px] text-muted-foreground lg:hidden" title={`${g.model ?? "—"}${g.provider ? ` · ${g.provider}` : ""}`}>
                      {g.model ?? (g.kind === "upstream" ? "(deleted)" : "—")}
                      {g.provider ? ` · ${g.provider}` : ""}
                    </div>
                  </TableCell>
                  <TableCell className="hidden max-w-0 truncate font-mono text-xs lg:table-cell" title={g.model ?? undefined}>
                    {g.model ?? (g.kind === "upstream" ? "(deleted)" : "—")}
                  </TableCell>
                  <TableCell className="hidden max-w-0 truncate font-mono text-xs lg:table-cell" title={g.provider ?? undefined}>
                    {g.provider ?? "—"}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{fmtNum(g.count)}</TableCell>
                  <TableCell className="hidden text-right tabular-nums text-muted-foreground lg:table-cell">
                    <EventTime ts={new Date(g.last_ts * 1000).toISOString()} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  )
}

function FailureEventListItem({
  event: e,
  onTimeline,
}: {
  event: FailureEvent
  onTimeline: (requestRef: string) => void
}) {
  return (
    <li className="space-y-3 px-5 py-4">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-xs text-muted-foreground tabular-nums">
          <EventTime ts={new Date(e.ts * 1000).toISOString()} />
        </span>
        <KindBadge kind={e.kind} />
        <span className={`font-mono text-xs font-semibold ${e.status != null ? statusClass(e.status) : "text-muted-foreground"}`}>
          {e.status ?? "—"}
        </span>
        {e.request_ref && (
          <span className="ml-auto">
            <IconAction label="Timeline" onClick={() => onTimeline(e.request_ref!)}>
              <History />
            </IconAction>
          </span>
        )}
      </div>
      <div className="min-w-0">
        <div className="truncate font-mono text-sm" title={modelLabel(e)}>
          {modelLabel(e)}
        </div>
        {e.provider && (
          <div className="mt-1 truncate font-mono text-xs text-muted-foreground" title={e.provider}>
            {e.provider}
          </div>
        )}
      </div>
      <ErrorCell code={e.code} reason={e.reason} detail={e.detail} />
      <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 text-xs">
        <dt className="text-muted-foreground">Key</dt>
        <dd className="min-w-0 truncate font-mono" title={e.key_prefix ?? undefined}>{e.key_prefix ?? "—"}</dd>
        <dt className="text-muted-foreground">Node</dt>
        <dd className="min-w-0 truncate font-mono" title={e.node ?? undefined}>{e.node ?? "—"}</dd>
        <dt className="text-muted-foreground">Request ID</dt>
        <dd className="min-w-0 [&>button]:max-w-full">
          {e.request_id ? <CopyMono text={e.request_id} /> : "—"}
        </dd>
      </dl>
    </li>
  )
}

export function Failures() {
  const [range, setRange] = useState("24h")
  const [kind, setKind] = useState("")
  const [summary, setSummary] = useState<FailureSummary | null>(null)
  const [events, setEvents] = useState<FailureEvent[] | null>(null)
  const [error, setError] = useState("")
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [total, setTotal] = useState(0)
  // Per-row timeline drill-down (request_ref of the open dialog, null = closed).
  const [timelineRef, setTimelineRef] = useState<string | null>(null)

  // Monotonic request id: the 30s poll, manual Refresh and filter changes can
  // overlap, and an older response must never overwrite a newer one.
  const loadGen = useRef(0)

  const load = (r: string, p = page, ps = pageSize, k = kind) => {
    const gen = ++loadGen.current
    return Promise.all([
      api<FailureSummary>(`/failures/summary?range=${r}`),
      api<{ total: number; events: FailureEvent[] }>(
        `/failures/events?range=${r}&limit=${ps}&offset=${(p - 1) * ps}` + (k ? `&kind=${k}` : ""),
      ),
    ])
      .then(([s, e]) => {
        if (gen !== loadGen.current) return
        setSummary(s)
        setEvents(e.events)
        setTotal(e.total)
        setError("")
      })
      .catch((err) => {
        if (gen !== loadGen.current) return
        setError(err.message)
      })
  }

  useEffect(() => {
    load(range)
    const t = setInterval(() => load(range), 30_000)
    return () => clearInterval(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [range, page, pageSize, kind])

  const totals = summary?.totals
  const top = summary?.by_error[0]

  return (
    <Layout
      title="Failures"
      description="Failed model calls — upstream errors from usage accounting plus pre-pick rejects recovered from gateway logs (reject history follows the log ring)"
      actions={
        <>
          <Select
            value={range}
            onValueChange={(v) => { setRange(v); setPage(1) }}
          >
            <SelectTrigger size="sm" aria-label="Time range" style={{ width: 100 }}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="24h">Last 24 hours</SelectItem>
              <SelectItem value="7d">Last 7 days</SelectItem>
              <SelectItem value="30d">Last 30 days</SelectItem>
            </SelectContent>
          </Select>
          <Button variant="outline" size="sm" onClick={() => load(range)}>
            <RefreshCw />
            Refresh
          </Button>
        </>
      }
    >
      {error && <ErrorFlash message={error} />}
      {!summary && !error && (
        <div className="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4">
          {Array.from({ length: 4 }).map((_, i) => (
            <StatCardSkeleton key={i} />
          ))}
        </div>
      )}

      {summary && totals && (
        <>
          <div className="grid grid-cols-2 gap-3 sm:gap-4 xl:grid-cols-4">
            <StatCard
              label="Failures"
              value={totals.failures}
              icon={OctagonX}
              className="animate-fade-up"
            />
            <StatCard
              label="Upstream errors"
              value={totals.upstream}
              subtitle="answered by a provider"
              icon={CircleAlert}
              className="animate-fade-up"
              style={{ animationDelay: "40ms" }}
            />
            <StatCard
              label="Rejected calls"
              value={totals.rejects}
              subtitle="pre-pick · from gateway logs"
              icon={Ban}
              className="animate-fade-up"
              style={{ animationDelay: "80ms" }}
            />
            <StatCard
              label="Top error"
              value={top ? fmtNum(top.count) : "—"}
              subtitle={top ? `${top.code ?? top.reason ?? "unclassified"} · ${top.model ?? "—"}` : "in window"}
              icon={CircleAlert}
              className="animate-fade-up"
              style={{ animationDelay: "120ms" }}
            />
          </div>

          <ByErrorCard rows={summary.by_error} />

          <Card className="animate-fade-up overflow-hidden" style={{ animationDelay: "240ms" }}>
            <CardHeader className="border-b">
              <CardTitle>Recent failures</CardTitle>
              <CardDescription>
                {total.toLocaleString()} in window · page {page}/
                {Math.max(1, Math.ceil(total / pageSize))} · local
              </CardDescription>
              <CardAction>
                <Select
                  value={kind || "all"}
                  onValueChange={(v) => { setKind(v === "all" ? "" : v); setPage(1) }}
                >
                  <SelectTrigger size="sm" aria-label="Filter by kind" style={{ width: 140 }}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="all">All kinds</SelectItem>
                    <SelectItem value="upstream">Upstream</SelectItem>
                    <SelectItem value="reject">Rejected</SelectItem>
                  </SelectContent>
                </Select>
              </CardAction>
            </CardHeader>
            <CardContent className="px-0">
              {error && !events ? (
                <EmptyState
                  title="Failures unavailable"
                  description="Could not read /api/failures/events — this is not an empty result set."
                />
              ) : !events ? (
                <Loading />
              ) : events.length === 0 ? (
                <EmptyState
                  compact
                  title={kind ? "No matching failures" : "No failures in this window"}
                  description={
                    kind
                      ? "Adjust the kind filter or widen the time range."
                      : "Nothing has failed — widen the time range if you expected rows here."
                  }
                />
              ) : (
                <>
                  <ul className="divide-y divide-border/60 lg:hidden" aria-label="Failure events">
                    {events.map((e, i) => (
                      <FailureEventListItem
                        key={e.request_id ?? e.request_ref ?? `${e.kind}-${e.ts}-${i}`}
                        event={e}
                        onTimeline={setTimelineRef}
                      />
                    ))}
                  </ul>
                  <div className="hidden lg:block">
                    <Table flush className="table-fixed">
                      <TableHeader>
                        <TableRow>
                          <TableHead className="w-32">Time</TableHead>
                          <TableHead className="w-24">Kind</TableHead>
                          <TableHead className="w-48">Model</TableHead>
                          <TableHead className="hidden 2xl:table-cell 2xl:w-40">Provider</TableHead>
                          <TableHead className="hidden 2xl:table-cell 2xl:w-28">Key</TableHead>
                          <TableHead className="w-16">Status</TableHead>
                          <TableHead>Error</TableHead>
                          <TableHead className="hidden 2xl:table-cell 2xl:w-36">Node</TableHead>
                          <TableHead className="hidden 2xl:table-cell 2xl:w-40">Request ID</TableHead>
                          <TableHead className="w-10">
                            <span className="sr-only">Timeline</span>
                          </TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {events.map((e, i) => (
                          <TableRow key={e.request_id ?? e.request_ref ?? `${e.kind}-${e.ts}-${i}`}>
                            <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
                              <EventTime ts={new Date(e.ts * 1000).toISOString()} />
                            </TableCell>
                            <TableCell>
                              <KindBadge kind={e.kind} />
                            </TableCell>
                            <TableCell className="max-w-0 truncate font-mono text-xs" title={modelLabel(e)}>
                              {modelLabel(e)}
                            </TableCell>
                            <TableCell className="hidden max-w-0 truncate font-mono text-xs 2xl:table-cell" title={e.provider ?? undefined}>
                              {e.provider ?? "—"}
                            </TableCell>
                            <TableCell className="hidden max-w-0 truncate font-mono text-xs 2xl:table-cell" title={e.key_prefix ?? undefined}>
                              {e.key_prefix ?? "—"}
                            </TableCell>
                            <TableCell
                              className={`font-mono text-xs font-semibold ${e.status != null ? statusClass(e.status) : "text-muted-foreground"}`}
                            >
                              {e.status ?? "—"}
                            </TableCell>
                            <TableCell className="max-w-0 whitespace-normal">
                              <ErrorCell code={e.code} reason={e.reason} detail={e.detail} />
                            </TableCell>
                            <TableCell className="hidden max-w-0 truncate font-mono text-xs text-muted-foreground 2xl:table-cell" title={e.node ?? undefined}>
                              {e.node ?? "—"}
                            </TableCell>
                            <TableCell className="hidden max-w-0 2xl:table-cell [&>button]:max-w-full">
                              {e.request_id ? <CopyMono text={e.request_id} /> : "—"}
                            </TableCell>
                            <TableCell>
                              {e.request_ref && (
                                <IconAction label="Timeline" onClick={() => setTimelineRef(e.request_ref)}>
                                  <History />
                                </IconAction>
                              )}
                            </TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>
                </>
              )}
              <div className="px-5">
                <Pagination
                  page={page}
                  pageCount={Math.max(1, Math.ceil(total / pageSize))}
                  total={total}
                  pageSize={pageSize}
                  onPageChange={setPage}
                  onPageSizeChange={(n) => {
                    setPageSize(n)
                    setPage(1)
                  }}
                />
              </div>
            </CardContent>
          </Card>
        </>
      )}
      {timelineRef && (
        <TimelineDialog requestRef={timelineRef} onClose={() => setTimelineRef(null)} />
      )}
    </Layout>
  )
}
