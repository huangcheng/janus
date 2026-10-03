import { useEffect, useState } from "react"
import { Check, Copy, Plus } from "lucide-react"
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
  FieldGroup,
  FieldLabel,
  FieldLegend,
  FieldSet,
} from "@/components/ui/field"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { AgentKey, Model, StateBadge } from "./shared"

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
                DELETE /api/keys/{modal.revoke.id} — agents using this key will immediately get{" "}
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
          <DialogDescription>POST /api/keys</DialogDescription>
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
