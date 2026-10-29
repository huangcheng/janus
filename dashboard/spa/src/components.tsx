import {
  ReactNode,
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react"
import { Link, useNavigate, useRouterState } from "@tanstack/react-router"
import {
  Activity,
  ArrowLeftRight,
  Check,
  ChevronDown,
  Copy,
  GitBranch,
  KeyRound,
  LayoutDashboard,
  LogOut,
  Moon,
  OctagonX,
  ScrollText,
  UserRound,
  Sun,
  Terminal,
  Server,
  Wrench,
} from "lucide-react"
import { toast } from "sonner"

import { api, clearToken } from "./api"
import { Alert } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
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
import { Tooltip } from "@/components/ui/tooltip"
import { cn } from "@/lib/utils"

// ---------- theme ----------

type Theme = "light" | "dark"

const ThemeContext = createContext<{ theme: Theme; toggle: () => void } | null>(null)

/** Owns the light/dark class for the whole console. One provider at the
 * router root keeps the sidebar toggle, the login-page toggle and the
 * sonner toaster in agreement (each useTheme() used to own its own state). */
export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>(() =>
    document.documentElement.classList.contains("dark") ? "dark" : "light",
  )
  const toggle = useCallback(() => {
    // <html>'s class is the source of truth (index.html seeds it before first
    // paint); derive from it rather than from an updater with side effects,
    // which StrictMode would invoke twice and so flip the class back.
    const next: Theme = document.documentElement.classList.contains("dark") ? "light" : "dark"
    document.documentElement.classList.toggle("dark", next === "dark")
    try {
      localStorage.setItem("janus-theme", next)
    } catch {}
    setTheme(next)
  }, [])
  const value = useMemo(() => ({ theme, toggle }), [theme, toggle])
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme() {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error("useTheme must be used inside <ThemeProvider>")
  return ctx
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

export function IconAction({
  label,
  onClick,
  destructive,
  disabled,
  expanded,
  controls,
  children,
}: {
  label: string
  onClick: () => void
  destructive?: boolean
  disabled?: boolean
  expanded?: boolean
  controls?: string
  children: ReactNode
}) {
  const button = (
    <Button
      type="button"
      variant="ghost"
      size="icon-xs"
      aria-label={label}
      aria-expanded={expanded}
      aria-controls={controls}
      disabled={disabled}
      onClick={onClick}
      className={
        destructive
          ? "text-destructive hover:bg-destructive/10 hover:text-destructive"
          : "text-muted-foreground hover:text-foreground"
      }
    >
      {children}
    </Button>
  )
  // A disabled button swallows pointer events, so the tooltip would never
  // show — hand the trigger role to a wrapper span while disabled. Keep it
  // focusable so the explanation remains available without enabling the action.
  return (
    <Tooltip side="bottom" content={label}>
      {disabled ? (
        <span className="inline-flex" role="button" aria-disabled="true" aria-label={label} tabIndex={0}>
          {button}
        </span>
      ) : (
        button
      )}
    </Tooltip>
  )
}

export function AppToaster() {
  const { theme } = useTheme()
  return <Toaster theme={theme} />
}

// ---------- shell ----------

const NAV = [
  { to: "/", icon: LayoutDashboard, label: "Dashboard", group: "Overview" },
  { to: "/providers", icon: ArrowLeftRight, label: "Providers & keys", group: "Configure" },
  { to: "/keys", icon: KeyRound, label: "Agent keys", group: "Configure" },
  { to: "/router", icon: GitBranch, label: "Router", group: "Configure" },
  { to: "/nodes", icon: Server, label: "Nodes", group: "Configure" },
  { to: "/maintenance", icon: Wrench, label: "Maintenance", group: "System" },
  { to: "/usage", icon: Activity, label: "Usage", group: "Observe" },
  { to: "/failures", icon: OctagonX, label: "Failures", group: "Observe" },
  { to: "/logs", icon: Terminal, label: "Logs", group: "Observe" },
  { to: "/audit", icon: ScrollText, label: "Audit log", group: "Observe" },
  { to: "/account", icon: UserRound, label: "Account", group: "System" },
] as const

const NAV_GROUPS = ["Overview", "Configure", "Observe", "System"] as const

function EndpointRow({ label, url }: { label: string; url: string }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      toast.error("Could not copy to clipboard")
    }
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
      <span className="relative grid size-3.5 shrink-0 place-items-center">
        <Check
          className={
            "col-start-1 row-start-1 size-3.5 text-success transition-[opacity,scale,filter] duration-300 ease-[cubic-bezier(0.2,0,0,1)] " +
            (copied ? "scale-100 opacity-100 blur-0" : "scale-[0.25] opacity-0 blur-[4px]")
          }
        />
        <Copy
          className={
            "col-start-1 row-start-1 size-3.5 text-muted-foreground/50 transition-[opacity,scale,filter] duration-300 ease-[cubic-bezier(0.2,0,0,1)] " +
            (copied
              ? "scale-[0.25] opacity-0 blur-[4px]"
              : "scale-100 opacity-0 blur-0 group-hover:opacity-100")
          }
        />
      </span>
    </button>
  )
}

