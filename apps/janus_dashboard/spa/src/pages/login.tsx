import { FormEvent, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { ArrowRight } from "lucide-react"
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
                {busy ? "Signing in…" : "Sign in"}
                {!busy && <ArrowRight />}
              </Button>
            </FieldGroup>
          </form>
        </CardContent>
        <CardFooter>
          <p className="text-xs text-muted-foreground">
            Password from <code>JANUS_DASHBOARD_PASSWORD</code> · 5 failed attempts lock the IP
            15&nbsp;min · session 12&nbsp;h
          </p>
        </CardFooter>
      </Card>
    </div>
  )
}
