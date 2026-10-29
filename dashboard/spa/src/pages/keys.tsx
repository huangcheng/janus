import { useEffect, useMemo, useRef, useState } from "react"
import { Ban, Check, Copy, KeyRound, Pencil, Plus, Power } from "lucide-react"
import { toast } from "sonner"
import { ApiError, api } from "../api"
import { EmptyState, ErrorFlash, IconAction, Layout, Loading } from "../components"
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
import { Checkbox } from "@/components/ui/checkbox"
import { Dialog, DialogContent, DialogFooter } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { AgentKey, StateBadge, fmtIsoLocalCompact } from "./shared"

type Modal =
  | "create"
  | { created: string; scope: "all" | string[] }
  | { revoke: AgentKey }
  | { toggle: AgentKey }
  | { edit: AgentKey }
  | null

function copyKeyLabel(hasSecret: boolean | undefined, copying: boolean): string {
  if (!hasSecret) return "Key not recoverable — revoke and create a new one."
  if (copying) return "Copying…"
  return "Copy key"
}

/** Clipboard helper with execCommand fallback (non-secure contexts / Clipboard API denial). */
async function copyText(text: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return
    } catch {
      // fall through to execCommand when present-but-denied (NotAllowedError, etc.)
    }
  }
  const ta = document.createElement("textarea")
  ta.value = text
  ta.setAttribute("readonly", "")
  ta.style.position = "fixed"
  ta.style.left = "-9999px"
  document.body.appendChild(ta)
  ta.select()
  try {
    if (!document.execCommand("copy")) {
      throw new Error("execCommand copy failed")
    }
  } finally {
    document.body.removeChild(ta)
  }
}

