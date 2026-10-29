import { useEffect, useMemo, useRef, useState } from "react"
import {
  Activity,
  ArrowDownToLine,
  ArrowUpFromLine,
  CircleAlert,
  History,
  RefreshCw,
  Timer,
  TimerReset,
  Zap,
} from "lucide-react"
import { Bar, BarChart, XAxis } from "recharts"
import { api } from "../api"
import { EmptyState, ErrorFlash, IconAction, Layout, Loading } from "../components"
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { StatCard, StatCardSkeleton } from "@/components/stat-card"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Tooltip } from "@/components/ui/tooltip"
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
  fmtTs,
  statusClass,
  TimelineDialog,
  type SpendResponse,
  type UsageEvent,
  type UsageRow,
  type UsageSummary,
} from "./shared"
import { Pagination } from "../components/pagination"
import { fmtUtcBucketLabel, utcUsageBucketKey } from "@/lib/time-format"

const tokensConfig = {
  prompt: { label: "Tokens in", color: "var(--color-chart-1)" },
  completion: { label: "Tokens out", color: "var(--color-chart-2)" },
} satisfies ChartConfig

const requestsConfig = {
  requests: { label: "Requests", color: "var(--color-chart-1)" },
} satisfies ChartConfig

/** Fill missing buckets with zeros so gaps render as 0-height bars. */
function zeroFill(summary: UsageSummary): { label: string; prompt: number; completion: number; requests: number }[] {
  const step = summary.range === "24h" ? 3600 : 86400
  const byBucket = new Map(summary.series.map((p) => [p.bucket, p]))
  const out: { label: string; prompt: number; completion: number; requests: number }[] = []
  for (let t = summary.ts_from; t < summary.ts_to; t += step) {
    const bucket = utcUsageBucketKey(t, step)
    const p = byBucket.get(bucket)
    const label = fmtUtcBucketLabel(bucket, summary.range)
    out.push({
      label,
      prompt: p?.prompt_tokens ?? 0,
      completion: p?.completion_tokens ?? 0,
      requests: p?.requests ?? 0,
    })
  }
  return out
}

type LiveKeyRow = Omit<UsageRow, "name"> & { name: string }

/** Drop revoked keys from the Per agent key card / filter (API also INNER JOINs). */
function liveKeys(rows: UsageRow[]): LiveKeyRow[] {
  return rows.filter(
    (r): r is LiveKeyRow =>
      r.name !== null && r.name !== undefined && r.name !== "(deleted)",
  )
}

function ResolutionCard({ rows }: { rows: UsageSummary["by_resolution"] }) {
  // Backend already filters to the configured auto-router virtual name
  // (settings.auto_router.model) — direct calls to real models are not
  // resolutions and never reach this card.
  return (
    <Card className="animate-fade-up overflow-hidden" style={{ animationDelay: "360ms" }}>
      <CardHeader className="border-b">
        <CardTitle>Resolutions</CardTitle>
        <CardDescription>
          janus-auto requests resolved to a concrete model — per-resolution
          accounting from the gateway's recorded requested name
        </CardDescription>
      </CardHeader>
      <CardContent className="px-0">
        <Table flush>
          <TableHeader>
            <TableRow>
              <TableHead>Requested</TableHead>
              <TableHead className="w-8" />
              <TableHead>Resolved model</TableHead>
              <TableHead className="text-right">Requests</TableHead>
              <TableHead className="text-right">Tokens</TableHead>
              <TableHead className="text-right">Last</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={`${r.requested}:${r.resolved}`}>
                <TableCell className="font-mono text-xs">{r.requested}</TableCell>
                <TableCell className="text-muted-foreground">→</TableCell>
                <TableCell className="font-mono text-xs">{r.resolved}</TableCell>
                <TableCell className="text-right tabular-nums">{fmtNum(r.requests)}</TableCell>
                <TableCell className="text-right tabular-nums">
                  {fmtNum(r.prompt_tokens + r.completion_tokens)}
                </TableCell>
                <TableCell className="text-right tabular-nums text-muted-foreground">
                  <EventTime ts={new Date(r.last_ts * 1000).toISOString()} />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  )
}

