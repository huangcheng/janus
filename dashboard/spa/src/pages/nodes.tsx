import { Fragment, useEffect, useMemo, useState } from "react"
import { ChevronDown, ChevronRight, Plus, Power, RefreshCw, Trash2 } from "lucide-react"
import { toast } from "sonner"
import { api, apiFetch } from "../api"
import { ExpandableText } from "../components/expandable-text"
import { formatRegionLabel } from "../lib/region-label"
import { EmptyState, ErrorFlash, IconAction, Layout, Loading } from "../components"
import { FleetRuntime } from "./fleet-runtime"
import { Provider, shortNode } from "./shared"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
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
import { Dialog, DialogContent, DialogFooter } from "@/components/ui/dialog"
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Tooltip } from "@/components/ui/tooltip"

const STALE_MS = 60_000

type Health = {
  status: string
  checked_at: number
  generation?: number
  ready?: boolean
  backend?: string
  uptime_sec?: number
  started_at?: number
  routes_cooling?: number
  requests_total?: number
  requests_failed?: number
  models_serving?: number
} | null

type FailureCool = {
  target?: { kind?: string; id?: string; provider_id?: string; model_id?: string | null }
  reason?: string
  until_ms?: number
  last_error_code?: string
}

type FailureTask = {
  name?: string
  instrumented?: boolean
  last_outcome?: string | null
  last_error?: string | null
  last_finished_at?: string | null
}

type FailureView = {
  boot_id?: string
  snapshot_ts?: string
  snapshot_age_sec?: number | null
  pulled_at?: string | null
  ops_lagging?: boolean
  unsupported_schema?: boolean
  cool?: FailureCool[]
  cool_count?: number
  cool_ids_overflow?: boolean
  rates?: { entity?: { kind?: string; id?: string }; degraded?: boolean; failure_ratio?: number | null; window?: string }[]
  degraded_ids?: unknown[]
  tasks?: FailureTask[]
  ops_ring?: { overflow_count?: number; next_idx?: number; oldest_idx?: number }
} | null

type Node = {
  id: number
  name: string
  data_host: string
  data_port: number
  stats_host: string
  stats_port: number
  enabled: boolean
  created_at: string
  stats_token_set?: boolean
  health: Health
  success_rate: number | null
  sched_error: string | null
  sched_scraped_at: number | null
  /** Master-only live failure snapshot from /stats/health (persisted). */
  failure?: FailureView
  /** Operator-set short build sha (≤12). Surfaces fleet version skew. */
  build_sha?: string | null
}

type Worker = {
  node: string
  via: string
  status?: string | null
  region?: string | null
  capacity?: number | null
  inflight?: number | null
  draining?: boolean
  sticky?: boolean
  dispatchable?: boolean
  sched_v?: number | null
  dispatched_total?: number | null
  health_ewma_ms?: number | null
  rtt_ms_avg?: number | null
  rtt_sample_count?: number | null
  would_demote?: boolean | null
  geo_region?: string | null
  geo_source?: string | null
  egress_fetched_at?: number | null
  /** Operator remark from worker_notes (dashboard-owned); "" when unset. */
  note?: string
  /** Dashboard-side TCP reach probe of the worker's dist port; null
   * before the first probe cycle, ok=null when the host can't be
   * resolved from the node name. */
  reach?: { ok: boolean | null; checked_at: number; error: string | null } | null
}

type Fleet = {
  available?: number
  members?: number
  sticky?: number
  dispatch_local_total?: {
    empty_pool?: number
    capacity?: number
    drained?: number
    drained_pin?: number
    send_fail?: number
    ack_miss?: number
  }
} | null

type NodesPayload = {
  nodes: Node[]
  workers: Worker[]
  fleet: Fleet
  /** False = the gateway's advisory fleet ring is off (JANUS_FLEET_ENABLED);
   * null = unknown (no successful sched cache yet). */
  fleet_effective?: boolean | null
  scraped_at: number | null
}

function dash<T>(v: T | null | undefined): string {
  return v === null || v === undefined ? "—" : String(v)
}

function isStale(ms: number | null | undefined): boolean {
  if (ms === null || ms === undefined) return false
  return Date.now() - ms > STALE_MS
}

function formatRate(rate: number | null | undefined): string {
  if (rate === null || rate === undefined || Number.isNaN(rate)) return "—"
  return `${(rate * 100).toFixed(1)}%`
}

