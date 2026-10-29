import { Fragment, useEffect, useMemo, useState } from "react"
import { ChevronDown, ChevronRight, GripVertical, Plus, Power, Search, SlidersHorizontal, Trash2, Unlink, X } from "lucide-react"
import { toast } from "sonner"
import {
  DndContext,
  closestCenter,
  KeyboardSensor,
  MouseSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from "@dnd-kit/core"
import {
  arrayMove,
  SortableContext,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from "@dnd-kit/sortable"
import { CSS } from "@dnd-kit/utilities"
import { api } from "../api"
import { notifyDeferredSurgery, notifyDeferredSurgeryMany } from "@/lib/cascade"
import { EmptyState, ErrorFlash, IconAction, Layout, Loading } from "../components"
import { ComboboxSingle } from "../components/combobox"
import { Pagination, useClientPagination } from "../components/pagination"
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
import { Alert } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Model, Provider, ProviderModel, StateBadge } from "./shared"
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Dialog, DialogContent, DialogFooter } from "@/components/ui/dialog"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
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
import { Textarea } from "@/components/ui/textarea"
import { Tooltip } from "@/components/ui/tooltip"

// Older rows may carry the literal string "undefined" from an earlier seeding
// bug; treat empty/missing the same and fall back to the public name.
function upstreamLabel(upstream: string | null, publicName: string) {
  return upstream && upstream !== "undefined" ? upstream : publicName
}

/** Capability flags for a public model name (model_capabilities settings
 *  key). Only vision gates janus-auto routing today; the rest are
 *  recorded for future capability-aware routing. Shared by the bind
 *  modal (create-time) and the tune dialog (edit existing). */
const MODEL_CAPS: [string, string][] = [
  ["vision", "Vision (images)"],
  ["reasoning", "Reasoning"],
  ["tools", "Tool calling"],
  ["file_input", "File input (PDF)"],
  ["image_gen", "Image generation"],
]

export type ModelLimits = { context_length?: number | null; max_output_tokens?: number | null }

/** Curated token limits for a public model name (model_limits settings
 *  key). Empty input = null = remove the curated value so the provider
 *  catalog / models.dev snapshot shows through. Shared by the bind modal
 *  and the tune dialog. */
function LimitsFields({
  value,
  onChange,
}: {
  value: ModelLimits
  onChange: (v: ModelLimits) => void
}) {
  const num = (raw: string) => {
    const n = Math.floor(Number(raw))
    return raw.trim() !== "" && Number.isFinite(n) && n > 0 ? n : null
  }
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      <Field>
        <FieldLabel htmlFor="limits-context">Context window (tokens)</FieldLabel>
        <Input
          id="limits-context"
          type="number"
          min={1}
          placeholder="catalog"
          value={value.context_length ?? ""}
          onChange={(e) => onChange({ ...value, context_length: num(e.target.value) })}
        />
      </Field>
      <Field>
        <FieldLabel htmlFor="limits-output">Max output (tokens)</FieldLabel>
        <Input
          id="limits-output"
          type="number"
          min={1}
          placeholder="catalog"
          value={value.max_output_tokens ?? ""}
          onChange={(e) => onChange({ ...value, max_output_tokens: num(e.target.value) })}
        />
      </Field>
    </div>
  )
}

type BindingRow = {
  key: string
  model: Model
  route: Model["routes"][number]
}

export type LocalJudgeCfg = {
  endpoint: string
  artifact: string
  artifact_url: string | null
  artifact_sha256: string | null
  timeout_ms: number
  local_max_inflight: number
  ensure_generation: number
}

export type AutoCfg = {
  model: string
  judge_backend: "off" | "online" | "local"
  judge_model: string | null
  local_judge: LocalJudgeCfg
  tiers: { fast: string[]; big: string[]; flagship: string[] }
  default_tier: string
  fast_ctx_tokens: number | null
  big_ctx_tokens: number | null
  max_ctx_tokens: number | null
  judge_timeout_ms: number
  cache_ttl_sec: number
  markers: string[]
  /** D11: after key failover exhausts, try next same-tier name (default off). */
  tier_failover_enabled: boolean
  /** Cap distinct names attempted per request; gateway clamps 1–8. */
  tier_failover_max_names: number
}


/** A public name whose row is disabled. D1 retires a model by DISABLING its
 * row (never deleting), so the name stays listed with its prices, usage and
 * re-binding and is restored automatically on provider re-enable / route add.
 * The badge is what lets an operator tell "off because its provider went
 * away" from "never existed" — a silently missing name would look the same
 * as a name that was never bound. */
function RetiredBadge() {
  return (
    <Tooltip content="Retired: this public name is disabled — normally because its last provider route or listing went away. The row is kept (prices, usage, re-binding) and restored automatically when a provider is re-enabled or a route is added. While retired the router does not serve it.">
      <Badge variant="warning" className="cursor-help text-[11px]">
        retired
      </Badge>
    </Tooltip>
  )
}

/** One binding row. showName=true renders the public-name cell (single-
 *  binding models); showName=false renders an indented child under its
 *  group header. All per-binding controls live here. */
function BindingRowView({
  r,
  showName,
  selected,
  toggleOne,
  setTune,
  act,
  setPendingUnbind,
}: {
  r: BindingRow
  showName: boolean
  selected: Set<string>
  toggleOne: (key: string, on: boolean) => void
  setTune: (r: BindingRow) => void
  act: (fn: () => Promise<unknown>, ok: string) => Promise<void>
  setPendingUnbind: (r: BindingRow) => void
}) {
  return (
    <TableRow data-state={selected.has(r.key) ? "selected" : undefined}>
      <TableCell>
        <Checkbox
          aria-label={`Select ${r.model.name} via ${r.route.provider_name ?? r.route.provider_id}`}
          checked={selected.has(r.key)}
          onCheckedChange={(v) => toggleOne(r.key, v === true)}
        />
      </TableCell>
      {showName ? (
        <TableCell className="max-w-64 font-medium">
          <div className="flex min-w-0 items-center gap-2">
            <span className="truncate font-mono text-[13px]" title={r.model.name}>{r.model.name}</span>
            {!r.model.enabled && <RetiredBadge />}
          </div>
        </TableCell>
      ) : (
        <TableCell className="text-muted-foreground">
          <span className="pl-8 text-[11px]">└</span>
        </TableCell>
      )}
      <TableCell className="max-w-64">
        <div className="flex min-w-0 flex-col gap-0.5">
          <span className="truncate text-[13px]">
            {r.route.provider_name ?? r.route.provider_id}
          </span>
          {upstreamLabel(r.route.upstream_model_id, r.model.name) !==
            (r.route.provider_name ?? r.route.provider_id) && (
            <span className="font-mono text-[11px] text-muted-foreground">
              {upstreamLabel(r.route.upstream_model_id, r.model.name)}
            </span>
          )}
        </div>
      </TableCell>
      <TableCell className="font-mono text-xs tabular-nums text-muted-foreground">
        <button
          type="button"
          title="Adjust priority / weight"
          aria-label={`Adjust priority and weight for ${r.model.name} via ${r.route.provider_name ?? r.route.provider_id}`}
          onClick={() => setTune(r)}
          className="inline-flex min-h-8 min-w-8 items-center justify-center rounded px-2 transition-colors hover:bg-accent hover:text-foreground"
        >
          {r.route.priority}
        </button>
      </TableCell>
      <TableCell className="font-mono text-xs tabular-nums text-muted-foreground">
        <button
          type="button"
          title="Adjust priority / weight"
          aria-label={`Adjust priority and weight for ${r.model.name} via ${r.route.provider_name ?? r.route.provider_id}`}
          onClick={() => setTune(r)}
          className="inline-flex min-h-8 min-w-8 items-center justify-center rounded px-2 transition-colors hover:bg-accent hover:text-foreground"
        >
          {r.route.weight}
        </button>
      </TableCell>
      <TableCell>
        <StateBadge enabled={r.route.enabled} />
      </TableCell>
      <TableCell>
        <div className="flex items-center justify-end gap-1">
          <IconAction label="Tune" onClick={() => setTune(r)}>
            <SlidersHorizontal />
          </IconAction>
          <IconAction
            label={r.route.enabled ? "Disable" : "Enable"}
            onClick={() =>
              act(
                () =>
                  api(
                    `/models/${r.route.model_id}/routes/${r.route.provider_id}/${r.route.enabled ? "disable" : "enable"}`,
                    { method: "POST", body: {} },
                  ),
                r.route.enabled ? "Binding disabled" : "Binding enabled",
              )
            }
          >
            <Power />
          </IconAction>
          <IconAction label="Unbind" destructive onClick={() => setPendingUnbind(r)}>
            <Unlink />
          </IconAction>
        </div>
      </TableCell>
    </TableRow>
  )
}