export function Keys() {
  const [keys, setKeys] = useState<AgentKey[]>([])
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [modal, setModal] = useState<Modal>(null)
  /** In-flight reveal+copy row id — disables the button to avoid concurrent secret GETs. */
  const [copyingId, setCopyingId] = useState<number | null>(null)
  const copyingRef = useRef(false)

  const load = () =>
    api("/keys")
      .then((k) => {
        setKeys(k.keys)
        setLoaded(true)
      })
      .catch((e) => setError(e.message))

  useEffect(() => {
    load()
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

  const { slice: pagedKeys, pageCount, page: safePage, total } = useClientPagination(
    keys,
    pageSize,
    page,
  )
  return (
    <Layout
      title="Agent keys"
      description="Bearer keys for the data plane — stored as peppered HMAC hashes."
    >
      {error && <ErrorFlash message={error} />}
      <Card className="flex h-fit max-h-full w-full flex-col self-start overflow-hidden animate-fade-up">
        <CardHeader className="border-b">
          <CardTitle>Keys</CardTitle>
          <CardDescription>
            Keys default to all models; restrict or widen access later without rotating the secret.
          </CardDescription>
          <CardAction>
            <Button size="sm" onClick={() => setModal("create")}>
              <Plus />
              Create key
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="min-h-0 px-0">
          {!loaded && !error ? (
            <Loading />
          ) : loaded && keys.length === 0 ? (
            <EmptyState
              title="No agent keys yet"
              description="Create a bearer key so clients can call the data plane."
              action={
                <Button size="sm" onClick={() => setModal("create")}>
                  <Plus />
                  Create key
                </Button>
              }
            />
          ) : (
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead>Prefix</TableHead>
                  <TableHead>Comment</TableHead>
                  <TableHead>Access</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {pagedKeys.map((k) => (
                  <TableRow key={k.id}>
                    <TableCell className="font-mono text-xs tabular-nums">{k.prefix}…</TableCell>
                    <TableCell
                      className="max-w-[14rem] truncate text-sm text-muted-foreground"
                      title={k.comment?.trim() || undefined}
                    >
                      {k.comment?.trim() ? k.comment : "—"}
                    </TableCell>
                    <TableCell>
                      {k.model_names === "all" ? (
                        <Badge variant="secondary" className="font-mono text-[11px]">
                          all models
                        </Badge>
                      ) : (
                        <div className="flex flex-wrap gap-1">
                          {k.model_names.map((n) => (
                            <Badge
                              variant="secondary"
                              className="font-mono text-[11px]"
                              key={n}
                            >
                              {n}
                            </Badge>
                          ))}
                          {k.model_names.length === 0 && (
                            <span className="text-muted-foreground">—</span>
                          )}
                        </div>
                      )}
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
                      {fmtIsoLocalCompact(k.created_at)}
                    </TableCell>
                    <TableCell>
                      <StateBadge enabled={k.enabled} />
                    </TableCell>
                    <TableCell>
                      <div className="flex items-center justify-end gap-1">
                        <IconAction
                          label={copyKeyLabel(k.has_secret, copyingId === k.id)}
                          disabled={!k.has_secret || copyingId === k.id}
                          onClick={async () => {
                            if (copyingRef.current) return
                            copyingRef.current = true
                            setCopyingId(k.id)
                            try {
                              const res = await api<{ key?: string }>(`/keys/${k.id}/secret`)
                              const secret = res.key
                              if (typeof secret !== "string" || secret.length === 0) {
                                toast.error("not recoverable")
                                return
                              }
                              await copyText(secret)
                              toast.success("copied to clipboard")
                            } catch (e: unknown) {
                              if (e instanceof ApiError && (e.status === 409 || e.code === "not_recoverable")) {
                                toast.error("not recoverable")
                              } else {
                                toast.error("copy failed")
                              }
                            } finally {
                              copyingRef.current = false
                              setCopyingId(null)
                            }
                          }}
                        >
                          <Copy />
                        </IconAction>
                        <IconAction label="Edit access" onClick={() => setModal({ edit: k })}>
                          <Pencil />
                        </IconAction>
                        <IconAction
                          label={k.enabled ? "Disable" : "Enable"}
                          onClick={() => setModal({ toggle: k })}
                        >
                          <Power />
                        </IconAction>
                        <IconAction label="Revoke" destructive onClick={() => setModal({ revoke: k })}>
                          <Ban />
                        </IconAction>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          <div className="px-5">
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
        </CardContent>
      </Card>

      {modal === "create" && (
        <AccessKeyModal
          mode="create"
          onClose={() => setModal(null)}
          onCreated={(key, scope) => setModal({ created: key, scope })}
        />
      )}

      {modal && typeof modal === "object" && "edit" in modal && (
        <AccessKeyModal
          mode="edit"
          keyRow={modal.edit}
          onClose={() => setModal(null)}
          onSaved={async () => {
            setModal(null)
            toast.success("access updated")
            await load()
          }}
        />
      )}

      {modal && typeof modal === "object" && "created" in modal && (
        <Dialog
          open
          onOpenChange={(o) => {
            if (!o) {
              setModal(null)
              load()
            }
          }}
        >
          <DialogContent
            title="Key created"
            description="Copy it now, or use Actions → Copy later — the secret is recoverable."
          >
            <div className="flex flex-col gap-3">
              <div className="flex size-10 items-center justify-center rounded-full bg-success/10">
                <KeyRound className="size-5 text-success" />
              </div>
              <div className="flex items-stretch gap-2">
                <Input
                  readOnly
                  value={modal.created}
                  aria-label="Generated agent key"
                  className="min-w-0 flex-1 cursor-text font-mono text-xs select-all"
                  onFocus={(e) => e.currentTarget.select()}
                  onClick={(e) => e.currentTarget.select()}
                />
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="shrink-0"
                  onClick={async () => {
                    try {
                      await copyText(modal.created)
                      toast.success("copied to clipboard")
                    } catch {
                      toast.error("copy failed — select the key and copy manually")
                    }
                  }}
                >
                  <Copy />
                  Copy
                </Button>
              </div>
              <p className="text-sm text-muted-foreground">
                {modal.scope === "all"
                  ? "This key can call every model (including unbound listings)."
                  : `This key is restricted to: ${(modal.scope as string[]).join(", ")}.`}
              </p>
            </div>
            <DialogFooter>
              <Button
                onClick={() => {
                  setModal(null)
                  load()
                }}
              >
                <Check />
                Done
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}

      {modal && typeof modal === "object" && "revoke" in modal && (
        <AlertDialog open onOpenChange={(o) => !o && setModal(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Revoke key <span className="font-mono">{modal.revoke.prefix}…</span>?
              </AlertDialogTitle>
              <AlertDialogDescription>
                Agents using this key will immediately get <code>401 unauthorized</code>. The
                HMAC hash is deleted; this cannot be undone.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                onClick={() =>
                  act(async () => {
                    await api(`/keys/${modal.revoke.id}`, { method: "DELETE" })
                    setModal(null)
                  }, "key revoked")
                }
              >
                Revoke permanently
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
      {modal && typeof modal === "object" && "toggle" in modal && (
        <AlertDialog open onOpenChange={(o) => !o && setModal(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                {modal.toggle.enabled ? "Disable" : "Enable"} key{" "}
                <span className="font-mono">{modal.toggle.prefix}…</span>?
              </AlertDialogTitle>
              <AlertDialogDescription>
                {modal.toggle.enabled ? (
                  <>
                    Requests with this key immediately get <code>401</code> until it is enabled
                    again. The secret is kept, so this is reversible.
                  </>
                ) : (
                  <>
                    Requests with this key are accepted again as soon as the gateways hot-reload
                    (a few seconds).
                  </>
                )}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant={modal.toggle.enabled ? "destructive" : "default"}
                onClick={() => {
                  const k = modal.toggle
                  void act(async () => {
                    await api(`/keys/${k.id}/${k.enabled ? "disable" : "enable"}`, {
                      method: "POST",
                      body: {},
                    })
                    setModal(null)
                  }, "key updated")
                }}
              >
                {modal.toggle.enabled ? "Disable key" : "Enable key"}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
    </Layout>
  )
}

function AccessKeyModal({
  mode,
  keyRow,
  onClose,
  onCreated,
  onSaved,
}: {
  mode: "create" | "edit"
  keyRow?: AgentKey
  onClose: () => void
  onCreated?: (key: string, scope: "all" | string[]) => void
  onSaved?: () => void
}) {
  const initialAll = mode === "create" || keyRow?.model_names === "all"
  const [scopeAll, setScopeAll] = useState(initialAll)
  const [selected, setSelected] = useState<Set<string>>(() => {
    if (keyRow && keyRow.model_names !== "all") return new Set(keyRow.model_names)
    return new Set()
  })
  const [comment, setComment] = useState(keyRow?.comment ?? "")
  // Picker entries: {name, source, providers} where source is bound |
  // listing (from the API) or orphan (a current grant whose listing vanished).
  type GrantEntry = { name: string; source: string; providers: string[] }
  const [entries, setEntries] = useState<GrantEntry[]>([])
  const [query, setQuery] = useState("")
  const [sourceFilter, setSourceFilter] = useState("all")
  const [pageSize, setPageSize] = useState(20)
  const [page, setPage] = useState(1)
  const [busy, setBusy] = useState(false)
  const [confirmWiden, setConfirmWiden] = useState(false)
  const [decisionsMsg, setDecisionsMsg] = useState<string | null>(null)

  useEffect(() => {
    api("/keys/grantable-models")
      .then(
        (r: {
          models?: { name?: string; source?: string; providers?: string[] }[]
        }) => {
          const fromApi: GrantEntry[] = (r.models ?? [])
            .map((m) => ({
              name: m.name ?? "",
              source: m.source === "bound" ? "bound" : "listing",
              providers: Array.isArray(m.providers)
                ? m.providers.filter((p): p is string => typeof p === "string" && p.length > 0)
                : [],
            }))
            .filter((m) => m.name.length > 0)
          // Keep orphan grants visible if a listing vanished since the key was scoped.
          const apiNames = new Set(fromApi.map((m) => m.name))
          const orphanList: GrantEntry[] =
            keyRow && keyRow.model_names !== "all"
              ? keyRow.model_names
                  .filter((n) => !apiNames.has(n))
                  .map((name) => ({ name, source: "orphan", providers: [] }))
              : []
          const merged = [...fromApi, ...orphanList].sort((a, b) =>
            a.name.localeCompare(b.name),
          )
          setEntries(merged)
          setPage(1)
        },
      )
      .catch((e) => toast.error(e.message))
  }, [keyRow])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return entries.filter((e) => {
      if (q) {
        const inName = e.name.toLowerCase().includes(q)
        const inProvider = e.providers.some((p) => p.toLowerCase().includes(q))
        if (!inName && !inProvider) return false
      }
      switch (sourceFilter) {
        case "selected":
          return selected.has(e.name)
        case "bound":
        case "listing":
        case "orphan":
          return e.source === sourceFilter
        default:
          return true
      }
    })
  }, [entries, query, sourceFilter, selected])

  const { slice, pageCount, page: safePage, total } = useClientPagination(filtered, pageSize, page)
  const pageChecked = slice.length > 0 && slice.every((e) => selected.has(e.name))
  const pageIndeterminate = !pageChecked && slice.some((e) => selected.has(e.name))

  const togglePage = () => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (pageChecked) slice.forEach((e) => next.delete(e.name))
      else slice.forEach((e) => next.add(e.name))
      return next
    })
  }

  const toggle = (name: string) => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      return next
    })
  }

  const restrictEmpty = !scopeAll && selected.size === 0

  const submit = async (opts: { decisions_confirmed?: boolean; confirm_unrestricted?: boolean } = {}) => {
    setBusy(true)
    setDecisionsMsg(null)
    try {
      const model_names = scopeAll ? [] : [...selected].sort()
      const commentBody = comment.trim() || null
      if (mode === "create") {
        const body: Record<string, unknown> = { model_names, comment: commentBody }
        if (opts.decisions_confirmed) body.decisions_confirmed = true
        const res = await api("/keys", { method: "POST", body })
        onCreated?.(res.key, scopeAll ? "all" : model_names)
        return
      }
      // Single PATCH: grants + comment in one transaction (partial-save safe).
      const body: Record<string, unknown> = { model_names, comment: commentBody }
      if (opts.decisions_confirmed) body.decisions_confirmed = true
      if (opts.confirm_unrestricted) body.confirm_unrestricted = true
      await api(`/keys/${keyRow!.id}/models`, { method: "PATCH", body })
      onSaved?.()
    } catch (e: any) {
      setBusy(false)
      if (e instanceof ApiError && e.code === "decisions_confirm_required") {
        setDecisionsMsg(e.message)
        return
      }
      if (e instanceof ApiError && e.code === "confirm_unrestricted_required") {
        setConfirmWiden(true)
        return
      }
      toast.error(e.message)
    }
  }

  const primary = () => {
    if (mode === "edit" && scopeAll && keyRow?.model_names !== "all" && !confirmWiden) {
      setConfirmWiden(true)
      return
    }
    void submit({
      decisions_confirmed: !!decisionsMsg,
      confirm_unrestricted:
        confirmWiden || (mode === "edit" && scopeAll && keyRow?.model_names !== "all"),
    })
  }

  return (
    <>
      <Dialog open onOpenChange={(o) => !o && onClose()}>
        <DialogContent
          size="lg"
          title={mode === "create" ? "Create key" : "Edit access"}
          description={
            mode === "create"
              ? "Default is all models. Restrict to any provider listing name when needed."
              : `Change grants for ${keyRow?.prefix}… without rotating the secret.`
          }
        >
          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="key-comment">Comment</Label>
              <Textarea
                id="key-comment"
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                placeholder="e.g. Alice — Claude Code, or Acme contractor"
                maxLength={500}
                rows={2}
                className="resize-none text-sm"
              />
              <p className="text-xs text-muted-foreground">
                Optional note for who owns or uses this key (max 500 characters).
              </p>
            </div>

            <div className="flex gap-2" role="group" aria-label="Model access scope">
              <Button
                type="button"
                size="sm"
                variant={scopeAll ? "default" : "outline"}
                aria-pressed={scopeAll}
                onClick={() => setScopeAll(true)}
              >
                All models
              </Button>
              <Button
                type="button"
                size="sm"
                variant={!scopeAll ? "default" : "outline"}
                aria-pressed={!scopeAll}
                onClick={() => setScopeAll(false)}
              >
                Restrict to…
              </Button>
            </div>

            {scopeAll ? (
              <p className="text-sm text-muted-foreground">
                Unrestricted keys can call every listing name and{" "}
                <code>janus-auto</code>. Restricted keys cannot use{" "}
                <code>janus-auto</code>.
              </p>
            ) : (
              <div className="flex flex-col gap-2">
                <div className="flex gap-2">
                  <Input
                    value={query}
                    aria-label="Search models or providers"
                    onChange={(e) => {
                      setQuery(e.target.value)
                      setPage(1)
                    }}
                    placeholder="Search models or providers…"
                    className="font-mono text-xs"
                  />
                  <Select
                    value={sourceFilter}
                    onValueChange={(v) => { setSourceFilter(v); setPage(1) }}
                  >
                    <SelectTrigger size="sm" aria-label="Filter by source" className="shrink-0" style={{ width: 168 }}>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="all">All sources</SelectItem>
                      <SelectItem value="selected">Selected only</SelectItem>
                      <SelectItem value="bound">Bound models</SelectItem>
                      <SelectItem value="listing">Provider listings</SelectItem>
                      <SelectItem value="orphan">Removed / orphaned</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="max-h-80 overflow-y-auto rounded-md border">
                  <Table flush>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="w-10">
                          <Checkbox
                            checked={pageIndeterminate ? "indeterminate" : pageChecked}
                            onCheckedChange={togglePage}
                            aria-label="Select all on page"
                          />
                        </TableHead>
                        <TableHead>Model</TableHead>
                        <TableHead className="min-w-[8rem]">Provider</TableHead>
                        <TableHead className="w-28">Source</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {entries.length === 0 ? (
                        <TableRow>
                          <TableCell colSpan={4} className="text-sm text-muted-foreground">
                            No grantable models yet.
                          </TableCell>
                        </TableRow>
                      ) : total === 0 ? (
                        <TableRow>
                          <TableCell colSpan={4} className="text-sm text-muted-foreground">
                            No matches for the current search / filter.
                          </TableCell>
                        </TableRow>
                      ) : (
                        slice.map((e) => (
                          <TableRow
                            key={e.name}
                            className="cursor-pointer"
                            onClick={() => toggle(e.name)}
                          >
                            <TableCell onClick={(ev) => ev.stopPropagation()}>
                              <Checkbox
                                checked={selected.has(e.name)}
                                onCheckedChange={() => toggle(e.name)}
                                aria-label={`Grant ${e.name}`}
                              />
                            </TableCell>
                            <TableCell className="font-mono text-xs">{e.name}</TableCell>
                            <TableCell className="text-xs text-muted-foreground">
                              {e.providers.length === 0 ? (
                                <span>—</span>
                              ) : (
                                <span className="font-mono" title={e.providers.join(", ")}>
                                  {e.providers.join(", ")}
                                </span>
                              )}
                            </TableCell>
                            <TableCell>
                              {e.source === "orphan" ? (
                                <Badge variant="destructive">removed</Badge>
                              ) : (
                                <Badge variant={e.source === "bound" ? "default" : "secondary"}>
                                  {e.source === "bound" ? "bound" : "listing"}
                                </Badge>
                              )}
                            </TableCell>
                          </TableRow>
                        ))
                      )}
                    </TableBody>
                  </Table>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-xs text-muted-foreground tabular-nums">
                    {selected.size} selected
                    {sourceFilter !== "all" || query.trim() ? ` · ${total} match(es)` : ""}
                  </span>
                  {selected.size > 0 && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      className="h-7 px-2 text-xs"
                      onClick={() => setSelected(new Set())}
                    >
                      Clear selection
                    </Button>
                  )}
                </div>
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

            {decisionsMsg && (
              <div className="flex flex-col gap-2 rounded-md border border-warning/30 bg-warning/10 px-3 py-2 text-sm">
                <p className="text-warning">{decisionsMsg}</p>
                <Label className="flex items-center gap-2 font-normal">
                  <Checkbox
                    checked
                    onCheckedChange={() => {
                      /* sticky until submit with confirm */
                    }}
                    disabled
                  />
                  I accept Decisions billing (will send decisions_confirmed=true)
                </Label>
              </div>
            )}

            {restrictEmpty && (
              <p className="text-sm text-destructive">Select at least one model, or choose All models.</p>
            )}
          </div>

          <DialogFooter className="shrink-0">
            <Button variant="outline" onClick={onClose}>
              Cancel
            </Button>
            <Button disabled={busy || restrictEmpty} onClick={primary}>
              {busy
                ? mode === "create"
                  ? "Generating…"
                  : "Saving…"
                : decisionsMsg
                  ? "Confirm & save"
                  : mode === "create"
                    ? "Generate key"
                    : "Save access"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <AlertDialog open={confirmWiden} onOpenChange={(o) => !o && setConfirmWiden(false)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Widen to all models?</AlertDialogTitle>
            <AlertDialogDescription>
              This key will be able to call every model, including Decisions-reaching listings and{" "}
              <code>janus-auto</code>. The secret is not rotated.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel
              onClick={() => {
                setConfirmWiden(false)
                setBusy(false)
              }}
            >
              Cancel
            </AlertDialogCancel>
            <AlertDialogAction
              onClick={() =>
                void submit({
                  decisions_confirmed: !!decisionsMsg,
                  confirm_unrestricted: true,
                })
              }
            >
              Widen access
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