function formatNum(v: number | null | undefined, digits = 1): string {
  if (v === null || v === undefined || Number.isNaN(v)) return "—"
  return typeof v === "number" && !Number.isInteger(v) ? v.toFixed(digits) : String(v)
}

export function Nodes() {
  const [payload, setPayload] = useState<NodesPayload | null>(null)
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [showAdd, setShowAdd] = useState(false)
  const [pendingDelete, setPendingDelete] = useState<Node | null>(null)
  const [nodeDetails, setNodeDetails] = useState<number | null>(null)

  const load = () =>
    // Providers carry the pins; a failed read must not blank the worker
    // view, so it degrades to "no pins known" instead of an error.
    Promise.all([api("/nodes"), api("/providers").catch(() => null)]).then(
      ([r, p]: [NodesPayload, { providers: Provider[] } | null]) => {
        setPayload({
          nodes: (r.nodes ?? []).map((n) => ({ ...n, failure: n.failure ?? null })),
          workers: r.workers ?? [],
          fleet: r.fleet ?? null,
          fleet_effective: r.fleet_effective ?? null,
          scraped_at: r.scraped_at ?? null,
        })
        if (p) setProviders(p.providers ?? [])
        setError("")
        setLoaded(true)
      },
    ).catch((e) => setError(e.message))

  useEffect(() => {
    load()
    const t = setInterval(load, 10000)
    return () => clearInterval(t)
  }, [])

  const act = async (fn: () => Promise<any>, ok: string) => {
    try {
      await fn()
      toast.success(ok)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  const [geoBusy, setGeoBusy] = useState<string | null>(null)
  const [noteEdit, setNoteEdit] = useState<string | null>(null)
  const [noteDraft, setNoteDraft] = useState("")
  const saveNote = async (w: Worker) => {
    const note = noteDraft.trim()
    setNoteEdit(null)
    if (note === (w.note ?? "")) return
    try {
      await apiFetch("/api/nodes/workers/note", {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ node: w.node, note }),
      })
      toast.success(note ? "Note saved" : "Note cleared")
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }
  const refreshGeo = async (w: Worker) => {
    const gw = nodes.find((n) => n.name === w.via)
    if (!gw) {
      toast.error("gateway not found for this worker")
      return
    }
    setGeoBusy(w.node)
    try {
      await apiFetch(`/nodes/${gw.id}/workers/geo-refresh`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ worker: w.node }),
      })
      toast.success("Region refresh requested — updates in a few seconds")
      // The worker re-runs discovery and re-hellos when it lands; give it
      // a beat, then pull the fresh sched view.
      setTimeout(load, 4000)
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setGeoBusy(null)
    }
  }
  const nodes = payload?.nodes ?? []
  // Fleet-wide build-sha skew (#8): if two or more distinct shas are
  // present, mark every row whose sha is in the multi-set so the
  // operator sees which row is on which version.
  const buildShaSet = useMemo(
    () => new Set(nodes.map((n) => n.build_sha).filter((s): s is string => !!s)),
    [nodes],
  )
  // An initial load failure must not render empty tables ("No nodes registered"):
  // that reads as a healthy-but-empty fleet instead of an unreadable API.
  const unavailable = !loaded && !!error
  const workers = useMemo(() => {
    const list = payload?.workers ?? []
    return [...list].sort((a, b) => {
      const viaCmp = (a.via || "").localeCompare(b.via || "")
      if (viaCmp !== 0) return viaCmp
      return (a.node || "").localeCompare(b.node || "")
    })
  }, [payload?.workers])
  const fleet = payload?.fleet ?? null
  const fleetDisabled = payload?.fleet_effective === false
  const scrapedAt = payload?.scraped_at ?? null
  const workersStale = isStale(scrapedAt)
  const anySchedError = nodes.some((n) => n.sched_error)
  const hadSuccessfulSched = scrapedAt !== null && scrapedAt !== undefined

  // --- provider→node pins (spec 2026-10-22 §6) ---
  // Pins are read from the providers list, not from gateway_nodes: the
  // gateway row's `name` is never a worker name and must never be shown as
  // a pin target. Grouping pinned providers by node makes a concentration
  // (many providers → one node) visible, which matters because pinned
  // picks bypass the capacity soft cap and outrank the health tier.
  const pinByNode = useMemo(() => {
    const byNode = new Map<string, Provider[]>()
    for (const p of providers) {
      const pin = p.affinity_node
      if (!pin) continue
      const list = byNode.get(pin)
      if (list) list.push(p)
      else byNode.set(pin, [p])
    }
    return byNode
  }, [providers])
  // A pin naming a node outside the live pool is not honoured: the gateway
  // fails open to any healthy node. Only claimable after a real scrape.
  const unmatchedPins = useMemo(() => {
    if (!hadSuccessfulSched) return []
    const live = new Set(workers.map((w) => w.node))
    return providers.filter((p) => p.affinity_node && !live.has(p.affinity_node))
  }, [providers, workers, hadSuccessfulSched])

  return (
    <Layout
      title="Gateway nodes"
      description="Register and monitor Janus gateway instances sharing this Postgres. Workers are observed via master /stats/sched — not registered as gateways."
    >
      {error && <ErrorFlash message={error} />}

      <FleetRuntime workers={workers} />

      <Card className="flex h-fit max-h-full w-full flex-col self-start overflow-hidden animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle>Gateways</CardTitle>
          <CardDescription>Health + /stats/sched polled every 10s</CardDescription>
          <CardAction>
            <Button size="sm" onClick={() => setShowAdd(true)}>
              <Plus />
              Add node
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="min-h-0 px-0">
          {!loaded && !error ? (
            <Loading />
          ) : unavailable ? (
            <EmptyState
              title="Gateways unavailable"
              description="Could not read /api/nodes. The poll retries every 10s — this table is not evidence of an empty fleet."
            />
          ) : loaded && nodes.length === 0 ? (
            <EmptyState
              title="No nodes registered"
              description="Register a gateway instance that shares this Postgres catalog."
              action={
                <Button size="sm" onClick={() => setShowAdd(true)}>
                  <Plus />
                  Add node
                </Button>
              }
            />
          ) : (
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Data endpoint</TableHead>
                  <TableHead>Health</TableHead>
                  <TableHead>Success rate</TableHead>
                  <TableHead>Generation</TableHead>
                  <TableHead>Requests</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {nodes.map((n) => (
                  <Fragment key={n.id}>
                    <TableRow>
                      <TableCell className="font-medium">
                        {n.name}
                        {n.stats_token_set && (
                          <Tooltip
                            side="top"
                            content="This node authenticates to its stats endpoint with its own write-only token, not the shared one."
                          >
                            <span
                              tabIndex={0}
                              className="ml-2 cursor-default rounded bg-muted px-1.5 py-0.5 text-[10px] text-muted-foreground"
                            >
                              own token
                            </span>
                          </Tooltip>
                        )}
                      </TableCell>
                      <TableCell className="font-mono text-xs text-muted-foreground">
                        {n.data_host}:{n.data_port}
                      </TableCell>
                      <TableCell>
                        <span className="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
                          <span
                            className={
                              "size-1.5 rounded-full " +
                              (n.health?.status === "healthy"
                                ? "bg-success"
                                : n.health?.status === "unreachable"
                                  ? "bg-destructive"
                                  : "bg-muted-foreground/40")
                            }
                          />
                          {n.health?.status ?? "unknown"}
                        </span>
                      </TableCell>
                      <TableCell className="tabular-nums">{formatRate(n.success_rate)}</TableCell>
                      <TableCell className="tabular-nums">{n.health?.generation ?? "—"}</TableCell>
                      <TableCell className="tabular-nums whitespace-nowrap">
                        {n.health?.requests_total !== null && n.health?.requests_total !== undefined ? (
                          <>
                            {n.health.requests_total}
                            {n.health.requests_failed ? (
                              <span className="text-destructive">
                                {" "}
                                ({n.health.requests_failed} failed)
                              </span>
                            ) : null}
                          </>
                        ) : (
                          "—"
                        )}
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end gap-1">
                          <IconAction
                            label={nodeDetails === n.id ? "Hide node details" : "Show node details"}
                            expanded={nodeDetails === n.id}
                            controls={`node-${n.id}-details`}
                            onClick={() => setNodeDetails(nodeDetails === n.id ? null : n.id)}
                          >
                            {nodeDetails === n.id ? <ChevronDown /> : <ChevronRight />}
                          </IconAction>
                          <IconAction
                            label={n.enabled ? "Disable" : "Enable"}
                            onClick={() =>
                              act(
                                () =>
                                  api(`/nodes/${n.id}`, {
                                    method: "PATCH",
                                    body: { enabled: !n.enabled },
                                  }),
                                n.enabled ? "node disabled" : "node enabled",
                              )
                            }
                          >
                            <Power />
                          </IconAction>
                          <IconAction
                            label="Remove node"
                            destructive
                            onClick={() => setPendingDelete(n)}
                          >
                            <Trash2 />
                          </IconAction>
                        </div>
                      </TableCell>
                    </TableRow>
                    {nodeDetails === n.id && (
                      <TableRow id={`node-${n.id}-details`} className="bg-muted/20 hover:bg-muted/20">
                        <TableCell colSpan={7} className="whitespace-normal">
                          <dl className="grid gap-3 px-1 py-1 sm:grid-cols-2 lg:grid-cols-5">
                            <div>
                              <dt className="text-xs text-muted-foreground">Build</dt>
                              <dd className="mt-1 font-mono text-xs">
                                {n.build_sha ? (
                                  <Tooltip
                                    side="top"
                                    content={
                                      buildShaSet.size > 1 && buildShaSet.has(n.build_sha)
                                        ? "Fleet has mixed versions — this row's sha matches the majority."
                                        : "Operator-set short sha for this gateway image."
                                    }
                                  >
                                    <span className={buildShaSet.size > 1 && buildShaSet.has(n.build_sha) ? "text-warning" : "text-muted-foreground"}>
                                      {n.build_sha}
                                    </span>
                                  </Tooltip>
                                ) : (
                                  "—"
                                )}
                              </dd>
                            </div>
                            <div>
                              <dt className="text-xs text-muted-foreground">Sched</dt>
                              <dd className="mt-1">
                                <SchedBadges error={n.sched_error} scrapedAt={n.sched_scraped_at} />
                              </dd>
                            </div>
                            <div>
                              <dt className="text-xs text-muted-foreground">Models</dt>
                              <dd className="mt-1 text-sm tabular-nums">{n.health?.models_serving ?? "—"}</dd>
                            </div>
                            <div>
                              <dt className="text-xs text-muted-foreground">Uptime</dt>
                              <dd className="mt-1 text-sm">
                                {n.health?.uptime_sec != null ? formatUptime(n.health.uptime_sec) : "—"}
                              </dd>
                            </div>
                            <div>
                              <dt className="text-xs text-muted-foreground">Started</dt>
                              <dd className="mt-1 text-sm">
                                {n.health?.started_at ? formatStarted(n.health.started_at) : "—"}
                              </dd>
                            </div>
                          </dl>
                        </TableCell>
                      </TableRow>
                    )}
                  </Fragment>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Card className="mt-4 flex h-fit max-h-full w-full flex-col self-start overflow-hidden animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle>Master failure health</CardTitle>
          <CardDescription>
            Live cool / rate-degraded / task status from each master&apos;s{" "}
            <span className="font-mono text-[11px]">/stats/health</span> snapshot
            (workers are not scraped). Usage stays request accounting only.
          </CardDescription>
        </CardHeader>
        <CardContent className="min-h-0 px-0">
          {!loaded && !error ? (
            <Loading />
          ) : unavailable ? (
            <EmptyState
              title="Failure health unavailable"
              description="Could not read /api/nodes, so no gateway health snapshot can be shown."
            />
          ) : (
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead>Gateway</TableHead>
                  <TableHead>Flags</TableHead>
                  <TableHead>Cooling</TableHead>
                  <TableHead>Degraded</TableHead>
                  <TableHead>Tasks</TableHead>
                  <TableHead>Snapshot age</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {nodes.filter((n) => n.enabled).map((n) => (
                  <FailureRow key={`fail-${n.id}`} node={n} />
                ))}
                {nodes.filter((n) => n.enabled).length === 0 && (
                  <TableRow>
                    <TableCell colSpan={6} className="text-center text-muted-foreground">
                      No enabled gateways
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Card className="mt-4 flex h-fit max-h-full w-full flex-col self-start overflow-hidden">
        <CardHeader className="border-b">
          <CardTitle>Workers</CardTitle>
          <CardDescription>
            Capacity plane via master /stats/sched. One row per (via, node).
          </CardDescription>
          <CardAction className="flex flex-wrap items-center gap-2">
            {workersStale && (
              <Badge variant="warning">stale</Badge>
            )}
            {anySchedError && (
              <Badge variant="destructive">scrape error</Badge>
            )}
          </CardAction>
        </CardHeader>
        <CardContent className="min-h-0 space-y-4 px-0 pb-4">
          {!unavailable && <FleetStrip fleet={fleet} stale={workersStale} disabled={fleetDisabled} />}
          {unmatchedPins.length > 0 && (
            <div className="mx-5 flex flex-wrap items-start gap-x-2 gap-y-1 rounded border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs">
              <span className="font-medium text-destructive">
                {unmatchedPins.length} pin{unmatchedPins.length === 1 ? "" : "s"} not honoured —
              </span>
              <span className="text-muted-foreground">
                no live worker matches, so the gateway fails open to any healthy node:
              </span>
              <span className="font-mono">
                {unmatchedPins
                  .map((p) => `${p.name} → ${shortNode(p.affinity_node ?? "")}`)
                  .join(" · ")}
              </span>
              <span className="w-full text-muted-foreground">
                Nothing is auto-corrected; fix the pin on the Providers page.
              </span>
            </div>
          )}
          {!loaded && !error ? (
            <Loading />
          ) : unavailable ? (
            <EmptyState
              title="Worker capacity unavailable"
              description="Could not read /api/nodes, so the sched-derived worker pool is unknown."
            />
          ) : !hadSuccessfulSched ? (
            <EmptyState
              title={anySchedError ? "Sched scrape failed" : "No sched data yet"}
              description={
                anySchedError
                  ? "No successful /stats/sched cache on any gateway. Check sched badges on Gateways."
                  : "Waiting for the first successful /stats/sched scrape from an enabled gateway."
              }
            />
          ) : workers.length === 0 ? (
            <EmptyState
              title="Empty pool"
              description="Successful sched scrape with zero workers (members ∪ sticky)."
            />
          ) : (
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead>Node</TableHead>
                  <TableHead>Note</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Region</TableHead>
                  <TableHead>Pinned</TableHead>
                  <TableHead>In-flight / Capacity</TableHead>
                  <TableHead>Dispatched (attempts)</TableHead>
                  <TableHead>EWMA</TableHead>
                  <TableHead>RTT</TableHead>
                  <TableHead>Would demote</TableHead>
                  <TableHead>Via</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {workers.map((w) => (
                  <TableRow key={`${w.via}\0${w.node}`}>
                    <TableCell className="font-mono text-xs font-medium">{w.node}</TableCell>
                    <TableCell className="text-xs">
                      {noteEdit === w.node ? (
                        <input
                          autoFocus
                          value={noteDraft}
                          aria-label={`Edit note for ${w.node}`}
                          onChange={(e) => setNoteDraft(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === "Enter") saveNote(w)
                            if (e.key === "Escape") setNoteEdit(null)
                          }}
                          onBlur={() => saveNote(w)}
                          placeholder="e.g. Aliyun Wuhan"
                          className="w-36 rounded border bg-background px-1.5 py-0.5 text-xs outline-none focus-visible:ring-2 focus-visible:ring-ring/50"
                        />
                      ) : (
                        <button
                          type="button"
                          title="Edit note"
                          aria-label={`Edit note for ${w.node}`}
                          onClick={() => { setNoteEdit(w.node); setNoteDraft(w.note ?? "") }}
                          className="inline-flex min-h-8 min-w-8 items-center justify-center rounded-md px-1.5 text-muted-foreground/90 hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
                        >
                          {w.note ? w.note : <span className="opacity-40">＋</span>}
                        </button>
                      )}
                    </TableCell>
                    <TableCell>
                      <WorkerStatus status={w.status} sticky={w.sticky} draining={w.draining} reach={w.reach} />
                    </TableCell>
                    <TableCell
                      className="text-xs text-muted-foreground"
                      title={
                        w.region
                          ? w.geo_region
                            ? `${w.region} (tag) · ${w.geo_region} discovered via ${w.geo_source ?? "?"}`
                            : String(w.region)
                          : w.geo_region
                            ? `${w.geo_region} discovered via ${w.geo_source ?? "?"}`
                            : undefined
                      }
                    >
                      {formatRegionLabel(w.region ?? w.geo_region) ?? "—"}
                    </TableCell>
                    <TableCell className="text-xs">
                      <PinnedProvidersCell pinned={pinByNode.get(w.node) ?? []} />
                    </TableCell>
                    <TableCell className="tabular-nums text-xs">
                      {dash(w.inflight)} / {dash(w.capacity)}
                    </TableCell>
                    <TableCell className="tabular-nums">{dash(w.dispatched_total)}</TableCell>
                    <TableCell className="tabular-nums text-xs">
                      {w.health_ewma_ms === null || w.health_ewma_ms === undefined ? "—" : `${formatNum(w.health_ewma_ms)} ms`}
                    </TableCell>
                    <TableCell className="tabular-nums text-xs">
                      {w.rtt_ms_avg === null || w.rtt_ms_avg === undefined
                        ? "—"
                        : `${formatNum(w.rtt_ms_avg)} ms${
                            w.rtt_sample_count !== null && w.rtt_sample_count !== undefined ? ` (n=${w.rtt_sample_count})` : ""
                          }`}
                    </TableCell>
                    <TableCell className="text-xs">
                      {w.would_demote === null || w.would_demote === undefined
                        ? "—"
                        : w.would_demote
                          ? "yes"
                          : "no"}
                    </TableCell>
                    <TableCell className="text-xs text-muted-foreground">{w.via}</TableCell>
                    <TableCell className="text-right">
                      <IconAction
                        label="Refresh region"
                        disabled={geoBusy === w.node}
                        onClick={() => refreshGeo(w)}
                      >
                        <RefreshCw className={geoBusy === w.node ? "animate-spin" : undefined} />
                      </IconAction>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {pendingDelete && (
        <AlertDialog open onOpenChange={(o) => !o && setPendingDelete(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Remove <span className="font-mono">{pendingDelete.name}</span>?
              </AlertDialogTitle>
              <AlertDialogDescription>
                This permanently deletes the gateway registration, including its stored stats
                token and health/sched history. The gateway keeps running but disappears from
                this console until it is registered again (with a new id).
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                onClick={() => {
                  const n = pendingDelete
                  setPendingDelete(null)
                  void act(() => api(`/nodes/${n.id}`, { method: "DELETE" }), "node removed")
                }}
              >
                Remove node
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}

      {showAdd && <AddNodeModal onClose={() => setShowAdd(false)} onDone={load} />}
    </Layout>
  )
}

const SNAPSHOT_STALE_SEC = 30

function FailureRow({ node }: { node: Node }) {
  const f = node.failure
  if (!f) {
    return (
      <TableRow>
        <TableCell className="font-medium">{node.name}</TableCell>
        <TableCell colSpan={5} className="text-xs text-muted-foreground">
          No failure snapshot yet (waiting for ops puller)
        </TableCell>
      </TableRow>
    )
  }
  const stale =
    typeof f.snapshot_age_sec === "number" && f.snapshot_age_sec > SNAPSHOT_STALE_SEC
  const coolN = f.cool_count ?? f.cool?.length ?? 0
  const degradedN =
    f.degraded_ids?.length ??
    f.rates?.filter((r) => r.degraded && r.window === "5m").length ??
    0
  const tasks = f.tasks ?? []
  const taskSummary =
    tasks.length === 0
      ? "—"
      : tasks
          .map((t) => {
            if (t.instrumented === false) return `${t.name}:uninstrumented`
            return `${t.name}:${t.last_outcome ?? "—"}`
          })
          .join(", ")
  return (
    <TableRow>
      <TableCell className="font-medium">{node.name}</TableCell>
      <TableCell>
        <span className="inline-flex flex-wrap gap-1">
          {f.ops_lagging ? (
            <Badge variant="warning" className="text-[10px]">
              ops lagging
            </Badge>
          ) : null}
          {stale ? (
            <Badge variant="warning" className="text-[10px]">
              stale
            </Badge>
          ) : null}
          {f.unsupported_schema ? (
            <Badge variant="destructive" className="text-[10px]">
              schema
            </Badge>
          ) : null}
          {f.cool_ids_overflow ? (
            <Badge variant="warning" className="text-[10px]">
              cool overflow
            </Badge>
          ) : null}
          {!f.ops_lagging && !stale && !f.unsupported_schema && !f.cool_ids_overflow ? (
            <span className="text-xs text-muted-foreground">ok</span>
          ) : null}
        </span>
      </TableCell>
      <TableCell className="tabular-nums">
        <Tooltip
          side="top"
          content={
            <div className="space-y-1">
              {(f.cool ?? []).slice(0, 8).map((c, i) => (
                <div key={i}>
                  {c.target?.kind}/{c.target?.id}
                  {c.reason ? ` · ${c.reason}` : ""}
                </div>
              ))}
              {(f.cool?.length ?? 0) === 0 ? "none cooling" : null}
            </div>
          }
        >
          <span className="cursor-help">{coolN}</span>
        </Tooltip>
      </TableCell>
      <TableCell className="tabular-nums">{degradedN}</TableCell>
      <TableCell className="max-w-[28rem] pr-4 text-xs text-muted-foreground">
        <ExpandableText text={taskSummary} className="max-w-[28rem]" />
      </TableCell>
      <TableCell className="text-xs text-muted-foreground tabular-nums">
        {typeof f.snapshot_age_sec === "number" ? `${Math.round(f.snapshot_age_sec)}s` : "—"}
      </TableCell>
    </TableRow>
  )
}

function SchedBadges({
  error,
  scrapedAt,
}: {
  error: string | null | undefined
  scrapedAt: number | null | undefined
}) {
  const stale = isStale(scrapedAt)
  if (!error && !stale) {
    return <span className="text-xs text-muted-foreground">ok</span>
  }
  return (
    <span className="inline-flex flex-wrap items-center gap-1">
      {error ? (
        <Tooltip side="top" content={<span className="break-all">{error}</span>}>
          <Badge variant="destructive" className="cursor-help text-[10px]">
            error
          </Badge>
        </Tooltip>
      ) : null}
      {stale ? (
        <Badge variant="warning" className="text-[10px]">
          stale
        </Badge>
      ) : null}
    </span>
  )
}

function WorkerStatus({
  status,
  sticky,
  draining,
  reach,
}: {
  status?: string | null
  sticky?: boolean
  draining?: boolean
  reach?: { ok: boolean | null; checked_at: number; error: string | null } | null
}) {
  // The probe outranks the master's cached hello: a worker whose dist
  // port cannot be reached AND that the master no longer reports up is
  // down. A probe failure alone is NOT proof of death — locked-down
  // workers (cloud security groups drop inbound dist ports; the mesh
  // dials master→... worker-initiated) read unreachable from the
  // dashboard forever while being perfectly healthy, so when the master
  // still says up the probe failure shows as a muted "no probe" note.
  if (reach && reach.ok === false) {
    const ago = Math.max(0, Math.round((Date.now() - reach.checked_at * 1000) / 1000))
    if (status === "up") {
      return (
        <Badge
          variant="outline"
          className="text-[10px] text-muted-foreground"
          title={`dist port not reachable from the dashboard (probed ${ago}s ago) — typically a locked-down security group; the master link is up`}
        >
          up · no probe
        </Badge>
      )
    }
    return (
      <Badge
        variant="destructive"
        className="text-[10px]"
        title={`dist port unreachable (probed ${ago}s ago): ${reach.error ?? "unknown error"}`}
      >
        unreachable
      </Badge>
    )
  }
  const label = status ?? (sticky ? "sticky" : draining ? "draining" : "—")
  const variant =
    label === "up"
      ? "success"
      : label === "draining"
        ? "warning"
        : label === "sticky"
          ? "secondary"
          : "secondary"
  return (
    <Badge variant={variant as "success" | "warning" | "secondary"} className="text-[10px]">
      {label}
    </Badge>
  )
}

/** Pinned-provider cell for one worker. A concentration (≥3 providers on one
 * node) is a warning: pinned picks outrank the health tier and bypass the
 * capacity soft cap, so that node keeps all of their traffic (spec failure
 * mode 7 — visible here, with no automatic mitigation). */
function PinnedProvidersCell({ pinned }: { pinned: Provider[] }) {
  if (pinned.length === 0) {
    return <span className="text-muted-foreground/40">—</span>
  }
  const names = pinned.map((p) => p.name)
  return (
    <Tooltip
      content={`Pinned here (absolute tier-2 pin — outranks health/geo, bypasses the capacity soft cap): ${names.join(", ")}`}
    >
      <span className="flex min-w-0 cursor-help items-center gap-1.5">
        <Badge
          variant={pinned.length >= 3 ? "warning" : "secondary"}
          className="tabular-nums text-[11px]"
        >
          {pinned.length}
        </Badge>
        <span className="truncate text-muted-foreground">
          {names.slice(0, 2).join(", ")}
          {names.length > 2 ? ` +${names.length - 2}` : ""}
        </span>
      </span>
    </Tooltip>
  )
}

function FleetStrip({ fleet, stale, disabled }: { fleet: Fleet; stale: boolean; disabled: boolean }) {
  if (!fleet) {
    return (
      <div className="border-b px-6 py-3 text-xs text-muted-foreground">
        {disabled
          ? "Fleet signals disabled on the gateway (JANUS_FLEET_ENABLED=off) — the advisory ring is off; workers still dispatch normally."
          : "Fleet: — (no successful sched cache, or pool not started)"}
      </div>
    )
  }
  const d = fleet.dispatch_local_total ?? {}
  const keys: Array<keyof NonNullable<NonNullable<Fleet>["dispatch_local_total"]>> = [
    "empty_pool",
    "capacity",
    "drained",
    "drained_pin",
    "send_fail",
    "ack_miss",
  ]
  return (
    <div className={"border-b px-6 py-3 text-xs " + (stale ? "text-muted-foreground" : "")}>
      <div className="mb-1 font-medium text-foreground">
        Fleet — master-side fallbacks, not per-worker
        {stale ? (
          <Badge variant="warning" className="ml-2 text-[10px]">
            stale
          </Badge>
        ) : null}
      </div>
      <div className="flex flex-wrap gap-x-4 gap-y-1 text-muted-foreground">
        <span>
          available <span className="tabular-nums text-foreground">{dash(fleet.available)}</span>
        </span>
        <span>
          members <span className="tabular-nums text-foreground">{dash(fleet.members)}</span>
        </span>
        <span>
          sticky <span className="tabular-nums text-foreground">{dash(fleet.sticky)}</span>
        </span>
      </div>
      <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 font-mono text-[11px] text-muted-foreground">
        {keys.map((k) => (
          <span key={k}>
            {k}=<span className="tabular-nums text-foreground">{d[k] ?? 0}</span>
          </span>
        ))}
      </div>
    </div>
  )
}

function AddNodeModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [name, setName] = useState("")
  const [dataHost, setDataHost] = useState("")
  const [dataPort, setDataPort] = useState("8080")
  const [statsHost, setStatsHost] = useState("")
  const [statsPort, setStatsPort] = useState("8090")
  const [statsToken, setStatsToken] = useState("")
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    const dp = Number(dataPort)
    const sp = Number(statsPort)
    const validPort = (n: number) => Number.isInteger(n) && n >= 1 && n <= 65535
    if (!validPort(dp) || !validPort(sp)) {
      toast.error("Ports must be whole numbers between 1 and 65535")
      return
    }
    setBusy(true)
    try {
      await api("/nodes", {
        method: "POST",
        body: {
          name,
          data_host: dataHost,
          data_port: dp,
          stats_host: statsHost.trim() || dataHost,
          stats_port: sp,
          ...(statsToken.trim() ? { stats_token: statsToken.trim() } : {}),
        },
      })
      toast.success(`node "${name}" registered`)
      onDone()
      onClose()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        title="Add gateway node"
        description="Register a Janus gateway instance that shares this Postgres. Workers hello into the master pool — do not register them here."
      >
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="node-name">Node name</FieldLabel>
            <Input
              id="node-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="gateway-1"
              autoFocus
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="node-host">Data host</FieldLabel>
            <Input
              id="node-host"
              value={dataHost}
              onChange={(e) => setDataHost(e.target.value)}
              placeholder="10.0.1.50"
            />
            <FieldDescription>Hostname or IP of the gateway data plane.</FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="node-port">Data port</FieldLabel>
            <Input
              id="node-port"
              type="number"
              min={1}
              max={65535}
              value={dataPort}
              onChange={(e) => setDataPort(e.target.value)}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="node-stats-host">Stats host</FieldLabel>
            <Input
              id="node-stats-host"
              value={statsHost}
              onChange={(e) => setStatsHost(e.target.value)}
              placeholder="defaults to data host"
            />
            <FieldDescription>Admin plane host (port 8090). Leave blank to reuse the data host.</FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="node-stats-port">Stats port</FieldLabel>
            <Input
              id="node-stats-port"
              type="number"
              min={1}
              max={65535}
              value={statsPort}
              onChange={(e) => setStatsPort(e.target.value)}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="node-stats-token">Stats token</FieldLabel>
            <Input
              id="node-stats-token"
              type="password"
              autoComplete="new-password"
              value={statsToken}
              onChange={(e) => setStatsToken(e.target.value)}
              placeholder="optional — leave blank to use the global token"
            />
            <FieldDescription>
              This node's JANUS_STATS_TOKEN, for per-node credentials.
              Stored encrypted, never displayed again. Leave blank to
              use the dashboard's global token.
            </FieldDescription>
          </Field>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={busy || !name || !dataHost} onClick={submit}>
            Register node
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function formatUptime(sec: number): string {
  if (sec < 60) return `${sec}s`
  if (sec < 3600) return `${Math.floor(sec / 60)}m ${sec % 60}s`
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}m`
  return `${Math.floor(sec / 86400)}d ${Math.floor((sec % 86400) / 3600)}h`
}

function formatStarted(epochSec: number): string {
  const d = new Date(epochSec * 1000)
  if (Number.isNaN(d.getTime())) return "—"
  return d.toLocaleString(undefined, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  })
}
