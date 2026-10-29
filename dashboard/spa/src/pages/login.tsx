import { FormEvent, useEffect, useRef, useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import { ArrowRight, Fingerprint, LoaderCircle } from "lucide-react"
import { api, setToken } from "../api"
import { toast } from "sonner"
import { ErrorFlash, useTheme } from "../components"
import { AuthShell } from "../components/auth-shell"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Field, FieldFooter, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Separator } from "@/components/ui/separator"

const TURNSTILE_SITEKEY = (import.meta.env.VITE_TURNSTILE_SITEKEY as string | undefined)?.trim() || ""
const TURNSTILE_SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"

type TurnstileApi = {
  render: (
    el: HTMLElement,
    opts: {
      sitekey: string
      action?: string
      theme?: "light" | "dark" | "auto"
      /** Expands to the host width (min ~300px) so it aligns with full-width controls. */
      size?: "normal" | "compact" | "flexible"
      callback?: (token: string) => void
      "expired-callback"?: () => void
      "error-callback"?: () => void
    },
  ) => string
  reset: (widgetId?: string) => void
  remove: (widgetId?: string) => void
}

declare global {
  interface Window {
    turnstile?: TurnstileApi
  }
}

function loadTurnstileScript(): Promise<TurnstileApi> {
  if (window.turnstile) return Promise.resolve(window.turnstile)
  return new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src^="${TURNSTILE_SCRIPT.split("?")[0]}"]`)
    if (existing) {
      const wait = () => {
        if (window.turnstile) resolve(window.turnstile)
        else setTimeout(wait, 50)
      }
      wait()
      return
    }
    const script = document.createElement("script")
    script.src = TURNSTILE_SCRIPT
    script.async = true
    script.onload = () => {
      if (window.turnstile) resolve(window.turnstile)
      else reject(new Error("Turnstile API missing after script load"))
    }
    script.onerror = () => reject(new Error("failed to load Turnstile"))
    document.head.appendChild(script)
  })
}

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

type AuthStatus = {
  configured: boolean
  username?: string
  has_password: boolean
  has_totp: boolean
  has_passkey: boolean
}

export function Login() {
  const nav = useNavigate()
  const { theme } = useTheme()
  const [username, setUsername] = useState("")
  const [password, setPassword] = useState("")
  const [totpCode, setTotpCode] = useState("")
  const [challengeToken, setChallengeToken] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [status, setStatus] = useState<AuthStatus | null>(null)
  const [turnstileToken, setTurnstileToken] = useState<string | null>(null)
  const widgetIdRef = useRef<string | null>(null)
  const containerRef = useRef<HTMLDivElement | null>(null)

  const resetTurnstile = () => {
    if (widgetIdRef.current && window.turnstile) {
      window.turnstile.reset(widgetIdRef.current)
      setTurnstileToken(null)
    }
  }

  useEffect(() => {
    api<AuthStatus>("/auth/status").then(setStatus).catch(() => setStatus(null))
  }, [])

  useEffect(() => {
    if (status && !status.configured) nav({ to: "/setup" })
  }, [status, nav])

  useEffect(() => {
    if (!TURNSTILE_SITEKEY || challengeToken || !containerRef.current) return
    let cancelled = false
    loadTurnstileScript()
      .then((ts) => {
        if (cancelled || !containerRef.current || widgetIdRef.current) return
        widgetIdRef.current = ts.render(containerRef.current, {
          sitekey: TURNSTILE_SITEKEY,
          theme: theme === "dark" ? "dark" : "light",
          size: "flexible",
          action: "login",
          callback: (t) => setTurnstileToken(t),
          "expired-callback": () => setTurnstileToken(null),
          "error-callback": () => setTurnstileToken(null),
        })
      })
      .catch(() => {})
    return () => {
      cancelled = true
      // Theme changes must replace the iframe, not just the React prop. Also
      // prevents stale widgets when moving to the TOTP step or unmounting.
      if (widgetIdRef.current && window.turnstile) {
        window.turnstile.remove(widgetIdRef.current)
        widgetIdRef.current = null
        setTurnstileToken(null)
      }
    }
  }, [theme, challengeToken, status])

  async function submitPassword(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const body: Record<string, string> = { username, password }
      if (TURNSTILE_SITEKEY) {
        if (!turnstileToken) throw new Error("complete the human verification first")
        body.turnstile_token = turnstileToken
      }
      const res = await api<{ token: string }>("/auth/login", {
        method: "POST",
        body: body,
      })
      setToken(res.token)
      nav({ to: "/" })
    } catch (err: any) {
      if (err?.code === "totp_required") {
        setChallengeToken(err.extra?.challenge_token ?? null)
        setTotpCode("")
        setError(null)
      } else {
        setError(err.message || "sign in failed")
        resetTurnstile()
      }
    } finally {
      setBusy(false)
    }
  }

  async function submitTotp(e: FormEvent) {
    e.preventDefault()
    if (!challengeToken) return
    setBusy(true)
    setError(null)
    try {
      const res = await api<{ token: string; recovery_remaining?: number }>("/auth/login/totp", {
        method: "POST",
        body: { challenge_token: challengeToken, code: totpCode.trim() },
      })
      if (typeof res.recovery_remaining === "number") {
        toast.success(`Recovery key used — ${res.recovery_remaining} left`)
      }
      setToken(res.token)
      nav({ to: "/" })
    } catch (err: any) {
      setError(err.message || "verification failed")
    } finally {
      setBusy(false)
    }
  }

  async function passkeyLogin() {
    setBusy(true)
    setError(null)
    try {
      const opts = await api<{
        challenge: string
        rpId: string
        allowCredentials: { id: string }[]
        timeout: number
      }>("/auth/login/passkey/assertion/options", { method: "POST", body: {} })
      const cred = (await navigator.credentials.get({
        publicKey: {
          challenge: b64urlToBuffer(opts.challenge),
          rpId: opts.rpId,
          allowCredentials: opts.allowCredentials.map((c) => ({
            type: "public-key" as const,
            id: b64urlToBuffer(c.id),
          })),
          userVerification: "preferred" as UserVerificationRequirement,
          timeout: opts.timeout,
        },
      })) as PublicKeyCredential | null
      if (!cred) throw new Error("passkey cancelled")
      const response = cred.response as AuthenticatorAssertionResponse
      const res = await api<{ token: string }>("/auth/login/passkey/verify", {
        method: "POST",
        body: {
          id: cred.id,
          challenge: opts.challenge,
          response: {
            clientDataJSON: bufferToB64url(response.clientDataJSON),
            authenticatorData: bufferToB64url(response.authenticatorData),
            signature: bufferToB64url(response.signature),
          },
        },
      })
      setToken(res.token)
      nav({ to: "/" })
    } catch (err: any) {
      setError(err.message || "passkey sign in failed")
    } finally {
      setBusy(false)
    }
  }

  const hasPasskey = status?.has_passkey ?? false

  return (
    <AuthShell footer={<span>Operator accounts are managed in Account settings</span>}>
      <Card className="shadow-sm">
        <CardHeader className="text-center">
          <CardTitle className="text-xl">
            {challengeToken ? "Two-factor verification" : "Sign in"}
          </CardTitle>
          <CardDescription>
            {challengeToken
              ? "Enter the 6-digit code — or paste a recovery key"
              : "Gateway console — operator access"}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {error && <ErrorFlash message={error} />}

          {challengeToken ? (
            <form onSubmit={submitTotp}>
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="totp-code">Authenticator code</FieldLabel>
                  <Input
                    id="totp-code"
                    autoComplete="one-time-code"
                    placeholder="123456"
                    value={totpCode}
                    onChange={(e) =>
                      setTotpCode(
                        e.target.value.toUpperCase().replace(/[^A-Z0-9-]/g, "").slice(0, 19),
                      )
                    }
                    autoFocus
                    required
                    className="text-center text-lg tracking-[0.25em] tabular-nums"
                  />
                </Field>
                <FieldFooter>
                  <Button type="button" variant="ghost" onClick={() => setChallengeToken(null)} disabled={busy}>
                    Back
                  </Button>
                  <Button type="submit" disabled={busy || totpCode.length < 6}>
                    {busy && <LoaderCircle className="animate-spin" />}
                    Verify
                  </Button>
                </FieldFooter>
              </FieldGroup>
            </form>
          ) : (
            <form onSubmit={submitPassword}>
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="username">Username</FieldLabel>
                  <Input
                    id="username"
                    autoComplete="username"
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                    autoFocus
                    required
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="password">Password</FieldLabel>
                  <Input
                    id="password"
                    type="password"
                    autoComplete="current-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    required
                  />
                </Field>
                {TURNSTILE_SITEKEY && <div ref={containerRef} />}
                <Button type="submit" className="w-full" disabled={busy || (TURNSTILE_SITEKEY ? !turnstileToken : false)}>
                  {busy && <LoaderCircle className="animate-spin" />}
                  Sign in
                  {!busy && <ArrowRight />}
                </Button>
              </FieldGroup>
            </form>
          )}

          {!challengeToken && hasPasskey && (
            <>
              <div className="after:border-border relative my-4 flex items-center">
                <Separator className="flex-1" />
                <span className="text-muted-foreground relative z-10 bg-card px-2 text-xs">or</span>
                <Separator className="flex-1" />
              </div>
              <Button
                type="button"
                variant="outline"
                className="w-full"
                onClick={passkeyLogin}
                disabled={busy}
              >
                <Fingerprint />
                Use passkey
              </Button>
            </>
          )}
        </CardContent>
      </Card>
    </AuthShell>
  )
}
