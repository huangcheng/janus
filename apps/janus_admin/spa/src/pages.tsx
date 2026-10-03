import { FormEvent, Fragment, ReactNode, useEffect, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import {
  ArrowRight,
  Check,
  ChevronDown,
  ChevronRight,
  Copy,
  Lock,
  Plus,
  RefreshCw,
  X,
} from "lucide-react"
import { toast } from "sonner"
import { Bar, BarChart, XAxis } from "recharts"

import { api, setCsrf } from "./api"
import { ErrorFlash, Layout, Loading, ThemeToggle } from "./components"
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
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart"
import { Checkbox } from "@/components/ui/checkbox"
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
  FieldLegend,
  FieldSet,
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
import { Skeleton } from "@/components/ui/skeleton"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { Textarea } from "@/components/ui/textarea"

type Provider = { id: number; name: string; base_url: string; protocol: string; enabled: boolean; keys: KeyMeta[] }
type KeyMeta = { id: number; key_id: string; weight: number; enabled: boolean }
type Model = { id: number; name: string; enabled: boolean; routes: Route[] }
type Route = { model_id: number; provider_id: number; provider_name: string | null; upstream_model_id: string | null; weight: number; priority: number; enabled: boolean }
type AgentKey = { id: number; prefix: string; enabled: boolean; created_at: string; model_ids: number[]; model_names: (string | null)[] }
type AuditEvent = { ts: string; actor: string; action: string; target: string | null; detail: string | null }

function StateBadge({ enabled }: { enabled: boolean }) {
  return <Badge variant={enabled ? "default" : "secondary"}>{enabled ? "enabled" : "disabled"}</Badge>
}

function ActionBadge({ action }: { action: string }) {
  const verb = action.split(".").pop() ?? ""
  const variant = /delete|revoke|disable/.test(verb)
    ? "destructive"
    : /add|create|enable/.test(verb)
      ? "default"
      : "secondary"
  return <Badge variant={variant}>{action}</Badge>
}

// ===================== Login =====================

export function Login() {
  const nav = useNavigate()
  const [password, setPassword] = useState("")
  const [error, setError] = useState("")
  const [busy, setBusy] = useState(false)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError("")
    try {
      const res = await api("/session", { method: "POST", body: { password } })
      setCsrf(res.csrf)
      nav({ to: "/" })
    } catch (err: any) {
      setError(err.message ?? "login failed")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="relative flex min-h-svh items-center justify-center bg-muted/40 p-4">
      <div className="absolute top-4 right-4">
        <ThemeToggle />
      </div>
      <Card className="w-full max-w-sm">
        <CardHeader>
          <div className="flex items-center gap-3">
            <img
              src={`${import.meta.env.BASE_URL}icon.png`}
              alt="Janus"
              className="size-9 rounded-md"
            />
            <div className="flex flex-col">
              <span className="font-semibold leading-none">Janus</span>
              <span className="text-xs text-muted-foreground">gateway console</span>
            </div>
          </div>
          <CardTitle>Sign in</CardTitle>
          <CardDescription>Operator access to the Janus LLM gateway.</CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={submit}>
            <FieldGroup>
              {error && <ErrorFlash message={error} />}
              <Field>
                <FieldLabel htmlFor="login-password">Admin password</FieldLabel>
                <Input
                  id="login-password"
                  type="password"
                  name="password"
                  autoFocus
                  autoComplete="current-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
              </Field>
              <Button type="submit" className="w-full" disabled={busy || !password}>
                {busy ? "Signing in…" : "Sign in"}
                {!busy && <ArrowRight />}
              </Button>
            </FieldGroup>
          </form>
        </CardContent>
        <CardFooter>
          <p className="text-xs text-muted-foreground">
            Password from <code>JANUS_ADMIN_PASSWORD</code> · 5 failed attempts lock the IP
            15&nbsp;min · session 12&nbsp;h
          </p>
        </CardFooter>
      </Card>
    </div>
  )
}

// ===================== Dashboard =====================

const activityConfig = {
  events: { label: "Events", color: "var(--primary)" },
} satisfies ChartConfig

function StatCard({ label, value }: { label: string; value: ReactNode }) {
  return (
    <Card>
      <CardHeader>
        <CardDescription>{label}</CardDescription>
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-semibold tabular-nums">{value}</div>
      </CardContent>
    </Card>
  )
}

function ActivityChart({ events }: { events: AuditEvent[] | null }) {
  if (events === null) return <Skeleton className="h-48 w-full" />
  const counts = new Array<number>(24).fill(0)
  const now = Date.now()
  for (const e of events) {
    const t = Date.parse(e.ts)
    if (Number.isNaN(t)) continue
    const hoursAgo = Math.floor((now - t) / 3_600_000)
    if (hoursAgo >= 0 && hoursAgo < 24) counts[23 - hoursAgo]++
  }
  const max = Math.max(...counts)
  if (max === 0) {
    return (
      <div className="flex h-48 items-center justify-center text-sm text-muted-foreground">
        No admin activity in the last 24h.
      </div>
    )
  }
  const data = counts.map((n, i) => {
    const hour = new Date(now - (23 - i) * 3_600_000).getHours()
    return { hour: `${String(hour).padStart(2, "0")}:00`, events: n }
  })
  return (
    <ChartContainer config={activityConfig} className="aspect-auto h-48 w-full">
      <BarChart data={data} accessibilityLayer margin={{ top: 4, right: 0, bottom: 0, left: 0 }}>
        <XAxis dataKey="hour" tickLine={false} axisLine={false} interval={3} />
        <ChartTooltip content={<ChartTooltipContent />} />
        <Bar dataKey="events" fill="var(--color-events)" radius={2} />
      </BarChart>
    </ChartContainer>
  )
}

export function Dashboard() {
  const [data, setData] = useState<any>(null)
  const [audit, setAudit] = useState<AuditEvent[] | null>(null)
  const [error, setError] = useState("")

  const load = () => api("/overview").then(setData).catch((e) => setError(e.message))

  useEffect(() => {
    load()
    api("/audit?limit=200")
      .then((r) => setAudit(r.events))
      .catch(() => setAudit([]))
  }, [])

  const reload = async () => {
    try {
      const res = await api("/catalog/reload", { method: "POST", body: {} })
      toast.success(`Catalog reloaded — generation ${res.generation}`)
      await load()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  const stats = data
    ? [
        { label: "Serving generation", value: data.generation },
        { label: "DB backend", value: String(data.backend) },
        { label: "Providers", value: data.counts.providers },
        { label: "Models", value: data.counts.models },
        { label: "Routes", value: data.counts.routes },
        { label: "Agent keys", value: data.counts.agent_keys },
      ]
    : []

  return (
    <Layout
      title="Dashboard"
      description="Configuration state and upstream health at a glance."
      actions={
        <Button onClick={reload}>
          <RefreshCw />
          Reload catalog
        </Button>
      }
    >
      {error && <ErrorFlash message={error} />}
      {!data && !error ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {Array.from({ length: 7 }).map((_, i) => (
            <Skeleton key={i} className="h-28 w-full" />
          ))}
        </div>
      ) : null}
      {data && (
        <>
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Card>
              <CardHeader>
                <CardDescription>Catalog state</CardDescription>
              </CardHeader>
              <CardContent>
                <Badge variant={data.ready ? "default" : "secondary"}>
                  {data.ready ? "ready" : "cold"}
                </Badge>
              </CardContent>
            </Card>
            {stats.map((s) => (
              <StatCard key={s.label} label={s.label} value={s.value} />
            ))}
          </div>

          <Card>
            <CardHeader>
              <CardTitle>Admin activity · last 24h</CardTitle>
              <CardDescription>audit events per hour</CardDescription>
            </CardHeader>
            <CardContent>
              <ActivityChart events={audit} />
            </CardContent>
          </Card>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>Providers</CardTitle>
                <CardDescription>health as of last reload</CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Provider</TableHead>
                      <TableHead>Protocol</TableHead>
                      <TableHead>Keys</TableHead>
                      <TableHead>State</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.providers.map((p: any) => (
                      <TableRow key={p.id}>
                        <TableCell className="font-medium">{p.name}</TableCell>
                        <TableCell className="font-mono text-xs text-muted-foreground">
                          {p.protocol}
                        </TableCell>
                        <TableCell className="tabular-nums">{p.keys}</TableCell>
                        <TableCell>
                          <StateBadge enabled={p.enabled} />
                        </TableCell>
                      </TableRow>
                    ))}
                    {data.providers.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={4} className="h-24 text-center text-muted-foreground">
                          No providers yet.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Recent admin actions</CardTitle>
                <CardDescription>last 5</CardDescription>
              </CardHeader>
              <CardContent>
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>When</TableHead>
                      <TableHead>Action</TableHead>
                      <TableHead>Target</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {data.recent_audit.map((a: AuditEvent, i: number) => (
                      <TableRow key={i}>
                        <TableCell className="font-mono text-xs text-muted-foreground">
                          {(a.ts ?? "").slice(11, 19)}
                        </TableCell>
                        <TableCell>
                          <ActionBadge action={a.action} />
                        </TableCell>
                        <TableCell className="font-mono text-xs text-muted-foreground">
                          {a.target ?? "—"}
                        </TableCell>
                      </TableRow>
                    ))}
                    {data.recent_audit.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={3} className="h-24 text-center text-muted-foreground">
                          No admin actions yet.
                        </TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </CardContent>
            </Card>
          </div>
        </>
      )}
    </Layout>
  )
}

// ===================== Providers =====================

export function Providers() {
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [expanded, setExpanded] = useState<number | null>(null)
  const [modal, setModal] = useState<
    "add" | { addKey: Provider } | { del: Provider } | { delKey: [Provider, KeyMeta] } | null
  >(null)

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
            provider secrets are write-only — never displayed or exported
          </CardDescription>
          <CardAction>
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
                        {p.base_url}
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
                            {expanded === p.id ? <ChevronDown /> : <ChevronRight />}
                          </Button>
                          <Button variant="ghost" size="xs" onClick={() => setModal({ del: p })}>
                            Delete
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                    {expanded === p.id && (
                      <TableRow className="bg-muted/50 hover:bg-muted/50">
                        <TableCell colSpan={5}>
                          <div className="flex flex-col gap-2">
                            {p.keys.length === 0 && (
                              <span className="text-sm text-muted-foreground">no keys</span>
                            )}
                            {p.keys.map((k) => (
                              <div key={k.id} className="flex items-center gap-3">
                                <span className="font-mono text-sm">{k.key_id}</span>
                                <span className="text-xs text-muted-foreground">w{k.weight}</span>
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

      {modal && typeof modal === "object" && "del" in modal && (
        <AlertDialog open onOpenChange={(o) => !o && setModal(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>
                Delete provider <span className="font-mono">{modal.del.name}</span>?
              </AlertDialogTitle>
              <AlertDialogDescription>
                DELETE /admin/api/providers/{modal.del.id} — this removes the provider, its{" "}
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
                DELETE /admin/api/provider-keys/{modal.delKey[1].id} — the encrypted credential is
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
          <DialogDescription>POST /admin/api/providers</DialogDescription>
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
          <DialogDescription>POST /admin/api/providers/{provider.id}/keys</DialogDescription>
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
            Encrypt &amp; store
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ===================== Models & routes =====================

export function Models() {
  const [models, setModels] = useState<Model[]>([])
  const [providers, setProviders] = useState<Provider[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [expanded, setExpanded] = useState<number | null>(null)
  const [modal, setModal] = useState<"add" | { route: Model } | null>(null)

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
          <CardAction>
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
          <DialogDescription>POST /admin/api/models</DialogDescription>
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
          <DialogDescription>POST /admin/api/models/{model.id}/routes</DialogDescription>
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

// ===================== Agent keys =====================

export function Keys() {
  const [keys, setKeys] = useState<AgentKey[]>([])
  const [models, setModels] = useState<Model[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [modal, setModal] = useState<"create" | { created: string } | { revoke: AgentKey } | null>(
    null,
  )

  const load = () =>
    Promise.all([api("/keys"), api("/models")])
      .then(([k, m]) => {
        setKeys(k.keys)
        setModels(m.models)
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

  return (
    <Layout
      title="Agent keys"
      description="Bearer keys for the data plane — stored as peppered HMAC hashes."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Keys</CardTitle>
          <CardDescription>empty grants = key cannot call any model</CardDescription>
          <CardAction>
            <Button size="sm" onClick={() => setModal("create")}>
              <Plus />
              Create key
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
                  <TableHead>Prefix</TableHead>
                  <TableHead>Model grants</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {keys.map((k) => (
                  <TableRow key={k.id}>
                    <TableCell className="font-mono text-xs">{k.prefix}…</TableCell>
                    <TableCell>
                      <div className="flex flex-wrap gap-1">
                        {k.model_names.filter(Boolean).map((n) => (
                          <Badge variant="secondary" key={n as string}>
                            {n}
                          </Badge>
                        ))}
                        {k.model_names.filter(Boolean).length === 0 && (
                          <span className="text-muted-foreground">—</span>
                        )}
                      </div>
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {k.created_at}
                    </TableCell>
                    <TableCell>
                      <StateBadge enabled={k.enabled} />
                    </TableCell>
                    <TableCell>
                      <div className="flex items-center justify-end gap-2">
                        <Button
                          variant="outline"
                          size="xs"
                          onClick={() =>
                            act(
                              () =>
                                api(`/keys/${k.id}/${k.enabled ? "disable" : "enable"}`, {
                                  method: "POST",
                                  body: {},
                                }),
                              "key updated",
                            )
                          }
                        >
                          {k.enabled ? "Disable" : "Enable"}
                        </Button>
                        <Button variant="ghost" size="xs" onClick={() => setModal({ revoke: k })}>
                          Revoke
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
                {loaded && keys.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} className="h-24 text-center text-muted-foreground">
                      No agent keys yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {modal === "create" && (
        <CreateKeyModal models={models} onClose={() => setModal(null)} onCreated={(key) => setModal({ created: key })} />
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
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Key created</DialogTitle>
              <DialogDescription>201 Created — shown only once</DialogDescription>
            </DialogHeader>
            <div className="flex flex-col gap-3">
              <p className="text-sm font-medium text-destructive">
                Copy it now — shown only once
              </p>
              <div className="flex items-center gap-2">
                <code className="flex-1 truncate rounded-md border bg-muted px-3 py-2 font-mono text-xs">
                  {modal.created}
                </code>
                <Button
                  variant="outline"
                  size="sm"
                  onClick={() => {
                    navigator.clipboard?.writeText(modal.created)
                    toast.success("copied to clipboard")
                  }}
                >
                  <Copy />
                  Copy
                </Button>
              </div>
              <p className="text-sm text-muted-foreground">
                Janus stores an HMAC-SHA256 hash and cannot recover the key.
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
                DELETE /admin/api/keys/{modal.revoke.id} — agents using this key will immediately get{" "}
                <code>401 unauthorized</code>. The HMAC hash is deleted; this cannot be undone.
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
    </Layout>
  )
}

function CreateKeyModal({
  models,
  onClose,
  onCreated,
}: {
  models: Model[]
  onClose: () => void
  onCreated: (key: string) => void
}) {
  const [grants, setGrants] = useState<Set<number>>(new Set(models.map((m) => m.id)))
  const [busy, setBusy] = useState(false)
  const toggle = (id: number) =>
    setGrants((g) => {
      const n = new Set(g)
      if (n.has(id)) {
        n.delete(id)
      } else {
        n.add(id)
      }
      return n
    })

  const create = async () => {
    setBusy(true)
    try {
      const res = await api("/keys", { method: "POST", body: { model_ids: [...grants] } })
      onCreated(res.key)
    } catch (e: any) {
      setBusy(false)
      toast.error(e.message)
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Create key</DialogTitle>
          <DialogDescription>POST /admin/api/keys</DialogDescription>
        </DialogHeader>
        <FieldGroup>
          <FieldSet>
            <FieldLegend>Model grants</FieldLegend>
            <FieldDescription>
              The full key is generated server-side and shown once on the next screen.
            </FieldDescription>
            <FieldGroup data-slot="checkbox-group">
              {models.map((m) => (
                <Field orientation="horizontal" key={m.id}>
                  <Checkbox
                    id={`grant-${m.id}`}
                    checked={grants.has(m.id)}
                    onCheckedChange={() => toggle(m.id)}
                  />
                  <FieldLabel htmlFor={`grant-${m.id}`} className="font-normal">
                    {m.name}
                  </FieldLabel>
                </Field>
              ))}
            </FieldGroup>
          </FieldSet>
        </FieldGroup>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={grants.size === 0 || busy} onClick={create}>
            {busy ? "Generating…" : "Generate key"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ===================== Audit =====================

export function Audit() {
  const [events, setEvents] = useState<AuditEvent[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    api("/audit?limit=200")
      .then((r) => {
        setEvents(r.events)
        setLoaded(true)
      })
      .catch((e) => setError(e.message))
  }, [])

  return (
    <Layout
      title="Audit log"
      description="Every admin mutation, newest first. Ring buffer — last 1000 events, in-memory."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Events</CardTitle>
          <CardDescription>in-memory; resets on restart</CardDescription>
        </CardHeader>
        <CardContent>
          {!loaded && !error ? (
            <Loading />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Time</TableHead>
                  <TableHead>Actor</TableHead>
                  <TableHead>Action</TableHead>
                  <TableHead>Target</TableHead>
                  <TableHead>Detail</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {events.map((a, i) => (
                  <TableRow key={i}>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {a.ts}
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {a.actor}
                    </TableCell>
                    <TableCell>
                      <ActionBadge action={a.action} />
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {a.target ?? "—"}
                    </TableCell>
                    <TableCell className="text-muted-foreground">{a.detail ?? "—"}</TableCell>
                  </TableRow>
                ))}
                {loaded && events.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} className="h-24 text-center text-muted-foreground">
                      No events yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </Layout>
  )
}
