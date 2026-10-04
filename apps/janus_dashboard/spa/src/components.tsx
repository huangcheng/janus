import { ReactNode, useCallback, useEffect, useState } from "react"
import { Link, useNavigate, useRouterState } from "@tanstack/react-router"
import {
  ArrowLeftRight,
  Check,
  CircleAlert,
  Copy,
  GitBranch,
  KeyRound,
  LayoutDashboard,
  LogOut,
  Moon,
  ScrollText,
  Sun, Terminal } from "lucide-react"

import { api } from "./api"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Separator } from "@/components/ui/separator"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"
import { Toaster } from "@/components/ui/sonner"

// ---------- theme ----------

export function useTheme() {
  const [theme, setTheme] = useState<"light" | "dark">(() =>
    document.documentElement.classList.contains("dark") ? "dark" : "light",
  )
  const toggle = useCallback(() => {
    setTheme((cur) => {
      const next = cur === "light" ? "dark" : "light"
      document.documentElement.classList.toggle("dark", next === "dark")
      try {
        localStorage.setItem("janus-theme", next)
      } catch {}
      return next
    })
  }, [])
  return { theme, toggle }
}

export function ThemeToggle() {
  const { theme, toggle } = useTheme()
  return (
    <Button variant="ghost" size="icon" onClick={toggle} aria-label="Toggle theme">
      <span className="relative grid size-4 place-items-center">
        <Moon
          className={
            "col-start-1 row-start-1 size-4 transition-[opacity,scale,filter] duration-300 ease-[cubic-bezier(0.2,0,0,1)] " +
            (theme === "light" ? "scale-100 opacity-100 blur-0" : "scale-[0.25] opacity-0 blur-[4px]")
          }
        />
        <Sun
          className={
            "col-start-1 row-start-1 size-4 transition-[opacity,scale,filter] duration-300 ease-[cubic-bezier(0.2,0,0,1)] " +
            (theme === "dark" ? "scale-100 opacity-100 blur-0" : "scale-[0.25] opacity-0 blur-[4px]")
          }
        />
      </span>
    </Button>
  )
}

export function AppToaster() {
  const { theme } = useTheme()
  return <Toaster theme={theme} />
}

// ---------- shell ----------

const NAV = [
  { to: "/", icon: LayoutDashboard, label: "Dashboard" },
  { to: "/providers", icon: ArrowLeftRight, label: "Providers & keys" },
  { to: "/router", icon: GitBranch, label: "Router" },
  { to: "/keys", icon: KeyRound, label: "Agent keys" },
  { to: "/logs", icon: Terminal, label: "Logs" },
    { to: "/audit", icon: ScrollText, label: "Audit log" },
] as const

function EndpointRow({ label, url }: { label: string; url: string }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {}
  }
  return (
    <button
      type="button"
      onClick={copy}
      title={`Copy ${url}`}
      className="group flex w-full items-center justify-between gap-2 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-sidebar-accent"
    >
      <span className="min-w-0">
        <span className="block text-xs">{label}</span>
        <span className="block truncate font-mono text-[11px] text-muted-foreground">
          {url}
        </span>
      </span>
      {copied ? (
        <Check className="size-3.5 shrink-0 text-success" />
      ) : (
        <Copy className="size-3.5 shrink-0 text-muted-foreground/50 opacity-0 transition-opacity group-hover:opacity-100" />
      )}
    </button>
  )
}

function AppSidebar() {
  const nav = useNavigate()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const [dataBase, setDataBase] = useState("")

  useEffect(() => {
    setDataBase(`${window.location.protocol}//${window.location.hostname}:8080`)
  }, [])

  const signOut = async () => {
    try {
      await api("/session", { method: "DELETE" })
    } catch {}
    nav({ to: "/login" })
  }

  return (
    <Sidebar>
      <SidebarHeader>
        <div className="flex items-center gap-2.5 px-2 py-1">
          <img
            src={`${import.meta.env.BASE_URL}icon.png`}
            alt="Janus"
            className="size-8 rounded-lg shadow-sm ring-1 ring-border"
          />
          <div className="flex flex-col">
            <span className="text-sm font-semibold tracking-tight">Janus</span>
            <span className="text-xs text-muted-foreground">gateway console</span>
          </div>
        </div>
      </SidebarHeader>
      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Console</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>
              {NAV.map((n) => (
                <SidebarMenuItem key={n.to}>
                  <SidebarMenuButton
                    asChild
                    isActive={n.to === "/" ? pathname === "/" : pathname.startsWith(n.to)}
                  >
                    <Link to={n.to}>
                      <n.icon />
                      <span>{n.label}</span>
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>
      <SidebarFooter>
        <div className="flex flex-col gap-0.5 rounded-lg border bg-background/60 px-1.5 py-1.5">
          <div className="px-2 pb-1 text-[11px] font-medium tracking-wider text-muted-foreground uppercase">
            Endpoints · data plane :8080
          </div>
          {dataBase && (
            <>
              <EndpointRow label="OpenAI chat" url={`${dataBase}/v1/chat/completions`} />
              <EndpointRow label="OpenAI responses" url={`${dataBase}/v1/responses`} />
              <EndpointRow label="Anthropic messages" url={`${dataBase}/v1/messages`} />
            </>
          )}
        </div>
        <Button variant="outline" size="sm" onClick={signOut}>
          <LogOut />
          Sign out
        </Button>
      </SidebarFooter>
    </Sidebar>
  )
}

export function Layout({
  children,
  title,
  description,
  actions,
}: {
  children: ReactNode
  title: string
  description?: string
  actions?: ReactNode
}) {
  return (
    <SidebarProvider>
      <AppSidebar />
      <SidebarInset>
        <header className="sticky top-0 z-20 flex min-h-16 flex-wrap items-center gap-x-4 gap-y-2 border-b bg-background/85 px-4 py-3 backdrop-blur-md supports-[backdrop-filter]:bg-background/75 md:px-6">
          <SidebarTrigger className="-ml-1" />
          <Separator orientation="vertical" className="data-[orientation=vertical]:h-4" />
          <div className="flex min-w-0 flex-1 flex-col">
            <h1 className="text-lg font-semibold tracking-tight">{title}</h1>
            {description && <p className="text-sm text-muted-foreground">{description}</p>}
          </div>
          {actions}
          <ThemeToggle />
        </header>
        <div className="mx-auto flex w-full max-w-[88rem] min-w-0 flex-1 flex-col gap-4 p-4 md:gap-6 md:p-6">
          {children}
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}

// ---------- bits ----------

export function Loading() {
  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border/70 bg-card p-6 shadow-sm">
      <Skeleton className="h-5 w-36" />
      <Skeleton className="h-4 w-64 max-w-full" />
      <div className="mt-2 flex flex-col gap-2">
        <Skeleton className="h-9 w-full" />
        <Skeleton className="h-9 w-full" />
        <Skeleton className="h-9 w-2/3" />
      </div>
    </div>
  )
}

export function ErrorFlash({ message }: { message: string }) {
  return (
    <Alert variant="destructive">
      <CircleAlert />
      <AlertTitle>Request failed</AlertTitle>
      <AlertDescription>{message}</AlertDescription>
    </Alert>
  )
}
