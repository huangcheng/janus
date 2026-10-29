import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { LoaderCircle, RefreshCw } from "lucide-react"
import { api } from "../api"
import { fmtIsoLocalSeconds } from "../lib/time-format"
import { cn } from "@/lib/utils"
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
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"

// --- wire types (mirror of janus_runtime:snapshot/0) ---

type SupChild = {
  id: string
  pid: string
  type: "supervisor" | "worker"
  name: string | null
  queue_len: number
  memory: number
  children?: SupChild[]
}

type TopProc = {
  pid: string
  name: string | null
  queue_len: number
  memory: number
}

type RuntimeSnapshot = {
  sup_tree: { roots: SupChild[]; truncated: boolean }
  memory: Record<string, number>
  process_count: number
  port_count: number
  ets_count: number
  uptime_sec: number
  run_queue_total: number
  schedulers_online: number
  dirty_cpu_schedulers_online: number
  msg_queue_top: TopProc[]
  memory_top: TopProc[]
  counters: {
    requests_total: number
    requests_failed: number
    signals_tx: number
    signals_rx: number
    dist_busy_events_total: number
  }
  connected: string[]
  role: string
  captured_at_ms: number
}

type RuntimePayload = {
  command: string
  outcome: string
  results: Record<string, { ok?: RuntimeSnapshot; error?: string }>
}

const SHORT = (node: string) => (node.includes("@") ? node.split("@")[1] : node)

function fmtMb(bytes: number | undefined): string {
  if (!bytes || Number.isNaN(bytes)) return "—"
  return `${(bytes / 1048576).toFixed(1)} MB`
}

function fmtRate(perSec: number | null | undefined): string {
  if (perSec === null || perSec === undefined || Number.isNaN(perSec)) return ""
  if (perSec >= 10) return `${perSec.toFixed(0)}/s`
  if (perSec >= 1) return `${perSec.toFixed(1)}/s`
  if (perSec > 0) return "<1/s"
  return "0/s"
}

/**
 * Fleet runtime observer: on-demand runtime_snapshot via the gateway's
 * fleet command, rendered as a star topology (master center) plus a
 * per-node detail sheet (supervision tree with birth/death marks, VM
 * stats, flow counters). Heavy by design — never auto-polled unless the
 * operator turns the 10s refresh on.
 */
