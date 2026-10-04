import { useEffect, useState } from "react"
import { Check, Copy, KeyRound, Plus } from "lucide-react"
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { AgentKey, StateBadge } from "./shared"

export function Keys() {
  const [keys, setKeys] = useState<AgentKey[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [modal, setModal] = useState<"create" | { created: string } | { revoke: AgentKey } | null>(
    null,
  )

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

  return (
    <Layout
      title="Agent keys"
      description="Bearer keys for the data plane — stored as peppered HMAC hashes."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Keys</CardTitle>
          <CardDescription>New keys can call every model on the gateway.</CardDescription>
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
                  <TableHead>Access</TableHead>
                  <TableHead>Created</TableHead>
                  <TableHead>State</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {keys.map((k) => (
                  <TableRow key={k.id}>
                    <TableCell className="font-mono text-xs tabular-nums">{k.prefix}…</TableCell>
                    <TableCell>
                      {k.model_ids === "all" ? (
                        <Badge variant="secondary" className="font-mono text-[11px]">
                          all models
                        </Badge>
                      ) : (
                        <div className="flex flex-wrap gap-1">
                          {k.model_names.filter(Boolean).map((n) => (
                            <Badge variant="secondary" className="font-mono text-[11px]" key={n as string}>
                              {n}
                            </Badge>
                          ))}
                          {k.model_names.filter(Boolean).length === 0 && (
                            <span className="text-muted-foreground">—</span>
                          )}
                        </div>
                      )}
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground tabular-nums">
                      {k.created_at.slice(0, 16).replace("T", " ")}
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
                        <Button
                          variant="ghost"
                          size="xs"
                          className="text-destructive hover:bg-destructive/10 hover:text-destructive"
                          onClick={() => setModal({ revoke: k })}
                        >
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
        <CreateKeyModal onClose={() => setModal(null)} onCreated={(key) => setModal({ created: key })} />
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
              <div className="mb-1 flex size-10 items-center justify-center rounded-full bg-success/10">
                <KeyRound className="size-5 text-success" />
              </div>
              <DialogTitle>Key created</DialogTitle>
              <DialogDescription>201 Created — shown only once</DialogDescription>
            </DialogHeader>
            <div className="flex flex-col gap-3">
              <p className="flex items-center gap-2 rounded-md border border-warning/30 bg-warning/10 px-3 py-2 text-sm font-medium text-warning">
                Copy it now — it will not be shown again
              </p>
              <div className="flex items-center gap-2">
                <code
                  className="flex-1 cursor-text truncate rounded-md border bg-muted px-3 py-2 font-mono text-xs select-all"
                  title={modal.created}
                >
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
                Janus stores an HMAC-SHA256 hash and cannot recover the key. This key can call
                every model.
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
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: (key: string) => void
}) {
  const [busy, setBusy] = useState(false)

  const create = async () => {
    setBusy(true)
    try {
      const res = await api("/keys", { method: "POST", body: {} })
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
        <p className="text-sm text-muted-foreground">
          Generates a bearer key with access to every model. The full key is shown once on the
          next screen.
        </p>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancel
          </Button>
          <Button disabled={busy} onClick={create}>
            {busy ? "Generating…" : "Generate key"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
