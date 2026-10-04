import { useCallback, useEffect, useRef, useState } from "react"
import { ArrowDownToLine, Pause, Play, RefreshCw } from "lucide-react"
import { api } from "../api"
import { ErrorFlash, Layout } from "../components"
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
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"

type LogEvent = {
  idx: number
  ts: string
  level: string
  fields: Record<string, any>
}

const LEVEL_STYLE: Record<string, string> = {
  error: "text-red-400",
  warn: "text-amber-400",
  info: "text-zinc-400",
  notice: "text-sky-400",
}

export function Logs() {
  const [events, setEvents] = useState<LogEvent[]>([])
  const [error, setError] = useState("")
  const [level, setLevel] = useState("info")
  const [live, setLive] = useState(true)
  const [autoScroll, setAutoScroll] = useState(true)
  const bottomRef = useRef<HTMLDivElement>(null)
  const liveRef = useRef(live)
  liveRef.current = live

  const load = useCallback(async () => {
    try {
      const r = await api(`/logs?limit=300&level=${level === "info" ? "" : level}`)
      setEvents(r.events)
      setError("")
    } catch (e: any) {
      setError(e.message)
    }
  }, [level])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    if (!live) return
    const t = setInterval(() => {
      if (liveRef.current) load()
    }, 2000)
    return () => clearInterval(t)
  }, [live])

  useEffect(() => {
    if (autoScroll && bottomRef.current) {
      bottomRef.current.scrollIntoView({ behavior: "smooth" })
    }
  }, [events])

  return (
    <Layout
      title="Logs"
      description="Gateway log stream — provider failures, model sync, catalog reloads, and more."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Event stream</CardTitle>
          <CardDescription>
            last {events.length} lines · ring buffer (2000, in-memory)
          </CardDescription>
          <CardAction className="flex items-center gap-2">
            <Button
              variant={live ? "default" : "outline"}
              size="sm"
              onClick={() => setLive(!live)}
            >
              {live ? (
                <span className="relative flex size-2">
                  <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-current opacity-60" />
                  <span className="relative inline-flex size-2 rounded-full bg-current" />
                </span>
              ) : (
                <Play />
              )}
              {live ? "Live" : "Paused"}
            </Button>
            <Button
              variant={autoScroll ? "secondary" : "outline"}
              size="sm"
              onClick={() => setAutoScroll(!autoScroll)}
            >
              <ArrowDownToLine />
              Follow
            </Button>
            <Select value={level} onValueChange={setLevel}>
              <SelectTrigger className="w-28" size="sm">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="info">All</SelectItem>
                <SelectItem value="warn">Warn+</SelectItem>
                <SelectItem value="error">Error</SelectItem>
              </SelectContent>
            </Select>
            <Button variant="outline" size="sm" onClick={load} aria-label="Refresh logs">
              <RefreshCw />
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent>
          <div className="max-h-[70vh] overflow-y-auto rounded-lg bg-zinc-950 p-3 font-mono text-xs leading-relaxed ring-1 ring-zinc-800 scrollbar-thin">
            {events.length === 0 && (
              <p className="py-8 text-center text-zinc-500">No log lines yet.</p>
            )}
            {events.map((e) => (
              <div key={e.idx} className="flex gap-3 whitespace-pre-wrap break-all">
                <span className="shrink-0 text-zinc-500 tabular-nums">
                  {e.ts?.slice(11, 23)}
                </span>
                <span
                  className={`inline-flex w-16 shrink-0 items-center gap-1.5 font-medium ${LEVEL_STYLE[e.level] ?? "text-zinc-400"}`}
                >
                  <span className="size-1.5 shrink-0 rounded-full bg-current" />
                  {e.level}
                </span>
                <span className="text-zinc-300">{formatFields(e.fields)}</span>
              </div>
            ))}
            <div ref={bottomRef} />
          </div>
          <div className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
            {live ? (
              <>
                <span className="relative flex size-1.5">
                  <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-60" />
                  <span className="relative inline-flex size-1.5 rounded-full bg-success" />
                </span>
                polling every 2s
              </>
            ) : (
              <>
                <Pause className="size-3" />
                paused
              </>
            )}
          </div>
        </CardContent>
      </Card>
    </Layout>
  )
}

function formatFields(fields: Record<string, any>): string {
  const parts = Object.entries(fields)
    .filter(([k]) => k !== "idx")
    .map(([k, v]) => {
      const vs = typeof v === "string" ? v : JSON.stringify(v)
      return `${k}=${vs}`
    })
  return parts.join(" ")
}