export function FleetRuntime({
  workers,
}: {
  workers: { node: string; reach?: { ok: boolean | null } | null }[]
}) {
  const [payload, setPayload] = useState<RuntimePayload | null>(null)
  const [prevPayload, setPrevPayload] = useState<RuntimePayload | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [auto, setAuto] = useState(false)
  const [openNode, setOpenNode] = useState<string | null>(null)
  const busyRef = useRef(false)

  const take = useCallback(async () => {
    if (busyRef.current) return
    busyRef.current = true
    setBusy(true)
    try {
      const next = await api<RuntimePayload>("/nodes/runtime")
      setPayload((cur) => {
        setPrevPayload(cur)
        return next
      })
      setError(null)
    } catch (e: any) {
      setError(e.message)
    } finally {
      busyRef.current = false
      setBusy(false)
    }
  }, [])

  useEffect(() => {
    if (!auto) return
    const t = setInterval(take, 10_000)
    return () => clearInterval(t)
  }, [auto, take])

  const results = payload?.results ?? {}
  const entries = useMemo(
    () =>
      Object.entries(results).sort((a, b) => {
        const roleA = a[1].ok?.role === "master" ? 0 : 1
        const roleB = b[1].ok?.role === "master" ? 0 : 1
        return roleA - roleB || a[0].localeCompare(b[0])
      }),
    [results],
  )
  const masters = entries.filter(([, r]) => r.ok?.role === "master")
  const workerNodes = entries.filter(([, r]) => r.ok && r.ok.role !== "master")
  const hasUnsupported = entries.some(([, r]) => (r.error ?? "").includes("unknown_command"))
  const reachByNode = useMemo(() => {
    const m = new Map<string, boolean | null>()
    for (const w of workers) m.set(w.node, w.reach?.ok ?? null)
    return m
  }, [workers])

  // Per-node flow rate vs the previous snapshot: req/s between the two
  // captures. Counters are monotone; a restart (counter reset) shows as
  // negative — report null and wait for the next pair.
  const flowRate = useCallback(
    (node: string): number | null => {
      const cur = results[node]?.ok
      const prev = prevPayload?.results?.[node]?.ok
      if (!cur || !prev) return null
      const dt = (cur.captured_at_ms - prev.captured_at_ms) / 1000
      if (dt <= 0) return null
      const d = cur.counters.requests_total - prev.counters.requests_total
      if (d < 0) return null
      return d / dt
    },
    [results, prevPayload],
  )

  return (
    <Card className="mt-1 w-full self-start animate-fade-up">
      <CardHeader className="border-b">
        <CardTitle>Fleet runtime</CardTitle>
        <CardDescription>
          On-demand observer snapshot — supervision trees, VM stats, traffic flow. Heavy: runs a
          tree walk on every node.
        </CardDescription>
        <CardAction>
          <div className="flex items-center gap-2">
            <label className="text-muted-foreground flex cursor-pointer items-center gap-1.5 text-xs select-none">
              <input
                type="checkbox"
                className="accent-foreground size-3.5"
                checked={auto}
                onChange={(e) => setAuto(e.target.checked)}
              />
              10s
            </label>
            <Button size="sm" variant="outline" onClick={take} disabled={busy}>
              {busy ? <LoaderCircle className="animate-spin" /> : <RefreshCw />}
              Snapshot
            </Button>
          </div>
        </CardAction>
      </CardHeader>
      <CardContent className="pt-4">
        {error && (
          <p className="text-destructive mb-3 text-sm">
            {hasUnsupported || (error ?? "").toLowerCase().includes("unknown_command")
              ? "The running gateway image predates the runtime_snapshot command — deploy the new gateway image first."
              : error}
          </p>
        )}
        {!payload && !busy ? (
          <p className="text-muted-foreground text-sm">
            No snapshot yet — take one to see the fleet topology and per-node runtime.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <div className="min-w-[640px]">
              <svg
                viewBox="0 0 720 250"
                className="h-[250px] w-full"
                role="img"
                aria-label="Fleet topology"
              >
                {workerNodes.map(([node, r], i) => {
                  const x = 40 + (640 * (i + 1)) / (workerNodes.length + 1)
                  const ok = r.ok
                  const reach = reachByNode.get(node)
                  const linked = !!ok?.connected.some((c) => masters.some(([m]) => m === c))
                  const dead = reach === false || (!linked && !!ok)
                  const rate = fmtRate(flowRate(node))
                  return (
                    <g key={node}>
                      <line
                        x1={360}
                        y1={100}
                        x2={x}
                        y2={182}
                        strokeWidth={1.5}
                        className={cn(
                          dead
                            ? "stroke-destructive/50"
                            : linked
                              ? "stroke-foreground/35"
                              : "stroke-muted-foreground/25",
                        )}
                        strokeDasharray={dead ? "4 3" : undefined}
                      />
                      {rate && rate !== "0/s" && (
                        <text
                          x={(360 + x) / 2}
                          y={(100 + 182) / 2 - 6}
                          textAnchor="middle"
                          className="fill-muted-foreground text-[10px] tabular-nums"
                        >
                          {rate}
                        </text>
                      )}
                      <NodeChip
                        x={x}
                        y={208}
                        node={node}
                        result={ok}
                        dead={dead}
                        onClick={() => setOpenNode(node)}
                      />
                    </g>
                  )
                })}
                {masters.map(([node, r], i) => (
                  <NodeChip
                    key={node}
                    x={360}
                    y={74}
                    node={node}
                    result={r.ok}
                    dead={false}
                    row={masters.length}
                    offset={i}
                    onClick={() => setOpenNode(node)}
                  />
                ))}
                {entries.length === 0 && !busy && (
                  <text
                    x={360}
                    y={130}
                    textAnchor="middle"
                    className="fill-muted-foreground text-sm"
                  >
                    {payload?.outcome === "error" ? "no node answered" : "no snapshot data"}
                  </text>
                )}
              </svg>
            </div>
          </div>
        )}
        {payload && payload.outcome !== "ok" && (
          <p className="text-muted-foreground mt-2 text-xs">
            Fleet outcome: {payload.outcome} — nodes that errored show no data until the next
            snapshot succeeds.
          </p>
        )}
      </CardContent>

      {entries.map(([node]) => (
        <RuntimeSheet
          key={node}
          node={node}
          snapshot={results[node]?.ok ?? null}
          error={results[node]?.error ?? null}
          prev={prevPayload?.results?.[node]?.ok ?? null}
          rate={flowRate(node)}
          open={openNode === node}
          onOpenChange={(v) => !v && setOpenNode(null)}
        />
      ))}
    </Card>
  )
}

