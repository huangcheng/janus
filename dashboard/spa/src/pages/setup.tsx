import { FormEvent, useEffect, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { LoaderCircle, ShieldCheck } from "lucide-react"
import { api, setToken } from "../api"
import { ErrorFlash } from "../components"
import { AuthShell } from "../components/auth-shell"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Field, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"

type AuthStatus = { configured: boolean }

export function Setup() {
  const nav = useNavigate()
  const [username, setUsername] = useState("")
  const [password, setPassword] = useState("")
  const [confirm, setConfirm] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [alreadyConfigured, setAlreadyConfigured] = useState(false)

  // Optional TOTP onboarding: generated AFTER the account exists (the
  // /totp/enable endpoint needs a session), so setup = password first,
  // TOTP lands on the /account page right after.
  useEffect(() => {
    api<AuthStatus>("/auth/status")
      .then((s) => {
        if (s.configured) setAlreadyConfigured(true)
      })
      .catch(() => {})
  }, [])

  async function submit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    if (password !== confirm) {
      setError("the passwords do not match")
      return
    }
    setBusy(true)
    try {
      const res = await api<{ token: string }>("/auth/setup", {
        method: "POST",
        body: { username: username.trim(), password },
      })
      setToken(res.token)
      nav({ to: "/account" })
    } catch (err: any) {
      const code = err?.body?.error?.code
      if (code === "already_configured") setAlreadyConfigured(true)
      else setError(err.message || "setup failed")
    } finally {
      setBusy(false)
    }
  }

  if (alreadyConfigured) {
    return (
      <AuthShell footer={<span>After setup: enable 2FA and register a passkey on Account</span>}>
        <Card className="w-full max-w-sm shadow-sm">
          <CardHeader className="text-center">
            <CardTitle className="text-xl">Already set up</CardTitle>
            <CardDescription>An operator account exists. Sign in instead.</CardDescription>
          </CardHeader>
          <CardContent>
            <Button className="w-full" onClick={() => nav({ to: "/login" })}>
              Go to sign in
            </Button>
          </CardContent>
        </Card>
      </AuthShell>
    )
  }

  return (
    <AuthShell footer={<span>After setup: enable 2FA and register a passkey on Account</span>}>
      <Card className="shadow-sm">
        <CardHeader className="text-center">
          <CardTitle className="text-xl">Create the operator account</CardTitle>
          <CardDescription>
            First-run setup — this username and password become the console
            credentials (the old shared env password no longer works).
          </CardDescription>
        </CardHeader>
        <CardContent>
          {error && <ErrorFlash message={error} />}
          <form onSubmit={submit}>
            <FieldGroup>
              <Field>
                <FieldLabel htmlFor="setup-username">Username</FieldLabel>
                <Input
                  id="setup-username"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  autoFocus
                  required
                  minLength={3}
                  maxLength={64}
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="setup-password">Password</FieldLabel>
                <Input
                  id="setup-password"
                  type="password"
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  required
                  minLength={8}
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="setup-confirm">Confirm password</FieldLabel>
                <Input
                  id="setup-confirm"
                  type="password"
                  autoComplete="new-password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  required
                  minLength={8}
                />
              </Field>
              <Button type="submit" className="w-full" disabled={busy}>
                {busy ? <LoaderCircle className="animate-spin" /> : <ShieldCheck />}
                Create account
              </Button>
            </FieldGroup>
          </form>
        </CardContent>
      </Card>
    </AuthShell>
  )
}
