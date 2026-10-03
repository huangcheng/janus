import { useCallback, useEffect, useRef, useState } from "react"
import { Pause, Play, RefreshCw } from "lucide-react"
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

const LEVEL_COLOR: Record<string, string> = {
  error: "text-red-500",
  warn: "text-amber-500",
  info: "text-muted-foreground",
  notice: "text-blue-400",
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
          <CardDescription>last {events.length} lines · ring buffer (2000, in-memory)</CardDescription>
          <CardAction className="flex items-center gap-3">
            <Button
              variant={live ? "default" : "outline"}
              size="sm"
              onClick={() => setLive(!live)}
            >
              {live ? <Pause /> : <Play />}
              {live ? "Live" : "Paused"}
            </Button>
            <Button
              variant={autoScroll ? "default" : "outline"}
              size="sm"
              onClick={() => setAutoScroll(!autoScroll)}
            >
              Follow
            </Button>
            <Select value={level} onValueChange={setLevel}>
              <SelectTrigger className="w-28">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="info">All</SelectItem>
                <SelectItem value="warn">Warn+</SelectItem>
                <SelectItem value="error">Error</SelectItem>
              </SelectContent>
            </Select>
            <Button variant="outline" size="sm" onClick={load}>
              <RefreshCw />
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent>
          <div className="max-h-[70vh] overflow-y-auto rounded-md border bg-muted/30 p-3 font-mono text-xs leading-relaxed">
            {events.length === 0 && (
              <p className="py-8 text-center text-muted-foreground">No log lines yet.</p>
            )}
            {events.map((e) => (
              <div key={e.idx} className="flex gap-2 whitespace-pre-wrap break-all">
                <span className="shrink-0 text-muted-foreground/60">
                  {e.ts?.slice(11, 23)}
                </span>
                <span className={`shrink-0 font-semibold ${LEVEL_COLOR[e.level] ?? ""}`}>
                  {e.level?.padEnd(5)}
                </span>
                <span className="text-foreground/90">{formatFields(e.fields)}</span>
              </div>
            ))}
            <div ref={bottomRef} />
          </div>
          <div className="mt-2 flex items-center gap-2 text-xs text-muted-foreground">
            {live ? <Play className="h-3 w-3" /> : <Pause className="h-3 w-3" />}
            {live ? "polling every 2s" : "paused"}
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
