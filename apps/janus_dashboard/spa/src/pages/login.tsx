import { FormEvent, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { ArrowRight, LoaderCircle } from "lucide-react"
import { api, setCsrf } from "../api"
import { ErrorFlash, ThemeToggle } from "../components"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Field, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"

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
    <div className="relative flex min-h-dvh items-center justify-center overflow-hidden bg-background p-4">
      <div aria-hidden className="pointer-events-none absolute inset-0">
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_60%_50%_at_50%_-10%,color-mix(in_oklch,var(--primary)_10%,transparent),transparent)]" />
        <div className="absolute inset-0 bg-[linear-gradient(to_right,var(--border)_1px,transparent_1px),linear-gradient(to_bottom,var(--border)_1px,transparent_1px)] bg-[size:56px_56px] opacity-50 [mask-image:radial-gradient(ellipse_70%_60%_at_50%_40%,black,transparent)]" />
      </div>
      <div className="absolute top-4 right-4">
        <ThemeToggle />
      </div>
      <div className="relative w-full max-w-[380px] animate-fade-up">
        <div className="mb-6 flex flex-col items-center gap-3">
          <img
            src={`${import.meta.env.BASE_URL}icon.png`}
            alt="Janus"
            className="size-12 rounded-xl shadow-md ring-1 ring-border"
          />
          <div className="flex flex-col items-center gap-0.5">
            <span className="text-lg font-semibold tracking-tight">Janus</span>
            <span className="text-sm text-muted-foreground">gateway console</span>
          </div>
        </div>
        <Card className="shadow-lg">
          <CardHeader>
            <CardTitle>Sign in</CardTitle>
            <CardDescription>Operator access to the Janus LLM gateway.</CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={submit}>
              <FieldGroup>
                {error && <ErrorFlash message={error} />}
                <Field>
                  <FieldLabel htmlFor="login-password">Dashboard password</FieldLabel>
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
                  {busy ? (
                    <>
                      <LoaderCircle className="animate-spin" />
                      Signing in…
                    </>
                  ) : (
                    <>
                      Sign in
                      <ArrowRight />
                    </>
                  )}
                </Button>
              </FieldGroup>
            </form>
          </CardContent>
          <CardFooter>
            <p className="text-xs leading-relaxed text-muted-foreground">
              Password from <code className="rounded bg-muted px-1 py-0.5 font-mono text-[11px]">JANUS_DASHBOARD_PASSWORD</code>.
              Five failed attempts lock the IP for 15&nbsp;min · session lasts 12&nbsp;h.
            </p>
          </CardFooter>
        </Card>
      </div>
    </div>
  )
}