function NodeChip({
  x,
  y,
  node,
  result,
  dead,
  row = 1,
  offset = 0,
  onClick,
}: {
  x: number
  y: number
  node: string
  result?: RuntimeSnapshot
  dead: boolean
  row?: number
  offset?: number
  onClick: () => void
}) {
  const w = 160
  const h = 46
  const spread = (row - 1) * (w + 14)
  const ox = x - w / 2 - spread / 2 + offset * (w + 14)
  const oy = y - h / 2
  return (
    <g transform={`translate(${ox}, ${oy})`} className="cursor-pointer" onClick={onClick}>
      <rect
        width={w}
        height={h}
        rx={10}
        className={cn(
          "fill-card",
          dead ? "stroke-destructive/60" : row === 1 ? "stroke-foreground/70" : "stroke-border",
        )}
        strokeWidth={1.5}
      />
      <circle cx={16} cy={16} r={4} className={cn(dead ? "fill-destructive" : "fill-success")} />
      <text x={28} y={20} className="fill-foreground text-[12px] font-medium">
        {SHORT(node)}
      </text>
      <text x={12} y={37} className="fill-muted-foreground text-[10px] tabular-nums">
        {result
          ? `${result.role} · ${result.process_count} procs · ${fmtMb(result.memory?.total)}`
          : "no data"}
      </text>
    </g>
  )
}

// --- per-node detail sheet ---

type TreeMark = "new" | "exited" | null

/** Flattened identity of every tree node: parent pid + own pid + id. */
function treeKeys(snap: RuntimeSnapshot | null): Set<string> {
  const keys = new Set<string>()
  if (!snap) return keys
  const walk = (children: SupChild[], parentPid: string) => {
    for (const c of children) {
      keys.add(`${parentPid}:${c.pid}:${c.id}`)
      if (c.children) walk(c.children, c.pid)
    }
  }
  walk(snap.sup_tree.roots, "root")
  return keys
}

