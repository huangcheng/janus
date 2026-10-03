import { Fragment, useEffect, useState } from "react"
import { ChevronDown, ChevronRight, Plus, RefreshCw, Settings2 } from "lucide-react"
import { toast } from "sonner"
import { api } from "../api"
import { ErrorFlash, Layout, Loading } from "../components"
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
import { Model, Provider, StateBadge } from "./shared"

export function Models() {
  const [models, setModels] = useState<Model[]>([])
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [expanded, setExpanded] = useState<number | null>(null)
  const [modal, setModal] = useState<"add" | { route: Model } | "syncSettings" | null>(null)
  const [syncing, setSyncing] = useState(false)

  const load = () =>
    Promise.all([api("/models"), api("/providers")])
      .then(([m, p]) => {
        setModels(m.models)
        setProviders(p.providers)
        setLoaded(true)
      })
      .catch((e) => setError(e.message))

  useEffect(() => {
    load()
  }, [])

  const syncNow = async () => {
    setSyncing(true)
    try {
      const r = await api("/models/sync", { method: "POST", body: {} })
      toast.success(`Sync done — ${r.models_added ?? 0} new model(s), ${r.errors ?? 0} error(s)`)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setSyncing(false)
    }
  }

  const act = async (fn: () => Promise<any>, ok: string) => {
    try {
      await fn()
      toast.success(ok)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  return (
    <Layout
      title="Models & routes"
      description="Public model names and the upstream providers that serve them."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Models</CardTitle>
          <CardDescription>
            model name = the <code>model</code> field agents send to /v1/chat/completions
          </CardDescription>
          <CardAction className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={() => setModal("syncSettings")}>
              <Settings2 />
              Sync settings
            </Button>
            <Button variant="outline" size="sm" disabled={syncing} onClick={syncNow}>
              <RefreshCw className={syncing ? "animate-spin" : undefined} />
              {syncing ? "Syncing…" : "Sync now"}
            </Button>
            <Button size="sm" onClick={() => setModal("add")}>
              <Plus />
              Add model
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent>
          {!loaded && !error ? (
            <Loading />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Model</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead>Routes</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {models.map((m) => (
                  <Fragment key={m.id}>
                    <TableRow>
                      <TableCell className="font-mono font-medium">{m.name}</TableCell>
                      <TableCell>
                        <StateBadge enabled={m.enabled} />
                      </TableCell>
                      <TableCell className="text-muted-foreground">
                        {m.routes.length} upstream
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end gap-2">
                          <Button variant="outline" size="xs" onClick={() => setModal({ route: m })}>
                            <Plus />
                            Route
                          </Button>
                          <Button
                            variant="outline"
                            size="xs"
                            onClick={() =>
                              act(
                                () =>
                                  api(`/models/${m.id}/${m.enabled ? "disable" : "enable"}`, {
                                    method: "POST",
                                    body: {},
                                  }),
                                "model updated",
                              )
                            }
                          >
                            {m.enabled ? "Disable" : "Enable"}
                          </Button>
                          <Button
                            variant="ghost"
                            size="xs"
                            onClick={() => setExpanded(expanded === m.id ? null : m.id)}
                          >
                            routes
                            {expanded === m.id ? <ChevronDown /> : <ChevronRight />}
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                    {expanded === m.id && (
                      <TableRow className="bg-muted/50 hover:bg-muted/50">
                        <TableCell colSpan={4}>
                          <Table>
                            <TableHeader>
                              <TableRow>
                                <TableHead>Provider</TableHead>
                                <TableHead>Upstream id</TableHead>
                                <TableHead>Weight</TableHead>
                                <TableHead>Priority</TableHead>
                                <TableHead>State</TableHead>
                                <TableHead className="text-right">Actions</TableHead>
                              </TableRow>
                            </TableHeader>
                            <TableBody>
                              {m.routes.map((r) => (
                                <TableRow key={`${r.model_id}-${r.provider_id}`}>
                                  <TableCell className="font-mono text-xs">
                                    {r.provider_name ?? r.provider_id}
                                  </TableCell>
                                  <TableCell className="font-mono text-xs text-muted-foreground">
                                    {r.upstream_model_id ?? "—"}
                                  </TableCell>
                                  <TableCell className="tabular-nums">{r.weight}</TableCell>
                                  <TableCell className="tabular-nums">{r.priority}</TableCell>
                                  <TableCell>
                                    <StateBadge enabled={r.enabled} />
                                  </TableCell>
                                  <TableCell>
                                    <div className="flex items-center justify-end gap-2">
                                      <Button
                                        variant="outline"
                                        size="xs"
                                        onClick={() =>
                                          act(
                                            () =>
                                              api(
                                                `/models/${r.model_id}/routes/${r.provider_id}/${r.enabled ? "disable" : "enable"}`,
                                                { method: "POST", body: {} },
                                              ),
                                            "route updated",
                                          )
                                        }
                                      >
                                        {r.enabled ? "Off" : "On"}
                                      </Button>
                                      <Button
                                        variant="ghost"
                                        size="xs"
                                        onClick={() =>
                                          act(
                                            () =>
                                              api(
                                                `/models/${r.model_id}/routes/${r.provider_id}`,
                                                { method: "DELETE" },
                                              ),
                                            "route removed",
                                          )
                                        }
                                      >
                                        Remove
                                      </Button>
                                    </div>
                                  </TableCell>
                                </TableRow>
                              ))}
                              {m.routes.length === 0 && (
                                <TableRow>
                                  <TableCell
                                    colSpan={6}
                                    className="h-16 text-center text-muted-foreground"
                                  >
                                    No routes — agents get <code>no_route</code>.
                                  </TableCell>
                                </TableRow>
                              )}
                            </TableBody>
                          </Table>
                        </TableCell>
                      </TableRow>
                    )}
                  </Fragment>
                ))}
                {loaded && models.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={4} className="h-24 text-center text-muted-foreground">
                      No models yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {modal === "add" && (
        <AddModelModal
          onClose={() => setModal(null)}
          onDone={(body) =>
            act(async () => {
              await api("/models", { method: "POST", body })
              setModal(null)
            }, "model added")
          }
        />
      )}

      {modal === "syncSettings" && (
        <SyncSettingsModal onClose={() => setModal(null)} />
      )}

      {modal && typeof modal === "object" && "route" in modal && (
        <AddRouteModal
          model={modal.route}
          providers={providers}
          onClose={() => setModal(null)}
          onDone={(body) =>
            act(async () => {
              await api(`/models/${modal.route.id}/routes`, { method: "POST", body })
              setModal(null)
            }, "route added")
          }
        />
      )}
    </Layout>
  )
}

function AddModelModal({ onClose, onDone }: { onClose: () => void; onDone: (b: any) => void }) {
  const [name, setName] = useState("")
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add model</DialogTitle>
          <DialogDescription>POST /dashboard/api/models</DialogDescription>
        </DialogHeader>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="model-name">Model name</FieldLabel>
            <Input
              id="model-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="qwen4-max"
              autoFocus
            />
            <FieldDescription>Created enabled; add a route next so agents can reach it.</FieldDescription>
          </Field>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={!name} onClick={() => onDone({ name })}>
            <Plus />
            Add model
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function AddRouteModal({
  model,
  providers,
  onClose,
  onDone,
}: {
  model: Model
  providers: Provider[]
  onClose: () => void
  onDone: (b: any) => void
}) {
  const [providerId, setProviderId] = useState(providers[0]?.id ?? 0)
  const [upstream, setUpstream] = useState("")
  const [weight, setWeight] = useState(1)
  const [priority, setPriority] = useState(0)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            Add route · <span className="font-mono">{model.name}</span>
          </DialogTitle>
          <DialogDescription>POST /dashboard/api/models/{model.id}/routes</DialogDescription>
        </DialogHeader>
        <FieldGroup>
          <Field>
            <FieldLabel>Provider</FieldLabel>
            <Select
              value={providerId ? String(providerId) : ""}
              onValueChange={(v) => setProviderId(Number(v))}
            >
              <SelectTrigger className="w-full">
                <SelectValue placeholder="Select provider" />
              </SelectTrigger>
              <SelectContent>
                <SelectGroup>
                  {providers.map((p) => (
                    <SelectItem key={p.id} value={String(p.id)}>
                      {p.name}
                    </SelectItem>
                  ))}
                </SelectGroup>
              </SelectContent>
            </Select>
          </Field>
          <Field>
            <FieldLabel htmlFor="route-upstream">Upstream model id</FieldLabel>
            <Input
              id="route-upstream"
              value={upstream}
              onChange={(e) => setUpstream(e.target.value)}
              placeholder="optional"
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="route-weight">Weight</FieldLabel>
            <Input
              id="route-weight"
              type="number"
              min={1}
              value={weight}
              onChange={(e) => setWeight(Number(e.target.value) || 1)}
            />
          </Field>
          <Field>
            <FieldLabel htmlFor="route-priority">Priority</FieldLabel>
            <Input
              id="route-priority"
              type="number"
              value={priority}
              onChange={(e) => setPriority(Number(e.target.value) || 0)}
            />
            <FieldDescription>
              Lower priority runs first; same priority = weighted round-robin.
            </FieldDescription>
          </Field>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={!providerId}
            onClick={() =>
              onDone({
                provider_id: providerId,
                upstream_model_id: upstream || undefined,
                weight,
                priority,
              })
            }
          >
            <Plus />
            Add route
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function SyncSettingsModal({ onClose }: { onClose: () => void }) {
  const [interval, setIntervalSec] = useState<number | null>(null)
  const [status, setStatus] = useState<any>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    api("/models/sync/status")
      .then((s) => {
        setStatus(s)
        setIntervalSec(Math.round((s.interval_sec ?? 21600) / 3600))
      })
      .catch((e) => toast.error(e.message))
  }, [])

  const save = async () => {
    if (interval === null) return
    setBusy(true)
    try {
      await api("/models/sync/interval", {
        method: "PUT",
        body: { interval_sec: Math.round(interval * 3600) },
      })
      toast.success(`Sync interval set to ${interval}h`)
      onClose()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setBusy(false)
    }
  }

  const presets = [0, 1, 6, 12, 24]

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Model sync settings</DialogTitle>
          <DialogDescription>
            Polls each enabled provider's GET /models and adds new names as
            disabled rows — one-click to enable and route.
          </DialogDescription>
        </DialogHeader>
        <FieldGroup>
          <Field>
            <FieldLabel>Sync interval (hours, 0 = manual only)</FieldLabel>
            <div className="flex items-center gap-2">
              {presets.map((h) => (
                <Button
                  key={h}
                  variant={interval === h ? "default" : "outline"}
                  size="sm"
                  onClick={() => setIntervalSec(h)}
                >
                  {h === 0 ? "Off" : `${h}h`}
                </Button>
              ))}
              <Input
                type="number"
                min={0}
                max={720}
                className="w-24"
                value={interval ?? ""}
                onChange={(e) => setIntervalSec(Number(e.target.value) || 0)}
              />
            </div>
          </Field>
          {status?.last_run && (
            <Field>
              <FieldDescription>
                Last run {new Date(status.last_run).toLocaleString()} ·{" "}
                {status.models_added ?? 0} added · {status.errors ?? 0} errors
              </FieldDescription>
            </Field>
          )}
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={busy || interval === null} onClick={save}>
            Save interval
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
