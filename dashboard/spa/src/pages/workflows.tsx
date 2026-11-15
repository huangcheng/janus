import { FormEvent, useCallback, useEffect, useState } from "react"
import { RefreshCw } from "lucide-react"
import { toast } from "sonner"
import { api } from "../api"
import { EmptyState, ErrorFlash, Layout, Loading } from "../components"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { parseBackendInstant } from "../lib/time-format"

type TemporalStatus = {
  enabled: boolean
  host?: string
  namespace?: string
  task_queue?: string
  error?: string
}

type TemporalWorkflowSummary = {
  workflow_id?: string | null
  run_id?: string | null
  workflow_type?: string | null
  task_queue?: string | null
  status?: string | null
  start_time?: string | null
  close_time?: string | null
  history_length?: number | null
}

type TemporalWorkflowEvent = {
  event_id?: number | null
  event_type?: string | null
  event_time?: string | null
}

type TemporalWorkflowDetail = {
  enabled: boolean
  workflow: TemporalWorkflowSummary
  query_status?: string | null
  events: TemporalWorkflowEvent[]
  failure?: string | null
  error?: string | null
}

function statusLabel(status: string | null | undefined): string {
  if (!status) return "Unknown"
  return status.replace(/^WORKFLOW_EXECUTION_STATUS_/, "").replace(/_/g, " ")
}

function statusVariant(
  status: string | null | undefined,
): "default" | "secondary" | "destructive" | "outline" {
  if (!status) return "outline"
  const u = status.toUpperCase()
  if (u.includes("FAILED") || u.includes("TERMINATED") || u.includes("TIMED")) {
    return "destructive"
  }
  if (u.includes("RUNNING")) return "default"
  if (u.includes("COMPLETED")) return "secondary"
  return "outline"
}

function fmtTs(iso: string | null | undefined): string {
  if (!iso) return "—"
  const d = parseBackendInstant(iso)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleString()
}

