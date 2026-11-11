import { useCallback, useEffect, useRef, useState } from "react"
import { Check, Copy } from "lucide-react"

import { api } from "../api"
import { ErrorFlash, Loading } from "../components"
import { Badge } from "@/components/ui/badge"
import { Dialog, DialogContent } from "@/components/ui/dialog"
import { Tooltip } from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"
import { fmtUnixTsLocal, parseBackendInstant, pad2 } from "@/lib/time-format"
import { copyText } from "@/lib/clipboard"

export type KeyMeta = { id: number; key_id: string; weight: number; enabled: boolean }
export type ProviderModel = { id: number; provider_id: number; name: string; enabled: boolean; modality?: string }
export type Provider = {
  id: number
  name: string
  base_url: string
  protocol: string
  enabled: boolean
  keys: KeyMeta[]
  models?: ProviderModel[]
  /** Absolute tier-2 pin: an Erlang long name (`janus@<ip>`) or null.
   * The gateway honours it over health/geo and bypasses the capacity
   * soft cap, but FAILS OPEN when the node is not in the live pool. */
  affinity_node?: string | null
  /** Soft geo preference (sched region tag). NEVER a pin — an existing
   * `affinity_node` outranks it, so the two must not be conflated in UI. */
  region_tag?: string | null
}
export type Model = { id: number; name: string; enabled: boolean; routes: Route[] }
export type Route = { model_id: number; provider_id: number; provider_name: string | null; upstream_model_id: string | null; weight: number; priority: number; enabled: boolean }
export type AgentKey = {
  id: number
  prefix: string
  enabled: boolean
  created_at: string
  /** `"all"` = unrestricted; otherwise explicit public model-name grants */
  model_names: string[] | "all"
  /** Operator note (owner / purpose); null when unset */
  comment?: string | null
  /** True when JSEC ciphertext is stored and reveal/copy is available */
  has_secret?: boolean
}
export type AuditEvent = { ts: string; actor: string; action: string; target: string | null; detail: string | null }

// --- Alerting (observability-depth Task 6) ---

export type AlertState = {
  rule: string
  scope: string
  severity: "info" | "warning" | "critical"
  message: string
  cycles: number
  /** ISO timestamp of the firing transition; null for stale rows */
  since: string | null
  last_eval_at: string | null
}

export type AlertEvent = {
  id: number
  ts: string | null
  rule: string
  scope: string
  severity: "info" | "warning" | "critical"
  state: "firing" | "resolved" | "test"
  message: string
  detail: unknown
  delivered: boolean
  attempts: number
}

export type AlertsResponse = {
  states: AlertState[]
  events: AlertEvent[]
  webhook_configured: boolean
}

// --- Entitlement matrix (spec 2026-10-05 Part A) ---

export type EntitlementKey = {
  provider_key_id: number
  label: string
  ok: number
  deny: number
  balance: number
  unknown: number
  input_shape: number
  broken: boolean
  escalated: number
  total: number
  last_checked_at: string | null
}

export type EntitlementCell = {
  status: "ok" | "deny" | "balance" | "unknown" | "broken"
  error_code: string | null
  escalated: boolean
  checked_at: string
}

export type EntitlementListing = {
  model_name: string
  ok: number
  deny: number
  balance: number
  unknown: number
  keys: number
  badge: "ok" | "partial" | "deny" | null
  stale_listing: boolean
  by_key: Record<string, EntitlementCell>
}

export type EntitlementMatrix = {
  provider_id: number
  provider: string
  keys: EntitlementKey[]
  listings: EntitlementListing[]
  budget: { calls: number; healing_calls: number; daily_limit: number }
}

export type EntitlementResponse = {
  providers: EntitlementMatrix[]
  probe: {
    running_providers: number[]
    queued_jobs: number
    last_batches: Record<string, { ran_at: string; trigger: string; calls: number; truncated: boolean }>
  }
  refresh: { ran_at: string; scanned: number; promoted: number; balance_canaries: number[] } | null
}

