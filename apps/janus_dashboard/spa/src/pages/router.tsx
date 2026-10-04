import { Fragment, useEffect, useMemo, useState } from "react"
import { ChevronDown, ChevronRight, Plus } from "lucide-react"
import { toast } from "sonner"
import { api } from "../api"
import { ErrorFlash, Layout, Loading } from "../components"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Model, Provider, ProviderBadges, ProviderModel, StateBadge } from "./shared"
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

export function RouterPage() {
  const [models, setModels] = useState<Model[]>([])
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [expanded, setExpanded] = useState<number | null>(null)
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
      description="Public model names agents call, each bound to one or more provider listings."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Bindings</CardTitle>
          <CardDescription>
            When several listings share one public name, calls fail over by priority (lowest
            first), then weighted round-robin.
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
          ) : loaded && models.length === 0 ? (
            <div className="flex h-24 items-center justify-center text-sm text-muted-foreground">
              No public models yet — bind a listing to create the first one.
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Public model</TableHead>
                  <TableHead>Routes to</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Bindings</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {models.map((m) => (
                  <Fragment key={m.id}>
                    <TableRow>
                      <TableCell className="font-mono font-medium">{m.name}</TableCell>
                      <TableCell>
                        <ProviderBadges routes={m.routes} />
                      </TableCell>
                      <TableCell>
                        <StateBadge enabled={m.enabled} />
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center justify-end">
                          <Button
                            variant="ghost"
                            size="xs"
                            onClick={() => setExpanded(expanded === m.id ? null : m.id)}
                          >
                            {m.routes.length} binding{m.routes.length === 1 ? "" : "s"}
                            {expanded === m.id ? <ChevronDown /> : <ChevronRight />}
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                    {expanded === m.id && (
                      <TableRow className="bg-muted/30 hover:bg-muted/30">
                        <TableCell colSpan={4}>
                          <div className="flex flex-col gap-2 rounded-lg border border-border/70 bg-background p-4 shadow-sm">
                            {m.routes.length === 0 ? (
                              <span className="text-sm text-muted-foreground">
                                Unbound — agents calling <code>{m.name}</code> get{" "}
                                <code>no_route</code>. Use Bind listing to route it.
                              </span>
                            ) : (
                              m.routes.map((r) => (
                                <div
                                  key={`${r.model_id}-${r.provider_id}`}
                                  className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-md border border-border/60 px-3 py-2"
                                >
                                  <span className="font-mono text-sm font-medium">
                                    {r.provider_name ?? r.provider_id}
                                  </span>
                                  <span className="font-mono text-xs break-all text-muted-foreground">
                                    {upstreamLabel(r.upstream_model_id, m.name)}
                                  </span>
                                  <Badge
                                    variant="outline"
                                    className="font-mono text-[11px] tabular-nums"
                                    title="Priority — lower is tried first"
                                  >
                                    p{r.priority}
                                  </Badge>
                                  <Badge
                                    variant="outline"
                                    className="font-mono text-[11px] tabular-nums"
                                    title="Weight within the same priority"
                                  >
                                    w{r.weight}
                                  </Badge>
                                  <StateBadge enabled={r.enabled} />
                                  <div className="flex-1" />
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
                                    {r.enabled ? "Disable" : "Enable"}
                                  </Button>
                                  <Button
                                    variant="ghost"
                                    size="xs"
                                    className="text-destructive hover:bg-destructive/10 hover:text-destructive"
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
                              ))
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
              setExpanded(model.id)
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
  const choice = listings.find((x) => `${x.provider.id}:${x.listing.id}` === picked)
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
                <SelectValue placeholder={listings.length ? "Select listing" : "No listings yet"} />
              </SelectTrigger>
              <SelectContent>
                <SelectGroup>
                  {listings.map((x) => (
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