function BreakdownCard({ title, rows }: { title: string; rows: UsageSummary["by_key"] }) {
  const maxReq = Math.max(1, ...rows.map((r) => r.requests))
  return (
    <Card className="w-full overflow-hidden">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>{rows.length} active in window</CardDescription>
      </CardHeader>
      <CardContent>
        {rows.length === 0 ? (
          <div className="flex min-h-12 items-center justify-center py-3 text-sm text-muted-foreground">
            No traffic in this window
          </div>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead className="text-right">Requests</TableHead>
                <TableHead className="text-right">Tokens</TableHead>
                <TableHead className="w-[30%]">Share</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r, i) => (
                <TableRow key={(r.id ?? "del") + ":" + i}>
                  <TableCell className="max-w-[220px] truncate font-mono text-xs" title={r.name ?? undefined}>
                    {r.name ?? "(deleted)"}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">{fmtNum(r.requests)}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {fmtNum(r.prompt_tokens + r.completion_tokens)}
                  </TableCell>
                  <TableCell>
                    <div className="h-1.5 w-full rounded bg-muted" aria-hidden>
                      <div
                        className="h-1.5 w-full origin-left rounded bg-primary/60 transition-transform duration-500 ease-out"
                        style={{ transform: `scaleX(${r.requests / maxReq})` }}
                      />
                  </div>
                    <span className="sr-only">
                      {Math.round((r.requests / maxReq) * 100)}% of the busiest row
                    </span>
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

// --- H8 cost reporting (spec 2026-10-15-maturity-hardening) ---------------

type SpendGroup = "key" | "model" | "day"

const SPEND_GROUP_LABEL: Record<SpendGroup, string> = {
  key: "Agent key",
  model: "Model",
  day: "Day",
}

function fmtCost(v: number): string {
  return v >= 1000
    ? v.toLocaleString("en-US", { maximumFractionDigits: 2 })
    : String(Number(v.toFixed(4)))
}

/** Query-time spend report (H8-D2): priced rows + the never-estimated
 * unpriced bucket + the failover-window gap badge. */
function SpendCard({ tsFrom, tsTo }: { tsFrom: number; tsTo: number }) {
  const [gb, setGb] = useState<SpendGroup>("key")
  const [data, setData] = useState<SpendResponse | null>(null)
  const [error, setError] = useState("")

  useEffect(() => {
    setData(null)
    setError("")
    api<SpendResponse>(`/usage/spend?from=${tsFrom}&to=${tsTo}&group_by=${gb}`)
      .then(setData)
      .catch((e) => setError(e.message))
  }, [tsFrom, tsTo, gb])

  const total = useMemo(
    () => (data ? data.rows.reduce((acc, r) => acc + (r.cost ?? 0), 0) : 0),
    [data],
  )
  const unpricedTotal =
    (data?.unpriced.prompt_tokens ?? 0) + (data?.unpriced.completion_tokens ?? 0)
  const windows = data?.failover_windows ?? []
  const maxRpo = Math.max(0, ...windows.map((w) => w.rpo_window_sec))
  const cur =
    data == null
      ? ""
      : data.currencies.length === 1
        ? ` ${data.currencies[0]}`
        : data.currencies.length > 1
          ? ` mixed ${data.currencies.join("/")}`
          : ""

  return (
    <Card className="animate-fade-up overflow-hidden">
      <CardHeader className="border-b">
        <CardTitle>Spend</CardTitle>
        <CardDescription>
          {data
            ? `Priced usage ${fmtCost(total)}${cur} in window — computed at query time from operator-entered prices`
            : "Per-1M-token prices are set on the Providers page"}
        </CardDescription>
        <CardAction>
          <div className="flex flex-wrap items-center gap-2">
            {windows.length > 0 && (
              <Tooltip
                side="bottom"
                content={`${windows.length} master failover window(s) overlap this range (async RPO ≤ ${maxRpo}s): usage rows may be missing — spend may be undercounted, never silently.`}
              >
                <Badge variant="warning" className="cursor-default">
                  failover gap
                </Badge>
              </Tooltip>
            )}
            <Select
              value={gb}
              onValueChange={(v) => setGb(v as SpendGroup)}
            >
              <SelectTrigger size="sm" aria-label="Group spend by" style={{ width: 144 }}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="key">By agent key</SelectItem>
                <SelectItem value="model">By model</SelectItem>
                <SelectItem value="day">By day</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </CardAction>
      </CardHeader>
      <CardContent className="px-0">
        {error ? (
          <div className="px-5">
            <ErrorFlash message={error} />
          </div>
        ) : !data ? (
          <Loading />
        ) : data.rows.length === 0 && unpricedTotal === 0 ? (
          <EmptyState
            title="No usage in this window"
            description="No tokens to price. Set prices on the Providers page to see spend."
          />
        ) : (
          <Table flush>
            <TableHeader>
              <TableRow>
                <TableHead>{SPEND_GROUP_LABEL[gb]}</TableHead>
                <TableHead className="text-right">Tokens in</TableHead>
                <TableHead className="text-right">Tokens out</TableHead>
                <TableHead className="text-right">Cost</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.rows.map((r, i) => {
                const unp = r.unpriced_prompt_tokens + r.unpriced_completion_tokens
                return (
                  <TableRow key={`${String(r.id)}:${i}`}>
                    <TableCell className="max-w-[220px] truncate font-mono text-xs">
                      {r.name}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {fmtNum(r.prompt_tokens)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {fmtNum(r.completion_tokens)}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {r.cost == null ? (
                        <span className="text-muted-foreground">—</span>
                      ) : (
                        <>
                          {fmtCost(r.cost)}{" "}
                          <span className="text-muted-foreground">{r.currency}</span>
                        </>
                      )}
                      {unp > 0 && (
                        <span
                          className="ml-1 text-[11px] text-muted-foreground"
                          title="tokens on models without a price row — excluded from cost, never estimated"
                        >
                          (+{fmtNum(unp)} unpriced)
                        </span>
                      )}
                    </TableCell>
                  </TableRow>
                )
              })}
              {unpricedTotal > 0 && (
                <TableRow className="bg-muted/40 text-muted-foreground">
                  <TableCell className="font-mono text-xs">
                    unpriced models ({data.unpriced.models})
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {fmtNum(data.unpriced.prompt_tokens)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {fmtNum(data.unpriced.completion_tokens)}
                  </TableCell>
                  <TableCell className="text-right">
                    <span title="no price row — never estimated">—</span>
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  )
}

export function Usage() {
  const [range, setRange] = useState("24h")
  const [summary, setSummary] = useState<UsageSummary | null>(null)
  const [events, setEvents] = useState<UsageEvent[] | null>(null)
  const [error, setError] = useState("")
  // Recent-requests drill-down: server-side pagination + filters.
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [statusFilter, setStatusFilter] = useState("")
  const [modelId, setModelId] = useState(0)
  const [keyId, setKeyId] = useState(0)
  const [total, setTotal] = useState(0)
  // Per-row timeline drill-down (request_ref of the open dialog, null = closed).
  const [timelineRef, setTimelineRef] = useState<string | null>(null)

  // Monotonic request id: the 30s poll, manual Refresh and filter changes can
  // overlap, and an older response must never overwrite a newer one.
  const loadGen = useRef(0)

  const load = (r: string, p = page, ps = pageSize, st = statusFilter, mid = modelId, kid = keyId) => {
    const gen = ++loadGen.current
    return Promise.all([
      api(`/usage/summary?range=${r}`),
      api(
        `/usage/events?limit=${ps}&offset=${(p - 1) * ps}` +
          (st ? `&status=${st}` : "") +
          (mid ? `&model_id=${mid}` : "") +
          (kid ? `&key_id=${kid}` : ""),
      ),
    ])
      .then(([s, e]) => {
        if (gen !== loadGen.current) return
        setSummary(s)
        setEvents(e.events)
        setTotal(e.total ?? e.events.length)
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
  }, [range, page, pageSize, statusFilter, modelId, keyId])

  const chartData = useMemo(() => (summary ? zeroFill(summary) : []), [summary])
  const liveKeyRows = useMemo(() => liveKeys(summary?.by_key ?? []), [summary])
  const totals = summary?.totals

  return (
    <Layout
      title="Usage"
      description="Token consumption and traffic across agent keys, models, and providers — times are local."
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
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
          {Array.from({ length: 6 }).map((_, i) => (
            <StatCardSkeleton key={i} />
          ))}
        </div>
      )}

      {summary && totals && (
        <>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
            <div className="relative animate-fade-up">
              <StatCard label="Requests" value={totals.requests} icon={Activity} className="h-full" />
              {summary.writer && summary.writer.dropped > 0 && (
                <Tooltip
                  side="bottom"
                  content="The gateway's usage writer dropped this many events (buffer overflow) — counts below are lower than real traffic."
                >
                  <Badge variant="warning" className="absolute -top-2 right-2 h-5 cursor-default px-1.5 text-[10px]">
                    {fmtNum(summary.writer.dropped)} dropped
                  </Badge>
                </Tooltip>
              )}
              {summary.writer && !summary.writer.alive && (
                <Tooltip
                  side="bottom"
                  content="The gateway's usage writer is not running — usage events are not being recorded."
                >
                  <Badge variant="destructive" className="absolute -top-2 right-2 h-5 cursor-default px-1.5 text-[10px]">
                    writer down
                  </Badge>
                </Tooltip>
              )}
            </div>
            <StatCard
              label="Tokens in"
              value={totals.prompt_tokens}
              icon={ArrowDownToLine}
              className="animate-fade-up"
              style={{ animationDelay: "40ms" }}
            />
            <StatCard
              label="Tokens out"
              value={totals.completion_tokens}
              icon={ArrowUpFromLine}
              className="animate-fade-up"
              style={{ animationDelay: "80ms" }}
            />
            <StatCard
              label="Errors"
              value={totals.errors}
              subtitle={`${((totals.errors / Math.max(1, totals.requests)) * 100).toFixed(1)}% of requests`}
              icon={CircleAlert}
              className="animate-fade-up"
              style={{ animationDelay: "120ms" }}
            />
            <StatCard
              label="p95 latency"
              value={totals.p95_latency_ms ?? "—"}
              suffix=" ms"
              subtitle="non-stream"
              icon={Timer}
              className="animate-fade-up"
              style={{ animationDelay: "160ms" }}
            />
            <StatCard
              label="p95 stream"
              value={totals.p95_stream_ms ?? "—"}
              suffix=" ms"
              subtitle="end-to-end drain"
              icon={TimerReset}
              className="animate-fade-up"
              style={{ animationDelay: "200ms" }}
            />
          </div>

          {totals.unreported > 0 && (
            <p className="text-xs text-muted-foreground">
              {fmtNum(totals.unreported)} successful request(s) had no provider usage report
              (streams without a usage chunk).
            </p>
          )}

          <div className="grid animate-fade-up gap-4 lg:grid-cols-2" style={{ animationDelay: "240ms" }}>
            <Card>
              <CardHeader>
                <CardTitle>Tokens</CardTitle>
                <CardDescription>
                  in {fmtNum(totals.prompt_tokens)} / out {fmtNum(totals.completion_tokens)} in window
                </CardDescription>
              </CardHeader>
              <CardContent>
                {totals.prompt_tokens + totals.completion_tokens === 0 ? (
                  <EmptyState
                    compact
                    title="No token usage in this window"
                    description="Token totals will appear after a provider reports usage."
                  />
                ) : (
                  <ChartContainer config={tokensConfig} className="aspect-auto h-[240px] w-full">
                    <BarChart data={chartData} accessibilityLayer margin={{ top: 4, right: 0, bottom: 0, left: 0 }}>
                      <XAxis dataKey="label" tickLine={false} axisLine={false} interval="preserveStartEnd" />
                      <ChartTooltip content={<ChartTooltipContent />} />
                      <Bar dataKey="prompt" stackId="t" fill="var(--color-prompt)" radius={[0, 0, 0, 0]} />
                      <Bar dataKey="completion" stackId="t" fill="var(--color-completion)" radius={[3, 3, 0, 0]} />
                    </BarChart>
                  </ChartContainer>
                )}
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle>Requests</CardTitle>
                <CardDescription>{fmtNum(totals.requests)} in window</CardDescription>
              </CardHeader>
              <CardContent>
                {totals.requests === 0 ? (
                  <EmptyState
                    compact
                    title="No requests in this window"
                    description="Traffic will appear here after agents call the gateway."
                  />
                ) : (
                  <ChartContainer config={requestsConfig} className="aspect-auto h-[240px] w-full">
                    <BarChart data={chartData} accessibilityLayer margin={{ top: 4, right: 0, bottom: 0, left: 0 }}>
                      <XAxis dataKey="label" tickLine={false} axisLine={false} interval="preserveStartEnd" />
                      <ChartTooltip content={<ChartTooltipContent />} />
                      <Bar dataKey="requests" fill="var(--color-requests)" radius={[3, 3, 0, 0]} />
                    </BarChart>
                  </ChartContainer>
                )}
              </CardContent>
            </Card>
          </div>

          <div
            className="grid animate-fade-up items-stretch gap-4 xl:grid-cols-2"
            style={{ animationDelay: "320ms" }}
          >
            <BreakdownCard title="Per agent key" rows={liveKeyRows} />
            <BreakdownCard title="Per model" rows={summary.by_model} />
            <BreakdownCard title="Per provider" rows={summary.by_provider} />
            <BreakdownCard title="Per provider key" rows={summary.by_provider_key} />
          </div>

          {summary.by_resolution.length > 0 && <ResolutionCard rows={summary.by_resolution} />}


          <SpendCard tsFrom={summary.ts_from} tsTo={summary.ts_to} />

          <Card className="animate-fade-up overflow-hidden" style={{ animationDelay: "400ms" }}>
            <CardHeader className="border-b">
              <CardTitle>Recent requests</CardTitle>
              <CardDescription>
                {total.toLocaleString()} total · page {page}/
                {Math.max(1, Math.ceil(total / pageSize))} · local
              </CardDescription>
              <CardAction>
                <div className="flex flex-wrap items-center gap-2">
                  <Select
                    value={statusFilter || "all"}
                    onValueChange={(v) => { setStatusFilter(v === "all" ? "" : v); setPage(1) }}
                  >
                    <SelectTrigger size="sm" aria-label="Filter by status" style={{ width: 140 }}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">All statuses</SelectItem>
                      <SelectItem value="ok">Succeeded (2xx)</SelectItem>
                      <SelectItem value="error">Failed (4xx/5xx)</SelectItem>
                    </SelectContent>
                  </Select>
                  {(summary?.by_model.length ?? 0) > 0 && (
                    <Select
                      value={String(modelId)}
                      onValueChange={(v) => { setModelId(Number(v)); setPage(1) }}
                    >
                      <SelectTrigger size="sm" aria-label="Filter by model" style={{ maxWidth: 180 }}>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="0">All models</SelectItem>
                        {summary!.by_model.map((m) => (
                      <SelectItem key={m.id ?? 0} value={String(m.id ?? 0)}>
                        {m.name ?? "(deleted)"}
                      </SelectItem>
                    ))}
                      </SelectContent>
                    </Select>
                  )}
                  {liveKeyRows.length > 0 && (
                    <Select
                      value={String(keyId)}
                      onValueChange={(v) => { setKeyId(Number(v)); setPage(1) }}
                    >
                      <SelectTrigger size="sm" aria-label="Filter by agent key" style={{ maxWidth: 150 }}>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="0">All keys</SelectItem>
                        {liveKeyRows.map((k) => (
                      <SelectItem key={k.id ?? 0} value={String(k.id ?? 0)}>
                        {k.name}
                      </SelectItem>
                    ))}
                      </SelectContent>
                    </Select>
                  )}
                  {summary.writer && (
                    <span className="hidden text-xs text-muted-foreground sm:inline">
                      Writer {summary.writer.alive ? "alive" : "down"} · buffered{" "}
                      {summary.writer.buffered}
                    </span>
                  )}
                </div>
              </CardAction>
            </CardHeader>
            <CardContent className="px-0">
              {error && !events ? (
                <EmptyState
                  title="Requests unavailable"
                  description="Could not read /api/usage/events — this is not an empty result set."
                />
              ) : !events ? (
                <Loading />
              ) : events.length === 0 ? (
                <EmptyState
                  title="No matching requests"
                  description="Adjust the filters or widen the time range."
                />
              ) : (
                <Table flush>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Time</TableHead>
                      <TableHead>Key</TableHead>
                      <TableHead>Model</TableHead>
                      <TableHead>Provider</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Stream</TableHead>
                      <TableHead className="text-right">In</TableHead>
                      <TableHead className="text-right">Out</TableHead>
                      <TableHead className="text-right">Latency</TableHead>
                      <TableHead>Request ID</TableHead>
                      <TableHead className="w-10">
                        <span className="sr-only">Timeline</span>
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {events.map((e, i) => (
                      <TableRow key={e.request_id ?? `${e.ts}-${i}`}>
                        <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
                          {fmtTs(e.ts)}
                        </TableCell>
                        <TableCell className="font-mono text-xs">{e.key_prefix ?? "(deleted)"}</TableCell>
                        <TableCell className="font-mono text-xs">{e.model ?? "(deleted)"}</TableCell>
                        <TableCell className="font-mono text-xs">{e.provider ?? "(deleted)"}</TableCell>
                        <TableCell className={`font-mono text-xs font-semibold ${statusClass(e.status)}`}>
                          {e.status}
                        </TableCell>
                        <TableCell>
                          {e.stream === 1 ? (
                            <>
                              <Zap className="size-3.5 text-muted-foreground" aria-hidden />
                              <span className="sr-only">streamed</span>
                            </>
                          ) : (
                            <span className="text-muted-foreground" aria-hidden>
                              ·
                            </span>
                          )}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {e.prompt_tokens ?? "—"}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {e.completion_tokens ?? "—"}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {e.latency_ms != null ? `${e.latency_ms} ms` : "—"}
                        </TableCell>
                        <TableCell>
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