export function RouterPage() {
  const [models, setModels] = useState<Model[]>([])
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [busy, setBusy] = useState(false)
  const [bindOpen, setBindOpen] = useState(false)
  const [confirmUnbind, setConfirmUnbind] = useState(false)
  const [pendingUnbind, setPendingUnbind] = useState<BindingRow | null>(null)
  const [delModel, setDelModel] = useState<Model | null>(null)
  const [auto, setAuto] = useState<AutoCfg | null>(null)
  const [autoSource, setAutoSource] = useState("")
  const [tune, setTune] = useState<BindingRow | null>(null)

  const load = () =>
    Promise.all([api("/models"), api("/providers")])
      .then(([m, p]) => {
        setModels(m.models)
        setProviders(p.providers)
        setLoaded(true)
        setError("")
        setSelected(new Set())
      })
      .catch((e) => {
        setError(e.message)
        // Never leave a selection pointing at stale rows.
        setSelected(new Set())
      })

  const applyAutoResponse = (r: { config: AutoCfg; source: string }) => {
    setAuto(r.config)
    setAutoSource(r.source)
  }

  useEffect(() => {
    load()
    api("/settings/auto-router").then(applyAutoResponse).catch(() => {})
  }, [])

  const rows = useMemo<BindingRow[]>(
    () =>
      models.flatMap((model) =>
        model.routes.map((route) => ({
          key: `${route.model_id}:${route.provider_id}`,
          model,
          route,
        })),
      ),
    [models],
  )
  const unbound = useMemo(() => models.filter((m) => m.routes.length === 0), [models])

  const [rowFilter, setRowFilter] = useState("")
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const needle = rowFilter.trim().toLowerCase()
  const fRows = useMemo(
    () =>
      needle
        ? rows.filter(
            (r) =>
              r.model.name.toLowerCase().includes(needle) ||
              (r.route.provider_name ?? String(r.route.provider_id)).toLowerCase().includes(needle) ||
              upstreamLabel(r.route.upstream_model_id, r.model.name)
                .toLowerCase()
                .includes(needle),
          )
        : rows,
    [rows, needle],
  )
  const fUnbound = useMemo(
    () => (needle ? unbound.filter((m) => m.name.toLowerCase().includes(needle)) : unbound),
    [unbound, needle],
  )
  // Group rows by public model (fRows is already in model order). Groups
  // and unbound names are the pagination units, so one model's bindings
  // never split across pages; the group row expands to its route rows.
  const groups = useMemo(() => {
    const out: { model: Model; rows: BindingRow[] }[] = []
    for (const r of fRows) {
      const last = out[out.length - 1]
      if (last && last.model.id === r.model.id) last.rows.push(r)
      else out.push({ model: r.model, rows: [r] })
    }
    return out
  }, [fRows])
  const combined = useMemo(
    () => [
      ...groups.map((g) => ({ kind: "group" as const, g })),
      ...fUnbound.map((m) => ({ kind: "unbound" as const, m })),
    ],
    [groups, fUnbound],
  )
  const { slice, pageCount, page: safePage, total } = useClientPagination(combined, pageSize, page)
  const [expanded, setExpanded] = useState<Set<number>>(new Set())
  const toggleExpanded = (id: number) =>
    setExpanded((cur) => {
      const next = new Set(cur)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  const listings = useMemo(() => {
    const out: { provider: Provider; listing: ProviderModel }[] = []
    for (const p of providers) {
      for (const l of p.models ?? []) {
        if (l.enabled) out.push({ provider: p, listing: l })
      }
    }
    return out
  }, [providers])

  const act = async (fn: () => Promise<unknown>, ok: string) => {
    try {
      const result = await fn()
      toast.success(ok)
      // Cascade spec §5.3: disabling/deleting a name (and a bind that revives
      // a retired one) can queue the tier-list rewrite when the router tier
      // lock is busy. Surface the queue instead of a bare success.
      notifyDeferredSurgery(result)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  const toggleOne = (key: string, on: boolean) =>
    setSelected((cur) => {
      const next = new Set(cur)
      if (on) next.add(key)
      else next.delete(key)
      return next
    })

  const allSelected = fRows.length > 0 && fRows.every((r) => selected.has(r.key))
  const headerState = allSelected
    ? true
    : fRows.some((r) => selected.has(r.key))
      ? ("indeterminate" as const)
      : false

  const bulk = async (op: "enable" | "disable" | "unbind") => {
    const targets = rows.filter((r) => selected.has(r.key))
    if (targets.length === 0) return
    setBusy(true)
    const results = await Promise.allSettled(
      targets.map((r) =>
        op === "unbind"
          ? api(`/models/${r.route.model_id}/routes/${r.route.provider_id}`, {
              method: "DELETE",
            })
          : api(`/models/${r.route.model_id}/routes/${r.route.provider_id}/${op}`, {
              method: "POST",
              body: {},
            }),
      ),
    )
    const ok = results.filter((r) => r.status === "fulfilled").length
    const failed = results.length - ok
    // Bulk route enabling can defer tier surgery too (revive_for_route):
    // allSettled hides the bodies, so read the fulfilled ones here.
    notifyDeferredSurgeryMany(
      results.filter((r) => r.status === "fulfilled").map((r) => (r as PromiseFulfilledResult<unknown>).value),
    )
    const verb = op === "unbind" ? "removed" : op === "enable" ? "enabled" : "disabled"
    if (failed > 0) {
      toast.error(`${ok} ${verb}, ${failed} failed`)
    } else {
      toast.success(`${ok} binding${ok === 1 ? "" : "s"} ${verb}`)
    }
    // The ops have settled — drop the selection even if the reload fails.
    setSelected(new Set())
    setBusy(false)
    setConfirmUnbind(false)
    await load()
  }

  const groupPower = async (g: { model: Model; rows: BindingRow[] }) => {
    const enable = !g.rows.every((r) => r.route.enabled)
    const results = await Promise.allSettled(
      g.rows.map((r) =>
        api(`/models/${r.route.model_id}/routes/${r.route.provider_id}/${enable ? "enable" : "disable"}`, {
          method: "POST",
          body: {},
        }),
      ),
    )
    const ok = results.filter((x) => x.status === "fulfilled").length
    notifyDeferredSurgeryMany(
      results.filter((x) => x.status === "fulfilled").map((x) => (x as PromiseFulfilledResult<unknown>).value),
    )
    if (ok < results.length) toast.error(`${ok} updated, ${results.length - ok} failed`)
    else toast.success(`${ok} binding${ok === 1 ? "" : "s"} ${enable ? "enabled" : "disabled"}`)
    await load()
  }

  return (
    <Layout
      title="Router"
      description="Public model names agents call, each bound to one or more provider listings."
    >
      {error && <ErrorFlash message={error} />}
      <Card className="flex h-fit max-h-full w-full flex-col self-start overflow-hidden animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle>Bindings</CardTitle>
          <CardDescription>
            One row per binding. Multi-provider names fail over by priority, then weighted
            round-robin — tune via the sliders action on a row.
          </CardDescription>
          <CardAction className="flex w-full flex-wrap items-center gap-2 @[520px]/card-header:w-auto">
            <div className="relative min-w-0 flex-1 @[520px]/card-header:flex-none">
              <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
              <Input
                id="filter-bindings"
                className="h-8 w-full pl-8 @[520px]/card-header:w-56"
                placeholder="Filter bindings"
                aria-label="Filter bindings"
                value={rowFilter}
                onChange={(e) => setRowFilter(e.target.value)}
              />
            </div>
            <Button size="sm" onClick={() => setBindOpen(true)}>
              <Plus />
              Bind listing
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="min-h-0 px-0">
          {!loaded && !error ? (
            <Loading />
          ) : loaded && rows.length === 0 && unbound.length === 0 ? (
            <EmptyState
              title="No bindings yet"
              description="Bind a provider listing to a public model name so agents can call it."
              action={
                <Button size="sm" onClick={() => setBindOpen(true)}>
                  <Plus />
                  Bind listing
                </Button>
              }
            />
          ) : loaded && combined.length === 0 ? (
            <EmptyState
              title="No matching bindings"
              description="Try a different public name, provider, or listing."
            />
          ) : (
            <div className="flex flex-col">
              {selected.size > 0 && (
                <div className="flex animate-fade-up flex-wrap items-center gap-2 border-b bg-muted/35 px-5 py-2.5">
                  <span className="text-sm font-medium tabular-nums">{selected.size} selected</span>
                  <div className="min-w-2 flex-1" />
                  <Button variant="outline" size="sm" disabled={busy} onClick={() => bulk("enable")}>Enable</Button>
                  <Button variant="outline" size="sm" disabled={busy} onClick={() => bulk("disable")}>Disable</Button>
                  <Button variant="ghost" size="sm" disabled={busy} className="text-destructive hover:bg-destructive/10 hover:text-destructive" onClick={() => setConfirmUnbind(true)}>Unbind</Button>
                  <Button variant="ghost" size="icon-xs" aria-label="Clear selection" onClick={() => setSelected(new Set())}><X /></Button>
                </div>
              )}
              <Table flush>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-8">
                      <Checkbox
                        aria-label="Select all bindings"
                        checked={headerState}
                        disabled={rows.length === 0}
                        onCheckedChange={(v) =>
                          setSelected(v === true ? new Set(fRows.map((r) => r.key)) : new Set())
                        }
                      />
                    </TableHead>
                    <TableHead>Public model</TableHead>
                    <TableHead>Provider listing</TableHead>
                    <TableHead>Priority</TableHead>
                    <TableHead>Weight</TableHead>
                    <TableHead>State</TableHead>
                    <TableHead className="text-right">Actions</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {slice.map((item) =>
                    item.kind === "group" ? (
                      item.g.rows.length === 1 ? (
                        <BindingRowView
                          key={item.g.rows[0].key}
                          r={item.g.rows[0]}
                          showName
                          selected={selected}
                          toggleOne={toggleOne}
                          setTune={setTune}
                          act={act}
                          setPendingUnbind={setPendingUnbind}
                        />
                      ) : (
                        <Fragment key={`group-${item.g.model.id}`}>
                          <TableRow
                            className="bg-muted/30"
                            data-state={
                              item.g.rows.every((r) => selected.has(r.key)) ? "selected" : undefined
                            }
                          >
                            <TableCell>
                              <Checkbox
                                aria-label={`Select all bindings of ${item.g.model.name}`}
                                checked={
                                  item.g.rows.every((r) => selected.has(r.key))
                                    ? true
                                    : item.g.rows.some((r) => selected.has(r.key))
                                      ? ("indeterminate" as const)
                                      : false
                                }
                                onCheckedChange={(v) =>
                                  setSelected((cur) => {
                                    const next = new Set(cur)
                                    for (const r of item.g.rows)
                                      v === true ? next.add(r.key) : next.delete(r.key)
                                    return next
                                  })
                                }
                              />
                            </TableCell>
                            <TableCell className="max-w-64 font-medium">
                              <div className="flex min-w-0 items-center gap-2">
                                <Button
                                  type="button"
                                  variant="ghost"
                                  size="icon-xs"
                                  aria-label={expanded.has(item.g.model.id) ? "Collapse" : "Expand"}
                                  aria-expanded={expanded.has(item.g.model.id)}
                                  onClick={() => toggleExpanded(item.g.model.id)}
                                >
                                  {expanded.has(item.g.model.id) ? <ChevronDown /> : <ChevronRight />}
                                </Button>
                                <span className="truncate font-mono text-[13px]" title={item.g.model.name}>
                                  {item.g.model.name}
                                </span>
                                <Badge variant="secondary" className="text-[11px]">
                                  {item.g.rows.length} bindings
                                </Badge>
                                {!item.g.model.enabled && <RetiredBadge />}
                              </div>
                            </TableCell>
                            <TableCell className="max-w-64 text-muted-foreground">
                              <span className="truncate text-[13px]">
                                {item.g.rows[0].route.provider_name ?? item.g.rows[0].route.provider_id}
                                {item.g.rows.length > 1 && ` +${item.g.rows.length - 1} more`}
                              </span>
                            </TableCell>
                            <TableCell className="text-muted-foreground">—</TableCell>
                            <TableCell className="text-muted-foreground">—</TableCell>
                            <TableCell>
                              {item.g.rows.every((r) => r.route.enabled) ? (
                                <StateBadge enabled />
                              ) : item.g.rows.every((r) => !r.route.enabled) ? (
                                <StateBadge enabled={false} />
                              ) : (
                                <Badge variant="warning" className="text-[11px]">mixed</Badge>
                              )}
                            </TableCell>
                            <TableCell>
                              <div className="flex items-center justify-end gap-1">
                                <IconAction
                                  label={
                                    item.g.rows.every((r) => r.route.enabled)
                                      ? "Disable all bindings"
                                      : "Enable all bindings"
                                  }
                                  onClick={() => groupPower(item.g)}
                                >
                                  <Power />
                                </IconAction>
                              </div>
                            </TableCell>
                          </TableRow>
                          {expanded.has(item.g.model.id) &&
                            item.g.rows.map((r) => (
                              <BindingRowView
                                key={r.key}
                                r={r}
                                showName={false}
                                selected={selected}
                                toggleOne={toggleOne}
                                setTune={setTune}
                                act={act}
                                setPendingUnbind={setPendingUnbind}
                              />
                            ))}
                        </Fragment>
                      )
                    ) : (
                      <TableRow key={`unbound-${item.m.id}`} className="text-muted-foreground">
                        <TableCell>
                          <Checkbox disabled aria-label={`${item.m.name} has no bindings to select`} />
                        </TableCell>
                        <TableCell className="font-medium text-foreground">
                          <div className="flex items-center gap-2">
                            <span className="font-mono text-[13px]">{item.m.name}</span>
                            <Badge variant="warning" className="text-[11px]">
                              unbound
                            </Badge>
                            {!item.m.enabled && <RetiredBadge />}
                          </div>
                        </TableCell>
                        <TableCell>—</TableCell>
                        <TableCell>—</TableCell>
                        <TableCell>—</TableCell>
                        <TableCell>
                          <StateBadge enabled={item.m.enabled} />
                        </TableCell>
                        <TableCell>
                          <div className="flex items-center justify-end gap-1">
                            <IconAction
                              label={item.m.enabled ? "Disable name" : "Enable name"}
                              onClick={() =>
                                act(
                                  () =>
                                    api(`/models/${item.m.id}/${item.m.enabled ? "disable" : "enable"}`, {
                                      method: "POST",
                                      body: {},
                                    }),
                                  item.m.enabled ? "Model disabled" : "Model enabled",
                                )
                              }
                            >
                              <Power />
                            </IconAction>
                            <IconAction label="Delete name" destructive onClick={() => setDelModel(item.m)}>
                              <Trash2 />
                            </IconAction>
                          </div>
                        </TableCell>
                      </TableRow>
                    ),
                  )}
                </TableBody>
              </Table>
              <Pagination
                page={safePage}
                pageCount={pageCount}
                total={total}
                pageSize={pageSize}
                onPageChange={setPage}
                onPageSizeChange={(n) => {
                  setPageSize(n)
                  setPage(1)
                }}
              />
            </div>
          )}
        </CardContent>
      </Card>

      {auto && (
        <AutoRouterCard
          cfg={auto}
          source={autoSource}
          boundModels={models.map((m) => m.name)}
          listingNames={listings.map((x) => `${x.provider.name}/${x.listing.name}`)}
          onChange={setAuto}
          reload={() => api("/settings/auto-router").then(applyAutoResponse).catch(() => {})}
        />
      )}

      <LimitsCoverageCard />

      {confirmUnbind && (
        <AlertDialog open onOpenChange={(o) => !o && setConfirmUnbind(false)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Unbind {selected.size} listing{selected.size === 1 ? "" : "s"}?
              </AlertDialogTitle>
              <AlertDialogDescription>
                Public names with no remaining bindings will answer <code>no_route</code> to
                agents.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                disabled={busy}
                onClick={() => bulk("unbind")}
              >
                Unbind {selected.size}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}

      {pendingUnbind && (
        <AlertDialog open onOpenChange={(o) => !o && setPendingUnbind(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Unbind this listing?</AlertDialogTitle>
              <AlertDialogDescription>
                <span className="font-mono">{pendingUnbind.model.name}</span> will no longer route
                to <span className="font-mono">{pendingUnbind.route.provider_name ?? pendingUnbind.route.provider_id}</span>.
                If it was the last binding for that public name, agents calling it start getting{" "}
                <code>no_route</code>.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                onClick={() => {
                  const row = pendingUnbind
                  setPendingUnbind(null)
                  void act(
                    () =>
                      api(`/models/${row.route.model_id}/routes/${row.route.provider_id}`, {
                        method: "DELETE",
                      }),
                    "binding removed",
                  )
                }}
              >
                Unbind
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}

      {delModel && (
        <DeleteModelDialog
          model={delModel}
          onClose={() => setDelModel(null)}
          onDeleted={async () => {
            setDelModel(null)
            toast.success("model deleted")
            await load()
          }}
        />
      )}

      {tune && (
        <TuneDialog
          row={tune}
          onClose={() => setTune(null)}
          onSave={async (weight, priority, caps, limits) => {
            await act(async () => {
              await api(`/models/${tune.route.model_id}/routes/${tune.route.provider_id}/rebalance`, {
                method: "POST",
                body: { weight, priority },
              })
              if (caps) {
                await api("/settings/model-capabilities", {
                  method: "PUT",
                  body: { name: tune.model.name, capabilities: caps },
                })
                toast.success("capabilities saved")
              }
              if (limits) {
                await api("/settings/model-limits", {
                  method: "PUT",
                  body: { name: tune.model.name, limits },
                })
                toast.success("token limits saved")
              }
            }, "binding updated")
            setTune(null)
          }}
        />
      )}

      {bindOpen && (
        <BindModal
          models={models}
          listings={listings}
          onClose={() => setBindOpen(false)}
          onDone={async (publicName, listing, caps, limits) => {
            await act(async () => {
              let model = models.find((m) => m.name === publicName)
              if (!model) {
                const created = await api("/models", {
                  method: "POST",
                  body: { name: publicName },
                })
                model = { id: created.id, name: publicName, enabled: true, routes: [] }
              }
              const res = await api(`/models/${model.id}/routes`, {
                method: "POST",
                body: {
                  provider_id: listing.provider.id,
                  upstream_model_id: listing.listing.name,
                  weight: 1,
                  priority: 0,
                },
              })
              // Bind-time entitlement validation (spec A.5): a partial
              // matrix binds, but the warning must reach the operator
              // (deny-on-all is rejected with entitlement_denied upstream).
              for (const w of res.warnings ?? []) toast.warning(`Bound with warning: ${w}`)
              if (caps) {
                await api("/settings/model-capabilities", {
                  method: "PUT",
                  body: { name: publicName, capabilities: caps },
                })
                toast.success("capabilities saved")
              }
              if (limits) {
                await api("/settings/model-limits", {
                  method: "PUT",
                  body: { name: publicName, limits },
                })
                toast.success("token limits saved")
              }
              setBindOpen(false)
              // A bind can REVIVE a model the cascade retired (D2/§4) and
              // therefore defer tier surgery — hand the body back to `act`.
              return res
            }, "listing bound")
          }}
        />
      )}
    </Layout>
  )
}

function TuneDialog({
  row,
  onClose,
  onSave,
}: {
  row: BindingRow
  onClose: () => void
  onSave: (
    weight: number,
    priority: number,
    caps: Record<string, boolean> | null,
    limits: ModelLimits | null,
  ) => void
}) {
  const [weight, setWeight] = useState(row.route.weight)
  const [priority, setPriority] = useState(row.route.priority)
  const [caps, setCaps] = useState<Record<string, boolean>>({})
  const [capsLoaded, setCapsLoaded] = useState<Record<string, boolean>>({})
  const [limits, setLimits] = useState<ModelLimits>({})
  const [limitsLoaded, setLimitsLoaded] = useState<ModelLimits>({})
  const name = row.model.name
  useEffect(() => {
    api("/settings/model-capabilities")
      .then((r) => {
        const cur = r.capabilities?.[name] ?? {}
        setCaps(cur)
        setCapsLoaded(cur)
      })
      .catch(() => {})
  }, [name])
  useEffect(() => {
    api("/settings/model-limits")
      .then((r) => {
        const cur = (r.limits?.[name] ?? {}) as ModelLimits
        setLimits(cur)
        setLimitsLoaded(cur)
      })
      .catch(() => {})
  }, [name])
  const capsDirty =
    JSON.stringify({
      ...Object.fromEntries(MODEL_CAPS.map(([k]) => [k, false])),
      ...capsLoaded,
    }) !==
    JSON.stringify({ ...Object.fromEntries(MODEL_CAPS.map(([k]) => [k, false])), ...caps })
  const limitsDirty =
    JSON.stringify({ context_length: null, max_output_tokens: null, ...limitsLoaded }) !==
    JSON.stringify({ context_length: null, max_output_tokens: null, ...limits })
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        title="Adjust binding"
        description={
          <>
            <span className="font-mono">{row.model.name}</span>
            {" → "}
            {row.route.provider_name ?? row.route.provider_id}
            {" / "}
            <span className="font-mono">
              {upstreamLabel(row.route.upstream_model_id, row.model.name)}
            </span>
          </>
        }
      >
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="tune-weight">Weight</FieldLabel>
            <Input
              id="tune-weight"
              type="number"
              min={1}
              value={weight}
              autoFocus
              onChange={(e) => setWeight(Math.max(1, Number(e.target.value) || 1))}
            />
            <FieldDescription>
              Traffic share within the same priority (weighted round-robin).
            </FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="tune-priority">Priority</FieldLabel>
            <Input
              id="tune-priority"
              type="number"
              value={priority}
              onChange={(e) => setPriority(Number(e.target.value) || 0)}
            />
            <FieldDescription>
              Lower priorities are tried first; failover moves to the next one.
            </FieldDescription>
          </Field>
          <Field>
            <FieldLabel>Capabilities</FieldLabel>
            <div className="flex flex-wrap gap-3">
              {MODEL_CAPS.map(([key, label]) => (
                <label key={key} className="flex items-center gap-1.5 text-xs">
                  <Checkbox
                    checked={Boolean(caps[key])}
                    onCheckedChange={(v) => setCaps((c) => ({ ...c, [key]: v === true }))}
                  />
                  {label}
                </label>
              ))}
            </div>
            <FieldDescription>
              Flags apply to <span className="font-mono">{row.model.name}</span> (the public
              name the janus-auto walk routes by), not to this one binding. Only{" "}
              <span className="font-medium">Vision</span> gates routing today.
            </FieldDescription>
          </Field>
          <Field>
            <FieldLabel>Token limits (curated)</FieldLabel>
            <LimitsFields value={limits} onChange={setLimits} />
            <FieldDescription>
              Overrides the provider catalog and the models.dev snapshot for{" "}
              <span className="font-mono">{row.model.name}</span>; empty falls back to them.
              Advertised on <span className="font-mono">/v1/models</span>.
            </FieldDescription>
          </Field>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={weight < 1}
            onClick={() =>
              onSave(weight, priority, capsDirty ? caps : null, limitsDirty ? limits : null)
            }
          >
            Save
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function BindModal({
  models,
  listings,
  onClose,
  onDone,
}: {
  models: Model[]
  listings: { provider: Provider; listing: ProviderModel }[]
  onClose: () => void
  onDone: (
    publicName: string,
    listing: { provider: Provider; listing: ProviderModel },
    caps: Record<string, boolean> | null,
    limits: ModelLimits | null,
  ) => void
}) {
  const [publicName, setPublicName] = useState("")
  const [picked, setPicked] = useState<string | null>(null)
  // Capability flags live on the public name (the janus-auto walk routes
  // by name). Loaded once for the whole override map; edited flags are
  // merged per name by PUT /api/settings/model-capabilities.
  const [capMap, setCapMap] = useState<Record<string, Record<string, boolean>>>({})
  const [caps, setCaps] = useState<Record<string, boolean>>({})
  const [limits, setLimits] = useState<ModelLimits>({})
  const [limitsLoaded, setLimitsLoaded] = useState<Record<string, ModelLimits>>({})
  const CAPS = MODEL_CAPS
  useEffect(() => {
    api("/settings/model-capabilities")
      .then((r) => setCapMap(r.capabilities ?? {}))
      .catch(() => {})
  }, [])
  useEffect(() => {
    api("/settings/model-limits")
      .then((r) => setLimitsLoaded((r.limits ?? {}) as Record<string, ModelLimits>))
      .catch(() => {})
  }, [])
  const name = publicName.trim()
  const existing = capMap[name]
  const capsDirty =
    JSON.stringify({ ...Object.fromEntries(CAPS.map(([k]) => [k, false])), ...(existing ?? {}) }) !==
    JSON.stringify({ ...Object.fromEntries(CAPS.map(([k]) => [k, false])), ...caps })
  const limitsDirty =
    JSON.stringify({
      context_length: null,
      max_output_tokens: null,
      ...(limitsLoaded[name] ?? {}),
    }) !== JSON.stringify({ context_length: null, max_output_tokens: null, ...limits })
  useEffect(() => {
    setCaps(capMap[name] ?? {})
  }, [name, capMap])
  useEffect(() => {
    setLimits(limitsLoaded[name] ?? {})
  }, [name, limitsLoaded])
  // Providers already bound to the target public name are hidden — a
  // duplicate (model, provider) route would be rejected by the DB anyway.
  const target = models.find((m) => m.name === publicName.trim())
  const boundProviders = new Set((target?.routes ?? []).map((r) => r.provider_id))
  const available = listings.filter((x) => !boundProviders.has(x.provider.id))
  const label = (x: { provider: Provider; listing: ProviderModel }) =>
    `${x.provider.name} / ${x.listing.name}`
  const byLabel = new Map(available.map((x) => [label(x), x]))
  const choice = picked ? byLabel.get(picked) : undefined
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        title="Bind listing"
        description="Route a public model name to a provider listing."
      >
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="bind-public-name">Public model name</FieldLabel>
            <ComboboxSingle
              id="bind-public-name"
              value={publicName.trim() || null}
              options={models.map((m) => m.name)}
              onChange={(v) => setPublicName(v ?? "")}
              placeholder="Pick existing or type a new name…"
              allowCreate
            />
            <FieldDescription>
              What agents send as <code>model</code>. Created if it does not exist.
            </FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="bind-listing">Provider listing</FieldLabel>
            <ComboboxSingle
              id="bind-listing"
              value={picked}
              options={[...byLabel.keys()]}
              onChange={(v) => {
                setPicked(v)
                // Common case: the public name mirrors the listing name.
                if (!publicName.trim() && v) setPublicName(v.split(" / ").slice(1).join(" / "))
              }}
              placeholder={`Pick from ${available.length} listings…`}
              groupBy={(v) => v.split(" / ")[0]}
            />
            <FieldDescription>
              New bindings start at priority 0, weight 1.
            </FieldDescription>
          </Field>
          {publicName.trim() && choice && (
            <p className="rounded-md border border-primary/25 bg-primary/[0.06] px-3 py-2 font-mono text-xs">
              model=&quot;{publicName.trim()}&quot; → {choice.provider.name} /{" "}
              {choice.listing.name}
            </p>
          )}
          {name && (
            <Field>
              <FieldLabel>Capabilities</FieldLabel>
              <div className="flex flex-wrap gap-3">
                {CAPS.map(([key, label]) => (
                  <label key={key} className="flex items-center gap-1.5 text-xs">
                    <Checkbox
                      checked={Boolean(caps[key])}
                      onCheckedChange={(v) =>
                        setCaps((c) => ({ ...c, [key]: v === true }))
                      }
                    />
                    {label}
                  </label>
                ))}
              </div>
              <FieldDescription>
                Only <span className="font-medium">Vision</span> gates routing today (janus-auto
                image requests). The rest are recorded for future capability-aware routing.
              </FieldDescription>
            </Field>
          )}
          {name && (
            <Field>
              <FieldLabel>Token limits (curated)</FieldLabel>
              <LimitsFields value={limits} onChange={setLimits} />
              <FieldDescription>
                Overrides the provider catalog and the models.dev snapshot; empty falls back
                to them. Advertised on <span className="font-mono">/v1/models</span>.
              </FieldDescription>
            </Field>
          )}
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={!publicName.trim() || !choice}
            onClick={() =>
              choice &&
              onDone(publicName.trim(), choice, capsDirty ? caps : null, limitsDirty ? limits : null)
            }
          >
            <Plus />
            Bind
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/** Single sortable tier member row with drag handle + remove button. */
function SortableTierItem({
  name,
  onRemove,
  title,
}: {
  name: string
  onRemove: (name: string) => void
  title: string
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: name })
  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.5 : 1,
    zIndex: isDragging ? 10 : undefined,
  }
  return (
    <li
      ref={setNodeRef}
      style={style}
      className="flex items-center gap-2 border-b border-border/60 px-3 py-1.5 last:border-b-0"
    >
      <button
        type="button"
        aria-label={`Drag to reorder ${name}`}
        title="Drag to reorder"
        className="grid size-6 shrink-0 cursor-grab touch-none place-items-center rounded text-muted-foreground hover:text-foreground active:cursor-grabbing focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"
        {...attributes}
        {...listeners}
      >
        <GripVertical className="size-3.5" />
      </button>
      <span className="min-w-0 flex-1 truncate font-mono text-xs">{name}</span>
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        aria-label={`Remove ${name} from ${title}`}
        className="shrink-0 text-muted-foreground hover:text-destructive"
        onClick={() => onRemove(name)}
      >
        <X />
      </Button>
    </li>
  )
}

/** Tier member list: drag-to-reorder rows in failover walk order; a footer
 *  combobox adds from the remaining bindings. No checkboxes — membership
 *  is explicit (add / delete), order is the failover walk order. */
function TierPanel({
  tier,
  options,
  members,
  onAdd,
  onRemove,
  onReorder,
}: {
  tier: "fast" | "big" | "flagship"
  options: string[]
  members: string[]
  onAdd: (name: string) => void
  onRemove: (name: string) => void
  onReorder: (oldIndex: number, newIndex: number) => void
}) {
  const memberSet = new Set(members)
  const others = options.filter((n) => !memberSet.has(n))
  const title = `${tier[0].toUpperCase()}${tier.slice(1)} tier`
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 5 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 250, tolerance: 5 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event
    if (over && active.id !== over.id) {
      const oldIndex = members.indexOf(active.id as string)
      const newIndex = members.indexOf(over.id as string)
      if (oldIndex >= 0 && newIndex >= 0) onReorder(oldIndex, newIndex)
    }
  }

  return (
    <section
      aria-label={`${title} members`}
      className="flex h-64 flex-col overflow-hidden rounded-md border"
    >
      <header className="flex items-center justify-between border-b bg-muted/40 px-3 py-2">
        <span className="text-xs font-medium">{title}</span>
        <span className="text-xs text-muted-foreground">
          {members.length} member{members.length === 1 ? "" : "s"}
        </span>
      </header>
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
        <SortableContext items={members} strategy={verticalListSortingStrategy}>
          <ul className="min-h-0 flex-1 overflow-y-auto">
            {members.map((name) => (
              <SortableTierItem key={name} name={name} onRemove={onRemove} title={title} />
            ))}
            {members.length === 0 && (
              <li className="px-3 py-4 text-xs text-muted-foreground">
                Drag models here or add below.
              </li>
            )}
          </ul>
        </SortableContext>
      </DndContext>
      <footer className="border-t p-2">
        <ComboboxSingle
          value={null}
          options={others}
          onChange={(v) => v && onAdd(v)}
          placeholder="Add model…"
          className="w-full"
          id={`add-${tier}`}
        />
      </footer>
    </section>
  )
}

function AutoRouterCard({
  cfg,
  source,
  boundModels,
  listingNames,
  onChange,
  reload,
}: {
  cfg: AutoCfg
  source: string
  boundModels: string[]
  listingNames: string[]
  onChange: (c: AutoCfg) => void
  reload: () => void
}) {
  const [saving, setSaving] = useState(false)

  const setBackend = (backend: "off" | "online") => {
    onChange({ ...cfg, judge_backend: backend })
  }

  const save = async () => {
    setSaving(true)
    try {
      await api("/settings/auto-router", { method: "PUT", body: cfg })
      toast.success("auto-router saved — gateways reload within seconds")
      reload()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setSaving(false)
    }
  }
  const num = (v: string): number | null => {
    const t = v.trim()
    return t === "" ? null : Number(t)
  }
  return (
    <Card className="overflow-hidden">
      <CardHeader className="border-b bg-muted/15">
        <CardTitle>Auto router · {cfg.model}</CardTitle>
        <CardDescription>
          Task adjudication for <code>{cfg.model}</code>: tier members, judge, and
          thresholds. Hot-reloaded by every gateway node on save.
          {source === "default" && " (currently defaults — not yet saved)"}
        </CardDescription>
        <CardAction>
          <Button size="sm" disabled={saving} onClick={save}>
            {saving ? "Saving…" : "Save auto-router"}
          </Button>
        </CardAction>
      </CardHeader>
      <CardContent>
        {cfg.tiers.fast.length + cfg.tiers.big.length + cfg.tiers.flagship.length ===
          0 && (
          <Alert className="mb-4">
            <p>
              <code>{cfg.model}</code> is not configured — calls to it return{" "}
              <code>404 no_route</code> and the model stays hidden from{" "}
              <code>/v1/models</code> until at least one tier has members.
            </p>
          </Alert>
        )}
        <div className="grid gap-4 lg:grid-cols-3">
          {(["fast", "big", "flagship"] as const).map((tier) => (
            <TierPanel
              key={tier}
              tier={tier}
              options={boundModels}
              members={cfg.tiers[tier]}
              onAdd={(name) => {
                // tiers are mutually exclusive — joining one tier
                // removes the model from the other two
                const cleared = Object.fromEntries(
                  Object.entries(cfg.tiers).map(([t, names]) => [
                    t,
                    t === tier ? [...names, name] : names.filter((n) => n !== name),
                  ]),
                ) as AutoCfg["tiers"]
                onChange({ ...cfg, tiers: cleared })
              }}
              onRemove={(name) =>
                onChange({
                  ...cfg,
                  tiers: {
                    ...cfg.tiers,
                    [tier]: cfg.tiers[tier].filter((n) => n !== name),
                  },
                })
              }
              onReorder={(oldIndex, newIndex) => {
                // Tier order IS the failover walk order.
                const next = arrayMove(cfg.tiers[tier], oldIndex, newIndex)
                onChange({ ...cfg, tiers: { ...cfg.tiers, [tier]: next } })
              }}
            />
          ))}
        </div>
        <Field className="mt-4">
          <FieldLabel>Judge backend</FieldLabel>
          <div className="flex flex-wrap gap-2" role="group" aria-label="Judge backend">
            {(
              [
                ["off", "Off (rules only)"],
                ["online", "Online LLM / Decisions"],
              ] as const
            ).map(([value, label]) => (
              <Button
                key={value}
                type="button"
                size="sm"
                variant={cfg.judge_backend === value ? "default" : "outline"}
                aria-pressed={cfg.judge_backend === value}
                onClick={() => setBackend(value)}
              >
                {label}
              </Button>
            ))}
          </div>
          <FieldDescription>
            Online prefers a Decisions-protocol listing for the judge model (System One), then falls
            back to chat.
          </FieldDescription>
        </Field>

        {cfg.judge_backend === "local" && (
          <Alert className="mt-2">
            <p>
              This fleet still has <code>judge_backend=local</code>. Local judging is retired from
              the dashboard — switch to Off or Online and Save.
            </p>
            <div className="mt-2 flex flex-wrap gap-2">
              <Button type="button" size="sm" variant="outline" onClick={() => setBackend("off")}>
                Switch to Off
              </Button>
              <Button type="button" size="sm" variant="secondary" onClick={() => setBackend("online")}>
                Switch to Online
              </Button>
            </div>
          </Alert>
        )}

        <div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {cfg.judge_backend === "online" && (
          <Field>
            <FieldLabel htmlFor="auto-judge-model">Judge model (required)</FieldLabel>
            <div className="flex items-center gap-1">
              <ComboboxSingle
                id="auto-judge-model"
                className="flex-1"
                options={listingNames}
                value={cfg.judge_model}
                placeholder="pick a catalog listing"
                onChange={(v) =>
                onChange({
                  ...cfg,
                  // options read "provider/listing" — the gateway routes
                  // by bare listing name, so strip the provider segment
                  judge_model: v ? v.split("/").slice(1).join("/") || v : null,
                })
              }
              />
              {cfg.judge_model && (
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label="Clear judge model"
                  onClick={() => onChange({ ...cfg, judge_model: null })}
                >
                  <X />
                </Button>
              )}
            </div>
          </Field>
          )}
          <Field>
            <FieldLabel htmlFor="auto-default-tier">Default tier</FieldLabel>
            <Select
              value={cfg.default_tier}
              onValueChange={(v) => onChange({ ...cfg, default_tier: v })}
            >
              <SelectTrigger id="auto-default-tier" size="sm">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="fast">fast</SelectItem>
                <SelectItem value="big">big</SelectItem>
                <SelectItem value="flagship">flagship</SelectItem>
              </SelectContent>
            </Select>
          </Field>
          <Field>
            <FieldLabel htmlFor="auto-fast-ctx">Fast &lt; tokens</FieldLabel>
            <Input
              id="auto-fast-ctx"
              type="number"
              value={cfg.fast_ctx_tokens ?? ""}
              onChange={(e) => onChange({ ...cfg, fast_ctx_tokens: num(e.target.value) })}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="auto-big-ctx">Big &gt; tokens</FieldLabel>
            <Input
              id="auto-big-ctx"
              type="number"
              value={cfg.big_ctx_tokens ?? ""}
              onChange={(e) => onChange({ ...cfg, big_ctx_tokens: num(e.target.value) })}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="auto-max-ctx">Max ctx (hard cap)</FieldLabel>
            <Input
              id="auto-max-ctx"
              type="number"
              value={cfg.max_ctx_tokens ?? ""}
              onChange={(e) => onChange({ ...cfg, max_ctx_tokens: num(e.target.value) })}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="auto-ttl">Decision cache TTL (s)</FieldLabel>
            <Input
              id="auto-ttl"
              type="number"
              value={cfg.cache_ttl_sec}
              onChange={(e) => onChange({ ...cfg, cache_ttl_sec: Number(e.target.value) })}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="auto-markers">Markers → flagship</FieldLabel>
            <Input
              id="auto-markers"
              className="font-mono text-xs"
              value={cfg.markers.join(", ")}
              onChange={(e) =>
                onChange({ ...cfg, markers: e.target.value.split(",").map((x) => x.trim()).filter(Boolean) })
              }
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="auto-model">Virtual model name</FieldLabel>
            <Input
              id="auto-model"
              className="font-mono text-xs"
              value={cfg.model}
              onChange={(e) => onChange({ ...cfg, model: e.target.value })}
            />
          </Field>
          <Field className="sm:col-span-2 lg:col-span-2">
            <div className="flex items-start gap-2.5">
              <Checkbox
                id="auto-tier-failover"
                checked={cfg.tier_failover_enabled}
                onCheckedChange={(v) =>
                  onChange({ ...cfg, tier_failover_enabled: v === true })
                }
                className="mt-0.5"
              />
              <div className="min-w-0 flex-1 space-y-2">
                <FieldLabel htmlFor="auto-tier-failover" className="cursor-pointer">
                  Same-tier next-name failover
                </FieldLabel>
                <FieldDescription>
                  After key failover exhausts, try the next model in the same tier
                  (pre-commit only; default off).
                </FieldDescription>
                <Field>
                  <FieldLabel htmlFor="auto-tier-failover-max">
                    Max names per request (1–8)
                  </FieldLabel>
                  <Input
                    id="auto-tier-failover-max"
                    type="number"
                    min={1}
                    max={8}
                    disabled={!cfg.tier_failover_enabled}
                    value={cfg.tier_failover_max_names}
                    onChange={(e) => {
                      const raw = e.target.value
                      const parsed = raw === "" ? 1 : Number(raw)
                      const clamped = Number.isFinite(parsed)
                        ? Math.max(1, Math.min(8, Math.trunc(parsed) || 1))
                        : 1
                      onChange({ ...cfg, tier_failover_max_names: clamped })
                    }}
                  />
                </Field>
              </div>
            </div>
          </Field>
        </div>
      </CardContent>
    </Card>
  )
}

function DeleteModelDialog({
  model,
  onClose,
  onDeleted,
}: {
  model: Model
  onClose: () => void
  onDeleted: () => void | Promise<void>
}) {
  const [busy, setBusy] = useState(false)

  const doDelete = async () => {
    setBusy(true)
    try {
      // Deleting a name prunes its tier memberships (spec §2); the prune can
      // be queued when the router tier lock is busy.
      const res = await api(`/models/${model.id}`, { method: "DELETE" })
      notifyDeferredSurgery(res)
      await onDeleted()
    } catch (e: any) {
      setBusy(false)
      toast.error(e.message)
    }
  }

  return (
    <AlertDialog open onOpenChange={(o) => !o && onClose()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>
            Delete model <span className="font-mono">{model.name}</span>?
          </AlertDialogTitle>
          <AlertDialogDescription>
            The public Router row and its bindings are removed. Agent-key name grants and
            provider listings for the same string are unchanged — edit Keys separately if needed.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
          <AlertDialogAction
            variant="destructive"
            disabled={busy}
            onClick={(ev) => {
              ev.preventDefault()
              void doDelete()
            }}
          >
            Delete model
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}

// --- Limits coverage (compaction readiness) --------------------------------
// Projection of GET /api/settings/model-limits/coverage: every name the
// dashboard knows, whether the gateway advertises BOTH a context window and an
// output cap, and which layer supplied each dimension. Curation happens right
// here: select rows and Curate (a typed patch) or Paste (a previewed batch),
// both applied through POST /api/settings/model-limits/bulk. Nothing is ever
// invented — the operator supplies every value, and a dry-run preview shows the
// exact diff (and the ready delta) before anything is written.

type LimitDims = { window: number | null; output: number | null }
type CoverageLayerName = "curated" | "route_min" | "listing" | "snapshot"
type CoverageStatus = "ready" | "missing_window" | "missing_output" | "missing_both"

type CoverageEntry = {
  name: string
  bound: boolean
  tiers: string[]
  window: number | null
  output: number | null
  status: CoverageStatus
  source: { window: CoverageLayerName | null; output: CoverageLayerName | null }
  layers: Record<CoverageLayerName, LimitDims>
  providers: string[]
}

type CoverageSummary = {
  names: number
  ready: number
  missing_window: number
  missing_output: number
  missing_both: number
  curated: number
  bound: number
  window_only: number
  output_only: number
}

type CoverageResponse = {
  source: string
  note: string
  summary: CoverageSummary
  entries: CoverageEntry[]
}

const COVERAGE_FILTERS = [
  { value: "not_ready", label: "Not ready" },
  { value: "ready", label: "Ready" },
  { value: "missing_window", label: "Missing window" },
  { value: "missing_output", label: "Missing output" },
  { value: "missing_both", label: "Missing both" },
  { value: "all", label: "All names" },
]

const COVERAGE_STATUS_LABEL: Record<CoverageStatus, string> = {
  ready: "Ready",
  missing_window: "Missing window",
  missing_output: "Missing output",
  missing_both: "Missing both",
}

const COVERAGE_STATUS_TONE: Record<CoverageStatus, "success" | "warning" | "destructive"> = {
  ready: "success",
  missing_window: "warning",
  missing_output: "warning",
  missing_both: "destructive",
}

// Worst-first ordering so the gaps an operator must fix lead the table.
const COVERAGE_STATUS_RANK: Record<CoverageStatus, number> = {
  missing_both: 0,
  missing_window: 1,
  missing_output: 2,
  ready: 3,
}

const COVERAGE_LAYER_LABEL: Record<CoverageLayerName, string> = {
  curated: "Curated limits",
  route_min: "Route cap",
  listing: "Provider listing",
  snapshot: "models.dev",
}

/** 128000 -> "128k", 1000000 -> "1M"; the raw number stays in the cell title. */
function formatTokenCount(n: number | null): string {
  if (n === null) return "—"
  const trim = (v: number) => String(Math.round(v * 100) / 100)
  if (n >= 1_000_000) return `${trim(n / 1_000_000)}M`
  if (n >= 1_000) return `${trim(n / 1_000)}k`
  return String(n)
}

function layerTitle(e: CoverageEntry): string {
  return (
    `curated ${JSON.stringify(e.layers.curated)} · ` +
    `route cap ${JSON.stringify(e.layers.route_min)} · ` +
    `listing ${JSON.stringify(e.layers.listing)} · ` +
    `models.dev ${JSON.stringify(e.layers.snapshot)}`
  )
}

// --- Bulk curation (POST /settings/model-limits/bulk) -----------------------
// Frozen contract: entries {name: {context_window, max_output_tokens}},
// mode dry_run | merge | replace. `before`/`after` carry each entry's effective
// curated window/output, so a context_length curation shows up under
// context_window.

type BulkDims = { context_window: number | null; max_output_tokens: number | null }
type BulkPatch = Partial<BulkDims>
type BulkMode = "dry_run" | "merge" | "replace"

type BulkDiffRow = {
  name: string
  before: BulkDims
  after: BulkDims
  status_before: CoverageStatus
  status_after: CoverageStatus
}

type BulkResponse = {
  ok: boolean
  mode: BulkMode
  applied: number
  cleared: number
  unchanged: number
  rejected: { name: string; reason: string }[]
  ready_before: number
  ready_after: number
  diff: BulkDiffRow[]
}

/** One Curate-dialog input: "" -> untouched (undefined), a positive whole
 *  number -> that value, anything else -> invalid (Apply stays disabled). */
type LimitInput = { ok: boolean; value?: number | null }

function parseLimitInput(raw: string): LimitInput {
  const v = raw.trim()
  if (v === "") return { ok: true, value: undefined }
  const n = Math.floor(Number(v))
  if (!Number.isFinite(n) || n <= 0) return { ok: false }
  return { ok: true, value: n }
}

/** Parse the Paste-limits textarea: one entry per line,
 *  `name,context_window,max_output_tokens`, separated by commas, tabs or
 *  whitespace. An empty field or `-` clears that key; an omitted field is left
 *  alone (merge semantics). Unparsable lines are returned, never dropped. */
function parsePastedLimits(text: string): {
  entries: Record<string, BulkPatch>
  bad: string[]
} {
  const entries: Record<string, BulkPatch> = {}
  const bad: string[] = []
  const toValue = (raw: string): number | null | undefined => {
    const v = raw.trim()
    if (v === "" || v === "-") return null
    const n = Math.floor(Number(v))
    return Number.isFinite(n) && n > 0 ? n : undefined
  }
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith("#")) continue
    const parts = line
      .split(/[,\t]/)
      .flatMap((chunk) => (/\s/.test(chunk) ? chunk.trim().split(/\s+/) : [chunk.trim()]))
    if (parts.length < 2 || parts.length > 3) {
      bad.push(line)
      continue
    }
    const [name, windowRaw, outputRaw] = parts
    const window = toValue(windowRaw)
    if (!name || window === undefined) {
      bad.push(line)
      continue
    }
    const entry: BulkPatch = { context_window: window }
    if (outputRaw !== undefined) {
      const output = toValue(outputRaw)
      if (output === undefined) {
        bad.push(line)
        continue
      }
      entry.max_output_tokens = output
    }
    entries[name] = entry
  }
  return { entries, bad }
}

function sameDims(a: BulkDims, b: BulkDims): boolean {
  return a.context_window === b.context_window && a.max_output_tokens === b.max_output_tokens
}

/** Dry-run result rendered before Apply: only the rows that change, plus the
 *  ready delta and any per-name rejects. */
function BulkPreview({ preview }: { preview: BulkResponse }) {
  const changed = preview.diff.filter((d) => !sameDims(d.before, d.after))
  return (
    <div className="rounded-md border border-border">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b border-border px-3 py-2 text-xs">
        <span className="font-medium">
          {changed.length} change{changed.length === 1 ? "" : "s"}
        </span>
        <span className="text-muted-foreground">{preview.unchanged} unchanged</span>
        <span className="text-muted-foreground">
          Ready {preview.ready_before} → {preview.ready_after}
        </span>
      </div>
      {changed.length > 0 ? (
        <div className="max-h-56 overflow-y-auto">
          <Table flush>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Window</TableHead>
                <TableHead>Output cap</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {changed.map((d) => (
                <TableRow key={d.name}>
                  <TableCell className="font-mono text-[12px]">{d.name}</TableCell>
                  <TableCell className="tabular-nums">
                    {formatTokenCount(d.before.context_window)} →{" "}
                    {formatTokenCount(d.after.context_window)}
                  </TableCell>
                  <TableCell className="tabular-nums">
                    {formatTokenCount(d.before.max_output_tokens)} →{" "}
                    {formatTokenCount(d.after.max_output_tokens)}
                  </TableCell>
                  <TableCell className="text-xs">
                    {COVERAGE_STATUS_LABEL[d.status_before]} →{" "}
                    {COVERAGE_STATUS_LABEL[d.status_after]}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      ) : (
        <div className="px-3 py-3 text-xs text-muted-foreground">
          No change — nothing would be written.
        </div>
      )}
      {preview.rejected.length > 0 && (
        <div className="border-t border-border px-3 py-2 text-xs text-destructive">
          Rejected ({preview.rejected.length}):{" "}
          {preview.rejected.map((r) => `${r.name} — ${r.reason}`).join("; ")}
        </div>
      )}
    </div>
  )
}

function LimitsCoverageCard() {
  const [data, setData] = useState<CoverageResponse | null>(null)
  const [error, setError] = useState("")
  const [filter, setFilter] = useState("not_ready")
  const [needle, setNeedle] = useState("")
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(10)
  // Bumped after every applied write: refetch keeps the current filter/search.
  const [reloadKey, setReloadKey] = useState(0)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [busy, setBusy] = useState(false)
  const [curateOpen, setCurateOpen] = useState(false)
  const [curateWindow, setCurateWindow] = useState("")
  const [curateOutput, setCurateOutput] = useState("")
  const [curateClearWindow, setCurateClearWindow] = useState(false)
  const [curateClearOutput, setCurateClearOutput] = useState(false)
  const [pasteOpen, setPasteOpen] = useState(false)
  const [pasteText, setPasteText] = useState("")
  const [preview, setPreview] = useState<BulkResponse | null>(null)
  const [previewBad, setPreviewBad] = useState<string[]>([])

  useEffect(() => {
    api<CoverageResponse>("/settings/model-limits/coverage")
      .then((d) => {
        setData(d)
        setError("")
      })
      .catch((e: any) => setError(e.message))
  }, [reloadKey])

  const entries = useMemo(() => {
    const matches = (e: CoverageEntry) => {
      if (filter === "all") return true
      if (filter === "not_ready") return e.status !== "ready"
      return e.status === filter
    }
    const rows = (data?.entries ?? []).filter(
      // Both sides lowercased: the input keeps the operator's casing, so a
      // mixed-case search like "MiniMax" would otherwise match nothing.
      (e) => matches(e) && (!needle || e.name.toLowerCase().includes(needle.trim().toLowerCase())),
    )
    return rows.sort(
      (a, b) =>
        COVERAGE_STATUS_RANK[a.status] - COVERAGE_STATUS_RANK[b.status] ||
        a.name.localeCompare(b.name),
    )
  }, [data, filter, needle])

  const { slice, pageCount, page: safePage, total } = useClientPagination(entries, pageSize, page)
  const summary = data?.summary

  // Selection follows the visible (filtered) rows: a hidden row is dropped, so
  // a filter change can never leave an invisible name inside a bulk patch.
  useEffect(() => {
    setSelected((prev) => {
      const visible = new Set(entries.map((e) => e.name))
      const next = new Set([...prev].filter((n) => visible.has(n)))
      return next.size === prev.size ? prev : next
    })
  }, [entries])

  const allVisibleSelected = entries.length > 0 && entries.every((e) => selected.has(e.name))
  const someVisibleSelected = entries.some((e) => selected.has(e.name))

  const toggleOne = (name: string, on: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (on) next.add(name)
      else next.delete(name)
      return next
    })
  }
  const toggleAllVisible = (on: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev)
      for (const e of entries) {
        if (on) next.add(e.name)
        else next.delete(e.name)
      }
      return next
    })
  }

  const parsedPaste = useMemo(() => parsePastedLimits(pasteText), [pasteText])
  const windowInput = curateClearWindow ? ({ ok: true, value: null } as const) : parseLimitInput(curateWindow)
  const outputInput = curateClearOutput ? ({ ok: true, value: null } as const) : parseLimitInput(curateOutput)
  const bothUntouched = windowInput.value === undefined && outputInput.value === undefined
  // Never send an empty patch: Apply needs at least one touched field.
  const curatePatch: BulkPatch | null =
    windowInput.ok && outputInput.ok && !bothUntouched
      ? {
          ...(windowInput.value !== undefined ? { context_window: windowInput.value } : {}),
          ...(outputInput.value !== undefined ? { max_output_tokens: outputInput.value } : {}),
        }
      : null
  const curateInputInvalid = !windowInput.ok || !outputInput.ok

  async function applyBulk(mode: BulkMode, entries: Record<string, BulkPatch>): Promise<BulkResponse | null> {
    setBusy(true)
    try {
      const res = await api<BulkResponse>("/settings/model-limits/bulk", {
        method: "POST",
        body: { entries, mode },
      })
      toast.success(
        `Limits saved · ${res.applied} applied · ${res.cleared} cleared · ready ${res.ready_before} → ${res.ready_after}`,
      )
      setReloadKey((k) => k + 1)
      setSelected(new Set())
      setCurateOpen(false)
      setPasteOpen(false)
      setPreview(null)
      setPreviewBad([])
      setPasteText("")
      setCurateWindow("")
      setCurateOutput("")
      setCurateClearWindow(false)
      setCurateClearOutput(false)
      return res
    } catch (e: any) {
      toast.error(e.message)
      return null
    } finally {
      setBusy(false)
    }
  }

  async function runPreview() {
    setBusy(true)
    try {
      const res = await api<BulkResponse>("/settings/model-limits/bulk", {
        method: "POST",
        body: { entries: parsedPaste.entries, mode: "dry_run" },
      })
      setPreview(res)
      setPreviewBad(parsedPaste.bad)
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setBusy(false)
    }
  }

  const curateNames = [...selected]
  const pasteEntries = Object.keys(parsedPaste.entries).length

  return (
    <Card className="flex h-fit w-full flex-col self-start overflow-hidden animate-fade-up">
      <CardHeader className="border-b">
        <CardTitle>Limits coverage</CardTitle>
        <CardDescription>
          A name is compaction-ready only when the gateway advertises both a context window and
          an output cap — pick a filter to see what is missing and which layer supplied it.
        </CardDescription>
        <CardAction className="flex w-full flex-wrap items-center gap-2 @[520px]/card-header:w-auto">
          <div className="relative min-w-0 flex-1 @[520px]/card-header:flex-none">
            <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
            <Input
              id="filter-limits-coverage"
              className="h-8 w-full pl-8 @[520px]/card-header:w-56"
              placeholder="Search names"
              aria-label="Search names"
              value={needle}
              onChange={(e) => {
                setNeedle(e.target.value)
                setPage(1)
              }}
            />
          </div>
          <Select
            value={filter}
            onValueChange={(v) => {
              setFilter(v)
              setPage(1)
            }}
          >
            <SelectTrigger id="filter-limits-status" size="sm" aria-label="Filter by readiness">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {COVERAGE_FILTERS.map((f) => (
                <SelectItem key={f.value} value={f.value}>
                  {f.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </CardAction>
      </CardHeader>
      <CardContent className="px-0">
        {error && <ErrorFlash message={error} />}
        {!data && !error ? (
          <Loading />
        ) : data ? (
          <>
            <div className="flex flex-wrap items-center gap-2 border-b bg-muted/20 px-5 py-3">
              <Badge variant="success">Ready · {summary?.ready ?? 0}</Badge>
              <Badge variant="warning">Missing window · {summary?.missing_window ?? 0}</Badge>
              <Badge variant="warning">Missing output · {summary?.missing_output ?? 0}</Badge>
              <Badge variant="danger">Missing both · {summary?.missing_both ?? 0}</Badge>
              <span className="text-xs text-muted-foreground">
                {summary?.names ?? 0} names · {summary?.curated ?? 0} curated ·{" "}
                {summary?.bound ?? 0} bound
              </span>
            </div>
            <div className="flex flex-wrap items-center gap-2 border-b bg-muted/20 px-5 py-3">
              <span className="text-xs tabular-nums text-muted-foreground">
                {selected.size} selected
              </span>
              {selected.size > 0 && (
                <Button variant="ghost" size="sm" onClick={() => setSelected(new Set())}>
                  Clear selection
                </Button>
              )}
              <div className="ml-auto flex flex-wrap items-center gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => {
                    setPreview(null)
                    setPreviewBad([])
                    setPasteOpen(true)
                  }}
                >
                  Paste limits
                </Button>
                <Button size="sm" disabled={selected.size === 0} onClick={() => setCurateOpen(true)}>
                  Curate limits
                </Button>
              </div>
            </div>
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-8">
                    <Checkbox
                      aria-label="Select all filtered names"
                      checked={allVisibleSelected ? true : someVisibleSelected ? "indeterminate" : false}
                      onCheckedChange={(v) => toggleAllVisible(v === true)}
                    />
                  </TableHead>
                  <TableHead>Name</TableHead>
                  <TableHead>Binding</TableHead>
                  <TableHead>Window</TableHead>
                  <TableHead>Output cap</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Source</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {slice.map((e) => (
                  <TableRow key={e.name} data-state={selected.has(e.name) ? "selected" : undefined}>
                    <TableCell>
                      <Checkbox
                        aria-label={`Select ${e.name}`}
                        checked={selected.has(e.name)}
                        onCheckedChange={(v) => toggleOne(e.name, v === true)}
                      />
                    </TableCell>
                    <TableCell
                      className="font-medium"
                      title={
                        e.providers.length
                          ? `listings from: ${e.providers.join(", ")}`
                          : "no provider listing"
                      }
                    >
                      {e.name}
                    </TableCell>
                    <TableCell>
                      <div className="flex flex-wrap items-center gap-1">
                        {e.bound ? (
                          <Badge variant="secondary">Bound</Badge>
                        ) : (
                          <span className="text-xs text-muted-foreground">unbound</span>
                        )}
                        {e.tiers.map((t) => (
                          <Badge key={t} variant="outline">
                            {t}
                          </Badge>
                        ))}
                      </div>
                    </TableCell>
                    <TableCell
                      className="tabular-nums"
                      title={e.window === null ? "no window advertised" : String(e.window)}
                    >
                      {formatTokenCount(e.window)}
                    </TableCell>
                    <TableCell
                      className="tabular-nums"
                      title={e.output === null ? "no output cap advertised" : String(e.output)}
                    >
                      {formatTokenCount(e.output)}
                    </TableCell>
                    <TableCell>
                      <Badge variant={e.status === "missing_both" ? "danger" : COVERAGE_STATUS_TONE[e.status]}>
                        {COVERAGE_STATUS_LABEL[e.status]}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-xs text-muted-foreground" title={layerTitle(e)}>
                      <div>
                        Window · {e.source.window ? COVERAGE_LAYER_LABEL[e.source.window] : "—"}
                      </div>
                      <div>
                        Output · {e.source.output ? COVERAGE_LAYER_LABEL[e.source.output] : "—"}
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
            {total === 0 ? (
              <EmptyState
                compact
                title="No matching names"
                description="Change the readiness filter or search text."
              />
            ) : (
              <Pagination
                page={safePage}
                pageCount={pageCount}
                total={total}
                pageSize={pageSize}
                onPageChange={setPage}
                onPageSizeChange={(n) => {
                  setPageSize(n)
                  setPage(1)
                }}
              />
            )}
          </>
        ) : null}
      </CardContent>
      <Dialog open={curateOpen} onOpenChange={(o) => !o && setCurateOpen(false)}>
        <DialogContent
          title="Curate limits"
          description={`Set curated token limits for ${curateNames.length} selected name${
            curateNames.length === 1 ? "" : "s"
          }. Curated values win over provider listings and the models.dev snapshot.`}
        >
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="curate-window">Context window</FieldLabel>
              <Input
                id="curate-window"
                type="number"
                min={1}
                inputMode="numeric"
                placeholder="e.g. 200000"
                value={curateWindow}
                disabled={curateClearWindow}
                onChange={(e) => setCurateWindow(e.target.value)}
              />
              <label className="flex items-center gap-1.5 text-xs">
                <Checkbox
                  checked={curateClearWindow}
                  onCheckedChange={(v) => setCurateClearWindow(v === true)}
                />
                Clear context window
              </label>
            </Field>
            <Field>
              <FieldLabel htmlFor="curate-output">Max output tokens</FieldLabel>
              <Input
                id="curate-output"
                type="number"
                min={1}
                inputMode="numeric"
                placeholder="e.g. 8192"
                value={curateOutput}
                disabled={curateClearOutput}
                onChange={(e) => setCurateOutput(e.target.value)}
              />
              <label className="flex items-center gap-1.5 text-xs">
                <Checkbox
                  checked={curateClearOutput}
                  onCheckedChange={(v) => setCurateClearOutput(v === true)}
                />
                Clear max output tokens
              </label>
            </Field>
          </FieldGroup>
          <FieldDescription>
            {curateInputInvalid
              ? "Enter a positive whole number, or tick Clear to remove that key."
              : "Untouched fields stay as they are; only the fields you set are written."}
          </FieldDescription>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCurateOpen(false)}>
              Cancel
            </Button>
            <Button
              disabled={!curatePatch || busy}
              onClick={() =>
                curatePatch &&
                applyBulk(
                  "merge",
                  Object.fromEntries(curateNames.map((n) => [n, curatePatch])),
                )
              }
            >
              {busy ? "Applying…" : "Apply"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog open={pasteOpen} onOpenChange={(o) => !o && setPasteOpen(false)}>
        <DialogContent
          size="md"
          title="Paste limits"
          description="One entry per line: name, context window, max output tokens — separated by commas, tabs or whitespace. An empty field or - clears that key."
        >
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="paste-limits">Limits</FieldLabel>
              <Textarea
                id="paste-limits"
                rows={8}
                className="font-mono text-xs"
                placeholder={
                  "glm-5.3-spec, 200000, 8192\nsome-listing, 128000, -\nsome-other, -, 4096"
                }
                value={pasteText}
                onChange={(e) => {
                  setPasteText(e.target.value)
                  setPreview(null)
                  setPreviewBad([])
                }}
              />
              <FieldDescription>
                {pasteEntries} entr{pasteEntries === 1 ? "y" : "ies"} parsed
                {previewBad.length > 0
                  ? ` · ${previewBad.length} line(s) not parsed`
                  : ""}
              </FieldDescription>
            </Field>
          </FieldGroup>
          {previewBad.length > 0 && (
            <div className="rounded-md border border-destructive/40 px-3 py-2 text-xs text-destructive">
              Not parsed: {previewBad.join(" · ")}
            </div>
          )}
          {preview && <BulkPreview preview={preview} />}
          <DialogFooter>
            <Button variant="outline" onClick={() => setPasteOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="outline"
              disabled={busy || pasteEntries === 0 || previewBad.length > 0}
              onClick={runPreview}
            >
              {busy ? "Previewing…" : "Preview"}
            </Button>
            <Button
              disabled={busy || !preview || preview.applied + preview.cleared === 0}
              onClick={() => applyBulk("merge", parsedPaste.entries)}
            >
              Apply
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  )
}