export type UsageTotals = {
  requests: number
  prompt_tokens: number
  completion_tokens: number
  errors: number
  unreported: number
  avg_latency_ms: number | null
  avg_stream_ms: number | null
  p95_latency_ms: number | null
  p95_stream_ms: number | null
}
export type UsagePoint = { bucket: string; requests: number; prompt_tokens: number; completion_tokens: number }
export type UsageRow = { id: number | null; name: string | null; requests: number; prompt_tokens: number; completion_tokens: number; last_ts: number }
export type UsageEvent = {
  ts: number
  key_prefix: string | null
  model: string | null
  provider: string | null
  protocol: string
  stream: number
  status: number
  prompt_tokens: number | null
  completion_tokens: number | null
  latency_ms: number | null
  modality: string
  units: number | null
  outcome: string | null
  cache_read_input_tokens: number | null
  request_id: string | null
  request_ref: string | null
  trace_id: string | null
}
export type TimelineAttempt = {
  ts: number
  attempt: number
  is_terminal: boolean
  status: number
  error_code: string | null
  failover_reason: string | null
  latency_ms: number | null
  protocol: string
  stream: number
  trace_id: string | null
  request_id: string | null
  model: string | null
  provider: string | null
  provider_key_id: number | null
  key_prefix: string | null
}
export type UsageTimeline = {
  request: {
    request_ref: string
    trace_id: string | null
    model: string | null
    key_prefix: string | null
    terminal_status: number
    total_latency_ms: number | null
    attempts: number
  }
  attempts: TimelineAttempt[]
}
export type UsageSummary = {
  range: string
  ts_from: number
  ts_to: number
  totals: UsageTotals
  series: UsagePoint[]
  by_key: UsageRow[]
  by_model: UsageRow[]
  by_resolution: { requested: string; resolved: string; requests: number; prompt_tokens: number; completion_tokens: number; last_ts: number }[]
  by_provider: UsageRow[]
  by_provider_key: UsageRow[]
  writer: { alive: boolean; buffered: number; dropped: number } | null
}

// H8 cost reporting (spec 2026-10-15-maturity-hardening). cost is the
// PRICED portion only; null = no priced models for this row ("—",
// never estimated). Unpriced token totals ride per row and in the
// top-level bucket.
export type SpendRow = {
  id: number | string | null
  name: string
  prompt_tokens: number
  completion_tokens: number
  cost: number | null
  currency: string | null
  unpriced_prompt_tokens: number
  unpriced_completion_tokens: number
}
export type SpendResponse = {
  from: number
  to: number
  group_by: string
  rows: SpendRow[]
  unpriced: { prompt_tokens: number; completion_tokens: number; models: number }
  currencies: string[]
  failover_windows: { ts: number; rpo_window_sec: number }[]
}
export type ModelPrice = {
  model_name: string
  input_per_mtok: number
  output_per_mtok: number
  currency: string
  updated_at: string
}

export function fmtNum(n: number) {
  return n.toLocaleString("en-US")
}

/** Unix seconds → local "MM-DD HH:MM:SS" (charts and tables share one clock). */
export function fmtTs(ts: number) {
  return fmtUnixTsLocal(ts)
}

export { fmtIsoLocalCompact, fmtIsoLocalMonthDayHm, fmtIsoLocalSeconds } from "@/lib/time-format"

/** Renders a backend ISO timestamp in the browser's local zone. Non-today rows
 * get a "MM-DD " prefix and dim; raw ISO stays in the tooltip. */
export function EventTime({ ts }: { ts?: string }) {
  if (!ts) return null
  const d = parseBackendInstant(ts)
  if (Number.isNaN(d.getTime())) return <>{ts}</>
  const now = new Date()
  const today =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate()
  const hms = `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`
  return (
    <span title={ts} className={today ? undefined : "opacity-70"}>
      {today ? hms : `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${hms}`}
    </span>
  )
}

/** OpenAI Decisions probe state (GET /api/providers/{id}/decisions-probe). */
export type DecisionsProbeResult = {
  outcome: "ok" | "bad_key" | "inconclusive"
  http_status: number | null
  latency_ms: number
  listing: string
  ran_at: string
}

