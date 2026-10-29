import { FormEvent, useCallback, useEffect, useState } from "react"
import QRCode from "qrcode"
import { toast } from "sonner"
import {
  Check,
  Copy,
  Download,
  Fingerprint,
  KeyRound,
  LoaderCircle,
  Plus,
  QrCode,
  ShieldAlert,
  ShieldCheck,
  Trash2,
} from "lucide-react"
import { api, apiFetch } from "../api"
import { ErrorFlash, Layout } from "../components"
import { fmtIsoLocalCompact, fmtIsoLocalMonthDayHm } from "../lib/time-format"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
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
  DialogFooter,
} from "@/components/ui/dialog"
import { Field, FieldDescription, FieldFooter, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"

type Status = {
  configured: boolean
  username?: string
  has_password: boolean
  has_totp: boolean
  has_passkey: boolean
}

type Passkey = {
  credential_id: string
  name: string
  transports: string[]
  created_at: string
  last_used_at: string | null
  sign_count: number
}

type Recovery = { total: number; remaining: number }

function b64urlToBuffer(s: string): ArrayBuffer {
  const pad = "=".repeat((4 - (s.length % 4)) % 4)
  const b64 = (s + pad).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(b64)
  const buf = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i)
  return buf.buffer
}

function bufferToB64url(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf)
  let s = ""
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function useQrDataUrl(text: string | undefined): string {
  const [url, setUrl] = useState("")
  useEffect(() => {
    let alive = true
    if (!text) {
      setUrl("")
      return
    }
    QRCode.toDataURL(text, { width: 480, margin: 2 })
      .then((u) => alive && setUrl(u))
      .catch(() => alive && setUrl(""))
    return () => {
      alive = false
    }
  }, [text])
  return url
}

/** QR codes need a white quiet zone even in dark mode to stay scannable. */
function QrFigure({ uri, className }: { uri: string; className?: string }) {
  const url = useQrDataUrl(uri)
  return url ? (
    <img
      src={url}
      alt="Authenticator QR code"
      className={cn("size-44 shrink-0 rounded-lg border bg-white p-2.5", className)}
    />
  ) : (
    <div
      className={cn(
        "flex size-44 shrink-0 items-center justify-center rounded-lg border bg-white",
        className,
      )}
    >
      <LoaderCircle className="size-5 animate-spin text-zinc-400" />
    </div>
  )
}

function CopyButton({ value, label = "Copy" }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <Button
      type="button"
      variant="ghost"
      size="sm"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value)
          setCopied(true)
          setTimeout(() => setCopied(false), 1500)
        } catch {
          toast.error("clipboard unavailable")
        }
      }}
    >
      {copied ? <Check className="text-success" /> : <Copy />}
      {copied ? "Copied" : label}
    </Button>
  )
}

/** The one-time reveal of a recovery-key set. */
function RecoveryCodes({ codes }: { codes: string[] }) {
  function download() {
    const text = [
      "Janus Dashboard — recovery keys",
      "Each key works once, in place of an authenticator code.",
      "",
      ...codes,
      "",
    ].join("\n")
    const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }))
    const a = document.createElement("a")
    a.href = url
    a.download = "janus-recovery-keys.txt"
    a.click()
    URL.revokeObjectURL(url)
  }
  return (
    <div className="flex flex-col gap-3">
      <p className="text-warning flex items-start gap-2 text-xs">
        <ShieldAlert className="mt-0.5 size-3.5 shrink-0" />
        Shown only this once — save them in your password manager or print them before closing.
      </p>
      <div className="grid gap-2 sm:grid-cols-2">
        {codes.map((c) => (
          <div
            key={c}
            className="rounded-md border bg-muted/40 px-3 py-2 text-center font-mono text-[13px] tracking-wide"
          >
            {c}
          </div>
        ))}
      </div>
      <div className="flex gap-2">
        <CopyButton value={codes.join("\n")} label="Copy all" />
        <Button type="button" variant="ghost" size="sm" onClick={download}>
          <Download />
          Download .txt
        </Button>
      </div>
    </div>
  )
}

