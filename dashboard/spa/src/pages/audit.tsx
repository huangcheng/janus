import { useEffect, useState } from "react"
import { api } from "../api"
import { EmptyState, ErrorFlash, Layout, Loading } from "../components"
import { ExpandableText } from "../components/expandable-text"
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
import { ActionBadge, AuditEvent, EventTime } from "./shared"
import { Pagination, useClientPagination } from "../components/pagination"

function auditDetailSummary(detail: string): string {
  try {
    const parsed = JSON.parse(detail) as unknown
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return Object.entries(parsed as Record<string, unknown>)
        .slice(0, 3)
        .map(([key, value]) => `${key}=${typeof value === "string" ? value : JSON.stringify(value)}`)
        .join(" · ")
    }
  } catch {
    return detail
  }
  return detail
}

export function Audit() {
  const [events, setEvents] = useState<AuditEvent[]>([])
  const [error, setError] = useState("")
  const [loaded, setLoaded] = useState(false)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(20)

  useEffect(() => {
    api("/audit?limit=1000")
      .then((r) => {
        setEvents(r.events)
        setLoaded(true)
      })
      .catch((e) => setError(e.message))
  }, [])

  const { slice: pagedEvents, pageCount, page: safePage, total } = useClientPagination(
    events,
    pageSize,
    page,
  )

  return (
    <Layout
      title="Audit log"
      description="Dashboard mutations, newest first. Up to 1000 events, persisted across restarts."
    >
      {error && <ErrorFlash message={error} />}
      <Card className="flex h-fit max-h-full w-full flex-col self-start overflow-hidden">
        <CardHeader className="border-b">
          <CardTitle>Events</CardTitle>
          <CardDescription>
            {loaded ? total.toLocaleString() : "—"} events fetched
          </CardDescription>
        </CardHeader>
        <CardContent className="min-h-0 px-0">
          {!loaded && !error ? (
            <Loading />
          ) : !loaded ? (
            <EmptyState
              title="Audit events unavailable"
              description="Could not read /api/audit — this is not an empty log."
            />
          ) : loaded && events.length === 0 ? (
            <EmptyState
              title="No events yet"
              description="Dashboard mutations will show up here as you change config."
            />
          ) : (
            <Table flush className="table-fixed">
              <TableHeader>
                <TableRow>
                  <TableHead className="w-[136px] sm:w-[144px]">Time</TableHead>
                  <TableHead className="hidden md:table-cell">Actor</TableHead>
                  <TableHead className="w-[108px] sm:w-[132px]">Action</TableHead>
                  <TableHead className="hidden md:table-cell">Target</TableHead>
                  <TableHead>Detail</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {pagedEvents.map((a) => (
                  <TableRow key={`${a.ts}|${a.action}|${a.target ?? ""}`}>
                    <TableCell className="font-mono text-xs whitespace-nowrap tabular-nums">
                      <EventTime ts={a.ts} />
                      <span className="mt-1 line-clamp-2 whitespace-normal text-muted-foreground md:hidden" title={`${a.actor}${a.target ? ` · ${a.target}` : ""}`}>
                        <span className="sr-only">Actor: </span>
                        {a.actor}
                        {a.target ? (
                          <>
                            {" · "}
                            <span className="sr-only">Target: </span>
                            {a.target}
                          </>
                        ) : null}
                      </span>
                    </TableCell>
                    <TableCell className="hidden font-mono text-xs text-muted-foreground md:table-cell">
                      {a.actor}
                    </TableCell>
                    <TableCell>
                      <ActionBadge action={a.action} />
                    </TableCell>
                    <TableCell className="hidden font-mono text-xs text-muted-foreground md:table-cell">
                      <span className="block max-w-[240px] truncate" title={a.target ?? undefined}>
                        {a.target ?? "—"}
                      </span>
                    </TableCell>
                    <TableCell className="whitespace-normal text-muted-foreground">
                      {a.detail ? (
                        <ExpandableText text={a.detail} summary={auditDetailSummary(a.detail)} className="w-full" />
                      ) : (
                        "—"
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {loaded && (
            <div className="px-5">
              <Pagination
                page={safePage}
                pageCount={pageCount}
                total={total}
                pageSize={pageSize}
                onPageChange={setPage}
                onPageSizeChange={(n) => {
                  setPageSize(n)
                  setPage(1)
                }}
              />
            </div>
          )}
        </CardContent>
      </Card>
    </Layout>
  )
}
