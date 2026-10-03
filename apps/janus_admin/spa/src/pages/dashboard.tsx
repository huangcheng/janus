import { ReactNode, useEffect, useState } from "react"
import { RefreshCw } from "lucide-react"
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

function StatCard({ label, value }: { label: string; value: ReactNode }) {
  return (
    <Card>
      <CardHeader>
        <CardDescription>{label}</CardDescription>
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-semibold tabular-nums">{value}</div>
      </CardContent>
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
        No admin activity in the last 24h.
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
        <Bar dataKey="events" fill="var(--color-events)" radius={2} />
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
        { label: "Serving generation", value: data.generation },
        { label: "DB backend", value: String(data.backend) },
        { label: "Providers", value: data.counts.providers },
        { label: "Models", value: data.counts.models },
        { label: "Routes", value: data.counts.routes },
        { label: "Agent keys", value: data.counts.agent_keys },
      ]
    : []

  return (
    <Layout
      title="Dashboard"
      description="Configuration state and upstream health at a glance."
      actions={
        <Button onClick={reload}>
          <RefreshCw />
          Reload catalog
        </Button>
      }
    >
      {error && <ErrorFlash message={error} />}
      {!data && !error ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {Array.from({ length: 7 }).map((_, i) => (
            <Skeleton key={i} className="h-28 w-full" />
          ))}
        </div>
      ) : null}
      {data && (
        <>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Card>
              <CardHeader>
                <CardDescription>Catalog state</CardDescription>
              </CardHeader>
              <CardContent>
                <Badge variant={data.ready ? "default" : "secondary"}>
                  {data.ready ? "ready" : "cold"}
                </Badge>
              </CardContent>
            </Card>
            {stats.map((s) => (
              <StatCard key={s.label} label={s.label} value={s.value} />
            ))}
          </div>

          <Card>
            <CardHeader>
              <CardTitle>Admin activity · last 24h</CardTitle>
              <CardDescription>audit events per hour</CardDescription>
            </CardHeader>
            <CardContent>
              <ActivityChart events={audit} />
            </CardContent>
          </Card>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>Providers</CardTitle>
                <CardDescription>health as of last reload</CardDescription>
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
                <CardTitle>Recent admin actions</CardTitle>
                <CardDescription>last 5</CardDescription>
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
                        <TableCell className="font-mono text-xs text-muted-foreground">
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
                          No admin actions yet.
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
