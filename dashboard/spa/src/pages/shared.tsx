import { useEffect, useState } from "react"
import { Check, Copy } from "lucide-react"

import { api } from "../api"
import { ErrorFlash, Loading } from "../components"
import { Badge } from "@/components/ui/badge"
import { Dialog, DialogContent } from "@/components/ui/dialog"
import { Tooltip } from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"
import { fmtUnixTsLocal, fmtUtcBucketLabel, parseBackendInstant, pad2 } from "@/lib/time-format"

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

/** Local label for a UTC usage bucket key; aggregation boundaries stay UTC server-side. */
export function fmtBucket(bucket: string, range: string) {
  return fmtUtcBucketLabel(bucket, range)
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

/** Human-friendly protocol labels (wire format stays openai_chat etc.). */
export const PROTOCOL_LABELS: Record<string, string> = {
  openai_chat: "OpenAI Chat",
  openai_responses: "OpenAI Responses",
  anthropic_messages: "Anthropic Messages",
  openai_decisions: "OpenAI Decisions",
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

export function protocolLabel(protocol: string): string {
  return PROTOCOL_LABELS[protocol] ?? protocol
}

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

/** Unique providers from a model's routes, for the models table. */
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
    <Badge variant={variant} className="font-mono text-[11px] font-normal">
      {action}
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

export function CopyMono({ text, label = "request ID" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false)
  const [failed, setFailed] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // L-49: a failed clipboard write used to be swallowed silently.
      setFailed(true)
      setTimeout(() => setFailed(false), 2000)
    }
  }
  return (
    <button
      type="button"
      onClick={copy}
      title={failed ? `Copy failed — select the ${label} manually` : `Copy ${text}`}
      aria-label={failed ? `Copy failed for ${label} ${text}` : `Copy ${label} ${text}`}
      className="group flex min-h-8 max-w-[160px] items-center gap-1.5 rounded text-left font-mono text-xs focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
    >
      <span className={"truncate" + (failed ? " text-destructive" : "")}>{text}</span>
      <span className="relative grid size-3.5 shrink-0 place-items-center">
        <Check
          className={
            "col-start-1 row-start-1 size-3.5 text-success transition-[opacity,scale,filter] duration-300 ease-[cubic-bezier(0.2,0,0,1)] " +
            (copied ? "scale-100 opacity-100 blur-0" : "scale-[0.25] opacity-0 blur-[4px]")
          }
        />
        <Copy
          className={
            "col-start-1 row-start-1 size-3.5 text-muted-foreground/50 transition-[opacity,scale,filter] duration-300 ease-[cubic-bezier(0.2,0,0,1)] " +
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
 * with a request_ref both drill into this. */
export function TimelineDialog({ requestRef, onClose }: { requestRef: string; onClose: () => void }) {
  const [data, setData] = useState<UsageTimeline | null>(null)
  const [error, setError] = useState("")

  useEffect(() => {
    api<UsageTimeline>(`/usage/timeline?request_ref=${requestRef}`)
      .then(setData)
      .catch((e) => setError(e.message))
  }, [requestRef])

  const req = data?.request
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        size="lg"
        title="Request timeline"
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
            {req.trace_id && (
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                <span className="shrink-0">trace</span>
                <CopyMono text={req.trace_id} label="trace ID" />
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
