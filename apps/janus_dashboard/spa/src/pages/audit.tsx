import { useEffect, useState } from "react"
import { api } from "../api"
import { ErrorFlash, Layout, Loading } from "../components"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { ActionBadge, AuditEvent } from "./shared"

export function Audit() {
  const [events, setEvents] = useState<AuditEvent[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    api("/audit?limit=200")
      .then((r) => {
        setEvents(r.events)
        setLoaded(true)
      })
      .catch((e) => setError(e.message))
  }, [])

  return (
    <Layout
      title="Audit log"
      description="Every dashboard mutation, newest first. Ring buffer — last 1000 events, in-memory."
    >
      {error && <ErrorFlash message={error} />}
      <Card>
        <CardHeader>
          <CardTitle>Events</CardTitle>
          <CardDescription>in-memory; resets on restart</CardDescription>
        </CardHeader>
        <CardContent>
          {!loaded && !error ? (
            <Loading />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Time</TableHead>
                  <TableHead>Actor</TableHead>
                  <TableHead>Action</TableHead>
                  <TableHead>Target</TableHead>
                  <TableHead>Detail</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {events.map((a, i) => (
                  <TableRow key={i}>
                    <TableCell className="font-mono text-xs whitespace-nowrap tabular-nums">
                      <div className="flex flex-col">
                        <span>{a.ts.slice(0, 10)}</span>
                        <span className="text-muted-foreground/70">{a.ts.slice(11, 19)}</span>
                      </div>
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {a.actor}
                    </TableCell>
                    <TableCell>
                      <ActionBadge action={a.action} />
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      {a.target ?? "—"}
                    </TableCell>
                    <TableCell className="whitespace-normal text-muted-foreground">
                      <div className="max-w-[360px]">{a.detail ?? "—"}</div>
                    </TableCell>
                  </TableRow>
                ))}
                {loaded && events.length === 0 && (
                  <TableRow>
                    <TableCell colSpan={5} className="h-24 text-center text-muted-foreground">
                      No events yet.
                    </TableCell>
                  </TableRow>
                )}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </Layout>
  )
}
