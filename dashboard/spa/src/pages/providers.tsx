import { Fragment, useEffect, useMemo, useState } from "react"
import { ArrowRight, Check, ChevronDown, ChevronRight, CircleAlert, ExternalLink, Grid3x3, LoaderCircle, Lock, Pencil, Pin, Plus, Power, RefreshCw, Search, Trash2, TriangleAlert, X, Zap } from "lucide-react"
import { toast } from "sonner"
import { ApiError, api } from "../api"
import { Pagination, useClientPagination } from "../components/pagination"
import { EmptyState, ErrorFlash, IconAction, Layout, Loading } from "../components"
import { notifyDeferredSurgery } from "@/lib/cascade"
import {
  PROTOCOLS,
  PROVIDER_PRESETS,
  presetEndpoints,
  presetKeysUrl,
  type JanusProtocol,
  type ProviderPreset,
} from "@/lib/provider-presets"
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
import { Checkbox } from "@/components/ui/checkbox"
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
  FieldError,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field"
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
import { ComboboxSingle } from "@/components/combobox"
import { cn } from "@/lib/utils"
import {
  AffinityPinBadge,
  AffinityWorker,
  DecisionsProbeResult,
  DecisionsProbeState,
  EntitlementListing,
  EntitlementMatrix,
  EntitlementResponse,
  KeyMeta,
  ModelPrice,
  Provider,
  ProviderModel,
  StateBadge,
  fmtIsoLocalSeconds,
  pinUnmatched,
  protocolLabel,
  shortNode,
} from "./shared"

/** True when the provider/protocol selection is the OpenAI Decisions
 * native face (spec 2026-10-07) — bills per decision upstream. */
const isDecisionsProtocol = (protocol: string) => protocol === "openai_decisions"

