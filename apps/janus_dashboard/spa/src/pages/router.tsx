import { useEffect, useMemo, useState } from "react"
import { Plus, SlidersHorizontal, X } from "lucide-react"
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
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
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

// Older rows may carry the literal string "undefined" from an earlier seeding
// bug; treat empty/missing the same and fall back to the public name.
function upstreamLabel(upstream: string | null, publicName: string) {
  return upstream && upstream !== "undefined" ? upstream : publicName
}

type BindingRow = {
  key: string
  model: Model
  route: Model["routes"][number]
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
  const [tune, setTune] = useState<BindingRow | null>(null)

  const load = () =>
    Promise.all([api("/models"), api("/providers")])
      .then(([m, p]) => {
        setModels(m.models)
        setProviders(p.providers)
        setLoaded(true)
        setSelected(new Set())
      })
      .catch((e) => setError(e.message))

  useEffect(() => {
    load()
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
      await fn()
      toast.success(ok)
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

  const allSelected = rows.length > 0 && selected.size === rows.length
  const headerState = allSelected ? true : selected.size > 0 ? ("indeterminate" as const) : false

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
    const verb = op === "unbind" ? "removed" : op === "enable" ? "enabled" : "disabled"
    if (failed > 0) {
      toast.error(`${ok} ${verb}, ${failed} failed`)
    } else {
      toast.success(`${ok} binding${ok === 1 ? "" : "s"} ${verb}`)
    }
    setBusy(false)
    setConfirmUnbind(false)
    await load()
  }

  return (
    <Layout
      title="Router"
      description="Public model names agents call, each bound to one or more provider listings."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Bindings</CardTitle>
          <CardDescription>
            One row per binding. When several listings share a public name, calls fail over by
            priority (lowest first), then weighted round-robin.
          </CardDescription>
          <CardAction>
            <Button size="sm" onClick={() => setBindOpen(true)}>
              <Plus />
              Bind listing
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent>
          {!loaded && !error ? (
            <Loading />
          ) : loaded && rows.length === 0 && unbound.length === 0 ? (
            <div className="flex h-24 items-center justify-center text-sm text-muted-foreground">
              No public models yet — bind a listing to create the first one.
            </div>
          ) : (
            <div className="flex flex-col gap-3">
              {selected.size > 0 && (
                <div className="flex animate-fade-up items-center gap-2 rounded-lg border border-primary/25 bg-primary/[0.06] px-3 py-2">
                  <span className="text-sm font-medium tabular-nums">
                    {selected.size} selected
                  </span>
                  <div className="flex-1" />
                  <Button
                    variant="outline"
                    size="xs"
                    disabled={busy}
                    onClick={() => bulk("enable")}
                  >
                    Enable
                  </Button>
                  <Button
                    variant="outline"
                    size="xs"
                    disabled={busy}
                    onClick={() => bulk("disable")}
                  >
                    Disable
                  </Button>
                  <Button
                    variant="ghost"
                    size="xs"
                    disabled={busy}
                    className="text-destructive hover:bg-destructive/10 hover:text-destructive"
                    onClick={() => setConfirmUnbind(true)}
                  >
                    Unbind
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon-xs"
                    aria-label="Clear selection"
                    onClick={() => setSelected(new Set())}
                  >
                    <X />
                  </Button>
                </div>
              )}
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-8">
                      <Checkbox
                        aria-label="Select all bindings"
                        checked={headerState}
                        onCheckedChange={(v) =>
                          setSelected(v === true ? new Set(rows.map((r) => r.key)) : new Set())
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
                  {rows.map((r) => (
                    <TableRow key={r.key} data-state={selected.has(r.key) ? "selected" : undefined}>
                      <TableCell>
                        <Checkbox
                          aria-label={`Select ${r.model.name} via ${r.route.provider_name ?? r.route.provider_id}`}
                          checked={selected.has(r.key)}
                          onCheckedChange={(v) => toggleOne(r.key, v === true)}
                        />
                      </TableCell>
                      <TableCell className="font-mono font-medium">
                        <div className="flex items-center gap-2">
                          {r.model.name}
                          {!r.model.enabled && (
                            <Badge variant="warning" className="text-[11px]">
                              name off
                            </Badge>
                          )}
                        </div>
                      </TableCell>
                      <TableCell>
                        <span className="font-mono text-sm">
                          {r.route.provider_name ?? r.route.provider_id}
                        </span>
                        <span className="font-mono text-xs break-all text-muted-foreground">
                          {" / "}
                          {upstreamLabel(r.route.upstream_model_id, r.model.name)}
                        </span>
                      </TableCell>
                      <TableCell className="font-mono text-xs tabular-nums">
                        {r.route.priority}
                      </TableCell>
                      <TableCell className="font-mono text-xs tabular-nums">
                        {r.route.weight}
                      </TableCell>
                      <TableCell>
                        <StateBadge enabled={r.route.enabled} />
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end gap-1">
                          <Button variant="ghost" size="xs" onClick={() => setTune(r)}>
                            <SlidersHorizontal />
                            Tune
                          </Button>
                          <Button
                            variant="outline"
                            size="xs"
                            onClick={() =>
                              act(
                                () =>
                                  api(
                                    `/models/${r.route.model_id}/routes/${r.route.provider_id}/${r.route.enabled ? "disable" : "enable"}`,
                                    { method: "POST", body: {} },
                                  ),
                                "binding updated",
                              )
                            }
                          >
                            {r.route.enabled ? "Disable" : "Enable"}
                          </Button>
                          <Button
                            variant="ghost"
                            size="xs"
                            className="text-destructive hover:bg-destructive/10 hover:text-destructive"
                            onClick={() =>
                              act(
                                () =>
                                  api(`/models/${r.route.model_id}/routes/${r.route.provider_id}`, {
                                    method: "DELETE",
                                  }),
                                "binding removed",
                              )
                            }
                          >
                            Unbind
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                  {unbound.map((m) => (
                    <TableRow key={`unbound-${m.id}`} className="text-muted-foreground">
                      <TableCell>
                        <Checkbox disabled aria-label={`${m.name} has no bindings to select`} />
                      </TableCell>
                      <TableCell className="font-mono font-medium text-foreground">
                        <div className="flex items-center gap-2">
                          {m.name}
                          <Badge variant="warning" className="text-[11px]">
                            unbound
                          </Badge>
                        </div>
                      </TableCell>
                      <TableCell>—</TableCell>
                      <TableCell>—</TableCell>
                      <TableCell>—</TableCell>
                      <TableCell>
                        <StateBadge enabled={m.enabled} />
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end gap-1">
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
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>

      {confirmUnbind && (
        <AlertDialog open onOpenChange={(o) => !o && setConfirmUnbind(false)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Unbind {selected.size} listing{selected.size === 1 ? "" : "s"}?
              </AlertDialogTitle>
              <AlertDialogDescription>
                DELETE /api/models/:id/routes/:pid for each selected binding. Public names with no
                remaining bindings will answer <code>no_route</code> to agents.
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

      {tune && (
        <TuneDialog
          row={tune}
          onClose={() => setTune(null)}
          onSave={async (weight, priority) => {
            await act(
              () =>
                api(`/models/${tune.route.model_id}/routes/${tune.route.provider_id}/rebalance`, {
                  method: "POST",
                  body: { weight, priority },
                }),
              "binding updated",
            )
            setTune(null)
          }}
        />
      )}

      {bindOpen && (
        <BindModal
          models={models}
          listings={listings}
          onClose={() => setBindOpen(false)}
          onDone={async (publicName, listing) => {
            await act(async () => {
              let model = models.find((m) => m.name === publicName)
              if (!model) {
                const created = await api("/models", {
                  method: "POST",
                  body: { name: publicName },
                })
                model = { id: created.id, name: publicName, enabled: true, routes: [] }
              }
              await api(`/models/${model.id}/routes`, {
                method: "POST",
                body: {
                  provider_id: listing.provider.id,
                  upstream_model_id: listing.listing.name,
                  weight: 1,
                  priority: 0,
                },
              })
              setBindOpen(false)
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
  onSave: (weight: number, priority: number) => void
}) {
  const [weight, setWeight] = useState(row.route.weight)
  const [priority, setPriority] = useState(row.route.priority)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Adjust binding</DialogTitle>
          <DialogDescription>
            <span className="font-mono">{row.model.name}</span>
            {" → "}
            {row.route.provider_name ?? row.route.provider_id}
            {" / "}
            <span className="font-mono">
              {upstreamLabel(row.route.upstream_model_id, row.model.name)}
            </span>
          </DialogDescription>
        </DialogHeader>
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
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={weight < 1} onClick={() => onSave(weight, priority)}>
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
  onDone: (publicName: string, listing: { provider: Provider; listing: ProviderModel }) => void
}) {
  const [publicName, setPublicName] = useState("")
  const [picked, setPicked] = useState("")
  // Providers already bound to the target public name are hidden — a
  // duplicate (model, provider) route would be rejected by the DB anyway.
  const target = models.find((m) => m.name === publicName.trim())
  const boundProviders = new Set((target?.routes ?? []).map((r) => r.provider_id))
  const available = listings.filter((x) => !boundProviders.has(x.provider.id))
  const choice = available.find((x) => `${x.provider.id}:${x.listing.id}` === picked)
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Bind listing</DialogTitle>
          <DialogDescription>
            Route a public model name to a provider listing.
          </DialogDescription>
        </DialogHeader>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="public-name">Public model name</FieldLabel>
            <Input
              id="public-name"
              list="existing-models"
              value={publicName}
              onChange={(e) => setPublicName(e.target.value)}
              placeholder="qwen-turbo"
              autoFocus
            />
            <datalist id="existing-models">
              {models.map((m) => (
                <option key={m.id} value={m.name} />
              ))}
            </datalist>
            <FieldDescription>
              What agents send as <code>model</code>. Created if it does not exist.
            </FieldDescription>
          </Field>
          <Field>
            <FieldLabel>Provider listing</FieldLabel>
            <Select value={picked} onValueChange={setPicked}>
              <SelectTrigger className="w-full">
                <SelectValue placeholder={available.length ? "Select listing" : "No listings available"} />
              </SelectTrigger>
              <SelectContent>
                <SelectGroup>
                  {available.map((x) => (
                    <SelectItem
                      key={`${x.provider.id}:${x.listing.id}`}
                      value={`${x.provider.id}:${x.listing.id}`}
                    >
                      {x.provider.name} / {x.listing.name}
                    </SelectItem>
                  ))}
                </SelectGroup>
              </SelectContent>
            </Select>
            <FieldDescription>New bindings start at priority 0, weight 1.</FieldDescription>
          </Field>
          {publicName.trim() && choice && (
            <p className="rounded-md border border-primary/25 bg-primary/[0.06] px-3 py-2 font-mono text-xs">
              model=&quot;{publicName.trim()}&quot; → {choice.provider.name} /{" "}
              {choice.listing.name}
            </p>
          )}
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button
            disabled={!publicName.trim() || !choice}
            onClick={() => choice && onDone(publicName.trim(), choice)}
          >
            <Plus />
            Bind
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