export type DecisionsProbeState = {
  provider_id: number
  last_probe_at: string | null
  probes_today: number
  day_utc: string | null
  in_flight: boolean
  daily_limit: number
  budget_remaining: number
  cooldown_remaining_sec: number
  listing_pick: string | null
  last_result: DecisionsProbeResult | null
}

export { PROTOCOL_LABELS, protocolLabel } from "@/lib/protocols"

export function StateBadge({ enabled }: { enabled: boolean }) {
  if (enabled) {
    return (
      <span className="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
        <span className="size-1.5 rounded-full bg-success" />
        Enabled
      </span>
    )
  }
  return (
    <span className="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
      <span className="size-1.5 rounded-full bg-warning" />
      Disabled
    </span>
  )
}

// --- Provider→node affinity (spec 2026-10-22 §6, decision D4) ---

/** One live worker from GET /api/nodes (the master sched cache). `node` is
 * the Erlang long name (`janus@<ip>`) and is the ONLY value a provider pin
 * may hold — `gateway_nodes.name` is the gateway row, never a worker. */
export type AffinityWorker = {
  node: string
  region?: string | null
  geo_region?: string | null
  /** Operator remark (dashboard-owned worker_notes); "" when unset. */
  note?: string
  status?: string | null
  dispatchable?: boolean
  draining?: boolean
  via?: string
}

/** Short display form of a worker long name (`janus@1.2.3.4` → `1.2.3.4`). */
export function shortNode(node: string): string {
  return node.includes("@") ? node.slice(node.indexOf("@") + 1) : node
}

/** True when a pin names a node that is NOT in the live pool, so the
 * gateway will fail open to any healthy node. `known` is false until a
 * sched scrape succeeds: a stale/unknown fleet view must not be reported
 * as an unmatched pin. */
export function pinUnmatched(
  pin: string | null | undefined,
  workers: AffinityWorker[],
  known: boolean,
): boolean {
  if (!pin || !known) return false
  return !workers.some((w) => w.node === pin)
}

/** Pin badge shared by the Providers and Nodes pages. A live pin is
 * informational; an unmatched pin is a warning, because the gateway fails
 * OPEN (no error, no metric) and this badge is the only operator-visible
 * signal that the pin is not being honoured. */
export function AffinityPinBadge({
  pin,
  workers,
  known,
  className,
}: {
  pin?: string | null
  workers: AffinityWorker[]
  known: boolean
  className?: string
}) {
  if (!pin) return null
  if (!known) {
    return (
      <Tooltip
        content={`Pinned to ${pin} — no successful sched scrape yet, so this pin is unverified (not reported as a miss).`}
      >
        <Badge variant="outline" className={cn("cursor-help font-mono text-[11px]", className)}>
          pin {shortNode(pin)} ?
        </Badge>
      </Tooltip>
    )
  }
  if (pinUnmatched(pin, workers, known)) {
    return (
      <Tooltip
        content={`Pin NOT honoured: "${pin}" is not in the live worker pool, so the gateway falls through to any healthy node (fail-open). Nothing is auto-corrected — pin a live worker or clear the pin.`}
      >
        <Badge variant="warning" className={cn("cursor-help font-mono text-[11px]", className)}>
          pin unmatched: {shortNode(pin)}
        </Badge>
      </Tooltip>
    )
  }
  return (
    <Tooltip
      content={`Pinned to ${pin} — absolute tier-2 pin: it outranks health and geo and bypasses the capacity soft cap.`}
    >
      <Badge variant="secondary" className={cn("cursor-help font-mono text-[11px]", className)}>
        pin {shortNode(pin)}
      </Badge>
    </Tooltip>
  )
}

export function ProviderBadges({ routes }: { routes: Route[] }) {
  const byId = new Map<number, { name: string; enabled: boolean }>()
  for (const r of routes) {
    const name = r.provider_name ?? String(r.provider_id)
    const prev = byId.get(r.provider_id)
    byId.set(r.provider_id, {
      name,
      enabled: (prev?.enabled ?? false) || r.enabled,
    })
  }
  const providers = [...byId.entries()]
  if (providers.length === 0) {
    return <span className="text-muted-foreground">—</span>
  }
  return (
    <div className="flex flex-wrap gap-1">
      {providers.map(([id, p]) => (
        <Badge key={id} variant={p.enabled ? "outline" : "secondary"} className="font-mono">
          {p.name}
        </Badge>
      ))}
    </div>
  )
}