/** Password-gated confirm used by QR reveal / disable / regenerate. */
function PasswordField({
  id,
  label,
  value,
  onChange,
}: {
  id: string
  label: string
  value: string
  onChange: (v: string) => void
}) {
  return (
    <Field>
      <FieldLabel htmlFor={id}>{label}</FieldLabel>
      <Input
        id={id}
        type="password"
        autoComplete="current-password"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </Field>
  )
}

function DialogError({ message }: { message: string | null }) {
  if (!message) return null
  return <p role="alert" className="text-destructive text-sm">{message}</p>
}

const ACCOUNT_SECTIONS = [
  { id: "signin", label: "Sign-in", icon: KeyRound },
  { id: "totp", label: "Two-factor", icon: ShieldCheck },
  { id: "recovery", label: "Recovery", icon: ShieldAlert },
  { id: "passkeys", label: "Passkeys", icon: Fingerprint },
] as const

type AccountSection = (typeof ACCOUNT_SECTIONS)[number]["id"]

export function Account() {
  const [status, setStatus] = useState<Status | null>(null)
  const [passkeys, setPasskeys] = useState<Passkey[]>([])
  const [recovery, setRecovery] = useState<Recovery | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [section, setSection] = useState<AccountSection>("signin")

  const load = useCallback(async () => {
    try {
      const [s, p, r] = await Promise.all([
        api<Status>("/auth/status"),
        api<{ passkeys: Passkey[] }>("/auth/passkeys"),
        api<Recovery>("/auth/recovery"),
      ])
      setStatus(s)
      setPasskeys(p.passkeys ?? [])
      setRecovery(r)
    } catch (e: any) {
      setError(e.message)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  return (
    <Layout title="Account" description="Credentials and sign-in security for this console.">
      {error && <ErrorFlash message={error} />}
      {/* Two-column split only from lg: below that the stats stack under
          the avatar with a divider, instead of squeezing into 60px cells
          beside it (which wrapped labels and looked detached). */}
      <section className="grid gap-5 rounded-xl border bg-card p-5 shadow-xs lg:grid-cols-[minmax(0,1fr)_auto] lg:items-center lg:gap-8">
        <div className="flex min-w-0 items-center gap-4">
          <div className="grid size-12 shrink-0 place-items-center rounded-xl bg-primary text-lg font-semibold text-primary-foreground shadow-xs">
            {(status?.username ?? "?").slice(0, 1).toUpperCase()}
          </div>
          <div className="min-w-0">
            <h2 className="truncate text-base font-semibold tracking-tight">{status?.username ?? "…"}</h2>
            <p className="mt-1 text-sm text-muted-foreground">Console operator</p>
          </div>
        </div>
        <dl className="grid grid-cols-3 gap-6 border-t pt-4 lg:gap-8 lg:border-t-0 lg:pt-0" aria-label="Sign-in methods">
          <div>
            <dt className="text-xs whitespace-nowrap text-muted-foreground">Password</dt>
            <dd className="mt-1 text-sm font-medium whitespace-nowrap">{status ? (status.has_password ? "Active" : "Off") : "…"}</dd>
          </div>
          <div>
            <dt className="text-xs whitespace-nowrap text-muted-foreground">Two-factor</dt>
            <dd className="mt-1 text-sm font-medium whitespace-nowrap">{status ? (status.has_totp ? "Enabled" : "Off") : "…"}</dd>
          </div>
          <div>
            <dt className="text-xs whitespace-nowrap text-muted-foreground">Passkeys</dt>
            <dd className="mt-1 text-sm font-medium whitespace-nowrap tabular-nums">{status ? passkeys.length : "…"}</dd>
          </div>
        </dl>
      </section>

      <div className="grid items-start gap-5 lg:grid-cols-[12rem_minmax(0,1fr)]">
        <nav
          aria-label="Account settings"
          className="grid grid-cols-2 gap-1 rounded-xl border bg-card p-1.5 lg:flex lg:flex-col lg:gap-0.5"
        >
          {ACCOUNT_SECTIONS.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              type="button"
              aria-current={section === id ? "page" : undefined}
              onClick={() => setSection(id)}
              className={cn(
                "flex min-h-9 items-center gap-2 whitespace-nowrap rounded-lg px-3 text-left text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60 lg:flex-none",
                section === id
                  ? "bg-primary/10 text-primary"
                  : "text-muted-foreground hover:bg-accent hover:text-foreground",
              )}
            >
              <Icon className="size-4 shrink-0" />
              {label}
            </button>
          ))}
        </nav>
        <div className="min-w-0">
          <section hidden={section !== "signin"} aria-label="Sign-in settings">
            <PasswordCard status={status} onDone={load} />
          </section>
          <section hidden={section !== "totp"} aria-label="Two-factor settings">
            <TotpCard status={status} onDone={load} />
          </section>
          <section hidden={section !== "recovery"} aria-label="Recovery settings">
            <RecoveryCard status={status} recovery={recovery} onDone={load} />
          </section>
          <section hidden={section !== "passkeys"} aria-label="Passkey settings">
            <PasskeyCard passkeys={passkeys} onDone={load} />
          </section>
        </div>
      </div>
    </Layout>
  )
}

function PasswordCard({ status, onDone }: { status: Status | null; onDone: () => void }) {
  const [current, setCurrent] = useState("")
  const [next, setNext] = useState("")
  const [confirm, setConfirm] = useState("")
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setErr(null)
    if (next !== confirm) {
      setErr("the new passwords do not match")
      return
    }
    setBusy(true)
    try {
      await api("/auth/password", { method: "POST", body: { current, next } })
      toast.success("Password updated")
      setCurrent("")
      setNext("")
      setConfirm("")
      onDone()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card className="w-full self-start overflow-hidden">
      <CardHeader>
        <CardTitle>Sign-in password</CardTitle>
        <CardDescription>
          {status?.has_password
            ? "Use a unique password with at least 8 characters."
            : "No password is set. Sign-in currently requires a passkey."}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {err && <ErrorFlash message={err} />}
        {/* Single column at a capped measure: a settings form reads best as
            a quiet stack — equal field widths, one rhythm, one action at
            the foot. Two-column halves with a divider left the sparse card
            looking misaligned. */}
        <form onSubmit={submit} className="max-w-sm">
          <div className="flex flex-col gap-4">
            <Field>
              <FieldLabel htmlFor="pw-current">Current password</FieldLabel>
              <Input
                id="pw-current"
                type="password"
                autoComplete="current-password"
                value={current}
                onChange={(e) => setCurrent(e.target.value)}
                required
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="pw-next">New password</FieldLabel>
              <Input
                id="pw-next"
                type="password"
                autoComplete="new-password"
                value={next}
                onChange={(e) => setNext(e.target.value)}
                required
                minLength={8}
              />
              <FieldDescription>At least 8 characters.</FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="pw-confirm">Confirm new password</FieldLabel>
              <Input
                id="pw-confirm"
                type="password"
                autoComplete="new-password"
                value={confirm}
                onChange={(e) => setConfirm(e.target.value)}
                required
                minLength={8}
              />
            </Field>
          </div>
          <FieldFooter className="mt-6">
            <Button type="submit" disabled={busy}>
              {busy && <LoaderCircle className="animate-spin" />}
              Update password
            </Button>
          </FieldFooter>
        </form>
      </CardContent>
    </Card>
  )
}

function TotpCard({ status, onDone }: { status: Status | null; onDone: () => void }) {
  const [wizardOpen, setWizardOpen] = useState(false)
  const [qrOpen, setQrOpen] = useState(false)
  const [disableOpen, setDisableOpen] = useState(false)
  const enabled = !!status?.has_totp

  return (
    <Card className="w-full self-start overflow-hidden">
      <CardHeader>
        <CardTitle>Two-factor authentication</CardTitle>
        <CardDescription>Require an authenticator code after password sign-in.</CardDescription>
        <CardAction>
          <Badge variant={enabled ? "success" : "secondary"}>{enabled ? "Enabled" : "Not enabled"}</Badge>
        </CardAction>
      </CardHeader>
      <CardContent>
        <div className="flex flex-col items-start gap-4">
          <p className="text-sm leading-relaxed text-muted-foreground">
            {enabled
              ? "Active on every password sign-in. Passkeys skip this step."
              : "Protect the console even if your password is compromised."}
          </p>
          <div className="flex flex-wrap gap-2">
            {enabled ? (
              <>
                <Button variant="outline" size="sm" onClick={() => setQrOpen(true)}>
                  <QrCode />
                  Show QR &amp; key
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  className="text-destructive hover:text-destructive"
                  onClick={() => setDisableOpen(true)}
                >
                  Disable…
                </Button>
              </>
            ) : (
              <Button size="sm" onClick={() => setWizardOpen(true)}>
                <ShieldCheck />
                Enable two-factor
              </Button>
            )}
          </div>
        </div>
      </CardContent>

      <TotpWizardDialog open={wizardOpen} onOpenChange={setWizardOpen} onDone={onDone} />
      <ShowQrDialog open={qrOpen} onOpenChange={setQrOpen} />
      <DisableTotpDialog open={disableOpen} onOpenChange={setDisableOpen} onDone={onDone} />
    </Card>
  )
}

function WizardSteps({ step }: { step: "scan" | "verify" | "keys" }) {
  const steps = ["Scan", "Verify", "Save keys"]
  const idx = step === "scan" ? 0 : step === "verify" ? 1 : 2
  return (
    <div className="text-muted-foreground flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
      {steps.map((label, i) => (
        <span
          key={label}
          className={cn("flex items-center gap-1.5", i === idx && "text-foreground font-medium")}
        >
          <span
            className={cn(
              "size-1.5 rounded-full",
              i < idx ? "bg-success" : i === idx ? "bg-foreground" : "bg-muted-foreground/30",
            )}
          />
          {label}
        </span>
      ))}
    </div>
  )
}

function TotpWizardDialog({
  open,
  onOpenChange,
  onDone,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onDone: () => void
}) {
  const [step, setStep] = useState<"scan" | "verify" | "keys">("scan")
  const [secret, setSecret] = useState("")
  const [uri, setUri] = useState("")
  const [code, setCode] = useState("")
  const [codes, setCodes] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setStep("scan")
    setCode("")
    setCodes([])
    setErr(null)
    setBusy(true)
    api<{ secret: string; provisioning_uri: string }>("/auth/totp/enable", {
      method: "POST",
      body: {},
    })
      .then((r) => {
        setSecret(r.secret)
        setUri(r.provisioning_uri)
      })
      .catch((e: any) => setErr(e.message))
      .finally(() => setBusy(false))
  }, [open])

  async function verify() {
    setBusy(true)
    setErr(null)
    try {
      const res = await api<{ codes: string[] }>("/auth/totp/confirm", {
        method: "POST",
        body: { secret, code: code.trim() },
      })
      setCodes(res.codes)
      setStep("keys")
      toast.success("Two-factor enabled")
      onDone()
    } catch (e: any) {
      setErr(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent title="Enable two-factor" description={<WizardSteps step={step} />} size="lg">
        <DialogError message={err} />
        {step === "scan" && (
          <>
            <div className="grid gap-5 sm:grid-cols-[auto_1fr] sm:items-start">
              <QrFigure uri={uri} />
              <div className="flex min-w-0 flex-col gap-3">
                <p className="text-muted-foreground text-sm">
                  Scan with your authenticator app — Google Authenticator, 1Password, Ente Auth,
                  Aegis all work.
                </p>
                <div>
                  <p className="mb-1.5 text-xs font-medium">Can&rsquo;t scan? Enter the key manually</p>
                  <div className="flex items-center gap-2">
                    <code className="min-w-0 flex-1 rounded-md border bg-muted/50 px-2.5 py-2 font-mono text-xs tracking-wider break-all">
                      {secret || "…"}
                    </code>
                    {secret && <CopyButton value={secret} />}
                  </div>
                </div>
                <p className="text-muted-foreground text-xs">
                  Nothing changes until the code is verified — closing now is safe.
                </p>
              </div>
            </div>
            <DialogFooter>
              <Button variant="ghost" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button onClick={() => setStep("verify")} disabled={!secret || busy}>
                Continue
              </Button>
            </DialogFooter>
          </>
        )}
        {step === "verify" && (
          <>
            <div className="flex flex-col items-center gap-3 py-2">
              <p className="text-muted-foreground text-sm">
                Enter the 6-digit code your app shows for this key.
              </p>
              <Input
                inputMode="numeric"
                autoComplete="one-time-code"
                aria-label="6-digit authenticator code"
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))}
                autoFocus
                className="w-36 text-center text-lg tracking-[0.4em] tabular-nums"
              />
            </div>
            <DialogFooter>
              <Button variant="ghost" onClick={() => setStep("scan")} disabled={busy}>
                Back
              </Button>
              <Button onClick={verify} disabled={busy || code.length !== 6}>
                {busy && <LoaderCircle className="animate-spin" />}
                Verify &amp; enable
              </Button>
            </DialogFooter>
          </>
        )}
        {step === "keys" && (
          <>
            <RecoveryCodes codes={codes} />
            <DialogFooter>
              <Button onClick={() => onOpenChange(false)}>Done — I saved them</Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}

function ShowQrDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  const [password, setPassword] = useState("")
  const [revealed, setRevealed] = useState<{ secret: string; provisioning_uri: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!open) {
      setPassword("")
      setRevealed(null)
      setErr(null)
    }
  }, [open])

  async function reveal() {
    setBusy(true)
    setErr(null)
    try {
      const r = await api<{ secret: string; provisioning_uri: string }>("/auth/totp/qr", {
        method: "POST",
        body: { password },
      })
      setRevealed(r)
    } catch (e: any) {
      setErr(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        title="Show QR &amp; key"
        description="For moving your authenticator to a new device — the key alone bypasses the second factor, so it stays password-gated."
      >
        <DialogError message={err} />
        {revealed ? (
          <>
            <div className="grid gap-5 sm:grid-cols-[auto_1fr] sm:items-start">
              <QrFigure uri={revealed.provisioning_uri} />
              <div className="flex min-w-0 flex-col gap-3">
                <p className="text-muted-foreground text-sm">
                  Scan it on the new device — the old one keeps working until you delete its entry.
                </p>
                <div>
                  <p className="mb-1.5 text-xs font-medium">Manual key</p>
                  <div className="flex items-center gap-2">
                    <code className="min-w-0 flex-1 rounded-md border bg-muted/50 px-2.5 py-2 font-mono text-xs tracking-wider break-all">
                      {revealed.secret}
                    </code>
                    <CopyButton value={revealed.secret} />
                  </div>
                </div>
                <p className="text-muted-foreground text-xs">
                  Visible only while this dialog is open.
                </p>
              </div>
            </div>
            <DialogFooter>
              <Button variant="outline" onClick={() => onOpenChange(false)}>
                Close
              </Button>
            </DialogFooter>
          </>
        ) : (
          <>
            <PasswordField
              id="qr-password"
              label="Console password"
              value={password}
              onChange={setPassword}
            />
            <DialogFooter>
              <Button variant="ghost" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button onClick={reveal} disabled={busy || !password}>
                {busy && <LoaderCircle className="animate-spin" />}
                Reveal
              </Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}

function DisableTotpDialog({
  open,
  onOpenChange,
  onDone,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onDone: () => void
}) {
  const [password, setPassword] = useState("")
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!open) {
      setPassword("")
      setErr(null)
    }
  }, [open])

  async function disable() {
    setBusy(true)
    setErr(null)
    try {
      await api("/auth/totp/disable", { method: "POST", body: { password } })
      toast.success("Two-factor disabled")
      onOpenChange(false)
      onDone()
    } catch (e: any) {
      setErr(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        title="Disable two-factor?"
        description="Password sign-in drops back to a single factor, and every recovery key is wiped."
      >
        <DialogError message={err} />
        <PasswordField
          id="totp-disable-pw"
          label="Console password"
          value={password}
          onChange={setPassword}
        />
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button variant="destructive" onClick={disable} disabled={busy || !password}>
            {busy && <LoaderCircle className="animate-spin" />}
            Disable two-factor
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function RecoveryCard({
  status,
  recovery,
  onDone,
}: {
  status: Status | null
  recovery: Recovery | null
  onDone: () => void
}) {
  const [open, setOpen] = useState(false)
  const enabled = !!status?.has_totp
  const total = recovery?.total ?? 10
  const remaining = recovery?.remaining ?? 0

  return (
    <Card className="w-full self-start overflow-hidden">
      <CardHeader>
        <CardTitle>Recovery keys</CardTitle>
        <CardDescription>One-time backup codes for authenticator sign-in.</CardDescription>
        <CardAction>
          <Badge variant={enabled ? (remaining > 0 ? "outline" : "warning") : "secondary"}>
            {enabled ? `${remaining} of ${total} left` : "Requires 2FA"}
          </Badge>
        </CardAction>
      </CardHeader>
      <CardContent>
        {!enabled ? (
          <p className="text-sm leading-relaxed text-muted-foreground">
            Enable two-factor authentication to create recovery keys.
          </p>
        ) : (
          <div className="flex flex-col items-start gap-4">
            <div className="flex items-center gap-3">
              <div className="flex gap-1" aria-hidden>
                {Array.from({ length: total }).map((_, i) => (
                  <span
                    key={i}
                    className={cn(
                      "h-1.5 w-3 rounded-full",
                      i < remaining ? "bg-primary/65" : "bg-muted-foreground/20",
                    )}
                  />
                ))}
              </div>
              <span className="text-xs text-muted-foreground tabular-nums">
                {remaining} unused
              </span>
            </div>
            <Button variant="outline" size="sm" onClick={() => setOpen(true)}>
              <ShieldAlert />
              Regenerate keys
            </Button>
          </div>
        )}
      </CardContent>
      <RegenerateDialog open={open} onOpenChange={setOpen} onDone={onDone} />
    </Card>
  )
}

function RegenerateDialog({
  open,
  onOpenChange,
  onDone,
}: {
  open: boolean
  onOpenChange: (v: boolean) => void
  onDone: () => void
}) {
  const [password, setPassword] = useState("")
  const [codes, setCodes] = useState<string[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (!open) {
      setPassword("")
      setCodes(null)
      setErr(null)
    }
  }, [open])

  async function regenerate() {
    setBusy(true)
    setErr(null)
    try {
      const res = await api<{ codes: string[] }>("/auth/recovery/regenerate", {
        method: "POST",
        body: { password },
      })
      setCodes(res.codes)
      onDone()
    } catch (e: any) {
      setErr(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        title={codes ? "New recovery keys" : "Regenerate recovery keys"}
        description={
          codes
            ? undefined
            : "Every existing key stops working — including any saved in your password manager."
        }
        size="md"
      >
        <DialogError message={err} />
        {codes ? (
          <>
            <RecoveryCodes codes={codes} />
            <DialogFooter>
              <Button onClick={() => onOpenChange(false)}>Done — I saved them</Button>
            </DialogFooter>
          </>
        ) : (
          <>
            <PasswordField
              id="regen-password"
              label="Console password"
              value={password}
              onChange={setPassword}
            />
            <DialogFooter>
              <Button variant="ghost" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button onClick={regenerate} disabled={busy || !password}>
                {busy && <LoaderCircle className="animate-spin" />}
                Regenerate
              </Button>
            </DialogFooter>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}

function PasskeyCard({ passkeys, onDone }: { passkeys: Passkey[]; onDone: () => void }) {
  const [name, setName] = useState("")
  const [busy, setBusy] = useState(false)
  const [pendingRemove, setPendingRemove] = useState<Passkey | null>(null)

  async function register() {
    if (!name.trim()) {
      toast.error("name this passkey first")
      return
    }
    setBusy(true)
    try {
      const opts = await api<{
        challenge: string
        rp: { name: string; id: string }
        user: { id: string; name: string; displayName: string }
        pubKeyCredParams: { type: string; alg: number }[]
        timeout: number
        excludeCredentials?: { type: string; id: string }[]
        authenticatorSelection?: Record<string, string>
        attestation?: string
      }>("/auth/passkey/register/options", { method: "POST", body: {} })
      const cred = (await navigator.credentials.create({
        publicKey: {
          challenge: b64urlToBuffer(opts.challenge),
          rp: opts.rp,
          user: {
            ...opts.user,
            id: b64urlToBuffer(opts.user.id),
          },
          pubKeyCredParams: opts.pubKeyCredParams as PublicKeyCredentialParameters[],
          timeout: opts.timeout,
          excludeCredentials: (opts.excludeCredentials ?? []).map((c) => ({
            type: "public-key" as const,
            id: b64urlToBuffer(c.id),
          })),
          authenticatorSelection: opts.authenticatorSelection as any,
          attestation: (opts.attestation ?? "none") as any,
        },
      })) as PublicKeyCredential | null
      if (!cred) throw new Error("passkey creation cancelled")
      const response = cred.response as AuthenticatorAttestationResponse
      await api("/auth/passkey/register/verify", {
        method: "POST",
        body: {
          name: name.trim(),
          challenge: opts.challenge,
          response: {
            clientDataJSON: bufferToB64url(response.clientDataJSON),
            attestationObject: bufferToB64url(response.attestationObject),
          },
        },
      })
      toast.success(`Passkey "${name.trim()}" registered`)
      setName("")
      onDone()
    } catch (e: any) {
      toast.error(e.message || "registration failed")
    } finally {
      setBusy(false)
    }
  }

  async function remove(id: string, label: string) {
    try {
      await apiFetch(`/auth/passkeys/${encodeURIComponent(id)}`, { method: "DELETE" })
      toast.success(`Removed "${label}"`)
      onDone()
    } catch (e: any) {
      toast.error(e.message)
    }
  }

  return (
    <>
      <Card className="w-full self-start overflow-hidden">
        <CardHeader>
          <CardTitle>Passkeys</CardTitle>
          <CardDescription>
            Use Touch ID, Windows Hello, or a security key for phishing-resistant sign-in.
          </CardDescription>
          <CardAction>
            <Badge variant="secondary">{passkeys.length} registered</Badge>
          </CardAction>
        </CardHeader>
        <CardContent className="px-0 pt-0">
          <div className="flex flex-col gap-3 border-y bg-muted/25 px-5 py-4 sm:flex-row sm:items-end">
            <Field className="min-w-0 flex-1">
              <FieldLabel htmlFor="passkey-name">Name a new passkey</FieldLabel>
              <Input
                id="passkey-name"
                placeholder="MacBook Touch ID"
                value={name}
                onChange={(e) => setName(e.target.value)}
                className="bg-card"
              />
            </Field>
            <Button onClick={register} disabled={busy || !name.trim()} className="sm:mb-0">
              {busy ? <LoaderCircle className="animate-spin" /> : <Plus />}
              Add passkey
            </Button>
          </div>
          {passkeys.length === 0 ? (
            <div className="flex items-center gap-4 px-5 py-7">
              <div className="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/8 text-primary">
                <Fingerprint className="size-5" />
              </div>
              <div>
                <p className="text-sm font-medium">No passkeys registered</p>
                <p className="mt-0.5 text-sm text-muted-foreground">
                  Add a device above for the fastest, most secure sign-in.
                </p>
              </div>
            </div>
          ) : (
            <Table flush>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Added</TableHead>
                  <TableHead>Last used</TableHead>
                  <TableHead className="text-right pr-5">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {passkeys.map((p) => (
                  <TableRow key={p.credential_id}>
                    <TableCell className="font-medium">
                      <span className="inline-flex items-center gap-2">
                        <Fingerprint className="text-muted-foreground size-4" />
                        {p.name}
                      </span>
                    </TableCell>
                    <TableCell className="text-muted-foreground text-xs tabular-nums">
                      {fmtIsoLocalCompact(p.created_at)}
                    </TableCell>
                    <TableCell className="text-muted-foreground text-xs tabular-nums">
                      {p.last_used_at ? fmtIsoLocalMonthDayHm(p.last_used_at) : "Never"}
                    </TableCell>
                    <TableCell className="text-right pr-5">
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label={`Remove ${p.name}`}
                        onClick={() => setPendingRemove(p)}
                      >
                        <Trash2 />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
      <AlertDialog open={pendingRemove !== null} onOpenChange={(open) => !open && setPendingRemove(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Remove {pendingRemove?.name}?</AlertDialogTitle>
            <AlertDialogDescription>
              This device will no longer be able to sign in with this passkey. Other sign-in methods are unchanged.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              onClick={() => {
                const target = pendingRemove
                setPendingRemove(null)
                if (target) void remove(target.credential_id, target.name)
              }}
            >
              Remove passkey
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