function RuntimeSheet({
  node,
  snapshot,
  error,
  prev,
  rate,
  open,
  onOpenChange,
}: {
  node: string
  snapshot: RuntimeSnapshot | null
  error: string | null
  prev: RuntimeSnapshot | null
  rate: number | null
  open: boolean
  onOpenChange: (v: boolean) => void
}) {
  const [tab, setTab] = useState<"sup" | "vm" | "flow">("sup")
  useEffect(() => {
    if (open) setTab("sup")
  }, [open])

  const marks = useMemo(() => {
    // No previous snapshot -> nothing to diff against; show a clean tree.
    if (!open || !prev) return new Map<string, TreeMark>()
    const cur = treeKeys(snapshot)
    const old = treeKeys(prev)
    const m = new Map<string, TreeMark>()
    for (const k of cur) if (!old.has(k)) m.set(k, "new")
    for (const k of old) if (!cur.has(k)) m.set(k, "exited")
    return m
  }, [snapshot, prev, open])

  if (error || !snapshot) {
    return (
      <Sheet open={open} onOpenChange={onOpenChange}>
        <SheetContent className="w-[520px] sm:max-w-[520px]">
          <SheetHeader>
            <SheetTitle className="font-mono text-sm">{node}</SheetTitle>
            <SheetDescription>Runtime snapshot unavailable</SheetDescription>
          </SheetHeader>
          <p className="text-destructive px-6 text-sm">{error || "no data in the last snapshot"}</p>
        </SheetContent>
      </Sheet>
    )
  }

  const mem = snapshot.memory
  const memRows: [string, number][] = [
    ["total", mem.total],
    ["processes", mem.processes],
    ["system", mem.system],
    ["code", mem.code],
    ["ets", mem.ets],
    ["binary", mem.binary],
    ["atom", mem.atom],
  ]
  const memMax = Math.max(...memRows.map(([, v]) => v ?? 0), 1)

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="flex w-[600px] max-w-[92vw] flex-col gap-0 overflow-y-auto sm:max-w-[600px]">
        <SheetHeader className="pr-10">
          <SheetTitle className="flex flex-wrap items-center gap-2 font-mono text-sm">
            {node}
            <Badge variant={snapshot.role === "master" ? "default" : "secondary"}>
              {snapshot.role}
            </Badge>
            <Badge variant="outline" className="font-sans">
              {fmtIsoLocalSeconds(new Date(snapshot.captured_at_ms).toISOString())}
            </Badge>
          </SheetTitle>
          <SheetDescription>
            {snapshot.process_count} processes · {snapshot.port_count} ports · {snapshot.ets_count}{" "}
            ETS tables · run queue {snapshot.run_queue_total}
          </SheetDescription>
        </SheetHeader>
        <div className="flex items-center justify-between px-6 pb-2">
          <div className="bg-muted inline-flex rounded-lg p-0.5">
            {(
              [
                ["sup", "Supervisors"],
                ["vm", "VM"],
                ["flow", "Flow"],
              ] as const
            ).map(([k, label]) => (
              <button
                key={k}
                onClick={() => setTab(k)}
                className={cn(
                  "rounded-md px-3 py-1 text-xs font-medium transition-colors",
                  tab === k
                    ? "bg-background text-foreground shadow-sm"
                    : "text-muted-foreground hover:text-foreground",
                )}
              >
                {label}
              </button>
            ))}
          </div>
        </div>

        <div className="flex-1 px-6 pb-6">
          {tab === "sup" && (
            <>
              {snapshot.sup_tree.truncated && (
                <p className="text-warning mb-2 text-xs">
                  Tree truncated (depth/entry caps) — the walk hit the safety limit.
                </p>
              )}
              <div className="font-mono text-xs">
                {snapshot.sup_tree.roots.map((r) => (
                  <SupRow key={r.pid} child={r} parentKey="root" marks={marks} depth={0} />
                ))}
              </div>
              {marks.size > 0 && (
                <p className="text-muted-foreground mt-3 font-sans text-xs">
                  Diff vs previous snapshot:{" "}
                  <span className="text-success">
                    {[...marks.values()].filter((m) => m === "new").length} started
                  </span>
                  ,{" "}
                  <span className="text-destructive">
                    {[...marks.values()].filter((m) => m === "exited").length} exited
                  </span>
                  {rate !== null && <> · ~{rate.toFixed(1)} req/s through this node</>}
                </p>
              )}
            </>
          )}
          {tab === "vm" && (
            <div className="flex flex-col gap-5">
              <div className="flex flex-col gap-2">
                {memRows.map(([k, v]) => (
                  <div key={k} className="flex items-center gap-3">
                    <span className="text-muted-foreground w-24 text-xs">{k}</span>
                    <div className="bg-muted h-2 flex-1 overflow-hidden rounded-full">
                      <div
                        className={cn(
                          "h-full rounded-full",
                          k === "total" ? "bg-foreground/70" : "bg-foreground/35",
                        )}
                        style={{ width: `${Math.max(2, ((v ?? 0) / memMax) * 100)}%` }}
                      />
                    </div>
                    <span className="w-20 text-right text-xs tabular-nums">{fmtMb(v)}</span>
                  </div>
                ))}
              </div>
              <TopList
                title="Largest mailboxes"
                rows={snapshot.msg_queue_top}
                metric={(r) => `${r.queue_len} msgs`}
              />
              <TopList
                title="Largest processes"
                rows={snapshot.memory_top}
                metric={(r) => fmtMb(r.memory)}
              />
            </div>
          )}
          {tab === "flow" && (
            <div className="flex flex-col gap-2 text-sm">
              <FlowRow
                label="Requests total"
                value={snapshot.counters.requests_total.toLocaleString()}
                delta={rate}
              />
              <FlowRow label="Requests failed" value={snapshot.counters.requests_failed.toLocaleString()} />
              <FlowRow
                label="Fleet signals tx / rx"
                value={`${snapshot.counters.signals_tx} / ${snapshot.counters.signals_rx}`}
              />
              <FlowRow
                label="Dist busy events"
                value={snapshot.counters.dist_busy_events_total.toLocaleString()}
              />
              <div className="text-muted-foreground mt-3 text-xs">
                Connected peers:{" "}
                {snapshot.connected.length ? snapshot.connected.join(", ") : "none"}
              </div>
            </div>
          )}
        </div>
      </SheetContent>
    </Sheet>
  )
}