export function ActionBadge({ action }: { action: string }) {
  const verb = action.split(".").pop() ?? ""
  const variant = /delete|revoke|disable/.test(verb) ? "destructive" : "secondary"
  return (
    <Badge variant={variant} className="max-w-full font-mono text-[11px] font-normal" title={action}>
      <span className="line-clamp-2 whitespace-normal break-words">{action}</span>
    </Badge>
  )
}

// --- Failure visibility (GET /api/failures/*) ---

/** One (kind, code, model, provider) cluster in the failures breakdown. */
export type FailureGroup = {
  kind: "upstream" | "reject"
  code: string | null
  reason: string | null
  model: string | null
  provider: string | null
  count: number
  last_ts: number
}

/** Unified failure row: `upstream` = terminal usage_events row (status >=
 * 400); `reject` = pre-pick rejection recovered from the gateway log drain
 * (quota 429, no_route 404, …) — reject rows have no provider/key/ref and
 * their history is bounded by the log ring. */
export type FailureEvent = {
  ts: number
  kind: "upstream" | "reject"
  status: number | null
  code: string | null
  reason: string | null
  model: string | null
  requested_model: string | null
  provider: string | null
  key_prefix: string | null
  node: string | null
  request_id: string | null
  request_ref: string | null
  /** The reply's own sentence (usage_events.error_detail, gateway
   * migration 027) — null on pre-migration or non-terminal rows. */
  detail: string | null
}

export type FailureSummary = {
  range: string
  ts_from: number
  ts_to: number
  totals: { failures: number; upstream: number; rejects: number }
  by_error: FailureGroup[]
}

// --- Shared usage/failure table pieces ---

/** HTTP status → tone class (usage + failures tables share one scale). */
export function statusClass(status: number) {
  if (status >= 500) return "text-destructive"
  if (status >= 400) return "text-warning"
  return "text-success"
}

/** The timeline query string, preferring a pivot over the opening props.
 *
 * Written as a function rather than nested ternaries: the precedence (pivot
 * beats prop beats request_ref) is the whole logic and is easier to read
 * stated once.
 */
function timelineQuery(
  pivot: { kind: "trace"; id: string } | null,
  traceId: string | undefined,
  requestRef: string | undefined,
): string {
  if (pivot) return `trace_id=${encodeURIComponent(pivot.id)}`
  if (traceId) return `trace_id=${encodeURIComponent(traceId)}`
  return `request_ref=${encodeURIComponent(requestRef as string)}`
}

function copyTitle(state: "idle" | "copied" | "failed", traceId: string): string {
  if (state === "copied") return "Copied"
  if (state === "failed") return "Copy failed"
  return `Copy ${traceId}`
}

function copyAriaLabel(state: "idle" | "copied" | "failed", traceId: string): string {
  if (state === "copied") return `Copied trace ID ${traceId}`
  if (state === "failed") return `Copy failed for trace ID ${traceId}`
  return `Copy trace ID ${traceId}`
}

function copyAnnouncement(state: "idle" | "copied" | "failed"): string {
  if (state === "copied") return "Trace ID copied"
  if (state === "failed") return "Copy failed"
  return ""
}

/** A trace id that opens the timeline for that trace.
 *
 * The trace id is the one id in the UI that spans more than this gateway: it
 * joins the client's request to the gateway and to everything downstream. So
 * it is a navigation affordance as well as a copyable value — clicking it shows
 * the timeline resolved BY TRACE, which the endpoint already supports.
 */