export function Providers() {
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  /** Live worker pool from GET /api/nodes — the only valid pin targets. */
  const [workers, setWorkers] = useState<AffinityWorker[]>([])
  /** True only after a successful sched scrape: an unmatched-pin warning is
   * a fact about the fleet, so it must not be raised from a stale/absent view. */
  const [schedKnown, setSchedKnown] = useState(false)
  const [regionEdit, setRegionEdit] = useState<{ id: number; value: string } | null>(null)
  const [expanded, setExpanded] = useState<{
    id: number
    section: "keys" | "models" | "affinity"
  } | null>(null)
  const [modal, setModal] = useState<
    | "add"
    | { addKey: Provider }
    | { addModel: Provider }
    | { del: Provider }
    | { delKey: [Provider, KeyMeta] }
    | { matrix: Provider }
    | null
  >(null)
  const [syncing, setSyncing] = useState(false)
  const [modalityCfg, setModalityCfg] = useState<Record<string, boolean> | null>(null)
  const [toolsTranslate, setToolsTranslate] = useState<boolean | null>(null)
  const [responsesTranslate, setResponsesTranslate] = useState<boolean | null>(null)

  // Settings knobs are read separately so a failed read can be surfaced:
  // otherwise the buttons just render disabled and look like "knob off".
  const [knobsError, setKnobsError] = useState("")

  const loadKnobs = () => {
    setKnobsError("")
    Promise.allSettled([api("/settings/modality"), api("/settings/translate")]).then(([m, t]) => {
      if (m.status === "fulfilled") setModalityCfg(m.value.config)
      if (t.status === "fulfilled") {
        setToolsTranslate(!!t.value.config.tools)
        setResponsesTranslate(!!t.value.config.responses)
      }
      const failed = [
        m.status === "rejected" ? `modality: ${m.reason?.message ?? m.reason}` : "",
        t.status === "rejected" ? `translate: ${t.reason?.message ?? t.reason}` : "",
      ].filter(Boolean)
      if (failed.length > 0) setKnobsError(`Settings knobs unavailable — ${failed.join("; ")}`)
    })
  }

  useEffect(() => {
    loadKnobs()
  }, [])

  const putTranslate = (knob: string, val: boolean, ok: string) => {
    api("/settings/translate", { method: "PUT", body: { [knob]: val } })
      .then(() => toast.success(`${ok} — gateways reload within seconds`))
      .catch((e: any) => toast.error(e.message))
  }

  const toggleToolsTranslate = () => {
    if (toolsTranslate === null) return
    const next = !toolsTranslate
    setToolsTranslate(next)
    putTranslate("tools", next, `cross-protocol tools streaming ${next ? "enabled" : "disabled"}`)
  }

  const toggleResponsesTranslate = () => {
    if (responsesTranslate === null) return
    const next = !responsesTranslate
    setResponsesTranslate(next)
    putTranslate("responses", next, `Responses-client streaming translation ${next ? "enabled" : "disabled"}`)
  }

  const toggleModality = (m: string) => {
    if (!modalityCfg) return
    const next = { ...modalityCfg, [m]: !modalityCfg[m] }
    setModalityCfg(next)
    api("/settings/modality", { method: "PUT", body: { [m]: next[m] } })
      .then(() => toast.success(`modality ${m} ${next[m] ? "enabled" : "disabled"} — gateways reload within seconds`))
      .catch((e: any) => {
        // Roll back only the knob that failed: restoring the pre-toggle
        // snapshot would clobber a concurrent toggle that settled meanwhile.
        setModalityCfg((prev) => (prev ? { ...prev, [m]: !next[m] } : prev))
        toast.error(e.message)
      })
  }
  const [weightEdit, setWeightEdit] = useState<{ id: number; value: string } | null>(null)
  // Entitlement matrix (spec 2026-10-05 Part A): per-provider badge data,
  // refreshed while a probe batch runs or is queued (async probe -> 202 -> poll).
  const [matrix, setMatrix] = useState<Record<number, EntitlementMatrix>>({})
  const [probeState, setProbeState] = useState<EntitlementResponse["probe"] | null>(null)
  const [probingKeys, setProbingKeys] = useState<Set<number>>(new Set())

  const load = () =>
    // The node picker needs the live worker pool (GET /api/nodes). A failed
    // /api/nodes read must not blank the page: the providers list still
    // renders, and the affinity surface reports the pool as unknown instead
    // of claiming an unmatched pin (see AffinityPinBadge).
    Promise.all([api("/providers"), api("/nodes").catch(() => null)])
      .then(([r, n]) => {
        setProviders(r.providers)
        if (n) {
          setWorkers(n.workers ?? [])
          setSchedKnown(n.scraped_at !== null && n.scraped_at !== undefined)
        }
        setLoaded(true)
      })
      .catch((e) => setError(e.message))

  const refreshMatrix = async (providerId?: number) => {
    const pid = providerId ?? expanded?.id
    try {
      const r: EntitlementResponse = await api(
        pid ? `/entitlements?provider_id=${pid}` : "/entitlements",
      )
      setProbeState(r.probe)
      setMatrix((prev) => {
        const next = { ...prev }
        for (const p of r.providers) next[p.provider_id] = p
        return next
      })
    } catch {
      // Badge data is best-effort; the page works without it.
    }
  }

  useEffect(() => {
    load()
    refreshMatrix()
  }, [])

  // Keep the live-worker list fresh (10s): the affinity "pin not honoured"
  // banner compares pins against this list, and a fetch-once list let a
  // transient (a pinned worker mid-restart is genuinely absent for ~30s)
  // stale the banner indefinitely — it must self-clear when the worker
  // rejoins the pool.
  useEffect(() => {
    const t = setInterval(() => {
      api("/nodes")
        .then((n) => {
          setWorkers(n.workers ?? [])
          setSchedKnown(n.scraped_at !== null && n.scraped_at !== undefined)
        })
        .catch(() => {})
    }, 10000)
    return () => clearInterval(t)
  }, [])

  // Load matrix rows for a provider when a section is expanded.
  useEffect(() => {
    if (expanded) refreshMatrix(expanded.id)
  }, [expanded?.id])

  // Poll the matrix while an async probe is running or queued. Target the
  // expanded provider (or the open matrix modal) explicitly so the interval
  // never refreshes a provider the operator has since collapsed.
  const probeActive =
    !!probeState && (probeState.running_providers.length > 0 || probeState.queued_jobs > 0)
  const matrixModalProviderId =
    modal && typeof modal === "object" && "matrix" in modal ? modal.matrix.id : undefined
  const pollProviderId = expanded?.id ?? matrixModalProviderId
  useEffect(() => {
    if (!probeActive || pollProviderId === undefined) return
    const t = setInterval(() => refreshMatrix(pollProviderId), 3000)
    return () => clearInterval(t)
  }, [probeActive, pollProviderId])

  const act = async (fn: () => Promise<any>, ok: string) => {
    try {
      const result = await fn()
      toast.success(ok)
      // Cascade spec §5.3: a disable/enable/delete can commit its data-plane
      // change while QUEUEING the tier-list rewrite (router tier lock busy).
      // The success toast stays; this adds the honest "queued" notice so the
      // operator never reads a busy lock as "nothing happened".
      notifyDeferredSurgery(result)
      setModal(null)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  const toggle = (p: Provider) =>
    act(
      () => api(`/providers/${p.id}/${p.enabled ? "disable" : "enable"}`, { method: "POST", body: {} }),
      `${p.name} ${p.enabled ? "disabled" : "enabled"}`,
    )

  // --- affinity (spec 2026-10-22 §6, decision D4) ---
  // The pin is always an explicit operator choice and is NEVER auto-set: an
  // empty picker means "no pin" and the gateway picks freely.
  const savePin = (p: Provider, node: string | null) => {
    if ((p.affinity_node ?? null) === node) return
    act(
      () => api(`/providers/${p.id}`, { method: "PATCH", body: { affinity_node: node } }),
      node ? `pinned ${p.name} to ${node}` : `pin cleared on ${p.name}`,
    )
  }

  const saveRegionTag = (p: Provider) => {
    const value = (regionEdit?.value ?? "").trim()
    setRegionEdit(null)
    if (value === (p.region_tag ?? "")) return
    act(
      () => api(`/providers/${p.id}`, { method: "PATCH", body: { region_tag: value } }),
      value ? `region tag "${value}" saved on ${p.name}` : `region tag cleared on ${p.name}`,
    )
  }

  const workerNames = useMemo(() => workers.map((w) => w.node).sort(), [workers])
  // Group the picker by region so a region preference is visible while
  // choosing; the note is shown in the live-worker list below the picker.
  const regionOf = (node: string) => workers.find((w) => w.node === node)?.region || "No region"

  const probeKey = async (p: Provider, k: KeyMeta) => {
    setProbingKeys((prev) => new Set(prev).add(k.id))
    try {
      const r = await api(`/providers/${p.id}/keys/${k.id}/probe`, { method: "POST", body: {} })
      const kc: any = Object.values(r.keys ?? {})[0]
      toast.success(
        `Probe done — ${kc ? `${kc.ok} ok · ${kc.deny} denied · ${kc.balance} balance-limited · ${kc.skipped} skipped` : "no results"}` +
          (kc?.broken ? ". KEY BROKEN (401/403)" : "") +
          (kc?.truncated
            ? `. Stopped early: ${kc.error === "decrypt_failed" ? "key decrypt failed (check dashboard JANUS_SECRETS_KEY)" : "call budget"}`
            : ""),
      )
      await Promise.all([load(), refreshMatrix(p.id)])
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setProbingKeys((prev) => {
        const n = new Set(prev)
        n.delete(k.id)
        return n
      })
    }
  }

  const probeAll = async (p: Provider) => {
    try {
      const r = await api(`/providers/${p.id}/probe`, { method: "POST", body: {} })
      toast.success(`Probe queued for ${r.keys} key(s) — the matrix updates as it runs`)
      refreshMatrix(p.id)
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  const listingsSupported = providers.some((p) => Array.isArray(p.models))

  const syncNow = async () => {
    if (!listingsSupported) {
      toast.error("This gateway build still syncs into the old global models table. Deploy the new backend before Sync.")
      return
    }
    setSyncing(true)
    try {
      const r = await api("/models/sync", { method: "POST", body: {} })
      toast.success(`Sync done — ${r.models_added ?? 0} new listing(s), ${r.errors ?? 0} error(s)`)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setSyncing(false)
    }
  }

  const saveWeight = (k: KeyMeta) => {
    const raw = (weightEdit?.value ?? "").trim()
    const weight = Number(raw)
    if (raw === "" || !Number.isInteger(weight) || weight < 1) {
      toast.error("Weight must be a whole number ≥ 1")
      return
    }
    setWeightEdit(null)
    act(
      () => api(`/provider-keys/${k.id}/weight`, { method: "POST", body: { weight } }),
      "weight updated",
    )
  }

  return (
    <Layout
      title="Providers & keys"
      description="Upstream endpoints and their encrypted credentials."
    >
      {error && <ErrorFlash message={error} />}
      <Card className="flex h-fit max-h-full w-full flex-col self-start overflow-hidden animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle>Providers</CardTitle>
          <CardDescription>
            Secrets are write-only. Listings are callable by name; bind on Router for janus-auto.
          </CardDescription>
          <CardAction className="flex flex-wrap items-center gap-2">
            {knobsError ? (
              <Button
                variant="outline"
                size="xs"
                className="text-destructive"
                title={knobsError}
                onClick={loadKnobs}
              >
                settings unavailable — retry
              </Button>
            ) : null}
            <Button variant="outline" size="sm" disabled={syncing || !listingsSupported} onClick={syncNow}>
              <RefreshCw className={syncing ? "animate-spin" : undefined} />
              {syncing ? "Syncing…" : "Sync models"}
            </Button>
            <Button size="sm" onClick={() => setModal("add")}>
              <Plus />
              Add provider
            </Button>
          </CardAction>
        </CardHeader>
        <div className="flex flex-wrap items-center gap-2 border-b bg-muted/20 px-5 py-3">
          <span className="mr-2 text-xs font-medium text-muted-foreground">Endpoint features</span>
          <Button
            variant={toolsTranslate ? "secondary" : "outline"}
            size="xs"
            disabled={toolsTranslate === null}
            aria-pressed={toolsTranslate === true}
            title="Cross-protocol streaming tool-call translation (settings knob, default off)"
            onClick={toggleToolsTranslate}
          >
            <span className={`size-1.5 rounded-full ${toolsTranslate ? "bg-success" : "bg-muted-foreground/40"}`} />
            tools-stream
          </Button>
          <Button
            variant={responsesTranslate ? "secondary" : "outline"}
            size="xs"
            disabled={responsesTranslate === null}
            aria-pressed={responsesTranslate === true}
            title="Responses-client streaming translation to chat/anthropic providers (settings knob, default off)"
            onClick={toggleResponsesTranslate}
          >
            <span className={`size-1.5 rounded-full ${responsesTranslate ? "bg-success" : "bg-muted-foreground/40"}`} />
            responses-stream
          </Button>
          {["image", "tts", "asr", "video", "embedding"].map((m) => (
            <Button
              key={m}
              variant={modalityCfg?.[m] ? "secondary" : "outline"}
              size="xs"
              disabled={!modalityCfg}
              aria-pressed={modalityCfg?.[m] === true}
              title={`Serve /v1 modality endpoints for ${m} (settings knob, default off)`}
              onClick={() => toggleModality(m)}
            >
              <span className={`size-1.5 rounded-full ${modalityCfg?.[m] ? "bg-success" : "bg-muted-foreground/40"}`} />
              {m}
            </Button>
          ))}
        </div>
        <CardContent className="min-h-0 px-0">
          {!loaded && !error ? (
            <Loading />
          ) : loaded && providers.length === 0 ? (
            <EmptyState
              title="No providers yet"
              description="Add an upstream so listings can be synced and bound on Router."
              action={
                <Button size="sm" onClick={() => setModal("add")}>
                  <Plus />
                  Add provider
                </Button>
              }
            />
          ) : (
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead>Provider</TableHead>
                  <TableHead className="w-full">Base URL</TableHead>
                  <TableHead>Protocol</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {providers.map((p) => (
                  <Fragment key={p.id}>
                    <TableRow>
                      <TableCell className="font-medium">
                        <div className="flex min-w-0 flex-wrap items-center gap-1.5">
                          <span className="truncate">{p.name}</span>
                          {p.region_tag && (
                            <Tooltip
                              content={`Soft geo preference: ${p.region_tag}. Not a pin — an existing pin outranks health and geo.`}
                            >
                              <Badge variant="outline" className="cursor-help text-[11px]">
                                {p.region_tag}
                              </Badge>
                            </Tooltip>
                          )}
                          <AffinityPinBadge
                            pin={p.affinity_node}
                            workers={workers}
                            known={schedKnown}
                          />
                        </div>
                      </TableCell>
                      <TableCell className="w-full max-w-0 min-w-[140px] font-mono text-xs text-muted-foreground">
                        <Tooltip content={p.base_url}>
                          <div className="truncate">{p.base_url}</div>
                        </Tooltip>
                      </TableCell>
                      <TableCell className="text-xs whitespace-nowrap text-muted-foreground">
                        {protocolLabel(p.protocol)}
                      </TableCell>
                      <TableCell>
                        <StateBadge enabled={p.enabled} />
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="xs"
                            className="text-muted-foreground tabular-nums"
                            aria-expanded={expanded?.id === p.id && expanded.section === "keys"}
                            aria-controls={`provider-${p.id}-keys`}
                            onClick={() =>
                              setExpanded(
                                expanded?.id === p.id && expanded.section === "keys"
                                  ? null
                                  : { id: p.id, section: "keys" },
                              )
                            }
                          >
                            {p.keys.length} {p.keys.length === 1 ? "key" : "keys"}
                            {expanded?.id === p.id && expanded.section === "keys" ? (
                              <ChevronDown />
                            ) : (
                              <ChevronRight />
                            )}
                          </Button>
                          <Button
                            variant="ghost"
                            size="xs"
                            className="text-muted-foreground tabular-nums"
                            aria-expanded={expanded?.id === p.id && expanded.section === "models"}
                            aria-controls={`provider-${p.id}-models`}
                            onClick={() =>
                              setExpanded(
                                expanded?.id === p.id && expanded.section === "models"
                                  ? null
                                  : { id: p.id, section: "models" },
                              )
                            }
                          >
                            {(p.models ?? []).length}{" "}
                            {(p.models ?? []).length === 1 ? "model" : "models"}
                            {expanded?.id === p.id && expanded.section === "models" ? (
                              <ChevronDown />
                            ) : (
                              <ChevronRight />
                            )}
                          </Button>
                          <Button
                            variant="ghost"
                            size="xs"
                            className={cn(
                              "gap-1 tabular-nums",
                              p.affinity_node ? "text-foreground" : "text-muted-foreground",
                              pinUnmatched(p.affinity_node, workers, schedKnown) &&
                                "text-destructive hover:text-destructive",
                            )}
                            aria-expanded={expanded?.id === p.id && expanded.section === "affinity"}
                            aria-controls={`provider-${p.id}-affinity`}
                            title={
                              p.affinity_node
                                ? `Node pin: ${p.affinity_node}`
                                : "No node pin — the gateway picks any healthy node"
                            }
                            onClick={() =>
                              setExpanded(
                                expanded?.id === p.id && expanded.section === "affinity"
                                  ? null
                                  : { id: p.id, section: "affinity" },
                              )
                            }
                          >
                            <Pin className="size-3" />
                            {p.affinity_node ? shortNode(p.affinity_node) : "pin"}
                            {expanded?.id === p.id && expanded.section === "affinity" ? (
                              <ChevronDown />
                            ) : (
                              <ChevronRight />
                            )}
                          </Button>
                          <IconAction
                            label={p.enabled ? "Disable" : "Enable"}
                            onClick={() => toggle(p)}
                          >
                            <Power />
                          </IconAction>
                          <IconAction
                            label="Delete provider"
                            destructive
                            onClick={() => setModal({ del: p })}
                          >
                            <Trash2 />
                          </IconAction>
                        </div>
                      </TableCell>
                    </TableRow>
                    {expanded?.id === p.id && (
                      <TableRow className="hover:bg-transparent">
                        <TableCell colSpan={5} className="p-0">
                          <div className="border-t border-border/60 bg-muted/20 px-5 py-4">
                            {expanded.section === "keys" && (
                            <div id={`provider-${p.id}-keys`} className="flex flex-col gap-2">
                              <div className="flex items-center gap-2">
                                <div className="text-xs font-medium text-muted-foreground">
                                  Keys · {p.keys.length}
                                </div>
                                <div className="flex-1" />
                                <Button
                                  variant="outline"
                                  size="xs"
                                  onClick={() => probeAll(p)}
                                >
                                  <Zap />
                                  Probe all
                                </Button>
                                <Button
                                  variant="outline"
                                  size="xs"
                                  onClick={() => setModal({ matrix: p })}
                                >
                                  <Grid3x3 />
                                  Matrix
                                </Button>
                              </div>
                              {p.keys.length === 0 && (
                                <span className="text-sm text-muted-foreground">
                                  No keys yet — add one to start routing.
                                </span>
                              )}
                              {p.keys.map((k) => {
                                const ek = matrix[p.id]?.keys.find(
                                  (x) => x.provider_key_id === k.id,
                                )
                                return (
                                <div key={k.id} className="flex flex-wrap items-center gap-3">
                                  <span className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">
                                    {k.key_id}
                                  </span>
                                  {ek && (
                                    <Tooltip
                                      content={`entitlement matrix: ok ${ek.ok} (input_shape ${ek.input_shape}) · deny ${ek.deny} · balance ${ek.balance} · unknown ${ek.unknown}${ek.escalated > 0 ? ` · escalated ${ek.escalated}` : ""}`}
                                    >
                                      <button
                                        type="button"
                                        className={
                                          "rounded px-1.5 py-0.5 font-mono text-[11px] tabular-nums transition-colors " +
                                          (ek.broken
                                            ? "bg-destructive/15 text-destructive"
                                            : "bg-muted text-muted-foreground hover:text-foreground")
                                        }
                                      >
                                        {ek.broken ? "broken" : `${ek.ok}/${ek.total} ok`}
                                      </button>
                                    </Tooltip>
                                  )}
                                  {weightEdit?.id === k.id ? (
                                    <span className="flex items-center gap-1">
                                      <Input
                                        type="number"
                                        min={1}
                                        className="h-7 w-20 px-2 text-xs"
                                        value={weightEdit.value}
                                        aria-label="Key weight"
                                        autoFocus
                                        onChange={(e) =>
                                          setWeightEdit({ id: k.id, value: e.target.value })
                                        }
                                        onKeyDown={(e) => {
                                          if (e.key === "Enter") saveWeight(k)
                                          if (e.key === "Escape") setWeightEdit(null)
                                        }}
                                      />
                                      <Button
                                        variant="ghost"
                                        size="icon-xs"
                                        aria-label="Save weight"
                                        onClick={() => saveWeight(k)}
                                      >
                                        <Check />
                                      </Button>
                                      <Button
                                        variant="ghost"
                                        size="icon-xs"
                                        aria-label="Cancel"
                                        onClick={() => setWeightEdit(null)}
                                      >
                                        <X />
                                      </Button>
                                    </span>
                                  ) : (
                                    <button
                                      type="button"
                                      className="group flex items-center gap-1 text-xs text-muted-foreground transition-colors hover:text-foreground"
                                      title="Traffic share when several keys are enabled on this provider (weighted round-robin) — click to edit"
                                      onClick={() =>
                                        setWeightEdit({ id: k.id, value: String(k.weight) })
                                      }
                                    >
                                      weight {k.weight}
                                      <Pencil className="size-3 opacity-0 transition-opacity group-hover:opacity-60" />
                                    </button>
                                  )}
                                  <div className="flex-1" />
                                  <StateBadge enabled={k.enabled} />
                                  <div className="flex items-center">
                                    <IconAction
                                      label={probingKeys.has(k.id) ? "Probing…" : "Probe"}
                                      disabled={probingKeys.has(k.id)}
                                      onClick={() => probeKey(p, k)}
                                    >
                                      {probingKeys.has(k.id) ? (
                                        <LoaderCircle className="animate-spin" />
                                      ) : (
                                        <Zap />
                                      )}
                                    </IconAction>
                                    <IconAction
                                      label={k.enabled ? "Disable" : "Enable"}
                                      onClick={() =>
                                        act(
                                          () =>
                                            api(
                                              `/provider-keys/${k.id}/${k.enabled ? "disable" : "enable"}`,
                                              { method: "POST", body: {} },
                                            ),
                                          k.enabled ? "Key disabled" : "Key enabled",
                                        )
                                      }
                                    >
                                      <Power />
                                    </IconAction>
                                    <IconAction
                                      label={`Remove key ${k.key_id}`}
                                      destructive
                                      onClick={() => setModal({ delKey: [p, k] })}
                                    >
                                      <X />
                                    </IconAction>
                                  </div>
                                </div>
                                )
                              })}
                              <div className="flex justify-end">
                                <Button
                                  variant="outline"
                                  size="xs"
                                  onClick={() => setModal({ addKey: p })}
                                >
                                  <Plus />
                                  Add key
                                </Button>
                              </div>
                            </div>
                            )}
                            {expanded.section === "models" && (
                            <div id={`provider-${p.id}-models`}>
                            <ProviderListings
                              provider={p}
                              entitlements={matrix[p.id]?.listings ?? null}
                              onToggle={(m) =>
                                act(
                                  () =>
                                    api(
                                      `/provider-models/${m.id}/${m.enabled ? "disable" : "enable"}`,
                                      { method: "POST", body: {} },
                                    ),
                                  m.enabled ? "Listing disabled" : "Listing enabled",
                                )
                              }
                              onAdd={() => setModal({ addModel: p })}
                            />
                            </div>
                            )}
                            {expanded.section === "affinity" && (
                            <div id={`provider-${p.id}-affinity`} className="flex flex-col gap-3">
                              <div className="flex flex-wrap items-center gap-2">
                                <div className="text-xs font-medium text-muted-foreground">
                                  Node affinity
                                </div>
                                <div className="flex-1" />
                                {p.affinity_node && (
                                  <Button
                                    variant="outline"
                                    size="xs"
                                    onClick={() => savePin(p, null)}
                                  >
                                    Clear pin
                                  </Button>
                                )}
                              </div>

                              {pinUnmatched(p.affinity_node, workers, schedKnown) && (
                                <div className="flex max-w-2xl items-start gap-2 rounded border border-destructive/40 bg-destructive/10 px-3 py-2 text-xs">
                                  <TriangleAlert className="mt-0.5 size-3.5 shrink-0 text-destructive" />
                                  <span>
                                    <span className="font-medium">Pin not honoured.</span>{" "}
                                    <span className="font-mono">{p.affinity_node}</span> is not in the
                                    live worker pool, so the gateway fails open to any healthy node:
                                    this provider is not running where it is pinned, and nothing
                                    corrects it automatically. Pin a live worker or clear the pin.
                                  </span>
                                </div>
                              )}

                              <div className="flex max-w-2xl flex-col gap-3">
                                <Field>
                                  <FieldLabel htmlFor={`affinity-pin-${p.id}`}>
                                    Pinned worker
                                  </FieldLabel>
                                  <ComboboxSingle
                                    id={`affinity-pin-${p.id}`}
                                    value={p.affinity_node ?? null}
                                    options={workerNames}
                                    groupBy={regionOf}
                                    onChange={(v) => savePin(p, v)}
                                    placeholder={
                                      schedKnown
                                        ? "No pin — any healthy node"
                                        : "Live worker set unknown"
                                    }
                                  />
                                  <FieldDescription>
                                    Absolute tier-2 pin (Erlang long name): it outranks health and
                                    geo and bypasses the capacity soft cap. Nothing is auto-picked
                                    — choose a worker explicitly, or leave it unpinned.
                                  </FieldDescription>
                                </Field>

                                <Field>
                                  <FieldLabel htmlFor={`affinity-region-${p.id}`}>
                                    Region tag — soft preference
                                  </FieldLabel>
                                  <div className="flex items-center gap-2">
                                    <Input
                                      id={`affinity-region-${p.id}`}
                                      className="h-9"
                                      placeholder="e.g. cn-north-4"
                                      value={
                                        regionEdit?.id === p.id
                                          ? regionEdit.value
                                          : (p.region_tag ?? "")
                                      }
                                      onChange={(e) =>
                                        setRegionEdit({ id: p.id, value: e.target.value })
                                      }
                                      onKeyDown={(e) => {
                                        if (e.key === "Enter") saveRegionTag(p)
                                      }}
                                    />
                                    <Button
                                      variant="outline"
                                      size="sm"
                                      onClick={() => saveRegionTag(p)}
                                    >
                                      Save
                                    </Button>
                                  </div>
                                  <FieldDescription>
                                    Soft geo preference only — NOT a pin. It never overrides a pin,
                                    health or capacity.
                                  </FieldDescription>
                                </Field>
                              </div>

                              <div className="max-w-2xl overflow-hidden rounded border border-border/60 bg-background/60">
                                <div className="flex items-center gap-2 border-b border-border/60 px-3 py-1.5 text-xs font-medium text-muted-foreground">
                                  <span>Live workers · {workers.length}</span>
                                  {p.affinity_node && (
                                    <span className="ml-auto font-mono">
                                      pinned → {p.affinity_node}
                                    </span>
                                  )}
                                </div>
                                {workers.length === 0 ? (
                                  <div className="px-3 py-2 text-xs text-muted-foreground">
                                    {schedKnown
                                      ? "A successful sched scrape reports zero workers — no worker can honour a pin right now."
                                      : "No successful sched scrape yet — the live worker set is unknown (a pin here is unverified, not necessarily wrong)."}
                                  </div>
                                ) : (
                                  <div className="divide-y divide-border/40">
                                    {workers.map((w) => (
                                      <div
                                        key={w.node}
                                        className={cn(
                                          "flex flex-wrap items-center gap-x-3 gap-y-0.5 px-3 py-1.5 text-xs",
                                          w.node === p.affinity_node && "bg-primary/5",
                                        )}
                                      >
                                        <span className="font-mono">{w.node}</span>
                                        <span className="text-muted-foreground">
                                          {w.region ?? "no region"}
                                        </span>
                                        <span className="truncate text-muted-foreground">
                                          {w.note || "no note"}
                                        </span>
                                        <span className="ml-auto text-muted-foreground">
                                          {w.status ?? "unknown"}
                                          {w.draining ? " · draining" : ""}
                                        </span>
                                        {w.node === p.affinity_node && (
                                          <Badge variant="secondary" className="text-[11px]">
                                            pinned
                                          </Badge>
                                        )}
                                      </div>
                                    ))}
                                  </div>
                                )}
                              </div>
                            </div>
                            )}
                          </div>
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

      {SHOW_MODEL_PRICES && <ModelPricesCard />}

      {modal === "add" && (
        <AddProviderModal
          onClose={() => setModal(null)}
          onDone={(body) =>
            // One atomic POST — the provider only exists once the key
            // step completes (or is explicitly skipped).
            act(async () => {
              // A re-create of a retired provider replays the cascade journal
              // (spec §4) and can defer tier surgery — return it to `act`.
              return await api("/providers", { method: "POST", body })
            }, body.key ? "provider & key added" : "provider added — key can be added later")
          }
        />
      )}

      {modal && typeof modal === "object" && "addKey" in modal && (
        <AddKeyModal
          provider={modal.addKey}
          onClose={() => setModal(null)}
          onDone={(body) =>
            act(async () => {
              await api(`/providers/${modal.addKey.id}/keys`, { method: "POST", body })
            }, "key encrypted & stored")
          }
        />
      )}

      {modal && typeof modal === "object" && "addModel" in modal && (
        <AddListingModal
          provider={modal.addModel}
          onClose={() => setModal(null)}
          onDone={(name, modality, decisionsConfirmed) =>
            act(async () => {
              await api(`/providers/${modal.addModel.id}/models`, {
                method: "POST",
                body: { name, modality, decisions_confirmed: decisionsConfirmed },
              })
            }, "listing added")
          }
        />
      )}

      {modal && typeof modal === "object" && "del" in modal && (
        <AlertDialog open onOpenChange={(o) => !o && setModal(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Delete provider <span className="font-mono">{modal.del.name}</span>?
              </AlertDialogTitle>
              <AlertDialogDescription>
                This removes the provider, its <strong>{modal.del.keys.length}</strong> stored
                key(s) and all of its model routes. Agents calling routed models will get{" "}
                <code>no_route</code> until another provider serves them.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                onClick={() =>
                  act(async () => {
                    // Deleting retires the provider's models + tier memberships
                    // (spec §2) — the tier rewrite can be deferred; return the body.
                    return await api(`/providers/${modal.del.id}`, { method: "DELETE" })
                  }, "provider deleted")
                }
              >
                Delete provider
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}

      {modal && typeof modal === "object" && "delKey" in modal && (
        <AlertDialog open onOpenChange={(o) => !o && setModal(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Remove key <span className="font-mono">{modal.delKey[1].key_id}</span> from{" "}
                <span className="font-mono">{modal.delKey[0].name}</span>?
              </AlertDialogTitle>
              <AlertDialogDescription>
                The encrypted credential is deleted from the database. This cannot be undone.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                onClick={() =>
                  act(async () => {
                    await api(`/provider-keys/${modal.delKey[1].id}`, { method: "DELETE" })
                  }, "key removed")
                }
              >
                Remove key
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}

      {modal && typeof modal === "object" && "matrix" in modal && (
        <MatrixModal
          provider={modal.matrix}
          matrix={matrix[modal.matrix.id] ?? null}
          probeActive={probeActive}
          onClose={() => setModal(null)}
          onProbeAll={() => probeAll(modal.matrix)}
        />
      )}
    </Layout>
  )
}

function AddProviderModal({
  onClose,
  onDone,
}: {
  onClose: () => void
  onDone: (body: {
    name: string
    base_url: string
    protocol: string
    key?: { secret: string; weight: number }
    decisions_confirmed?: boolean
  }) => void
}) {
  const [step, setStep] = useState<"pick" | "form" | "key">("pick")
  const [query, setQuery] = useState("")
  const [presetId, setPresetId] = useState<string | null>(null)
  const [regionId, setRegionId] = useState("")
  const [name, setName] = useState("")
  const [baseUrl, setBaseUrl] = useState("")
  const [protocol, setProtocol] = useState<JanusProtocol>("openai_chat")
  const [secret, setSecret] = useState("")
  const [weight, setWeight] = useState(1)
  const [err, setErr] = useState("")
  // D10 (Decisions): the billable-per-decision warning must be accepted
  // before the create POST is allowed through.
  const [decisionsConfirmed, setDecisionsConfirmed] = useState(false)

  const isDecisions = isDecisionsProtocol(protocol)
  const preset = PROVIDER_PRESETS.find((p) => p.id === presetId)
  const keysUrl = preset ? presetKeysUrl(preset, regionId || undefined) : undefined

  const pickPreset = (id: string | null) => {
    setPresetId(id)
    setErr("")
    setStep("form")
    const p = PROVIDER_PRESETS.find((x) => x.id === id)
    if (!p) return
    setRegionId(p.regions?.[0]?.id ?? "")
    setName(p.id)
    setProtocol(p.defaultProtocol)
    setBaseUrl(presetEndpoints(p, undefined)[p.defaultProtocol] ?? "")
  }

  const pickRegion = (rid: string) => {
    setRegionId(rid)
    if (!preset) return
    const url = presetEndpoints(preset, rid)[protocol]
    if (url) setBaseUrl(url)
  }

  const pickProtocol = (v: string) => {
    const proto = v as JanusProtocol
    setProtocol(proto)
    if (!preset) return
    const url = presetEndpoints(preset, regionId || undefined)[proto]
    if (url) setBaseUrl(url)
  }

  const submitForm = () => {
    if (!/^https?:\/\//.test(baseUrl)) {
      setErr("base_url must start with http:// or https://")
      return
    }
    // Keyless presets (local servers, free tiers) create in one step;
    // everything else goes through the key step first — nothing is
    // written until the key is submitted or explicitly skipped.
    if (preset?.noKey) {
      onDone({ name, base_url: baseUrl, protocol, decisions_confirmed: decisionsConfirmed })
    } else {
      setStep("key")
    }
  }

  const submitAll = () =>
    onDone({
      name,
      base_url: baseUrl,
      protocol,
      key: { secret: secret.trim(), weight },
      decisions_confirmed: decisionsConfirmed,
    })

  const formIncomplete = !name || !baseUrl || (isDecisions && !decisionsConfirmed)

  const q = query.trim().toLowerCase()
  const matches = (p: ProviderPreset) =>
    !q || p.name.toLowerCase().includes(q) || p.id.includes(q)
  const groups: [string, ProviderPreset[]][] = [
    ["Vendors", PROVIDER_PRESETS.filter((p) => p.kind === "vendor" && matches(p))],
    ["Relays", PROVIDER_PRESETS.filter((p) => p.kind === "relay" && matches(p))],
    ["Local", PROVIDER_PRESETS.filter((p) => p.kind === "local" && matches(p))],
  ]
  const firstMatch = groups.flatMap(([, ps]) => ps)[0]

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
        <DialogContent title="Add provider" description="POST /api/providers">
        {step === "pick" && (
          <>
            <div className="relative">
              <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground/60" />
              <Input
                className="pl-9"
                placeholder="Search providers…"
                aria-label="Search providers"
                value={query}
                autoFocus
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && q && firstMatch) pickPreset(firstMatch.id)
                }}
              />
            </div>
            <div className="max-h-72 overflow-y-auto rounded-md border border-border/70 scrollbar-thin">
              <button
                type="button"
                onClick={() => pickPreset(null)}
                className="flex w-full items-center justify-between gap-3 border-b border-border/60 px-2.5 py-2 text-left transition-colors hover:bg-accent"
              >
                <span className="text-sm font-medium">Custom endpoint…</span>
                <span className="truncate text-xs text-muted-foreground">
                  any OpenAI/Anthropic-compatible URL
                </span>
              </button>
              {groups.map(([label, ps]) =>
                ps.length === 0 ? null : (
                  <div key={label}>
                    <div className="px-2.5 pt-2 pb-1 text-xs font-medium text-muted-foreground">
                      {label}
                    </div>
                    {ps.map((p) => (
                      <button
                        key={p.id}
                        type="button"
                        onClick={() => pickPreset(p.id)}
                        className="flex w-full items-center justify-between gap-3 px-2.5 py-1.5 text-left transition-colors hover:bg-accent"
                      >
                        <span className="text-sm font-medium">{p.name}</span>
                        {p.note && (
                          <span className="truncate text-xs text-muted-foreground">{p.note}</span>
                        )}
                      </button>
                    ))}
                  </div>
                ),
              )}
              {q && !firstMatch && (
                <div className="px-3 py-4 text-center text-sm text-muted-foreground">
                  No match — Custom endpoint takes any URL.
                </div>
              )}
            </div>
          </>
        )}
        {step === "form" && (
          <FieldGroup>
            <Field>
              <FieldLabel>Preset</FieldLabel>
              <div className="flex items-center justify-between gap-2 rounded-md border border-border/70 bg-muted/40 py-1.5 pr-1.5 pl-3">
                <span className="min-w-0 truncate text-sm font-medium">
                  {preset ? preset.name : "Custom endpoint"}
                </span>
                <Button variant="ghost" size="xs" onClick={() => setStep("pick")}>
                  Change
                </Button>
              </div>
              {preset && (preset.note || keysUrl) && (
                <FieldDescription>
                  {preset.note}
                  {preset.note && keysUrl ? " · " : ""}
                  {keysUrl && (
                    <a
                      href={keysUrl}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center gap-0.5 font-medium text-primary hover:underline"
                    >
                      Get a key
                      <ExternalLink className="size-3" />
                    </a>
                  )}
                </FieldDescription>
              )}
            </Field>
            {preset?.regions && (
              <Field>
                <FieldLabel htmlFor="provider-region">{preset.regionLabel ?? "Region"}</FieldLabel>
                <Select
                  value={regionId}
                  onValueChange={pickRegion}
                >
                  <SelectTrigger id="provider-region" size="sm">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {preset.regions.map((r) => (
                  <SelectItem key={r.id} value={r.id}>{r.name}</SelectItem>
                ))}
                  </SelectContent>
                </Select>
              </Field>
            )}
            <Field>
              <FieldLabel htmlFor="provider-name">Name</FieldLabel>
              <Input
                id="provider-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="openrouter"
                autoFocus
              />
            </Field>
            <Field data-invalid={err ? true : undefined}>
              <FieldLabel htmlFor="provider-base-url">Base URL</FieldLabel>
              <Input
                id="provider-base-url"
                value={baseUrl}
                onChange={(e) => setBaseUrl(e.target.value)}
                placeholder={preset?.endpointPlaceholder ?? "https://api.example.com/v1"}
                aria-invalid={!!err}
              />
              {preset?.endpointHint && !err && (
                <FieldDescription>{preset.endpointHint}</FieldDescription>
              )}
              {err && <FieldError>{err}</FieldError>}
            </Field>
            <Field>
              <FieldLabel htmlFor="provider-protocol">Protocol</FieldLabel>
              <Select
                value={protocol}
                onValueChange={pickProtocol}
              >
                <SelectTrigger id="provider-protocol" size="sm">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {PROTOCOLS.map((p) => (
                    <SelectItem key={p} value={p}>
                      <span className="flex flex-1 items-baseline justify-between gap-3">
                        <span>{protocolLabel(p)}</span>
                        <span className="font-mono text-xs text-muted-foreground">{p}</span>
                      </span>
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            {isDecisions && (
              <Field data-invalid={!decisionsConfirmed ? true : undefined}>
                <div className="flex items-start gap-2.5 rounded-md border border-warning/40 bg-warning/10 p-3">
                  <Checkbox
                    id="decisions-confirm"
                    checked={decisionsConfirmed}
                    onCheckedChange={(v) => setDecisionsConfirmed(v === true)}
                    className="mt-0.5"
                    aria-required
                  />
                  <label htmlFor="decisions-confirm" className="cursor-pointer text-sm leading-snug">
                    <span className="font-medium text-warning">
                      Decisions calls are billed per decision
                    </span>
                    <span className="mt-1 block text-xs text-muted-foreground">
                      The upstream charges per decision request — this is NOT covered by chat
                      token grants. Creating also requires every gateway node to advertise{" "}
                      <code>openai_decisions</code> on <code>/readyz</code> (write gate, fail
                      closed), and Decisions providers take manual listings only (no model
                      sync).
                    </span>
                  </label>
                </div>
                {!decisionsConfirmed && (
                  <FieldError>accept the Decisions billing warning to continue</FieldError>
                )}
              </Field>
            )}
          </FieldGroup>
        )}
        {step === "key" && (
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="new-key-secret">API key secret</FieldLabel>
              <Textarea
                id="new-key-secret"
                rows={3}
                value={secret}
                onChange={(e) => setSecret(e.target.value)}
                placeholder="sk-…"
                autoFocus
              />
              <FieldDescription>
                Encrypted (AES-256-GCM) on store — the plaintext is never shown again.
                {keysUrl && (
                  <>
                    {" "}
                    <a
                      href={keysUrl}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-flex items-center gap-0.5 font-medium text-primary hover:underline"
                    >
                      Get a key
                      <ExternalLink className="size-3" />
                    </a>
                  </>
                )}
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="new-key-weight">Weight</FieldLabel>
              <Input
                id="new-key-weight"
                type="number"
                min={1}
                value={weight}
                onChange={(e) => setWeight(Number(e.target.value) || 1)}
              />
            </Field>
            <KeyTester baseUrl={baseUrl} protocol={protocol} secret={secret} />
          </FieldGroup>
        )}
        <DialogFooter>
          {step === "key" && (
            <Button variant="ghost" onClick={() => setStep("form")}>
              Back
            </Button>
          )}
          {step !== "key" && (
            <Button variant="outline" onClick={onClose}>
              Cancel
            </Button>
          )}
          {step === "form" &&
            (preset?.noKey ? (
              <Button disabled={formIncomplete} onClick={submitForm}>
                <Plus />
                Add provider
              </Button>
            ) : (
              <Button disabled={formIncomplete} onClick={submitForm}>
                Next · API key
                <ArrowRight />
              </Button>
            ))}
          {step === "key" && (
            <>
              <Button
                variant="outline"
                disabled={isDecisions && !decisionsConfirmed}
                onClick={() =>
                  onDone({ name, base_url: baseUrl, protocol, decisions_confirmed: decisionsConfirmed })
                }
              >
                Skip — add key later
              </Button>
              <Button disabled={!secret.trim() || (isDecisions && !decisionsConfirmed)} onClick={submitAll}>
                <Lock />
                Add provider & key
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/** Live key probe against the vendor's model list (POST /api/providers/test-key). */
function KeyTester({
  baseUrl,
  protocol,
  secret,
}: {
  baseUrl: string
  protocol: string
  secret: string
}) {
  const [testing, setTesting] = useState(false)
  const [result, setResult] = useState<{
    ok: boolean
    error?: string
    models?: number
    detail?: string
  } | null>(null)

  // A changed secret or endpoint invalidates the previous verdict.
  useEffect(() => setResult(null), [baseUrl, protocol, secret])

  const run = async () => {
    setTesting(true)
    setResult(null)
    try {
      setResult(
        await api("/providers/test-key", {
          method: "POST",
          body: { base_url: baseUrl, protocol, secret: secret.trim() },
        }),
      )
    } catch (e: any) {
      setResult({ ok: false, error: "unreachable", detail: e.message })
    } finally {
      setTesting(false)
    }
  }

  const message = result
    ? result.ok
      ? `Valid — ${result.models ?? 0} models listed`
      : result.error === "invalid_key"
        ? "Vendor rejected this key"
        : result.error === "unverifiable"
          ? "Can't verify here — no model list on this endpoint; you can still save"
          : result.error === "unreachable"
            ? `Endpoint unreachable (${result.detail})`
            : `Upstream error (${result.detail})`
    : ""

  return (
    <div className="flex min-h-8 flex-wrap items-center gap-2">
      <Button
        type="button"
        variant="outline"
        size="xs"
        disabled={!secret.trim() || testing}
        onClick={run}
      >
        {testing ? <LoaderCircle className="animate-spin" /> : <Zap />}
        {testing ? "Testing…" : "Test key"}
      </Button>
      {result && (
        <span
          className={
            "flex items-center gap-1 text-xs " +
            (result.ok
              ? "text-success"
              : result.error === "unverifiable"
                ? "text-warning"
                : "text-destructive")
          }
        >
          {result.ok ? <Check className="size-3.5" /> : <CircleAlert className="size-3.5" />}
          {message}
        </span>
      )}
    </div>
  )
}

function AddKeyModal({
  provider,
  onClose,
  onDone,
}: {
  provider: Provider
  onClose: () => void
  onDone: (b: any) => void
}) {
  const [secret, setSecret] = useState("")
  const [weight, setWeight] = useState(1)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        title={`Add key · ${provider.name}`}
        description={`POST /api/providers/${provider.id}/keys`}
      >
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="key-secret">API key secret</FieldLabel>
            <Textarea
              id="key-secret"
              rows={3}
              value={secret}
              onChange={(e) => setSecret(e.target.value)}
              placeholder="sk-…"
              autoFocus
            />
            <FieldDescription>
              Stored as an AES-256-GCM envelope. The plaintext is discarded after encryption and can
              never be shown again.
            </FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="key-weight">Weight</FieldLabel>
            <Input
              id="key-weight"
              type="number"
              min={1}
              value={weight}
              onChange={(e) => setWeight(Number(e.target.value) || 1)}
            />
          </Field>
          <KeyTester baseUrl={provider.base_url} protocol={provider.protocol} secret={secret} />
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={!secret} onClick={() => onDone({ secret, weight })}>
            <Lock />
            Encrypt & store
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function ProviderListings({
  provider,
  entitlements,
  onToggle,
  onAdd,
}: {
  provider: Provider
  entitlements: EntitlementListing[] | null
  onToggle: (m: ProviderModel) => void
  onAdd: () => void
}) {
  // The filter state lives here (not in Providers) so typing re-renders
  // only this card, not the whole providers table.
  const [filter, setFilter] = useState("")
  const listings = provider.models ?? []
  const q = filter.trim().toLowerCase()
  const matched = useMemo(
    () => (q ? listings.filter((m) => m.name.toLowerCase().includes(q)) : listings),
    [listings, q],
  )
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const { slice: shown, pageCount, page: safePage, total } = useClientPagination(matched, pageSize, page)
  useEffect(() => setPage(1), [filter])
  const entByName = useMemo(
    () => new Map((entitlements ?? []).map((l) => [l.model_name, l])),
    [entitlements],
  )
  const [tests, setTests] = useState<Record<number, { loading?: boolean; r?: ListingTestResult }>>({})
  const runTest = async (m: ProviderModel) => {
    setTests((t) => ({ ...t, [m.id]: { loading: true } }))
    try {
      const r = await api(`/providers/${provider.id}/models/${m.id}/test`, {
        method: "POST",
        body: {},
      })
      setTests((t) => ({ ...t, [m.id]: { r } }))
    } catch (e) {
      // Dashboard-side rejection (no key / decrypt) — surface as a result
      // badge, keeping the server's code/status when available.
      const err =
        e instanceof ApiError
          ? { code: e.code, status: e.status, message: e.message }
          : { code: "request_failed", status: null as number | null, message: e instanceof Error ? e.message : String(e) }
      setTests((t) => ({
        ...t,
        [m.id]: { r: { ok: false, kind: "error", http_status: err.status, error_code: err.code, error_message: err.message } },
      }))
    }
  }
  return (
    <div className="flex flex-col gap-2">
      {isDecisionsProtocol(provider.protocol) && <DecisionsProbeBar provider={provider} />}
      <div className="flex items-center gap-2">
        <div className="text-xs font-medium text-muted-foreground">
          Models
        </div>
        <Badge variant="secondary" className="font-mono text-[11px] tabular-nums">
          {listings.length}
        </Badge>
        <div className="flex-1" />
        {listings.length > 8 && (
          <div className="relative">
            <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground/60" />
            <Input
              className="h-8 w-48 pl-8"
              placeholder="Filter models"
              aria-label="Filter models"
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
            />
          </div>
        )}
        <Button variant="outline" size="xs" onClick={onAdd}>
          <Plus />
          Add model
        </Button>
      </div>
      {listings.length === 0 && (
        <span className="text-sm text-muted-foreground">
          {isDecisionsProtocol(provider.protocol)
            ? "No listings yet. Decisions providers never sync — add listings manually by name."
            : "No listings yet. Sync models or add one by name."}
        </span>
      )}
      {listings.length > 0 && (
        <div className="max-h-64 overflow-y-auto rounded-md border border-border/70 bg-background scrollbar-thin">
          {shown.map((m) => {
            const ent = entByName.get(m.name)
            const st = tests[m.id]
            return (
            <div
              key={m.id}
              className="flex items-center gap-3 border-b border-border/60 px-3 py-1.5 transition-colors last:border-b-0 hover:bg-muted/50"
            >
              <span className="font-mono text-sm">{m.name}</span>
              {m.modality && m.modality !== "chat" && (
                <Badge variant="secondary" className="font-mono text-[11px]">
                  {m.modality}
                </Badge>
              )}
              <EntitlementBadge listing={ent} keysTotal={provider.keys.length} />
              {st?.r && <TestResultBadge r={st.r} />}
              <div className="flex-1" />
              <StateBadge enabled={m.enabled} />
              <div className="flex items-center">
                {/* The generic per-listing Test posts a chat-shaped
                 * request — wrong shape for Decisions; the budgeted
                 * DecisionsProbeBar above is the probe path there. */}
                {!isDecisionsProtocol(provider.protocol) && (
                  <IconAction
                    label={st?.loading ? "Testing…" : "Test"}
                    disabled={!!st?.loading}
                    onClick={() => runTest(m)}
                  >
                    {st?.loading ? <LoaderCircle className="animate-spin" /> : <Zap />}
                  </IconAction>
                )}
                <IconAction label={m.enabled ? "Disable" : "Enable"} onClick={() => onToggle(m)}>
                  <Power />
                </IconAction>
              </div>
            </div>
            )
          })}
          {shown.length === 0 && (
            <div className="px-3 py-4 text-center text-sm text-muted-foreground">
              No listings match this filter.
            </div>
          )}
        </div>
      )}
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
  )
}

type ListingTestResult = {
  ok: boolean
  kind: string
  http_status: number | null
  latency_ms?: number
  key_label?: string
  error_code?: string | null
  error_message?: string | null
  snippet?: string
}

/** One-shot upstream test result: green ok + latency (reply snippet and
 * key on hover), red kind · status · code (message on hover). */
function TestResultBadge({ r }: { r: ListingTestResult }) {
  if (r.ok) {
    return (
      <Badge
        variant="success"
        className="font-mono text-[11px] tabular-nums"
        title={`via key ${r.key_label} · replied: ${r.snippet || "(empty)"}`}
      >
        ok · {r.latency_ms} ms
      </Badge>
    )
  }
  const label = [r.kind, r.http_status, r.error_code].filter(Boolean).join(" · ")
  return (
    <Badge
      variant="destructive"
      className="max-w-56 truncate font-mono text-[11px]"
      title={`${r.error_message || label}${r.key_label ? ` — via key ${r.key_label}` : ""}`}
    >
      {label}
    </Badge>
  )
}

/** Matrix badge per listing (spec A.5): ok N/K / partial n/K (amber,
 * tooltip) / deny 0/K (grey) / none (unknown). */
function EntitlementBadge({
  listing,
  keysTotal,
}: {
  listing?: EntitlementListing
  keysTotal: number
}) {
  if (!listing || listing.badge === null || keysTotal === 0) return null
  if (listing.badge === "ok") {
    return (
      <Badge variant="success" className="font-mono text-[11px] tabular-nums">
        ok {listing.ok}/{listing.keys}
      </Badge>
    )
  }
  if (listing.badge === "partial") {
    return (
      <Tooltip
        content={`ok on ${listing.ok}/${listing.keys} keys · deny ${listing.deny} · balance ${listing.balance} · unknown ${listing.unknown}`}
      >
        <Badge variant="warning" className="cursor-help font-mono text-[11px] tabular-nums">
          partial {listing.ok}/{listing.keys}
        </Badge>
      </Tooltip>
    )
  }
  return (
    <Tooltip
      content={`deny-marked on every key${listing.stale_listing
        ? " — likely renamed or removed upstream; re-sync the provider rather than debugging fail-open churn"
        : ""}`}
    >
      <Badge
        variant="secondary"
        className="cursor-help font-mono text-[11px] tabular-nums text-muted-foreground"
      >
        deny 0/{listing.keys}
        {listing.stale_listing ? " · stale-listing?" : ""}
      </Badge>
    </Tooltip>
  )
}

/** Full matrix modal: listings x keys cells with statuses and budget. */
function MatrixModal({
  provider,
  matrix,
  probeActive,
  onClose,
  onProbeAll,
}: {
  provider: Provider
  matrix: EntitlementMatrix | null
  probeActive: boolean
  onClose: () => void
  onProbeAll: () => void
}) {
  const keys = matrix?.keys ?? []
  const allListings = matrix?.listings ?? []
  const [mpage, setMPage] = useState(1)
  const [mpageSize, setMPageSize] = useState(20)
  const { slice: listings, pageCount, page: safeMPage, total } = useClientPagination(
    allListings,
    mpageSize,
    mpage,
  )
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        size="lg"
        title={`Entitlement matrix · ${provider.name}`}
        description={`GET /api/entitlements?provider_id=${provider.id} — per-(key, model) probe evidence. ok rows never exclude a key; deny expires after 24h, balance after 1h.`}
      >
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          {probeActive && (
            <span className="flex items-center gap-1 text-warning">
              <LoaderCircle className="size-3.5 animate-spin" /> probe running — updating…
            </span>
          )}
          {matrix && (
            <span>
              probe budget today: {matrix.budget.calls}/{matrix.budget.daily_limit} calls
              (healing {matrix.budget.healing_calls})
            </span>
          )}
          <div className="flex-1" />
          <Button variant="outline" size="xs" onClick={onProbeAll}>
            <Zap />
            Probe all
          </Button>
        </div>
        <div className="max-h-[60vh] overflow-auto rounded-md border border-border/70 scrollbar-thin">
          <Table flush>
            <TableHeader>
              <TableRow>
                <TableHead className="sticky left-0 bg-background">Model</TableHead>
                {keys.map((k) => (
                  <TableHead key={k.provider_key_id} className="font-mono text-[11px]">
                    {k.label}
                    {k.broken ? " ⛔" : ""}
                  </TableHead>
                ))}
              </TableRow>
            </TableHeader>
            <TableBody>
              {listings.length === 0 && (
                <TableRow>
                  <TableCell colSpan={keys.length + 1} className="text-center text-sm text-muted-foreground">
                    no probe evidence yet — run a probe
                  </TableCell>
                </TableRow>
              )}
              {listings.map((l) => (
                <TableRow key={l.model_name}>
                  <TableCell className="sticky left-0 bg-background font-mono text-xs">
                    {l.model_name}
                  </TableCell>
                  {keys.map((k) => {
                    const cell = l.by_key[String(k.provider_key_id)]
                    return (
                      <TableCell key={k.provider_key_id} className="p-1">
                        <MatrixCell cell={cell} />
                      </TableCell>
                    )
                  })}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
        <Pagination
          page={safeMPage}
          pageCount={pageCount}
          total={total}
          pageSize={mpageSize}
          onPageChange={setMPage}
          onPageSizeChange={(n) => {
            setMPageSize(n)
            setMPage(1)
          }}
        />
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Close
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function MatrixCell({ cell }: { cell?: EntitlementListing["by_key"][string] }) {
  if (!cell) return <span className="text-muted-foreground">—</span>
  if (cell.status === "ok") {
    return (
      <Badge
        variant={cell.error_code === "input_shape" ? "outline" : "success"}
        className="font-mono text-[10px]"
      >
        {cell.error_code === "input_shape" ? "shape" : "ok"}
        {cell.escalated ? "!" : ""}
      </Badge>
    )
  }
  if (cell.status === "deny") return <Badge variant="secondary" className="font-mono text-[10px]">deny</Badge>
  if (cell.status === "balance") return <Badge variant="warning" className="font-mono text-[10px]">bal</Badge>
  if (cell.status === "broken") return <Badge variant="destructive" className="font-mono text-[10px]">broken</Badge>
  return <span className="font-mono text-[10px] text-muted-foreground">unknown</span>
}

/** Decisions probe (spec 2026-10-07 §4.3): one budgeted (20/day,
 * 5-min cooldown) BILLABLE ping against {base}/decisions with the
 * stored provider key, on the lowest-id enabled listing. */
function DecisionsProbeBar({ provider }: { provider: Provider }) {
  const [state, setState] = useState<DecisionsProbeState | null>(null)
  const [running, setRunning] = useState(false)

  useEffect(() => {
    api<DecisionsProbeState>(`/providers/${provider.id}/decisions-probe`)
      .then(setState)
      .catch(() => {})
  }, [provider.id])

  const run = async () => {
    setRunning(true)
    try {
      const r = await api<{ result: DecisionsProbeResult; state: DecisionsProbeState }>(
        `/providers/${provider.id}/decisions-probe`,
        { method: "POST", body: {} },
      )
      setState(r.state)
      toast.success(
        `Decisions probe: ${r.result.outcome}` +
          (r.result.http_status != null ? ` · HTTP ${r.result.http_status}` : "") +
          ` · ${r.result.latency_ms} ms · budget ${r.state.probes_today}/${r.state.daily_limit}`,
      )
    } catch (e: any) {
      toast.error(e.message)
      // Refetch: a 429 updates budget/cooldown display even on failure.
      api<DecisionsProbeState>(`/providers/${provider.id}/decisions-probe`)
        .then(setState)
        .catch(() => {})
    } finally {
      setRunning(false)
    }
  }

  const last = state?.last_result
  return (
    <div className="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-md border border-border/70 bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
      <CircleAlert className="size-3.5 shrink-0 text-warning" aria-hidden />
      <span className="font-medium text-warning">Decisions probes are billable</span>
      <span className="tabular-nums">
        · budget {state ? `${state.probes_today}/${state.daily_limit} today` : "20/day"}
      </span>
      {state && state.cooldown_remaining_sec > 0 && (
        <span className="tabular-nums">
          · cooldown ~{Math.ceil(state.cooldown_remaining_sec / 60)} min
        </span>
      )}
      {state?.listing_pick && (
        <span className="truncate">
          · probes <span className="font-mono">{state.listing_pick}</span>
        </span>
      )}
      {last && (
        <Tooltip content={new Date(last.ran_at + "Z").toLocaleString()}>
            <span
              className={
                last.outcome === "ok"
                  ? "text-success"
                  : last.outcome === "bad_key"
                    ? "text-destructive"
                    : "text-warning"
              }
            >
              · last: {last.outcome}
              {last.http_status != null ? ` (HTTP ${last.http_status})` : ""} · {last.latency_ms} ms
            </span>
        </Tooltip>
      )}
      <div className="flex-1" />
      <Button variant="outline" size="xs" disabled={running} onClick={run}>
        {running ? <LoaderCircle className="animate-spin" /> : <Zap />}
        {running ? "Probing…" : "Probe decisions"}
      </Button>
    </div>
  )
}

function AddListingModal({
  provider,
  onClose,
  onDone,
}: {
  provider: Provider
  onClose: () => void
  onDone: (name: string, modality: string, decisionsConfirmed: boolean) => void
}) {
  const [name, setName] = useState("")
  const [modality, setModality] = useState("chat")
  const [decisionsConfirmed, setDecisionsConfirmed] = useState(false)
  const isDecisions = isDecisionsProtocol(provider.protocol)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        title={`Add model · ${provider.name}`}
        description={
          isDecisions
            ? "Manual listing (Decisions providers never sync) — the name is the upstream model id used verbatim on /v1/decisions."
            : "Inventory entry — the name is callable directly; binding on Router curates janus-auto."
        }
      >
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="listing-name">Upstream model id</FieldLabel>
            <Input
              id="listing-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder={isDecisions ? "gpt-5.1-decisions" : "qwen-turbo"}
              autoFocus
            />
          </Field>
          {isDecisions ? (
            <Field>
              <div className="flex items-start gap-2.5 rounded-md border border-warning/40 bg-warning/10 p-3">
                <Checkbox
                  id="listing-decisions-confirm"
                  checked={decisionsConfirmed}
                  onCheckedChange={(v) => setDecisionsConfirmed(v === true)}
                  className="mt-0.5"
                  aria-required
                />
                <label
                  htmlFor="listing-decisions-confirm"
                  className="cursor-pointer text-sm leading-snug"
                >
                  <span className="font-medium text-warning">
                    This listing is billed per decision
                  </span>
                  <span className="mt-1 block text-xs text-muted-foreground">
                    Calls to it are charged per decision by the upstream and are not covered by
                    chat token grants.
                  </span>
                </label>
              </div>
            </Field>
          ) : (
            <Field>
              <FieldLabel htmlFor="listing-modality">Modality</FieldLabel>
              <Select
                value={modality}
                onValueChange={setModality}
              >
                <SelectTrigger id="listing-modality" size="sm">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {["chat", "image", "tts", "asr", "video", "computer", "embedding"].map((m) => (
                <SelectItem key={m} value={m}>{m}</SelectItem>
              ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                Non-chat modalities serve their dedicated endpoint (images / audio / video).
              </FieldDescription>
            </Field>
          )}
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={!name.trim() || (isDecisions && !decisionsConfirmed)}
            onClick={() => onDone(name.trim(), isDecisions ? "chat" : modality, decisionsConfirmed)}
          >
            <Plus />
            Add
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

/** H8-D1 (spec 2026-10-15-maturity-hardening): operator-entered
 * per-1M-token prices powering the Usage page's Spend card. Dashboard-
 * only data (the gateway never reads it); display reporting only —
 * never a routing signal (H8-D4). Model-name autocomplete comes from
 * the agent-visible surface (bound + synced listing names); free text
 * is allowed so a not-yet-synced listing can be priced ahead of
 * traffic. */
// Build-time feature flag: build the SPA with VITE_FLAG_MODEL_PRICES=1 to
// bring the per-1M-token price editor back once its UX is reworked
// (hidden 2026-10-18). The /prices API and the Usage spend report are
// unaffected. Remote toggling (GrowthBook/OpenFeature) is the upgrade path
// if flags ever need to flip without a rebuild.
const SHOW_MODEL_PRICES = import.meta.env.VITE_FLAG_MODEL_PRICES === "1"

function ModelPricesCard() {
  const [prices, setPrices] = useState<ModelPrice[] | null>(null)
  const [error, setError] = useState("")
  const [names, setNames] = useState<string[]>([])
  const [name, setName] = useState<string | null>(null)
  const [inPrice, setInPrice] = useState("")
  const [outPrice, setOutPrice] = useState("")
  const [currency, setCurrency] = useState("CNY")
  const [saving, setSaving] = useState(false)

  const load = () =>
    api("/prices")
      .then((r) => setPrices(r.prices))
      .catch((e) => setError(e.message))

  useEffect(() => {
    load()
    // Autocomplete options: every public model name (bound + listings).
    api("/keys/grantable-models")
      .then((r) => setNames(r.models.map((m: { name: string }) => m.name)))
      .catch(() => {})
  }, [])

  const save = async () => {
    if (!name || !name.trim()) {
      toast.error("Pick or type a model name")
      return
    }
    const inp = Number(inPrice)
    const outp = Number(outPrice)
    if (!Number.isFinite(inp) || inp < 0 || !Number.isFinite(outp) || outp < 0) {
      toast.error("Prices must be non-negative numbers (per 1M tokens)")
      return
    }
    setSaving(true)
    try {
      await api(`/prices/${encodeURIComponent(name.trim())}`, {
        method: "PUT",
        body: { input_per_mtok: inp, output_per_mtok: outp, currency },
      })
      toast.success(`price saved for ${name.trim()} — Usage spend updates on next load`)
      setName(null)
      setInPrice("")
      setOutPrice("")
      load()
    } catch (e) {
      toast.error((e as ApiError).message)
    } finally {
      setSaving(false)
    }
  }

  const remove = async (p: ModelPrice) => {
    try {
      await api(`/prices/${encodeURIComponent(p.model_name)}`, { method: "DELETE" })
      toast.success(`price removed for ${p.model_name}`)
      load()
    } catch (e) {
      toast.error((e as ApiError).message)
    }
  }

  const edit = (p: ModelPrice) => {
    setName(p.model_name)
    setInPrice(String(p.input_per_mtok))
    setOutPrice(String(p.output_per_mtok))
    setCurrency(p.currency)
  }

  return (
    <Card className="w-full self-start overflow-hidden animate-fade-up">
      <CardHeader className="border-b">
        <CardTitle>Model prices</CardTitle>
        <CardDescription>
          Per-1M-token prices for the Usage page's Spend report — display only, no
          routing. Models without a price row show as "—" (never estimated).
        </CardDescription>
      </CardHeader>
      <CardContent className="px-0">
        {error && <div className="px-5 pb-3"><span className="text-xs text-destructive">{error}</span></div>}
        {!prices ? (
          <Loading />
        ) : prices.length === 0 ? (
          <EmptyState
            title="No prices set"
            description="Add a per-1M-token price below to start tracking spend on the Usage page."
          />
        ) : (
          <Table flush>
            <TableHeader>
              <TableRow>
                <TableHead>Model</TableHead>
                <TableHead className="text-right">In / Mtok</TableHead>
                <TableHead className="text-right">Out / Mtok</TableHead>
                <TableHead>Currency</TableHead>
                <TableHead>Updated</TableHead>
                <TableHead className="w-10">
                  <span className="sr-only">Actions</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {prices.map((p) => (
                <TableRow key={p.model_name}>
                  <TableCell className="font-mono text-xs">{p.model_name}</TableCell>
                  <TableCell className="text-right tabular-nums">{p.input_per_mtok}</TableCell>
                  <TableCell className="text-right tabular-nums">{p.output_per_mtok}</TableCell>
                  <TableCell>{p.currency}</TableCell>
                  <TableCell className="font-mono text-xs text-muted-foreground">
                    {fmtIsoLocalSeconds(p.updated_at)}
                  </TableCell>
                  <TableCell>
                    <div className="flex items-center justify-end gap-1">
                      <IconAction label={`Edit price for ${p.model_name}`} onClick={() => edit(p)}>
                        <Pencil />
                      </IconAction>
                      <IconAction label={`Delete price for ${p.model_name}`} onClick={() => remove(p)}>
                        <Trash2 />
                      </IconAction>
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        <div className="flex flex-wrap items-end gap-2 border-t px-5 py-4">
          <div className="w-64">
            <FieldLabel htmlFor="price-model">Model</FieldLabel>
            <ComboboxSingle
              id="price-model"
              value={name}
              options={names}
              onChange={setName}
              placeholder="Pick or type…"
              allowCreate
            />
          </div>
          <div className="w-28">
            <FieldLabel htmlFor="price-in">In / Mtok</FieldLabel>
            <Input
              id="price-in"
              type="number"
              min="0"
              step="0.0001"
              value={inPrice}
              onChange={(e) => setInPrice(e.target.value)}
              placeholder="2.50"
            />
          </div>
          <div className="w-28">
            <FieldLabel htmlFor="price-out">Out / Mtok</FieldLabel>
            <Input
              id="price-out"
              type="number"
              min="0"
              step="0.0001"
              value={outPrice}
              onChange={(e) => setOutPrice(e.target.value)}
              placeholder="10.00"
            />
          </div>
          <div className="w-28">
            <FieldLabel htmlFor="price-cur">Currency</FieldLabel>
            <Select
              value={currency}
              onValueChange={setCurrency}
            >
              <SelectTrigger id="price-cur" size="sm" aria-label="Currency">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="CNY">CNY</SelectItem>
                <SelectItem value="USD">USD</SelectItem>
              </SelectContent>
            </Select>
          </div>
          {/* Default size (h-9) matches the Input row so the buttons sit
              flush with the labeled fields above them. */}
          <Button disabled={saving} onClick={save}>
            {saving ? <LoaderCircle className="animate-spin" /> : <Plus />}
            {prices?.some((p) => p.model_name === name) ? "Update" : "Save"}
          </Button>
          {name && (
            <Button
              variant="ghost"
              onClick={() => {
                setName(null)
                setInPrice("")
                setOutPrice("")
                setCurrency("CNY")
              }}
            >
              <X />
              Clear
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  )
}
