import { ComponentType, ReactNode, useEffect, useState } from "react"
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
import { ErrorFlash, Layout } from "../components"
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { ActionBadge, AuditEvent, StateBadge } from "./shared"

const activityConfig = {
  events: { label: "Events", color: "var(--primary)" },
} satisfies ChartConfig

function StatCard({
  label,
  value,
  icon: Icon,
}: {
  label: string
  value: ReactNode
  icon: ComponentType<{ className?: string }>
}) {
  return (
    <Card className="gap-2 py-4">
      <div className="flex items-center justify-between gap-2 px-4">
        <span className="truncate text-xs font-medium text-muted-foreground">{label}</span>
        <Icon className="size-4 shrink-0 text-muted-foreground/50" />
      </div>
      <div className="px-4 text-2xl font-semibold tracking-tight tabular-nums">{value}</div>
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
        No dashboard activity in the last 24h.
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

export function Dashboard() {
  const [data, setData] = useState<any>(null)
  const [audit, setAudit] = useState<AuditEvent[] | null>(null)
  const [error, setError] = useState("")

  const load = () => api("/overview").then(setData).catch((e) => setError(e.message))

  useEffect(() => {
    load()
    api("/audit?limit=200")
      .then((r) => setAudit(r.events))
      .catch(() => setAudit([]))
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
        { label: "DB backend", value: String(data.backend), icon: Database },
        { label: "Providers", value: data.counts.providers, icon: ArrowLeftRight },
        { label: "Listings", value: data.counts.listings ?? data.counts.models, icon: Layers },
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
            <Badge
              variant={data.ready ? "success" : "warning"}
              className="h-7 px-2.5"
            >
              <span
                className={
                  "size-1.5 rounded-full " + (data.ready ? "bg-success" : "bg-warning")
                }
              />
              {data.ready ? "catalog ready" : "catalog cold"}
            </Badge>
          )}
          <Button onClick={reload}>
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
            <Skeleton key={i} className="h-[92px] w-full rounded-xl" />
          ))}
        </div>
      ) : null}
      {data && (
        <>
          <div className="grid animate-fade-up gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
            {stats.map((s) => (
              <StatCard key={s.label} label={s.label} value={s.value} icon={s.icon} />
            ))}
          </div>

          <Card className="animate-fade-up" style={{ animationDelay: "80ms" }}>
            <CardHeader>
              <CardTitle>Dashboard activity · last 24h</CardTitle>
              <CardDescription>Audit events per hour</CardDescription>
            </CardHeader>
            <CardContent>
              <ActivityChart events={audit} />
            </CardContent>
          </Card>

          <div
            className="grid animate-fade-up gap-4 lg:grid-cols-2"
            style={{ animationDelay: "160ms" }}
          >
            <Card>
              <CardHeader>
                <CardTitle>Providers</CardTitle>
                <CardDescription>Health as of last reload</CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Provider</TableHead>
                      <TableHead>Protocol</TableHead>
                      <TableHead>Keys</TableHead>
                      <TableHead>State</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.providers.map((p: any) => (
                      <TableRow key={p.id}>
                        <TableCell className="font-medium">{p.name}</TableCell>
                        <TableCell className="font-mono text-xs text-muted-foreground">
                          {p.protocol}
                        </TableCell>
                        <TableCell className="tabular-nums">{p.keys}</TableCell>
                        <TableCell>
                          <StateBadge enabled={p.enabled} />
                        </TableCell>
                      </TableRow>
                    ))}
                    {data.providers.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={4} className="h-24 text-center text-muted-foreground">
                          No providers yet.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Recent dashboard actions</CardTitle>
                <CardDescription>Last 5</CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>When</TableHead>
                      <TableHead>Action</TableHead>
                      <TableHead>Target</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.recent_audit.map((a: AuditEvent, i: number) => (
                      <TableRow key={i}>
                        <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
                          {(a.ts ?? "").slice(11, 19)}
                        </TableCell>
                        <TableCell>
                          <ActionBadge action={a.action} />
                        </TableCell>
                        <TableCell className="font-mono text-xs text-muted-foreground">
                          {a.target ?? "—"}
                        </TableCell>
                      </TableRow>
                    ))}
                    {data.recent_audit.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={3} className="h-24 text-center text-muted-foreground">
                          No dashboard actions yet.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </div>
        </>
      )}
    </Layout>
  )
}