export function Workflows() {
  const [status, setStatus] = useState<TemporalStatus | null>(null)
  const [items, setItems] = useState<TemporalWorkflowSummary[]>([])
  const [query, setQuery] = useState("")
  const [appliedQuery, setAppliedQuery] = useState("")
  const [error, setError] = useState("")
  const [listError, setListError] = useState<string | null>(null)
  const [selected, setSelected] = useState<TemporalWorkflowDetail | null>(null)
  const [detailBusy, setDetailBusy] = useState(false)
  const [drawerOpen, setDrawerOpen] = useState(false)

  const load = useCallback(async () => {
    try {
      const qs = new URLSearchParams({ page_size: "50" })
      if (appliedQuery) qs.set("query", appliedQuery)
      const [st, list] = await Promise.all([
        api("/temporal/status") as Promise<TemporalStatus>,
        api(`/temporal/workflows?${qs}`) as Promise<{
          items?: TemporalWorkflowSummary[]
          error?: string
        }>,
      ])
      setStatus(st)
      setItems(list.items ?? [])
      setListError(list.error ?? null)
      setError("")
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load Temporal")
    }
  }, [appliedQuery])

  useEffect(() => {
    void load()
    const id = window.setInterval(() => void load(), 15000)
    return () => window.clearInterval(id)
  }, [load])

  async function openDetail(row: TemporalWorkflowSummary) {
    if (!row.workflow_id) return
    setDetailBusy(true)
    setDrawerOpen(true)
    setSelected(null)
    try {
      const qs = new URLSearchParams()
      if (row.run_id) qs.set("run_id", row.run_id)
      const path = `/temporal/workflows/${encodeURIComponent(row.workflow_id)}${
        qs.toString() ? `?${qs}` : ""
      }`
      const d = (await api(path)) as TemporalWorkflowDetail
      setSelected(d)
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Failed to load workflow")
      setDrawerOpen(false)
    } finally {
      setDetailBusy(false)
    }
  }

  function onSearch(e: FormEvent) {
    e.preventDefault()
    setAppliedQuery(query.trim())
  }

  const enabled = Boolean(status?.enabled) && !status?.error
  const running = items.filter((i) => (i.status || "").toUpperCase().includes("RUNNING")).length
  const failed = items.filter((i) => {
    const u = (i.status || "").toUpperCase()
    return u.includes("FAILED") || u.includes("TIMED") || u.includes("TERMINATED")
  }).length

  return (
    <Layout
      title="Workflows"
      description="Temporal control-plane runs for model sync and GeoLite2 refresh."
    >
      {error && <ErrorFlash message={error} />}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="pb-2">
            <CardDescription>Control plane</CardDescription>
            <CardTitle className="text-base">
              {status == null
                ? "Checking…"
                : enabled
                  ? "Connected"
                  : status.error
                    ? "Unreachable"
                    : "Not configured"}
            </CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardDescription>Namespace</CardDescription>
            <CardTitle className="font-mono text-base">{status?.namespace ?? "—"}</CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardDescription>Task queue</CardDescription>
            <CardTitle className="font-mono text-base">{status?.task_queue ?? "—"}</CardTitle>
          </CardHeader>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardDescription>Host</CardDescription>
            <CardTitle className="truncate font-mono text-base" title={status?.host}>
              {status?.host ?? "—"}
            </CardTitle>
          </CardHeader>
        </Card>
      </div>

      {!enabled && status ? (
        <EmptyState
          title="Control plane offline"
          description={
            status.error
              ? status.error
              : "Set TEMPORAL_HOST on the dashboard and start the temporal compose profile to list workflows here."
          }
        />
      ) : null}

      {enabled ? (
        <>
          <div className="flex flex-wrap items-end gap-3">
            <form onSubmit={onSearch} className="flex min-w-[16rem] flex-1 flex-wrap gap-2">
              <Input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder='Visibility query (default: TaskQueue = "janus-control")'
                aria-label="Visibility query"
                className="min-w-[14rem] flex-1"
              />
              <Button type="submit" variant="outline">
                Apply
              </Button>
            </form>
            <Button type="button" variant="outline" onClick={() => void load()}>
              <RefreshCw className="size-4" />
              Refresh
            </Button>
          </div>

          <div className="flex flex-wrap gap-6 text-sm">
            <div>
              <span className="text-muted-foreground">Listed </span>
              <span className="font-mono font-medium">{items.length}</span>
            </div>
            <div>
              <span className="text-muted-foreground">Running </span>
              <span className="font-mono font-medium">{running}</span>
            </div>
            <div>
              <span className="text-muted-foreground">Failed </span>
              <span className="font-mono font-medium">{failed}</span>
            </div>
          </div>

          {listError ? <ErrorFlash message={listError} /> : null}

          <Card>
            <CardHeader className="border-b">
              <CardTitle>Durable control-plane runs</CardTitle>
              <CardDescription>Model sync and GeoLite2 MMDB refresh on the Janus task queue.</CardDescription>
            </CardHeader>
            <CardContent className="px-0">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Workflow</TableHead>
                    <TableHead>Type</TableHead>
                    <TableHead>Status</TableHead>
                    <TableHead>Started</TableHead>
                    <TableHead>Closed</TableHead>
                    <TableHead className="w-[1%]" />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {items.length === 0 ? (
                    <TableRow>
                      <TableCell colSpan={6} className="text-muted-foreground">
                        No workflow runs yet. Click Sync models (or wait for the
                        model-sync / geoip-mmdb schedule) — runs appear here.
                      </TableCell>
                    </TableRow>
                  ) : (
                    items.map((row) => (
                      <TableRow key={`${row.workflow_id}:${row.run_id}`}>
                        <TableCell className="max-w-[14rem] truncate font-mono text-xs" title={row.workflow_id ?? undefined}>
                          {row.workflow_id}
                        </TableCell>
                        <TableCell className="font-mono text-xs">{row.workflow_type ?? "—"}</TableCell>
                        <TableCell>
                          <Badge variant={statusVariant(row.status)}>{statusLabel(row.status)}</Badge>
                        </TableCell>
                        <TableCell className="text-xs">{fmtTs(row.start_time)}</TableCell>
                        <TableCell className="text-xs">{fmtTs(row.close_time)}</TableCell>
                        <TableCell>
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            onClick={() => void openDetail(row)}
                          >
                            Inspect
                          </Button>
                        </TableCell>
                      </TableRow>
                    ))
                  )}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </>
      ) : null}

      <Sheet
        open={drawerOpen}
        onOpenChange={(open) => {
          setDrawerOpen(open)
          if (!open) setSelected(null)
        }}
      >
        <SheetContent className="flex w-[520px] max-w-[92vw] flex-col gap-0 overflow-y-auto sm:max-w-[520px]">
          <SheetHeader className="pr-10">
            <SheetTitle className="font-mono text-sm break-all">
              {detailBusy ? "Loading…" : selected?.workflow.workflow_id ?? "Workflow"}
            </SheetTitle>
            <SheetDescription className="font-mono">
              {selected?.workflow.workflow_type ?? "—"}
            </SheetDescription>
          </SheetHeader>
          <div className="flex flex-1 flex-col gap-4 px-4 pb-6">
            {detailBusy ? <Loading /> : null}
            {selected && !detailBusy ? (
              <>
                <dl className="grid gap-3 text-sm sm:grid-cols-2">
                  <div>
                    <dt className="text-muted-foreground">Status</dt>
                    <dd>
                      <Badge variant={statusVariant(selected.workflow.status)}>
                        {statusLabel(selected.workflow.status)}
                      </Badge>
                    </dd>
                  </div>
                  <div>
                    <dt className="text-muted-foreground">Query status</dt>
                    <dd className="font-mono text-xs">{selected.query_status ?? "—"}</dd>
                  </div>
                  <div className="sm:col-span-2">
                    <dt className="text-muted-foreground">Run ID</dt>
                    <dd className="break-all font-mono text-xs">{selected.workflow.run_id ?? "—"}</dd>
                  </div>
                  <div>
                    <dt className="text-muted-foreground">Started</dt>
                    <dd className="text-xs">{fmtTs(selected.workflow.start_time)}</dd>
                  </div>
                  <div>
                    <dt className="text-muted-foreground">Closed</dt>
                    <dd className="text-xs">{fmtTs(selected.workflow.close_time)}</dd>
                  </div>
                </dl>
                {selected.failure ? <ErrorFlash message={selected.failure} /> : null}
                {selected.error ? <ErrorFlash message={selected.error} /> : null}
                <div>
                  <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
                    History
                  </p>
                  <ol className="space-y-2 text-xs">
                    {selected.events.length === 0 ? (
                      <li className="text-muted-foreground">No events</li>
                    ) : (
                      selected.events.map((ev) => (
                        <li key={String(ev.event_id)} className="flex flex-wrap gap-x-3 gap-y-1">
                          <span className="font-mono text-muted-foreground">{ev.event_id}</span>
                          <span className="font-mono">{ev.event_type}</span>
                          <span className="text-muted-foreground">{fmtTs(ev.event_time)}</span>
                        </li>
                      ))
                    )}
                  </ol>
                </div>
              </>
            ) : null}
          </div>
        </SheetContent>
      </Sheet>
    </Layout>
  )
}
