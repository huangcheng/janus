import { useEffect, useMemo, useState } from "react"
import { Plus } from "lucide-react"
import { toast } from "sonner"
import { api } from "../api"
import { ErrorFlash, Layout, Loading } from "../components"
import { Button } from "@/components/ui/button"
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

export function RouterPage() {
  const [models, setModels] = useState<Model[]>([])
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [selected, setSelected] = useState<number | null>(null)
  const [bindOpen, setBindOpen] = useState(false)

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

  const selectable = models.filter((m) => m.routes.length > 0 || m.enabled)
  const current = selectable.find((m) => m.id === selected) ?? selectable[0]
  useEffect(() => {
    if (current && selected === null) setSelected(current.id)
  }, [current, selected])

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

  return (
    <Layout
      title="Router"
      description="Public names agents send, bound to provider listings. Inventory stays under Providers."
    >
      {error && <ErrorFlash message={error} />}
      {!loaded && !error ? (
        <Loading />
      ) : (
        <div className="flex flex-col gap-4">
          <Card>
            <CardHeader>
              <CardTitle>Bindings</CardTitle>
              <CardDescription>
                One public <code>model</code> can point at several listings (failover / weight).
              </CardDescription>
              <CardAction>
                <Button size="sm" onClick={() => setBindOpen(true)}>
                  <Plus />
                  Bind listing
                </Button>
              </CardAction>
            </CardHeader>
            <CardContent>
              <div className="grid gap-6 lg:grid-cols-[minmax(12rem,16rem)_1fr_minmax(16rem,22rem)]">
                <div className="flex flex-col gap-2">
                  <div className="text-xs font-medium text-muted-foreground">Agent model</div>
                  <div className="flex max-h-96 flex-col gap-1 overflow-y-auto rounded-xl border p-2">
                    {selectable.length === 0 && (
                      <span className="p-2 text-sm text-muted-foreground">
                        No public names yet — bind a listing.
                      </span>
                    )}
                    {selectable.map((m) => (
                      <button
                        key={m.id}
                        type="button"
                        onClick={() => setSelected(m.id)}
                        className={`rounded-lg border px-3 py-2 text-left text-sm ${
                          current?.id === m.id
                            ? "border-foreground bg-muted"
                            : "border-transparent hover:bg-muted/60"
                        }`}
                      >
                        <div className="font-mono">{m.name}</div>
                        <div className="text-xs text-muted-foreground">
                          {m.routes.length} listing{m.routes.length === 1 ? "" : "s"}
                        </div>
                      </button>
                    ))}
                  </div>
                </div>

                <div className="flex min-h-64 items-center justify-center">
                  <div className="flex items-center gap-3 text-muted-foreground">
                    <div className="hidden h-px w-8 border-t border-dashed lg:block" />
                    <div className="rounded-2xl border bg-card px-5 py-4 text-center shadow-sm">
                      <div className="text-xs text-muted-foreground">Janus</div>
                      <div className="font-mono text-sm font-medium">
                        {current?.name ?? "—"}
                      </div>
                      <div className="mt-1 text-xs">priority then weighted RR</div>
                    </div>
                    <div className="hidden h-px w-8 border-t border-dashed lg:block" />
                  </div>
                </div>

                <div className="flex flex-col gap-2">
                  <div className="text-xs font-medium text-muted-foreground">Upstream listings</div>
                  <div className="flex max-h-96 flex-col gap-2 overflow-y-auto rounded-xl border p-2">
                    {(current?.routes ?? []).map((r) => (
                      <div
                        key={`${r.model_id}-${r.provider_id}`}
                        className="rounded-lg border bg-card px-3 py-2"
                      >
                        <div className="flex items-center gap-2">
                          <span className="font-mono text-sm">
                            {r.provider_name ?? r.provider_id}
                          </span>
                          <StateBadge enabled={r.enabled} />
                        </div>
                        <div className="mt-1 font-mono text-xs text-muted-foreground">
                          {r.upstream_model_id ?? current?.name}
                        </div>
                        <div className="mt-1 text-xs text-muted-foreground">
                          priority {r.priority} · weight {r.weight}
                        </div>
                        <div className="mt-2 flex justify-end gap-1">
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
                                "binding updated",
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
                                  api(`/models/${r.model_id}/routes/${r.provider_id}`, {
                                    method: "DELETE",
                                  }),
                                "binding removed",
                              )
                            }
                          >
                            Unbind
                          </Button>
                        </div>
                      </div>
                    ))}
                    {current && current.routes.length === 0 && (
                      <span className="p-2 text-sm text-muted-foreground">
                        Unbound — agents get <code>no_route</code>.
                      </span>
                    )}
                  </div>
                </div>
              </div>
            </CardContent>
          </Card>
        </div>
      )}

      {bindOpen && (
        <BindModal
          models={models}
          listings={listings}
          current={current}
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
              setSelected(model.id)
              setBindOpen(false)
            }, "listing bound")
          }}
        />
      )}
    </Layout>
  )
}

function BindModal({
  models,
  listings,
  current,
  onClose,
  onDone,
}: {
  models: Model[]
  listings: { provider: Provider; listing: ProviderModel }[]
  current?: Model
  onClose: () => void
  onDone: (publicName: string, listing: { provider: Provider; listing: ProviderModel }) => void
}) {
  const [publicName, setPublicName] = useState(current?.name ?? "")
  const [picked, setPicked] = useState("")
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
            Public name is what agents send. Listing is <code>provider / upstream id</code>.
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
            <FieldDescription>Creates the public name if it does not exist.</FieldDescription>
          </Field>
          <Field>
            <FieldLabel>Provider listing</FieldLabel>
            <Select value={picked} onValueChange={setPicked}>
              <SelectTrigger className="w-full">
                <SelectValue
                  placeholder={
                    available.length
                      ? "Select listing"
                      : listings.length
                        ? "All listings already bound"
                        : "No listings yet"
                  }
                />
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
          </Field>
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
