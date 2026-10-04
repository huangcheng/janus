import { Fragment, useEffect, useState } from "react"
import { ChevronDown, ChevronRight, Lock, Plus, RefreshCw, Search, X } from "lucide-react"
import { toast } from "sonner"
import { api } from "../api"
import { ErrorFlash, Layout, Loading } from "../components"
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
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
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
  SelectGroup,
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
import { KeyMeta, Provider, ProviderModel, StateBadge } from "./shared"

export function Providers() {
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [expanded, setExpanded] = useState<number | null>(null)
  const [modal, setModal] = useState<
    | "add"
    | { addKey: Provider }
    | { addModel: Provider }
    | { del: Provider }
    | { delKey: [Provider, KeyMeta] }
    | null
  >(null)
  const [syncing, setSyncing] = useState(false)
  const [listingFilter, setListingFilter] = useState("")

  const load = () =>
    api("/providers")
      .then((r) => {
        setProviders(r.providers)
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

  return (
    <Layout
      title="Providers & keys"
      description="Upstream endpoints and their encrypted credentials."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Providers</CardTitle>
          <CardDescription>
            provider secrets are write-only — never displayed or exported.
            Model lists live under each vendor; bind them on Router.
          </CardDescription>
          <CardAction className="flex items-center gap-2">
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
        <CardContent>
          {!loaded && !error ? (
            <Loading />
          ) : loaded && providers.length === 0 ? (
            <div className="flex h-24 items-center justify-center text-sm text-muted-foreground">
              No providers yet — add one to start routing.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Provider</TableHead>
                  <TableHead>Base URL</TableHead>
                  <TableHead>Protocol</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {providers.map((p) => (
                  <Fragment key={p.id}>
                    <TableRow>
                      <TableCell className="font-medium">{p.name}</TableCell>
                      <TableCell className="font-mono text-xs text-muted-foreground">
                        <div className="max-w-[260px] truncate">{p.base_url}</div>
                      </TableCell>
                      <TableCell className="font-mono text-xs text-muted-foreground">
                        {p.protocol}
                      </TableCell>
                      <TableCell>
                        <StateBadge enabled={p.enabled} />
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end gap-2">
                          <Button variant="outline" size="xs" onClick={() => toggle(p)}>
                            {p.enabled ? "Disable" : "Enable"}
                          </Button>
                          <Button
                            variant="ghost"
                            size="xs"
                            onClick={() => setExpanded(expanded === p.id ? null : p.id)}
                          >
                            {p.keys.length} {p.keys.length === 1 ? "key" : "keys"}
                            {" · "}
                            {(p.models ?? []).length} {(p.models ?? []).length === 1 ? "model" : "models"}
                            {expanded === p.id ? <ChevronDown /> : <ChevronRight />}
                          </Button>
                          <Button
                            variant="ghost"
                            size="xs"
                            className="text-destructive hover:bg-destructive/10 hover:text-destructive"
                            onClick={() => setModal({ del: p })}
                          >
                            Delete
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                    {expanded === p.id && (
                      <TableRow className="bg-muted/30 hover:bg-muted/30">
                        <TableCell colSpan={5}>
                          <div className="flex flex-col gap-4 rounded-lg border border-border/70 bg-background p-4 shadow-sm">
                            <div className="flex flex-col gap-2">
                              <div className="text-[11px] font-medium tracking-wider text-muted-foreground uppercase">
                                Keys · {p.keys.length}
                              </div>
                              {p.keys.length === 0 && (
                                <span className="text-sm text-muted-foreground">no keys</span>
                              )}
                              {p.keys.map((k) => (
                                <div key={k.id} className="flex items-center gap-3">
                                  <span className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">
                                    {k.key_id}
                                  </span>
                                  <Badge variant="outline" className="font-mono text-[11px] tabular-nums">
                                    w{k.weight}
                                  </Badge>
                                  <StateBadge enabled={k.enabled} />
                                  <div className="flex-1" />
                                  <Button
                                    variant="outline"
                                    size="xs"
                                    onClick={() =>
                                      act(
                                        () =>
                                          api(
                                            `/provider-keys/${k.id}/${k.enabled ? "disable" : "enable"}`,
                                            { method: "POST", body: {} },
                                          ),
                                        "key updated",
                                      )
                                    }
                                  >
                                    {k.enabled ? "Disable" : "Enable"}
                                  </Button>
                                  <Button
                                    variant="ghost"
                                    size="icon-xs"
                                    className="text-destructive hover:bg-destructive/10 hover:text-destructive"
                                    aria-label={`Remove key ${k.key_id}`}
                                    onClick={() => setModal({ delKey: [p, k] })}
                                  >
                                    <X />
                                  </Button>
                                </div>
                              ))}
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
                            <ProviderListings
                              provider={p}
                              filter={expanded === p.id ? listingFilter : ""}
                              onFilter={setListingFilter}
                              onToggle={(m) =>
                                act(
                                  () =>
                                    api(
                                      `/provider-models/${m.id}/${m.enabled ? "disable" : "enable"}`,
                                      { method: "POST", body: {} },
                                    ),
                                  "listing updated",
                                )
                              }
                              onAdd={() => setModal({ addModel: p })}
                            />
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

      {modal === "add" && (
        <AddProviderModal
          onClose={() => setModal(null)}
          onDone={(name) =>
            act(async () => {
              await api("/providers", { method: "POST", body: name })
            }, "provider added")
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
          onDone={(name) =>
            act(async () => {
              await api(`/providers/${modal.addModel.id}/models`, {
                method: "POST",
                body: { name },
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
                DELETE /api/providers/{modal.del.id} — this removes the provider, its{" "}
                <strong>{modal.del.keys.length}</strong> stored key(s) and all of its model routes.
                Agents calling routed models will get <code>no_route</code> until another provider
                serves them.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction
                variant="destructive"
                onClick={() =>
                  act(async () => {
                    await api(`/providers/${modal.del.id}`, { method: "DELETE" })
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
                DELETE /api/provider-keys/{modal.delKey[1].id} — the encrypted credential is
                deleted from the database. This cannot be undone.
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
    </Layout>
  )
}

function AddProviderModal({ onClose, onDone }: { onClose: () => void; onDone: (b: any) => void }) {
  const [name, setName] = useState("")
  const [baseUrl, setBaseUrl] = useState("")
  const [protocol, setProtocol] = useState("openai_chat")
  const [err, setErr] = useState("")

  const submit = () => {
    if (!/^https?:\/\//.test(baseUrl)) {
      setErr("base_url must start with http:// or https://")
      return
    }
    onDone({ name, base_url: baseUrl, protocol })
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add provider</DialogTitle>
          <DialogDescription>POST /api/providers</DialogDescription>
        </DialogHeader>
        <FieldGroup>
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
              placeholder="https://api.example.com/v1"
              aria-invalid={!!err}
            />
            {err && <FieldError>{err}</FieldError>}
          </Field>
          <Field>
            <FieldLabel>Protocol</FieldLabel>
            <Select value={protocol} onValueChange={setProtocol}>
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectGroup>
                  <SelectItem value="openai_chat">openai_chat</SelectItem>
                  <SelectItem value="anthropic_messages">anthropic_messages</SelectItem>
                  <SelectItem value="openai_responses">openai_responses</SelectItem>
                </SelectGroup>
              </SelectContent>
            </Select>
          </Field>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={!name || !baseUrl} onClick={submit}>
            <Plus />
            Add provider
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
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
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            Add key · <span className="font-mono">{provider.name}</span>
          </DialogTitle>
          <DialogDescription>POST /api/providers/{provider.id}/keys</DialogDescription>
        </DialogHeader>
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
  filter,
  onFilter,
  onToggle,
  onAdd,
}: {
  provider: Provider
  filter: string
  onFilter: (v: string) => void
  onToggle: (m: ProviderModel) => void
  onAdd: () => void
}) {
  const listings = provider.models ?? []
  const q = filter.trim().toLowerCase()
  const shown = q ? listings.filter((m) => m.name.toLowerCase().includes(q)) : listings
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2">
        <div className="text-[11px] font-medium tracking-wider text-muted-foreground uppercase">
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
              placeholder="Filter models…"
              value={filter}
              onChange={(e) => onFilter(e.target.value)}
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
          no listings — Sync models or add one by name
        </span>
      )}
      {listings.length > 0 && (
        <div className="max-h-64 overflow-y-auto rounded-md border border-border/70 bg-background scrollbar-thin">
          {shown.map((m) => (
            <div
              key={m.id}
              className="flex items-center gap-3 border-b border-border/60 px-3 py-1.5 transition-colors last:border-b-0 hover:bg-muted/50"
            >
              <span className="font-mono text-sm">{m.name}</span>
              <div className="flex-1" />
              <StateBadge enabled={m.enabled} />
              <Button variant="outline" size="xs" onClick={() => onToggle(m)}>
                {m.enabled ? "Disable" : "Enable"}
              </Button>
            </div>
          ))}
          {shown.length === 0 && (
            <div className="px-3 py-4 text-center text-sm text-muted-foreground">no match</div>
          )}
        </div>
      )}
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
  onDone: (name: string) => void
}) {
  const [name, setName] = useState("")
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            Add model · <span className="font-mono">{provider.name}</span>
          </DialogTitle>
          <DialogDescription>
            Inventory only — this does not make the name callable until you bind it on Router.
          </DialogDescription>
        </DialogHeader>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="listing-name">Upstream model id</FieldLabel>
            <Input
              id="listing-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="qwen-turbo"
              autoFocus
            />
          </Field>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={!name.trim()} onClick={() => onDone(name.trim())}>
            <Plus />
            Add
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