export function TraceLink({
  traceId,
  onOpen,
}: {
  traceId: string
  onOpen: (traceId: string) => void
}) {
  const { state: copyState, copy } = useCopyFeedback()
  const copied = copyState === "copied"
  return (
    <span className="flex min-w-0 items-center gap-1">
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation()
          onOpen(traceId)
        }}
        title={`Open the timeline for trace ${traceId}`}
        aria-label={`Open the timeline for trace ${traceId}`}
        className="truncate font-mono text-xs text-link underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        {traceId}
      </button>
      <button
        type="button"
        onClick={(e) => void copy(traceId, e)}
        title={copyTitle(copyState, traceId)}
        aria-label={copyAriaLabel(copyState, traceId)}
        className="grid size-4 shrink-0 place-items-center rounded text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        {copied ? (
          <Check className="size-3 text-success" />
        ) : (
          <Copy className={copyState === "failed" ? "size-3 text-destructive" : "size-3"} />
        )}
      </button>
      {/* The live region is a SIBLING of the button, not a child: several
          screen readers ignore a status node nested inside an interactive
          element, so the announcement would never be spoken. */}
      <span role="status" aria-live="polite" className="sr-only">
        {copyAnnouncement(copyState)}
      </span>
    </span>
  )
}

/** The clipboard-feedback state machine, shared by every copy affordance.
 *
 * Extracted rather than repeated: two copies of it had already drifted (one
 * kept a timer ref, the other leaked its timer on unmount, and one swallowed
 * failures). One implementation means one behaviour, and the cleanup lives
 * here instead of in each caller.
 */
function useCopyFeedback() {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle")
  const timer = useRef<number | null>(null)
  useEffect(() => {
    return () => {
      if (timer.current !== null) window.clearTimeout(timer.current)
    }
  }, [])
  const copy = useCallback(async (text: string, stopEvent?: React.MouseEvent) => {
    // A failed clipboard write used to be swallowed silently (L-49).
    stopEvent?.stopPropagation()
    try {
      await copyText(text)
      setState("copied")
    } catch {
      setState("failed")
    }
    if (timer.current !== null) window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => setState("idle"), 2000)
  }, [])
  return { state, copy }
}

export function CopyMono({ text, label = "request ID" }: { text: string; label?: string }) {
  const { state, copy } = useCopyFeedback()
  const copied = state === "copied"
  const failed = state === "failed"
  return (
    <button
      type="button"
      onClick={() => void copy(text)}
      title={failed ? `Copy failed — select the ${label} manually` : `Copy ${text}`}
      aria-label={failed ? `Copy failed for ${label} ${text}` : `Copy ${label} ${text}`}
      className="group flex min-h-8 max-w-[160px] items-center gap-1.5 rounded text-left font-mono text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <span className={"truncate" + (failed ? " text-destructive" : "")}>{text}</span>
      <span className="relative grid size-3.5 shrink-0 place-items-center">
        <Check
          className={
            "col-start-1 row-start-1 size-3.5 text-success transition-[opacity,scale,filter] duration-200 ease-[cubic-bezier(0.2,0,0,1)] " +
            (copied ? "scale-100 opacity-100 blur-0" : "scale-[0.25] opacity-0 blur-[4px]")
          }
        />
        <Copy
          className={
            "col-start-1 row-start-1 size-3.5 text-muted-foreground/70 transition-[opacity,scale,filter] duration-200 ease-[cubic-bezier(0.2,0,0,1)] " +
            (copied
              ? "scale-[0.25] opacity-0 blur-[4px]"
              : "scale-100 opacity-0 blur-0 group-hover:opacity-100 group-focus-visible:opacity-100")
          }
        />
      </span>
    </button>
  )
}

/** Per-attempt failover timeline dialog — usage events and failure rows
 * drill into this by request_ref, and a trace id drills in by trace_id.
 *
 * Both keys exist because they answer different questions: a request_ref is
 * one gateway request, while a trace_id spans the client's request through the
 * gateway and every service it called. The endpoint already distinguishes "in
 * flight" from "not found" for either key, so that distinction is surfaced
 * rather than collapsed into a generic error. */
type TimelineKey = { requestRef: string; traceId?: never } | { traceId: string; requestRef?: never }

