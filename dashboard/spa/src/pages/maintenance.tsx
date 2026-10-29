import {
  ChangeEvent,
  ReactNode,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react"
import { Link } from "@tanstack/react-router"
import { Download, LoaderCircle, Save, Upload } from "lucide-react"
import { toast } from "sonner"
import { ApiError, api, apiFetch } from "../api"
import { EmptyState, ErrorFlash, Layout, Loading } from "../components"
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
import { Button, buttonVariants } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"

type SchedConfig = {
  health: boolean
  rtt: boolean
  geo: boolean
  probe: boolean
  probe_max_hourly: number
  unary_fallback: boolean
}

type ModelSyncConfig = {
  interval_sec: number
}

type FleetConfig = {
  enabled: boolean
}

type SchedLive = {
  health_enabled?: boolean
  rtt_enabled?: boolean
  geo_enabled?: boolean
  geo_desired?: boolean | null
  probe_enabled?: boolean
  unary_fallback_enabled?: boolean
  probe_max_hourly?: number
  model_sync_interval_sec?: number
  mmdb_present?: boolean
  fleet_desired?: boolean | null
  fleet_effective?: boolean
  sched_geo_refused_total?: number
  knobs_source?: Record<string, string> | null
}

type NodeRow = {
  id: number
  name: string
  enabled: boolean
  health: { status?: string; role?: string } | null
}

type ConfirmKind = "probe" | "unary_fallback" | "fleet" | null

type SchedScrapeResponse =
  | { ok: true; sched: SchedLive }
  | { ok: false; error?: string }

const SCHED_DEFAULTS: SchedConfig = {
  health: false,
  rtt: false,
  geo: false,
  probe: false,
  probe_max_hourly: 10,
  unary_fallback: false,
}

function modelSyncIntervalValid(sec: number): boolean {
  return sec === 0 || sec >= 60
}

function KnobButton({
  label,
  on,
  disabled,
  onClick,
  title,
}: {
  label: string
  on: boolean
  disabled?: boolean
  onClick: () => void
  title?: string
}) {
  return (
    <Button
      type="button"
      variant={on ? "secondary" : "outline"}
      size="xs"
      disabled={disabled}
      aria-pressed={on}
      title={title}
      onClick={onClick}
    >
      <span
        className={`size-1.5 rounded-full ${on ? "bg-success" : "bg-muted-foreground/40"}`}
      />
      {label}
    </Button>
  )
}

function liveBoolCell(on: boolean | undefined) {
  if (on === undefined) return "—"
  return (
    <span className="inline-flex items-center gap-1.5">
      <span
        className={`size-1.5 rounded-full ${on ? "bg-success" : "bg-muted-foreground/40"}`}
      />
      {on ? "on" : "off"}
    </span>
  )
}

const BACKUP_SECTIONS = [
  "providers",
  "provider_keys",
  "listings",
  "models",
  "routes",
  "agent_keys",
  "grants",
  "auto_router",
  "auto_router_reorder",
] as const

const BACKUP_SECTION_LABEL: Record<(typeof BACKUP_SECTIONS)[number], string> = {
  providers: "Providers",
  provider_keys: "Provider keys",
  listings: "Listings",
  models: "Models",
  routes: "Routes",
  agent_keys: "Agent keys",
  grants: "Grants",
  auto_router: "Auto router",
  auto_router_reorder: "Auto router reorder",
}

type BackupDeleteCounts = { explicit: number; cascade: number }

type BackupSectionCounts = {
  insert: number
  update: number
  delete: BackupDeleteCounts
  unchanged: number
}

type BackupPlan = {
  mode: string
  apply: boolean
  sections: Record<string, BackupSectionCounts>
  warnings: string[]
  generation?: number
  would_noop?: boolean
  noop?: boolean
  source_config_generation?: number
}

type BackupFlags = { replace: boolean; foreign: boolean }

type DriftField = "insert" | "update" | "unchanged" | "delete.explicit" | "delete.cascade"

type DriftRow = {
  section: string
  field: DriftField
  preview: number
  applied: number
  loud: boolean
}

const DRIFT_FIELD_LABEL: Record<DriftField, string> = {
  insert: "insert",
  update: "update",
  unchanged: "unchanged",
  "delete.explicit": "delete (explicit)",
  "delete.cascade": "delete (cascade)",
}

function backupCount(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0
}

function backupSectionCounts(raw: unknown): BackupSectionCounts {
  const row = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {}
  const del =
    row.delete && typeof row.delete === "object" ? (row.delete as Record<string, unknown>) : {}
  return {
    insert: backupCount(row.insert),
    update: backupCount(row.update),
    delete: { explicit: backupCount(del.explicit), cascade: backupCount(del.cascade) },
    unchanged: backupCount(row.unchanged),
  }
}

function normalizeBackupPlan(raw: unknown): BackupPlan {
  const body = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {}
  const rawSections =
    body.sections && typeof body.sections === "object"
      ? (body.sections as Record<string, unknown>)
      : {}
  const sections: Record<string, BackupSectionCounts> = {}
  for (const name of BACKUP_SECTIONS) sections[name] = backupSectionCounts(rawSections[name])
  const warnings = Array.isArray(body.warnings)
    ? body.warnings.filter((w): w is string => typeof w === "string")
    : []
  return {
    mode: typeof body.mode === "string" ? body.mode : "merge",
    apply: body.apply === true,
    sections,
    warnings,
    generation: typeof body.generation === "number" ? body.generation : undefined,
    would_noop: body.would_noop === true ? true : undefined,
    noop: body.noop === true ? true : undefined,
    source_config_generation:
      typeof body.source_config_generation === "number" ? body.source_config_generation : undefined,
  }
}

function backupDrift(preview: BackupPlan, applied: BackupPlan): DriftRow[] {
  const rows: DriftRow[] = []
  for (const section of BACKUP_SECTIONS) {
    const before = preview.sections[section]
    const after = applied.sections[section]
    const cells: [DriftField, number, number, boolean][] = [
      ["insert", before.insert, after.insert, true],
      ["delete.explicit", before.delete.explicit, after.delete.explicit, true],
      ["delete.cascade", before.delete.cascade, after.delete.cascade, true],
      ["update", before.update, after.update, false],
      ["unchanged", before.unchanged, after.unchanged, false],
    ]
    for (const [field, previewN, appliedN, loud] of cells) {
      if (previewN !== appliedN) {
        rows.push({ section, field, preview: previewN, applied: appliedN, loud })
      }
    }
  }
  return rows
}

function filenameFromContentDisposition(header: string | null): string | null {
  if (!header) return null
  const starred = /filename\*=(?:UTF-8''|utf-8'')([^;]+)/i.exec(header)
  if (starred?.[1]) {
    const raw = starred[1].trim().replace(/^"|"$/g, "")
    try {
      return decodeURIComponent(raw)
    } catch {
      return raw
    }
  }
  const quoted = /filename="([^"]+)"/i.exec(header)
  if (quoted?.[1]) return quoted[1]
  const plain = /filename=([^;]+)/i.exec(header)
  if (plain?.[1]) return plain[1].trim().replace(/^"|"$/g, "")
  return null
}

