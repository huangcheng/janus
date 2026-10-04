import { ReactNode, useCallback, useEffect, useState } from "react"
import { Link, useNavigate, useRouterState } from "@tanstack/react-router"
import {
  ArrowLeftRight,
  CircleAlert,
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
      {theme === "light" ? <Moon /> : <Sun />}
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

function AppSidebar() {
  const nav = useNavigate()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const [gen, setGen] = useState<number | null>(null)

  useEffect(() => {
    api("/overview")
      .then((o) => setGen(o.generation))
      .catch(() => {})
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
        <div className="flex items-center gap-2 px-2 py-1">
          <img
            src={`${import.meta.env.BASE_URL}icon.png`}
            alt="Janus"
            className="size-8 rounded-md"
          />
          <div className="flex flex-col">
            <span className="text-sm font-semibold">Janus</span>
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
        <div className="flex flex-col gap-1 px-2 py-1 text-xs text-muted-foreground">
          <div className="flex items-center justify-between">
            <span>data plane</span>
            <span className="font-mono">:8080</span>
          </div>
          <div className="flex items-center justify-between">
            <span>dashboard plane</span>
            <span className="font-mono">:8090</span>
          </div>
          {gen !== null && (
            <div className="flex items-center justify-between">
              <span>catalog</span>
              <span className="font-mono">gen {gen}</span>
            </div>
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
        <header className="flex min-h-16 flex-wrap items-center gap-x-4 gap-y-2 border-b px-4 py-3 md:px-6">
          <SidebarTrigger className="-ml-1" />
          <Separator orientation="vertical" className="data-[orientation=vertical]:h-4" />
          <div className="flex min-w-0 flex-1 flex-col">
            <h1 className="text-lg font-semibold tracking-tight">{title}</h1>
            {description && <p className="text-sm text-muted-foreground">{description}</p>}
          </div>
          {actions}
          <ThemeToggle />
        </header>
        <div className="flex min-w-0 flex-1 flex-col gap-4 p-4 md:p-6">{children}</div>
      </SidebarInset>
    </SidebarProvider>
  )
}

// ---------- bits ----------

export function Loading() {
  return (
    <div className="flex flex-col gap-2">
      <Skeleton className="h-8 w-full" />
      <Skeleton className="h-8 w-full" />
      <Skeleton className="h-8 w-full" />
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