function AppSidebar() {
  const nav = useNavigate()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const [dataBase, setDataBase] = useState("")

  useEffect(() => {
    // Resolution order: JANUS_PUBLIC_URL (from /overview) → same origin
    // (reverse proxy path-routes both planes) → console host on :8080
    // (bare-metal / local dev).
    const fallback = () => {
      const { protocol, hostname, port, origin } = window.location
      return port === "" || port === "80" || port === "443"
        ? origin
        : `${protocol}//${hostname}:8080`
    }
    api("/overview")
      .then((o) => setDataBase(o.public_url ?? fallback()))
      .catch(() => setDataBase(fallback()))
  }, [])

  const signOut = async () => {
    try {
      await api("/session", { method: "DELETE" })
    } catch {}
    clearToken()
    nav({ to: "/login" })
  }

  return (
    <Sidebar>
      <SidebarHeader className="border-b border-sidebar-border/70 px-4 py-4">
        <div className="flex items-center gap-3">
          <img
            src={`${import.meta.env.BASE_URL}icon.png`}
            alt="Janus"
            className="size-9 rounded-xl shadow-sm ring-1 ring-border"
          />
          <div className="flex flex-col gap-0.5">
            <span className="text-[15px] leading-none font-semibold tracking-[-0.02em]">Janus</span>
            <span className="text-[11px] tracking-wide text-muted-foreground uppercase">Gateway console</span>
          </div>
        </div>
      </SidebarHeader>
      <SidebarContent className="gap-1 py-2">
        {NAV_GROUPS.map((group) => (
          <SidebarGroup key={group} className="px-3 py-1">
            <SidebarGroupLabel className="h-7 px-2 text-[10px] font-semibold tracking-[0.12em] text-muted-foreground/80 uppercase">
              {group}
            </SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {NAV.filter((n) => n.group === group).map((n) => (
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
        ))}
      </SidebarContent>
      <SidebarFooter className="border-t border-sidebar-border/70 p-3">
        <Popover>
          <PopoverTrigger asChild>
            <Button variant="outline" size="sm" className="w-full justify-between">
              <span className="flex items-center gap-2">
                <Terminal />
                API endpoints
              </span>
              <ChevronDown />
            </Button>
          </PopoverTrigger>
          <PopoverContent
            side="top"
            align="start"
            className="w-[min(28rem,calc(100vw-2rem))] p-2"
          >
            <div className="px-2 pb-1 pt-1 text-[10px] font-semibold uppercase tracking-[0.12em] text-muted-foreground">
              Data plane
            </div>
            {dataBase ? (
              <>
                <EndpointRow label="OpenAI chat" url={`${dataBase}/v1/chat/completions`} />
                <EndpointRow label="OpenAI responses" url={`${dataBase}/v1/responses`} />
                <EndpointRow label="Anthropic messages" url={`${dataBase}/v1/messages`} />
                <EndpointRow label="OpenAI decisions" url={`${dataBase}/v1/decisions`} />
              </>
            ) : (
              <p className="px-2 py-3 text-xs text-muted-foreground">Resolving endpoints…</p>
            )}
          </PopoverContent>
        </Popover>
        <Button variant="ghost" size="sm" className="justify-start text-muted-foreground" style={{ justifyContent: "flex-start" }} onClick={signOut}>
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
  fill,
}: {
  children: ReactNode
  title: string
  description?: string
  actions?: ReactNode
  /** App-panel pages (e.g. Logs): the content column fills the viewport and
   *  never scrolls the page — the page's own inner pane owns scrolling
   *  (live tail / stick-to-bottom needs a stable scroller). */
  fill?: boolean
}) {
  return (
    <SidebarProvider>
      <AppSidebar />
      <SidebarInset>
        <header className="sticky top-0 z-20 flex min-h-16 flex-wrap items-center gap-x-3 gap-y-2 border-b border-border/80 bg-background/90 px-4 py-3 backdrop-blur-md md:px-7">
          <SidebarTrigger className="-ml-1" />
          <Separator orientation="vertical" className="hidden data-[orientation=vertical]:h-5 sm:block" />
          <div className="flex min-w-0 flex-1 flex-col gap-1.5">
            <h1 className="truncate text-xl leading-7 font-semibold tracking-[-0.025em] text-pretty">
              {title}
            </h1>
            {description && (
              <p
                className="hidden max-w-3xl text-[13px] leading-5 text-muted-foreground sm:block"
                title={description}
              >
                {description}
              </p>
            )}
          </div>
          <div className="flex items-center gap-2 [&>span]:hidden sm:[&>span]:inline-flex">{actions}</div>
          <ThemeToggle />
        </header>
        {/* Document pages: flex-none sizes to content (flex-1/flex-auto would
            let the fixed-height main flex column squash this box to the
            viewport, flushing every page's last cards past the bottom padding
            — flush-cut at the scroll end). Fill pages: the column fills the
            viewport and the page never scrolls, so its inner pane (live log
            tail) can own scrolling and stick to the bottom. */}
        <div
          className={
            "mx-auto flex w-full max-w-[88rem] min-w-0 flex-col gap-6 p-4 md:p-7 " +
            (fill ? "min-h-0 flex-1 pb-4 md:pb-6" : "flex-none pb-12 md:pb-16")
          }
        >
          {children}
        </div>
      </SidebarInset>
    </SidebarProvider>
  )
}

// ---------- bits ----------

export function Loading() {
  return (
    <div className="flex flex-col gap-3 px-5 py-4">
      <Skeleton className="h-4 w-36" />
      <Skeleton className="h-3.5 w-64 max-w-full" />
      <div className="mt-1 flex flex-col gap-2">
        <Skeleton className="h-8 w-full" />
        <Skeleton className="h-8 w-full" />
        <Skeleton className="h-8 w-2/3" />
      </div>
    </div>
  )
}

export function ErrorFlash({ message }: { message: string }) {
  return (
    <Alert tone="danger" title="Request failed">
      {message}
    </Alert>
  )
}

export function EmptyState({
  title,
  description,
  action,
  compact,
  className,
}: {
  title: string
  description?: string
  action?: ReactNode
  compact?: boolean
  className?: string
}) {
  return (
    <div
      className={cn(
        compact
          ? "flex flex-col items-center justify-center gap-1 px-4 py-8 text-center"
          : "flex flex-col items-center justify-center gap-1.5 px-6 py-14 text-center",
        className,
      )}
    >
      <p className="text-sm font-medium">{title}</p>
      {description && (
        <p className="max-w-sm text-sm leading-relaxed text-muted-foreground">{description}</p>
      )}
      {action ? <div className="mt-3">{action}</div> : null}
    </div>
  )
}