function safeDownloadName(name: string | null): string {
  const base = (name ?? "janus-config-backup.json").split(/[/\\]/).pop() || "janus-config-backup.json"
  const cleaned = base.replace(/[^A-Za-z0-9._-]+/g, "_")
  return cleaned.endsWith(".json") ? cleaned : `${cleaned}.json`
}

function saveBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = filename
  anchor.rel = "noopener"
  document.body.appendChild(anchor)
  try {
    anchor.click()
  } finally {
    anchor.remove()
    URL.revokeObjectURL(url)
  }
}

function restoreQuery(flags: BackupFlags, apply: boolean): string {
  const params = new URLSearchParams()
  params.set("mode", flags.replace ? "replace" : "merge")
  if (flags.foreign) params.set("allow_foreign_keys", "1")
  if (apply) {
    params.set("apply", "1")
    const members = ["apply"]
    if (flags.replace) members.push("replace")
    if (flags.foreign) members.push("allow_foreign_keys")
    params.set("confirm", members.join(","))
  }
  return params.toString()
}

function actionMessage(error: unknown): string {
  if (error instanceof ApiError) return error.message
  if (error instanceof Error) return error.message
  return String(error)
}

function BackupPlanTable({ plan }: { plan: BackupPlan }) {
  return (
    <div className="overflow-x-auto rounded-md border">
      <table className="w-full text-sm">
        <thead className="text-xs text-muted-foreground">
          <tr className="border-b">
            <th scope="col" className="px-3 py-2 text-left font-medium">
              Section
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Insert
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Update
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Delete (explicit)
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Delete (cascade)
            </th>
            <th scope="col" className="px-3 py-2 text-right font-medium">
              Unchanged
            </th>
          </tr>
        </thead>
        <tbody>
          {BACKUP_SECTIONS.map((name) => {
            const counts = plan.sections[name]
            return (
              <tr key={name} className="border-b last:border-0">
                <th scope="row" className="px-3 py-1.5 text-left font-medium">
                  {BACKUP_SECTION_LABEL[name]}
                </th>
                <td className="px-3 py-1.5 text-right tabular-nums">{counts.insert}</td>
                <td className="px-3 py-1.5 text-right tabular-nums">{counts.update}</td>
                <td className="px-3 py-1.5 text-right tabular-nums">{counts.delete.explicit}</td>
                <td className="px-3 py-1.5 text-right tabular-nums">{counts.delete.cascade}</td>
                <td className="px-3 py-1.5 text-right tabular-nums">{counts.unchanged}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function BackupWarnings({ warnings }: { warnings: string[] }) {
  if (warnings.length === 0) return null
  return (
    <ul className="list-disc space-y-1 pl-5 text-sm text-warning">
      {warnings.map((warning, index) => (
        <li key={`${index}-${warning}`}>{warning}</li>
      ))}
    </ul>
  )
}

function ConfigBackupCard() {
  const [file, setFile] = useState<File | null>(null)
  const [replaceMode, setReplaceMode] = useState(false)
  const [allowForeignKeys, setAllowForeignKeys] = useState(false)
  const [plan, setPlan] = useState<BackupPlan | null>(null)
  const [planFlags, setPlanFlags] = useState<BackupFlags | null>(null)
  const [applied, setApplied] = useState<BackupPlan | null>(null)
  const [drift, setDrift] = useState<DriftRow[]>([])
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [actionError, setActionError] = useState("")
  const [busy, setBusy] = useState<"export" | "preview" | "apply" | "sync" | null>(null)

  const flags: BackupFlags = { replace: replaceMode, foreign: allowForeignKeys }
  const previewCurrent =
    plan !== null &&
    planFlags !== null &&
    planFlags.replace === replaceMode &&
    planFlags.foreign === allowForeignKeys
  const formLocked = busy === "preview" || busy === "apply" || confirmOpen
  const loudDrift = drift.filter((row) => row.loud)
  const infoDrift = drift.filter((row) => !row.loud)

  const clearPreview = () => {
    setPlan(null)
    setPlanFlags(null)
  }

  const onFile = (event: ChangeEvent<HTMLInputElement>) => {
    setFile(event.target.files?.[0] ?? null)
    clearPreview()
    setApplied(null)
    setDrift([])
    setActionError("")
  }

  const onReplace = (next: boolean) => {
    setReplaceMode(next)
    clearPreview()
    setActionError("")
  }

  const onForeign = (next: boolean) => {
    setAllowForeignKeys(next)
    clearPreview()
    setActionError("")
  }

  const exportBackup = async () => {
    setBusy("export")
    setActionError("")
    try {
      const res = await apiFetch("/config/backup")
      const warning = res.headers.get("X-Janus-Backup-Warning")?.trim()
      const filename = safeDownloadName(filenameFromContentDisposition(res.headers.get("Content-Disposition")))
      const blob = await res.blob()
      saveBlob(blob, filename)
      if (warning) {
        toast.warning(
          `Backup exceeds the restore cap (${warning}). The file downloaded, but restore will refuse it until the cap is raised and the dashboard is restarted.`,
        )
      } else {
        toast.success(`Downloaded ${filename}`)
      }
    } catch (error: unknown) {
      const message = actionMessage(error)
      setActionError(message)
      toast.error(message)
    } finally {
      setBusy(null)
    }
  }

  const postRestore = async (target: File, apply: boolean): Promise<BackupPlan> => {
    const res = await apiFetch(`/config/restore?${restoreQuery(flags, apply)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: target,
    })
    const data: unknown = await res.json().catch(() => null)
    if (!data || typeof data !== "object") {
      throw new ApiError("restore response was not JSON", "invalid_json", res.status)
    }
    return normalizeBackupPlan(data)
  }

  const previewRestore = async () => {
    if (!file) return
    setBusy("preview")
    setActionError("")
    setApplied(null)
    setDrift([])
    const requested = flags
    try {
      const next = await postRestore(file, false)
      setPlan(next)
      setPlanFlags(requested)
    } catch (error: unknown) {
      clearPreview()
      const message = actionMessage(error)
      setActionError(message)
      toast.error(message)
    } finally {
      setBusy(null)
    }
  }

  const applyRestore = async () => {
    if (!file || !plan || !planFlags) return
    if (planFlags.replace !== replaceMode || planFlags.foreign !== allowForeignKeys) {
      setActionError("Preview is stale. Run Preview restore again.")
      setConfirmOpen(false)
      return
    }
    const preview = plan
    setConfirmOpen(false)
    setBusy("apply")
    setActionError("")
    try {
      const next = await postRestore(file, true)
      const rows = backupDrift(preview, next)
      setApplied(next)
      setDrift(rows)
      toast.success(next.noop ? "Restore applied — no config rows changed" : "Restore applied")
      const loud = rows.filter((row) => row.loud)
      if (loud.length > 0) {
        toast.warning(
          `Plan drift: ${loud.length} section insert/delete count(s) differ from the preview`,
        )
      } else if (rows.length > 0) {
        toast.message("Some update or unchanged counts shifted since the preview")
      }
    } catch (error: unknown) {
      const message = actionMessage(error)
      setActionError(message)
      toast.error(message)
    } finally {
      setBusy(null)
    }
  }

  const syncModels = async () => {
    setBusy("sync")
    setActionError("")
    try {
      const result = await api<{ models_added?: number; errors?: number }>("/models/sync", {
        method: "POST",
        body: {},
      })
      toast.success(
        `Sync done — ${result.models_added ?? 0} new listing(s), ${result.errors ?? 0} error(s)`,
      )
    } catch (error: unknown) {
      const message = actionMessage(error)
      setActionError(message)
      toast.error(message)
    } finally {
      setBusy(null)
    }
  }

  const confirmLines = [
    "This writes the previewed plan. The server re-checks the file before any change; the preview counts are advisory.",
  ]
  if (plan?.would_noop) {
    confirmLines.push("The preview is a no-op: no config rows are expected to change. Confirm is still required.")
  }
  if (replaceMode) {
    confirmLines.push(
      "Replace mode deletes rows in applied sections that are absent from the file. Scoped children cascade. Usage history is kept; attribution on deleted rows is cleared.",
    )
  }
  if (allowForeignKeys) {
    confirmLines.push(
      "Allow foreign keys skips the agent-keys section entirely: no upsert and no delete, including under replace. The pepper is not checked. Keys already on this host stay as they are.",
    )
  }
  confirmLines.push("Continue?")

  return (
    <Card className="animate-fade-up">
      <CardHeader className="border-b">
        <CardTitle className="text-base">Config backup</CardTitle>
        <CardDescription>
          Export providers, keys, and router config as one JSON file, or restore a file.
          The download reads <span className="font-mono">X-Janus-Backup-Warning</span> so an
          over-cap export is visible. A restore larger than the configured cap is refused;
          that error names the cap.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4 pt-4">
        <div className="flex flex-wrap gap-2">
          <Button size="sm" disabled={busy !== null} onClick={() => void exportBackup()}>
            {busy === "export" ? <LoaderCircle className="animate-spin" /> : <Download />}
            Export
          </Button>
        </div>

        <FieldGroup className="gap-3">
          <Field>
            <FieldLabel htmlFor="config-backup-file">Restore file</FieldLabel>
            <Input
              id="config-backup-file"
              type="file"
              accept="application/json,.json"
              disabled={formLocked}
              onChange={onFile}
            />
            <FieldDescription>
              {file ? file.name : "JSON document from Export, or a re-hashed file."}
            </FieldDescription>
          </Field>
        </FieldGroup>

        <div className="grid gap-3">
          <div className="flex items-start gap-2.5 rounded-md border border-warning/40 bg-warning/10 p-3">
            <Checkbox
              id="config-backup-replace"
              checked={replaceMode}
              disabled={formLocked}
              onCheckedChange={(value) => onReplace(value === true)}
              className="mt-0.5"
            />
            <label htmlFor="config-backup-replace" className="cursor-pointer text-sm leading-snug">
              <span className="font-medium">Replace mode</span>
              <span className="mt-1 block text-xs text-muted-foreground">
                Deletes rows in each applied section that are absent from the file. Scoped
                children cascade. Usage history is kept; attribution on deleted rows is cleared.
                Requires its own confirm.
              </span>
            </label>
          </div>
          <div className="flex items-start gap-2.5 rounded-md border border-destructive/40 bg-destructive/5 p-3">
            <Checkbox
              id="config-backup-allow-foreign-keys"
              checked={allowForeignKeys}
              disabled={formLocked}
              onCheckedChange={(value) => onForeign(value === true)}
              className="mt-0.5"
            />
            <label
              htmlFor="config-backup-allow-foreign-keys"
              className="cursor-pointer text-sm leading-snug"
            >
              <span className="font-medium">Allow foreign keys</span>
              <span className="mt-1 block text-xs text-muted-foreground">
                Skips the agent-keys section entirely: no upsert and no delete, in merge and in
                replace. The pepper is not checked. Keys already on this host stay as they are.
                Requires its own confirm.
              </span>
            </label>
          </div>
        </div>

        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={!file || busy !== null || confirmOpen}
            onClick={() => void previewRestore()}
          >
            {busy === "preview" ? <LoaderCircle className="animate-spin" /> : <Upload />}
            Preview restore
          </Button>
          <Button
            size="sm"
            variant={replaceMode || allowForeignKeys ? "destructive" : "default"}
            disabled={!previewCurrent || busy !== null}
            onClick={() => setConfirmOpen(true)}
          >
            Apply restore
          </Button>
        </div>

        {actionError ? <p role="alert" className="text-sm text-destructive">{actionError}</p> : null}

        {previewCurrent && plan ? (
          <div className="space-y-3">
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-medium">Preview</span>
              <Badge variant="outline">{plan.mode}</Badge>
              {plan.would_noop ? <Badge variant="secondary">No changes</Badge> : null}
              {typeof plan.generation === "number" ? (
                <span className="text-xs text-muted-foreground">
                  Generation {plan.generation}
                </span>
              ) : null}
            </div>
            <BackupPlanTable plan={plan} />
            <BackupWarnings warnings={plan.warnings} />
          </div>
        ) : null}

        {applied ? (
          <div className="space-y-3">
            {loudDrift.length > 0 ? (
              <Alert tone="danger" title="Plan drift on insert or delete">
                <p>
                  The apply response is authoritative. These section insert or delete counts
                  changed after the preview.
                </p>
                <ul className="list-disc pl-5">
                  {loudDrift.map((row) => (
                    <li key={`${row.section}-${row.field}`}>
                      {BACKUP_SECTION_LABEL[row.section as (typeof BACKUP_SECTIONS)[number]] ??
                        row.section}{" "}
                      {DRIFT_FIELD_LABEL[row.field]}: {row.preview} → {row.applied}
                    </li>
                  ))}
                </ul>
              </Alert>
            ) : null}
            {infoDrift.length > 0 ? (
              <Alert title="Other counts shifted">
                <ul className="list-disc pl-5">
                  {infoDrift.map((row) => (
                    <li key={`${row.section}-${row.field}`}>
                      {BACKUP_SECTION_LABEL[row.section as (typeof BACKUP_SECTIONS)[number]] ??
                        row.section}{" "}
                      {DRIFT_FIELD_LABEL[row.field]}: {row.preview} → {row.applied}
                    </li>
                  ))}
                </ul>
              </Alert>
            ) : null}
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-medium">Applied</span>
              <Badge variant="outline">{applied.mode}</Badge>
              {applied.noop ? <Badge variant="secondary">No-op</Badge> : null}
              {typeof applied.generation === "number" ? (
                <span className="text-xs text-muted-foreground">
                  Generation {applied.generation}
                </span>
              ) : applied.noop ? (
                <span className="text-xs text-muted-foreground">Generation unchanged</span>
              ) : null}
            </div>
            <BackupPlanTable plan={applied} />
            <BackupWarnings warnings={applied.warnings} />
            <Alert title="Sync listings and re-probe">
              <p>
                Listing metadata and the entitlement matrix were not in the backup. Run a model
                sync, then re-probe entitlements on the Providers page.
                {applied.noop ? " This apply did not change config rows." : ""}
              </p>
              <span className="mt-2 flex flex-wrap gap-2">
                <Button size="sm" disabled={busy !== null} onClick={() => void syncModels()}>
                  {busy === "sync" ? <LoaderCircle className="animate-spin" /> : null}
                  Sync models
                </Button>
                <Link
                  to="/providers"
                  className={buttonVariants({ variant: "outline", size: "sm" })}
                >
                  Re-probe on Providers
                </Link>
              </span>
            </Alert>
          </div>
        ) : null}
      </CardContent>

      <AlertDialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {replaceMode ? "Apply replace restore?" : "Apply config restore?"}
            </AlertDialogTitle>
            <AlertDialogDescription className="space-y-2">
              {confirmLines.map((line) => (
                <span key={line} className="block">
                  {line}
                </span>
              ))}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              variant={replaceMode || allowForeignKeys ? "destructive" : "default"}
              onClick={() => void applyRestore()}
            >
              Confirm
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  )
}

export function Maintenance() {
  const [schedCfg, setSchedCfg] = useState<SchedConfig | null>(null)
  const [schedSaved, setSchedSaved] = useState<SchedConfig | null>(null)
  const [schedSource, setSchedSource] = useState<string>("default")
  // True only after a successful GET /settings/sched. PUT is a full replace,
  // so a form seeded from fallbacks must never be saveable.
  const [schedLoaded, setSchedLoaded] = useState(false)
  const [modelSyncCfg, setModelSyncCfg] = useState<ModelSyncConfig | null>(null)
  const [modelSyncSaved, setModelSyncSaved] = useState<ModelSyncConfig | null>(null)
  const [fleetCfg, setFleetCfg] = useState<FleetConfig | null>(null)
  const [fleetSource, setFleetSource] = useState<string>("default")

  const [live, setLive] = useState<SchedLive | null>(null)
  const [liveVia, setLiveVia] = useState<string | null>(null)
  const [liveError, setLiveError] = useState("")
  const [liveLoading, setLiveLoading] = useState(true)

  const [pageError, setPageError] = useState("")
  const [settingsLoaded, setSettingsLoaded] = useState(false)
  const [saving, setSaving] = useState<"sched" | "model_sync" | "fleet" | "mmdb" | "maxmind" | null>(
    null,
  )
  const [confirm, setConfirm] = useState<ConfirmKind>(null)
  const [pendingFleetEnabled, setPendingFleetEnabled] = useState<boolean | null>(null)
  const [settingsLoading, setSettingsLoading] = useState(false)
  const [maxmindAccountId, setMaxmindAccountId] = useState("")
  const [maxmindLicenseKey, setMaxmindLicenseKey] = useState("")
  const [maxmindLicenseSet, setMaxmindLicenseSet] = useState(false)

  const liveInFlight = useRef(false)
  const livePollGen = useRef(0)
  const settingsInFlight = useRef(false)

  const loadSettings = useCallback(async () => {
    if (settingsInFlight.current) return
    settingsInFlight.current = true
    setSettingsLoading(true)
    try {
      const results = await Promise.allSettled([
        api("/settings/sched"),
        api("/settings/model_sync"),
        api("/settings/fleet"),
        api("/settings/maxmind"),
      ])
      const errors: string[] = []
      const [schedR, syncR, fleetR, maxmindR] = results

      if (schedR.status === "fulfilled") {
        const next = { ...SCHED_DEFAULTS, ...schedR.value.config }
        setSchedCfg(next)
        setSchedSaved(next)
        setSchedSource(schedR.value.source ?? "default")
        setSchedLoaded(true)
      } else {
        // Never seed SCHED_DEFAULTS here: PUT /settings/sched is a full
        // replace, so a Save built from fallbacks overwrites the live config.
        setSchedLoaded(false)
        errors.push(`sched: ${schedR.reason?.message ?? schedR.reason}`)
      }

      const syncNext = {
        interval_sec:
          syncR.status === "fulfilled"
            ? (syncR.value.config?.interval_sec ?? 21600)
            : 21600,
      }
      setModelSyncCfg(syncNext)
      setModelSyncSaved(syncNext)
      if (syncR.status === "rejected") {
        errors.push(`model_sync: ${syncR.reason?.message ?? syncR.reason}`)
      }

      if (fleetR.status === "fulfilled") {
        setFleetCfg({ enabled: !!fleetR.value.config?.enabled })
        setFleetSource(fleetR.value.source ?? "default")
      } else {
        setFleetCfg({ enabled: false })
        setFleetSource("default")
        errors.push(`fleet: ${fleetR.reason?.message ?? fleetR.reason}`)
      }

      if (maxmindR.status === "fulfilled") {
        setMaxmindAccountId(String(maxmindR.value.config?.account_id ?? ""))
        setMaxmindLicenseSet(!!maxmindR.value.config?.license_key_set)
        setMaxmindLicenseKey("")
      } else {
        errors.push(`maxmind: ${maxmindR.reason?.message ?? maxmindR.reason}`)
      }

      setPageError(
        errors.length === 4
          ? errors.join("; ")
          : errors.length
            ? `Partial load — ${errors.join("; ")}`
            : "",
      )
      setSettingsLoaded(true)
    } finally {
      settingsInFlight.current = false
      setSettingsLoading(false)
    }
  }, [])

  const refreshLive = useCallback(async () => {
    if (liveInFlight.current) return
    liveInFlight.current = true
    const gen = ++livePollGen.current
    try {
      const payload = (await api("/nodes")) as { nodes?: NodeRow[] }
      if (gen !== livePollGen.current) return
      const nodes = (payload.nodes ?? []).filter((n) => n.enabled)
      const masters = nodes
        .filter(
          (n) =>
            n.health?.status === "healthy" &&
            String(n.health?.role ?? "").toLowerCase() === "master",
        )
        .sort((a, b) => a.id - b.id)
      if (masters.length === 0) {
        setLive(null)
        setLiveVia(null)
        setLiveError("No healthy master gateway in the node registry (check /stats role=master).")
        setLiveLoading(false)
        return
      }
      const pick = masters[0]
      const r = await api<SchedScrapeResponse>(`/nodes/${pick.id}/sched`)
      if (gen !== livePollGen.current) return
      if (!r.ok || !("sched" in r) || !r.sched) {
        setLive(null)
        setLiveVia(pick.name)
        setLiveError(("error" in r && r.error) || "Master sched scrape failed")
        setLiveLoading(false)
        return
      }
      setLive(r.sched)
      setLiveVia(pick.name)
      setLiveError("")
      setLiveLoading(false)
    } catch (e: unknown) {
      if (gen !== livePollGen.current) return
      setLive(null)
      setLiveVia(null)
      setLiveError(e instanceof Error ? e.message : String(e))
      setLiveLoading(false)
    } finally {
      liveInFlight.current = false
    }
  }, [])

  useEffect(() => {
    loadSettings()
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const tick = async () => {
      await refreshLive()
      if (!cancelled) timer = setTimeout(tick, 5000)
    }
    void tick()
    return () => {
      cancelled = true
      if (timer) clearTimeout(timer)
      livePollGen.current += 1
    }
  }, [loadSettings, refreshLive])

  const fleetInheritingEnv = live?.fleet_desired === null || live?.fleet_desired === undefined
  const fleetRestartPending =
    live?.fleet_desired !== null &&
    live?.fleet_desired !== undefined &&
    live.fleet_effective !== undefined &&
    live.fleet_desired !== live.fleet_effective

  const geoWarning =
    !!live?.geo_desired && live.mmdb_present === false

  const schedDirty = useMemo(() => {
    if (!schedCfg || !schedSaved) return false
    return JSON.stringify(schedCfg) !== JSON.stringify(schedSaved)
  }, [schedCfg, schedSaved])

  const modelSyncInvalid =
    !!modelSyncCfg && !modelSyncIntervalValid(modelSyncCfg.interval_sec)

  const modelSyncDirty = useMemo(() => {
    if (!modelSyncCfg || !modelSyncSaved) return false
    return modelSyncCfg.interval_sec !== modelSyncSaved.interval_sec
  }, [modelSyncCfg, modelSyncSaved])

  const saveSched = () => {
    if (!schedCfg || !schedLoaded) return
    setSaving("sched")
    api("/settings/sched", { method: "PUT", body: schedCfg })
      .then(() => {
        toast.success("Scheduler settings saved — master hot-reloads within seconds")
        setSchedSource("db")
        setSchedSaved({ ...schedCfg })
      })
      .catch((e: Error) => toast.error(e.message))
      .finally(() => setSaving(null))
  }

  const saveModelSync = () => {
    if (!modelSyncCfg || !modelSyncIntervalValid(modelSyncCfg.interval_sec)) return
    setSaving("model_sync")
    api("/settings/model_sync", { method: "PUT", body: modelSyncCfg })
      .then(() => {
        toast.success("Model sync interval saved — timer reschedules on the master")
        setModelSyncSaved({ ...modelSyncCfg })
      })
      .catch((e: Error) => toast.error(e.message))
      .finally(() => setSaving(null))
  }

  const persistMaxmind = async (): Promise<boolean> => {
    if (!maxmindAccountId.trim()) {
      toast.error("Account ID required")
      return false
    }
    if (!/^\d+$/.test(maxmindAccountId.trim())) {
      toast.error("Account ID must be numeric")
      return false
    }
    if (!maxmindLicenseKey.trim() && !maxmindLicenseSet) {
      toast.error("License key required (none stored yet)")
      return false
    }
    const body: Record<string, string> = { account_id: maxmindAccountId.trim() }
    if (maxmindLicenseKey.trim()) body.license_key = maxmindLicenseKey.trim()
    const r = (await api("/settings/maxmind", { method: "PUT", body })) as {
      config?: { account_id?: string; license_key_set?: boolean }
    }
    setMaxmindAccountId(String(r.config?.account_id ?? maxmindAccountId.trim()))
    setMaxmindLicenseSet(!!r.config?.license_key_set)
    setMaxmindLicenseKey("")
    return true
  }

  const saveMaxmind = () => {
    setSaving("maxmind")
    persistMaxmind()
      .then((ok) => {
        if (ok) toast.success("MaxMind credentials saved")
      })
      .catch((e: Error) => toast.error(e.message))
      .finally(() => setSaving(null))
  }

  const refreshMmdb = () => {
    setSaving("mmdb")
    // Refresh reads settings/env only — persist the form first when the
    // operator typed a new key or nothing is stored yet.
    void (async () => {
      try {
        if (maxmindLicenseKey.trim() || !maxmindLicenseSet) {
          if (!(await persistMaxmind())) return
        }
        const r = (await api("/maintenance/mmdb/refresh", {
          method: "POST",
          body: {},
        })) as { bytes?: number; reload?: { geo_enabled?: boolean } }
        const mb = r.bytes != null ? `${(r.bytes / 1_000_000).toFixed(1)} MB` : "ok"
        toast.success(
          `GeoLite2 refreshed (${mb})` +
            (r.reload?.geo_enabled === true ? " — geo effective" : ""),
        )
        void refreshLive()
      } catch (e: unknown) {
        toast.error(e instanceof Error ? e.message : String(e))
      } finally {
        setSaving(null)
      }
    })()
  }

  const saveFleet = (enabled: boolean) => {
    setSaving("fleet")
    api("/settings/fleet", { method: "PUT", body: { enabled } })
      .then(() => {
        toast.success("Fleet desired state saved — recreate gateways to apply")
        setFleetCfg({ enabled })
        setFleetSource("db")
      })
      .catch((e: Error) => toast.error(e.message))
      .finally(() => {
        setSaving(null)
        setPendingFleetEnabled(null)
      })
  }

  const setSchedBool = (key: keyof Omit<SchedConfig, "probe_max_hourly">, next: boolean) => {
    if (!schedCfg) return
    if (key === "probe" && next) {
      setConfirm("probe")
      return
    }
    if (key === "unary_fallback" && next) {
      setConfirm("unary_fallback")
      return
    }
    setSchedCfg({ ...schedCfg, [key]: next })
  }

  const applyConfirm = () => {
    if (confirm === "fleet") {
      if (pendingFleetEnabled !== null) {
        saveFleet(pendingFleetEnabled)
      }
      setConfirm(null)
      return
    }
    if (!schedCfg) {
      setConfirm(null)
      return
    }
    if (confirm === "probe") {
      setSchedCfg({ ...schedCfg, probe: true })
    } else if (confirm === "unary_fallback") {
      setSchedCfg({ ...schedCfg, unary_fallback: true })
    }
    setConfirm(null)
  }

  const fleetDisplayOn = fleetInheritingEnv
    ? !!(live?.fleet_effective ?? false)
    : !!fleetCfg?.enabled

  const toggleFleet = () => {
    if (!fleetCfg || saving) return
    const next = fleetInheritingEnv
      ? !(live?.fleet_effective ?? false)
      : !fleetCfg.enabled
    setPendingFleetEnabled(next)
    setConfirm("fleet")
  }

  if (!settingsLoaded && !pageError) {
    return (
      <Layout title="Maintenance" description="Cluster scheduler knobs and legacy fleet desired state.">
        <Loading />
      </Layout>
    )
  }

  return (
    <Layout
      title="Maintenance"
      description="Hot scheduler and model-sync knobs on the master; fleet desired applies on gateway recreate."
    >
      {pageError && (
        <div className="flex flex-wrap items-start gap-3">
          <div className="min-w-0 flex-1">
            <ErrorFlash message={pageError} />
          </div>
          <Button
            size="sm"
            variant="outline"
            disabled={settingsLoading}
            onClick={() => void loadSettings()}
          >
            {settingsLoading ? <LoaderCircle className="animate-spin" /> : null}
            Retry
          </Button>
        </div>
      )}

      <Card className="animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle className="text-base">Live effective state</CardTitle>
          <CardDescription>
            Scraped from /stats/sched on a healthy master only
            {liveVia ? ` (${liveVia})` : ""}.
          </CardDescription>
        </CardHeader>
        <CardContent className="pt-4">
          {liveLoading && !live && !liveError ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <LoaderCircle className="size-4 animate-spin" />
              Waiting for master sched…
            </div>
          ) : liveError ? (
            <EmptyState title="Live strip unavailable" description={liveError} />
          ) : live ? (
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {(
                [
                  ["Health", liveBoolCell(live.health_enabled)],
                  ["RTT", liveBoolCell(live.rtt_enabled)],
                  ["Geo (effective)", liveBoolCell(live.geo_enabled)],
                  ["MMDB present", liveBoolCell(live.mmdb_present)],
                  ["Probe", liveBoolCell(live.probe_enabled)],
                  ["Unary fallback", liveBoolCell(live.unary_fallback_enabled)],
                  ["Fleet effective", liveBoolCell(live.fleet_effective)],
                  ["Probe max / hr", live.probe_max_hourly ?? "—"],
                  [
                    "Model sync interval",
                    live.model_sync_interval_sec === 0
                      ? "manual only"
                      : `${live.model_sync_interval_sec ?? "—"}s`,
                  ],
                ] as [string, ReactNode][]
              ).map(([label, value]) => (
                <div key={label} className="rounded-md border px-3 py-2">
                  <div className="text-xs text-muted-foreground">{label}</div>
                  <div className="mt-0.5 text-sm font-medium">{value}</div>
                </div>
              ))}
            </div>
          ) : null}
        </CardContent>
      </Card>

      {geoWarning && (
        <Alert tone="danger" title="Geo desired but MMDB missing" className="animate-fade-up">
          Geo scheduling stays off until MaxMind data is present at JANUS_MMDB_PATH on the master.
          Use <strong>Refresh GeoLite2</strong> below (requires MaxMind credentials on the
          dashboard), or redeploy so step 3b fetches it.
          {typeof live?.sched_geo_refused_total === "number" && live.sched_geo_refused_total > 0
            ? ` Refused picks this process lifetime: ${live.sched_geo_refused_total}.`
            : null}
        </Alert>
      )}

      <Card className="animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle className="text-base">GeoLite2 MMDB</CardTitle>
          <CardDescription>
            Paste your MaxMind Account ID + License Key (from GeoIP.conf / the MaxMind portal).
            The license is encrypted at rest and never shown again. Refresh downloads the latest
            City DB and reloads locus without a full gateway restart.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4 pt-4">
          <div className="text-sm text-muted-foreground">
            Present:{" "}
            <span className="font-medium text-foreground">
              {live?.mmdb_present === true ? "yes" : live?.mmdb_present === false ? "no" : "—"}
            </span>
            {" · "}
            Geo effective:{" "}
            <span className="font-medium text-foreground">
              {live?.geo_enabled === true ? "on" : live?.geo_enabled === false ? "off" : "—"}
            </span>
            {" · "}
            Credentials:{" "}
            <span className="font-medium text-foreground">
              {maxmindLicenseSet ? "saved" : "not set"}
            </span>
          </div>
          <FieldGroup className="grid max-w-4xl gap-4 sm:grid-cols-2">
            <Field>
              <FieldLabel htmlFor="maxmind-account">Account ID</FieldLabel>
              <Input
                id="maxmind-account"
                inputMode="numeric"
                autoComplete="off"
                placeholder="e.g. 1427293"
                value={maxmindAccountId}
                onChange={(e) => setMaxmindAccountId(e.target.value)}
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="maxmind-license">License key</FieldLabel>
              <Input
                id="maxmind-license"
                type="password"
                autoComplete="off"
                placeholder={maxmindLicenseSet ? "•••••••• (leave blank to keep)" : "LicenseKey from GeoIP.conf"}
                value={maxmindLicenseKey}
                onChange={(e) => setMaxmindLicenseKey(e.target.value)}
              />
              <FieldDescription>
                Write-only. Leave blank on later saves to keep the stored key.
              </FieldDescription>
            </Field>
          </FieldGroup>
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              disabled={saving !== null}
              onClick={() => saveMaxmind()}
            >
              {saving === "maxmind" ? <LoaderCircle className="animate-spin" /> : <Save />}
              Save credentials
            </Button>
            <Button
              size="sm"
              variant="outline"
              disabled={saving !== null || (!maxmindLicenseSet && !maxmindLicenseKey.trim())}
              onClick={() => refreshMmdb()}
            >
              {saving === "mmdb" ? <LoaderCircle className="animate-spin" /> : null}
              Refresh GeoLite2
            </Button>
          </div>
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card className="animate-fade-up">
          <CardHeader className="border-b">
            <CardTitle className="text-base">Scheduler</CardTitle>
            <CardDescription>
              Desired knobs (settings.sched). Effective values update hot on the master.
              {schedLoaded && schedSource === "default"
                ? " Using code defaults until first save."
                : null}
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4 pt-4">
            {!schedCfg ? (
              <EmptyState
                title="Scheduler settings unavailable"
                description="Could not read settings.sched. Retry the load above — saving stays disabled until the real config has been read."
              />
            ) : (
              <>
                <div className="flex flex-wrap gap-2">
                  <KnobButton
                    label="Health"
                    on={schedCfg.health}
                    onClick={() => setSchedBool("health", !schedCfg.health)}
                  />
                  <KnobButton
                    label="RTT"
                    on={schedCfg.rtt}
                    onClick={() => setSchedBool("rtt", !schedCfg.rtt)}
                  />
                  <KnobButton
                    label="Geo"
                    on={schedCfg.geo}
                    onClick={() => setSchedBool("geo", !schedCfg.geo)}
                    title="Requires MMDB on master for effective geo"
                  />
                  <KnobButton
                    label="Probe"
                    on={schedCfg.probe}
                    onClick={() => setSchedBool("probe", !schedCfg.probe)}
                    title="Enabling probe spends upstream capacity"
                  />
                  <KnobButton
                    label="Unary fallback"
                    on={schedCfg.unary_fallback}
                    onClick={() => setSchedBool("unary_fallback", !schedCfg.unary_fallback)}
                    title="Can double-bill on worker loss"
                  />
                </div>
                <FieldGroup>
                  <Field>
                    <FieldLabel htmlFor="probe-max">Probe max hourly</FieldLabel>
                    <Input
                      id="probe-max"
                      type="number"
                      min={1}
                      className="max-w-32 tabular-nums"
                      value={schedCfg.probe_max_hourly}
                      onChange={(e) =>
                        setSchedCfg({
                          ...schedCfg,
                          probe_max_hourly: Math.max(1, parseInt(e.target.value, 10) || 1),
                        })
                      }
                    />
                    <FieldDescription>
                      Minimum 1. The master re-reads it on every sched tick.
                    </FieldDescription>
                  </Field>
                </FieldGroup>
                <div className="flex flex-wrap items-center gap-3 border-t pt-4">
                  <Button
                    size="sm"
                    disabled={saving === "sched" || !schedLoaded || !schedDirty}
                    onClick={saveSched}
                  >
                    {saving === "sched" ? (
                      <LoaderCircle className="animate-spin" />
                    ) : (
                      <Save />
                    )}
                    Save scheduler
                  </Button>
                  {!schedLoaded ? (
                    <span className="text-xs text-destructive">
                      Config not loaded — Save disabled
                    </span>
                  ) : schedDirty ? (
                    <span className="text-xs text-warning">
                      Unsaved changes
                    </span>
                  ) : null}
                </div>
              </>
            )}
          </CardContent>
        </Card>

        <Card className="animate-fade-up">
          <CardHeader className="border-b">
            <CardTitle className="text-base">Model sync interval</CardTitle>
            <CardDescription>
              Hot on the master. Use 0 for manual-only sync; otherwise at least 60 seconds.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4 pt-4">
            {!modelSyncCfg ? (
              <Loading />
            ) : (
              <>
                <FieldGroup>
                  <Field>
                    <FieldLabel htmlFor="sync-interval">Interval (seconds)</FieldLabel>
                    <Input
                      id="sync-interval"
                      type="number"
                      min={0}
                      step={60}
                      className="max-w-32 tabular-nums"
                      value={modelSyncCfg.interval_sec}
                      onChange={(e) =>
                        setModelSyncCfg({
                          interval_sec: parseInt(e.target.value, 10) || 0,
                        })
                      }
                    />
                    <FieldDescription>0 = manual only. Values 1–59 are rejected.</FieldDescription>
                    {modelSyncInvalid ? (
                      <p className="text-xs text-destructive">
                        Interval must be 0 (manual) or ≥ 60 seconds.
                      </p>
                    ) : null}
                  </Field>
                </FieldGroup>
                <div className="flex flex-wrap items-center gap-3 border-t pt-4">
                  <Button
                    size="sm"
                    disabled={saving === "model_sync" || modelSyncInvalid || !modelSyncDirty}
                    onClick={saveModelSync}
                  >
                    {saving === "model_sync" ? (
                      <LoaderCircle className="animate-spin" />
                    ) : (
                      <Save />
                    )}
                    Save model sync
                  </Button>
                  {modelSyncDirty && !modelSyncInvalid ? (
                    <span className="text-xs text-warning">
                      Unsaved changes
                    </span>
                  ) : null}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>

      <ConfigBackupCard />

      <Card className="animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle className="text-base">Signal fleet (legacy)</CardTitle>
          <CardDescription>
            Desired state only — not hot. Recommended OFF; worker pool capacity is independent.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4 pt-4">
          {fleetRestartPending && (
            <Badge variant="warning">
              Restart required — desired ≠ effective until gateway recreate
            </Badge>
          )}
          {!fleetCfg ? (
            <Loading />
          ) : (
            <>
              <div className="flex flex-wrap items-center gap-3">
                <KnobButton
                  label="Fleet"
                  on={fleetDisplayOn}
                  disabled={saving === "fleet"}
                  onClick={toggleFleet}
                  title={
                    fleetInheritingEnv
                      ? "Inheriting env — first change creates a settings row"
                      : "Applies on next gateway recreate"
                  }
                />
                {fleetInheritingEnv && (
                  <span className="text-xs text-muted-foreground">Inheriting env</span>
                )}
                {fleetSource === "db" && !fleetInheritingEnv && (
                  <span className="text-xs text-muted-foreground">Persisted in settings.fleet</span>
                )}
              </div>
            </>
          )}
        </CardContent>
      </Card>

      <AlertDialog open={confirm !== null} onOpenChange={(o) => !o && setConfirm(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>
              {confirm === "probe" && "Enable scheduler probe?"}
              {confirm === "unary_fallback" && "Enable unary fallback?"}
              {confirm === "fleet" && "Change fleet desired state?"}
            </AlertDialogTitle>
            <AlertDialogDescription>
              {confirm === "probe" &&
                "Probe jobs spend real upstream capacity and provider quota. Continue?"}
              {confirm === "unary_fallback" &&
                "On worker loss the master may re-run the request locally, which can double-bill. Continue?"}
              {confirm === "fleet" &&
                "Fleet desired state applies only after a rolling gateway recreate (not hot). Continue?"}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={applyConfirm}>Confirm</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Layout>
  )
}
