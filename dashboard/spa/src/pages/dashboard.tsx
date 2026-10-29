import { useEffect, useState } from "react"
import {
  ArrowLeftRight,
  Database,
  Gauge,
  GitBranch,
  KeyRound,
  Layers,
  RefreshCw,
} from "lucide-react"
import { toast } from "sonner"
import { Bar, BarChart, XAxis } from "recharts"
import { api } from "../api"
import { EmptyState, ErrorFlash, Layout } from "../components"
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { StatCard, StatCardSkeleton } from "@/components/stat-card"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Tooltip } from "@/components/ui/tooltip"
import {
  ActionBadge,
  AlertsResponse,
  AuditEvent,
  EventTime,
  StateBadge,
  fmtIsoLocalMonthDayHm,
  protocolLabel,
} from "./shared"
import { Badge } from "@/components/ui/badge"

const activityConfig = {
  events: { label: "Events", color: "var(--color-chart-1)" },
} satisfies ChartConfig

const SEVERITY_VARIANT = {
  critical: "destructive",
  warning: "warning",
  info: "outline",
} as const

function AlertsCardBody({ alerts, error }: { alerts: AlertsResponse | null; error: string }) {
  if (!alerts) {
    return error ? (
      <EmptyState
        compact
        title="Alerts unavailable"
        description={`Could not load /api/alerts — ${error}`}
      />
    ) : (
      <Skeleton className="m-4 h-16" />
    )
  }
  if (alerts.states.length === 0) {
    return (
      <EmptyState
        compact
        title={error ? "Alert state unknown" : "No active alerts"}
        description={
          error
            ? "The last alerts refresh failed, so an all-clear cannot be confirmed."
            : "Firing rules will appear here while they are active."
        }
      />
    )
  }
  return (
    <Table flush className="table-fixed">
      <TableHeader>
        <TableRow>
          <TableHead className="w-24">Severity</TableHead>
          <TableHead className="w-32">Rule</TableHead>
          <TableHead className="w-32">Scope</TableHead>
          <TableHead>Message</TableHead>
          <TableHead className="w-28">Since</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {alerts.states.map((a) => (
          <TableRow key={`${a.rule}|${a.scope}`}>
            <TableCell>
              <Badge variant={SEVERITY_VARIANT[a.severity] ?? "outline"}>
                {a.severity}
              </Badge>
            </TableCell>
            <TableCell className="max-w-28 truncate font-mono text-xs" title={a.rule}>
              {a.rule}
            </TableCell>
            <TableCell className="max-w-28 truncate font-mono text-xs" title={a.scope}>
              {a.scope}
            </TableCell>
            <TableCell className="max-w-[26rem] truncate text-sm" title={a.message}>
              {a.message}
            </TableCell>
            <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
              {a.since ? (
                <span title={a.since}>{fmtIsoLocalMonthDayHm(a.since)}</span>
              ) : (
                "—"
              )}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

function AlertsCard({ alerts, error }: { alerts: AlertsResponse | null; error: string }) {
  return (
    <Card className="animate-fade-up overflow-hidden" style={{ animationDelay: "280ms" }}>
      <CardHeader className="border-b bg-muted/20">
        <CardTitle>Active alerts</CardTitle>
        <CardDescription>Firing alert rules across nodes and providers</CardDescription>
      </CardHeader>
      <CardContent className="px-0">
        <AlertsCardBody alerts={alerts} error={error} />
      </CardContent>
      {alerts && (
        <CardFooter className="border-t text-xs text-muted-foreground">
          {error ? (
            <span className="text-destructive">
              Alerts refresh failed — showing last known state.
            </span>
          ) : (
            <>Webhook: {alerts.webhook_configured ? "configured" : "not configured"}</>
          )}
        </CardFooter>
      )}
    </Card>
  )
}

function ActivityChart({ events }: { events: AuditEvent[] | null }) {
  if (events === null) return <Skeleton className="h-48 w-full" />
  const counts = new Array<number>(24).fill(0)
  const now = Date.now()
  for (const e of events) {
    const t = Date.parse(e.ts)
    if (Number.isNaN(t)) continue
    const hoursAgo = Math.floor((now - t) / 3_600_000)
    if (hoursAgo >= 0 && hoursAgo < 24) counts[23 - hoursAgo]++
  }
  const max = Math.max(...counts)
  if (max === 0) {
    return (
          <div className="flex h-48 items-center justify-center text-sm text-muted-foreground">
            No dashboard activity in the last 24 hours.
          </div>
    )
  }
  const data = counts.map((n, i) => {
    const hour = new Date(now - (23 - i) * 3_600_000).getHours()
    return { hour: `${String(hour).padStart(2, "0")}:00`, events: n }
  })
  return (
    <ChartContainer config={activityConfig} className="aspect-auto h-48 w-full">
      <BarChart data={data} accessibilityLayer margin={{ top: 4, right: 0, bottom: 0, left: 0 }}>
        <XAxis dataKey="hour" tickLine={false} axisLine={false} interval={3} />
        <ChartTooltip content={<ChartTooltipContent />} />
        <Bar dataKey="events" fill="var(--color-events)" radius={[3, 3, 0, 0]} />
      </BarChart>
    </ChartContainer>
  )
}

// L5: the overview payload was consumed as `any`, so a backend shape change
// could not be caught by the compiler. Only the fields this page reads are
// modelled; keep them in sync with GET /api/overview.
type Overview = {
  generation: number
  backend: string
  ready: boolean
  counts: {
    providers: number
    listings?: number
    models?: number
    routes: number
    agent_keys: number
  }
  providers: Array<{
    id: number
    name: string
    protocol: string
    keys: number
    enabled: boolean
  }>
  recent_audit: AuditEvent[]
}

export function Dashboard() {
  const [data, setData] = useState<Overview | null>(null)
  const [audit, setAudit] = useState<AuditEvent[] | null>(null)
  const [alerts, setAlerts] = useState<AlertsResponse | null>(null)
  const [alertsError, setAlertsError] = useState("")
  const [error, setError] = useState("")

  const load = () => api<Overview>("/overview").then(setData).catch((e) => setError(e.message))

  useEffect(() => {
    load()
    api("/audit?limit=200")
      .then((r) => setAudit(r.events))
      .catch(() => setAudit([]))
    const loadAlerts = () =>
      api("/alerts")
        .then((r) => {
          setAlerts(r)
          setAlertsError("")
        })
        // Keep the last good alert list; a failed poll must not fake an all-clear.
        .catch((e) => setAlertsError(e.message))
    loadAlerts()
    const t = setInterval(loadAlerts, 30000)
    return () => clearInterval(t)
  }, [])

  const reload = async () => {
    try {
      const res = await api("/catalog/reload", { method: "POST", body: {} })
      toast.success(`Catalog reloaded — generation ${res.generation}`)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  const stats = data
    ? [
        { label: "Generation", value: data.generation, icon: Gauge },
        {
          label: "DB backend",
          value: String(data.backend).replace(/^\S/, (c: string) => c.toUpperCase()),
          icon: Database,
        },
        { label: "Providers", value: data.counts.providers, icon: ArrowLeftRight },
        { label: "Listings", value: data.counts.listings ?? data.counts.models ?? 0, icon: Layers },
        { label: "Bindings", value: data.counts.routes, icon: GitBranch },
        { label: "Agent keys", value: data.counts.agent_keys, icon: KeyRound },
      ]
    : []

  return (
    <Layout
      title="Dashboard"
      description="Configuration state and upstream health at a glance."
      actions={
        <>
          {data && (
            <Tooltip
              side="bottom"
              content={
                data.ready
                  ? "Gateways have loaded the latest config generation."
                  : "No gateway has loaded a config generation yet — use Reload catalog to push one."
              }
            >
              <span className="inline-flex cursor-default items-center gap-1.5 text-xs text-muted-foreground">
                <span
                  className={
                    "size-1.5 rounded-full " + (data.ready ? "bg-success" : "bg-warning")
                  }
                />
                {data.ready ? "Catalog ready" : "Catalog cold"}
              </span>
            </Tooltip>
          )}
          <Button variant="outline" size="sm" onClick={reload}>
            <RefreshCw />
            Reload catalog
          </Button>
        </>
      }
    >
      {error && <ErrorFlash message={error} />}
      {!data && !error ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
          {Array.from({ length: 6 }).map((_, i) => (
            <StatCardSkeleton key={i} />
          ))}
        </div>
      ) : null}
      {data && (
        <>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
            {stats.map((s, i) => (
              <StatCard
                key={s.label}
                label={s.label}
                value={s.value}
                icon={s.icon}
                className="animate-fade-up"
                style={{ animationDelay: `${i * 40}ms` }}
              />
            ))}
          </div>

          <div className="grid items-stretch gap-5 xl:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
            <Card className="animate-fade-up" style={{ animationDelay: "240ms" }}>
              <CardHeader>
                <CardTitle>Activity</CardTitle>
                <CardDescription>Dashboard mutations per hour, last 24 hours (local time)</CardDescription>
              </CardHeader>
              <CardContent>
                <ActivityChart events={audit} />
              </CardContent>
            </Card>

            <AlertsCard alerts={alerts} error={alertsError} />
          </div>

          {/* Stack below xl: side-by-side at lg left both tables ~350px wide,
              forcing inner horizontal scrollbars. */}
          <div
            className="grid animate-fade-up items-stretch gap-4 xl:grid-cols-2"
            style={{ animationDelay: "320ms" }}
          >
            <Card className="flex h-full min-h-0 w-full flex-col overflow-hidden">
              <CardHeader className="shrink-0 border-b">
                <CardTitle>Providers</CardTitle>
                <CardDescription>Health as of last reload</CardDescription>
              </CardHeader>
              <CardContent className="min-h-0 flex-1 px-0">
                <Table flush>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Provider</TableHead>
                      <TableHead>Protocol</TableHead>
                      <TableHead>Keys</TableHead>
                      <TableHead>State</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.providers.map((p) => (
                      <TableRow key={p.id}>
                        <TableCell className="font-medium">{p.name}</TableCell>
                        <TableCell className="text-xs text-muted-foreground">
                          {protocolLabel(p.protocol)}
                        </TableCell>
                        <TableCell className="tabular-nums">{p.keys}</TableCell>
                        <TableCell>
                          <StateBadge enabled={p.enabled} />
                        </TableCell>
                      </TableRow>
                    ))}
                    {data.providers.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={4} className="p-0">
                          <EmptyState
                            compact
                            title="No providers yet"
                            description="Add an upstream on Providers & keys."
                          />
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>

            <Card className="flex h-full min-h-0 w-full flex-col overflow-hidden">
              <CardHeader className="shrink-0 border-b">
                <CardTitle>Recent actions</CardTitle>
                <CardDescription>Last five dashboard mutations</CardDescription>
              </CardHeader>
              <CardContent className="min-h-0 flex-1 px-0">
                <Table flush>
                  <TableHeader>
                    <TableRow>
                      <TableHead>When</TableHead>
                      <TableHead>Action</TableHead>
                      <TableHead>Target</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.recent_audit.map((a: AuditEvent) => (
                      <TableRow key={`${a.ts}|${a.action}|${a.target ?? ""}`}>
                        <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
                          <EventTime ts={a.ts} />
                        </TableCell>
                        <TableCell>
                          <ActionBadge action={a.action} />
                        </TableCell>
                        <TableCell
                          className="max-w-64 truncate font-mono text-xs text-muted-foreground"
                          title={a.target ?? ""}
                        >
                          {a.target ?? "—"}
                        </TableCell>
                      </TableRow>
                    ))}
                    {data.recent_audit.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={3} className="p-0">
                          <EmptyState
                            compact
                            title="No actions yet"
                            description="Mutations you make will appear here."
                          />
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </div>
          {/* Scroll-end spacer: guarantees visible gutter below the last row. */}
          <div className="h-2 shrink-0" aria-hidden />
        </>
      )}
    </Layout>
  )
}