function FlowRow({
  label,
  value,
  delta,
}: {
  label: string
  value: string
  delta?: number | null
}) {
  return (
    <div className="flex items-center justify-between border-b pb-1.5">
      <span className="text-muted-foreground text-xs">{label}</span>
      <span className="text-xs tabular-nums">
        {value}
        {delta !== undefined && delta !== null && (
          <span className="text-muted-foreground ml-2">({fmtRate(delta)})</span>
        )}
      </span>
    </div>
  )
}

function TopList({
  title,
  rows,
  metric,
}: {
  title: string
  rows: TopProc[]
  metric: (r: TopProc) => string
}) {
  return (
    <div>
      <p className="mb-1.5 text-xs font-medium">{title}</p>
      {rows.length === 0 ? (
        <p className="text-muted-foreground text-xs">Nothing notable.</p>
      ) : (
        <div className="flex flex-col gap-1">
          {rows.map((r) => (
            <div key={r.pid} className="flex items-center justify-between text-xs">
              <span className="truncate font-mono">
                {r.name ?? r.pid}
                {r.name && <span className="text-muted-foreground ml-1.5">{r.pid}</span>}
              </span>
              <span className="text-muted-foreground shrink-0 tabular-nums">{metric(r)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function SupRow({
  child,
  parentKey,
  marks,
  depth,
}: {
  child: SupChild
  parentKey: string
  marks: Map<string, TreeMark>
  depth: number
}) {
  const key = `${parentKey}:${child.pid}:${child.id}`
  return (
    <>
      <SupRowLine child={child} mark={marks.get(key) ?? null} depth={depth} />
      {child.type === "supervisor" &&
        child.children?.map((c) => (
          <SupRow
            key={c.pid}
            child={c}
            parentKey={key}
            marks={marks}
            depth={depth + 1}
          />
        ))}
    </>
  )
}

function SupRowLine({ child, mark, depth }: { child: SupChild; mark: TreeMark; depth: number }) {
  const isSup = child.type === "supervisor"
  return (
    <div
      className={cn(
        "flex items-center gap-2 rounded py-0.5 pr-1",
        depth > 0 && "border-l pl-3",
        mark === "new" && "bg-success/10",
        mark === "exited" && "bg-destructive/10 line-through opacity-70",
      )}
    >
      {isSup ? (
        <Badge variant="secondary" className="h-4 px-1 text-[10px]">
          sup
        </Badge>
      ) : (
        <span className="bg-muted text-muted-foreground inline-flex h-4 shrink-0 items-center rounded px-1 text-[10px]">
          w
        </span>
      )}
      <span
        className={cn("truncate", child.name ? "" : "text-muted-foreground")}
        title={child.name ?? child.pid}
      >
        {child.name ?? child.pid}
      </span>
      {child.queue_len > 0 && (
        <span className="text-warning shrink-0 tabular-nums" title="messages waiting in the mailbox">
          {child.queue_len}◐
        </span>
      )}
      {mark && (
        <span
          className={cn(
            "ml-auto shrink-0 text-[10px]",
            mark === "new" ? "text-success" : "text-destructive",
          )}
        >
          {mark}
        </span>
      )}
    </div>
  )
}