export function TimelineDialog({
  requestRef,
  traceId,
  onClose,
}: TimelineKey & { onClose: () => void }) {
  const [data, setData] = useState<UsageTimeline | null>(null)
  const [error, setError] = useState("")
  // A click on the trace id inside the dialog pivots the SAME dialog rather
  // than opening a second one on top of the first.
  const [pivot, setPivot] = useState<{ kind: "trace"; id: string } | null>(null)

  const query = timelineQuery(pivot, traceId, requestRef)

  useEffect(() => {
    // Reset before fetching: a stale success or failure from the previous
    // query would otherwise render as if it described the new one. The
    // `alive` guard drops a late response from a query that is no longer
    // current, which the pivot makes reachable.
    setData(null)
    setError("")
    let alive = true
    api<UsageTimeline>(`/usage/timeline?${query}`)
      .then((d) => alive && setData(d))
      .catch((e) => alive && setError(e.message))
    return () => {
      alive = false
    }
  }, [query])

  const req = data?.request
  return (
    <Dialog
      open
      onOpenChange={(o) => {
        if (o) return
        setPivot(null)
        onClose()
      }}
    >
      <DialogContent
        size="lg"
        title={traceId || pivot ? "Trace timeline" : "Request timeline"}
        description="Every gateway attempt for this request, in order — non-terminal rows are the failover evidence."
      >
        {error ? (
          <ErrorFlash message={error} />
        ) : !data || !req ? (
          <Loading />
        ) : (
          <div className="flex flex-col gap-4">
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1.5 text-xs text-muted-foreground">
              <span>
                <span className="text-foreground">{req.model ?? "(deleted)"}</span> via{" "}
                {req.key_prefix ?? "(deleted)"}…
              </span>
              <span>
                status{" "}
                <span className={`font-mono font-semibold ${statusClass(req.terminal_status)}`}>
                  {req.terminal_status}
                </span>
              </span>
              <span className="tabular-nums">
                {req.total_latency_ms != null ? `${req.total_latency_ms} ms total` : "—"}
              </span>
              <span>
                {req.attempts} attempt{req.attempts === 1 ? "" : "s"}
              </span>
            </div>
            {pivot && (
              <div className="flex items-center gap-2 rounded-md border bg-muted/40 px-2.5 py-1.5 text-xs">
                <span className="text-muted-foreground">Viewing by trace</span>
                <span className="truncate font-mono">{pivot.id}</span>
                <button
                  type="button"
                  onClick={() => setPivot(null)}
                  className="ml-auto shrink-0 rounded px-1.5 py-0.5 text-link underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                >
                  Back to this request
                </button>
              </div>
            )}
            {req.trace_id && (
              <div className="flex min-w-0 items-center gap-2 text-xs text-muted-foreground">
                <span className="shrink-0">trace</span>
                <TraceLink
                  traceId={req.trace_id}
                  onOpen={(tid) => {
                    setPivot({ kind: "trace", id: tid })
                  }}
                />
              </div>
            )}
            <ol className="flex flex-col gap-2">
              {data.attempts.map((a) => (
                <li
                  key={a.attempt}
                  className="flex flex-col gap-1 rounded-md border px-3 py-2 text-xs"
                >
                  <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <span className="font-mono font-semibold">#{a.attempt}</span>
                    <span className="font-mono">{a.provider ?? "(deleted)"}</span>
                    <span className="font-mono text-muted-foreground">
                      key {a.provider_key_id != null ? `#${a.provider_key_id}` : "—"}
                    </span>
                    <span className={`font-mono font-semibold ${statusClass(a.status)}`}>
                      {a.status}
                    </span>
                    <span className="tabular-nums text-muted-foreground">
                      {a.latency_ms != null ? `${a.latency_ms} ms` : "—"}
                    </span>
                    {a.is_terminal && <Badge variant="success">final</Badge>}
                    {a.failover_reason && (
                      <Badge variant="warning" className="font-mono">
                        {a.failover_reason}
                      </Badge>
                    )}
                    {a.error_code && (
                      <span className="font-mono text-muted-foreground">{a.error_code}</span>
                    )}
                  </div>
                  <div className="flex items-center gap-3 text-muted-foreground">
                    <span className="tabular-nums">{fmtTs(a.ts)}</span>
                    {a.trace_id ? (
                      <CopyMono text={a.trace_id} label="trace ID" />
                    ) : (
                      <span aria-hidden>—</span>
                    )}
                  </div>
                </li>
              ))}
            </ol>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
