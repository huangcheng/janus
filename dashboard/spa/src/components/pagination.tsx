import { ChevronLeftIcon, ChevronRightIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { cn } from "@/lib/utils"

/** Shared pagination control. Sliding five-page window with prev/next
 * arrows; optional rows-per-page select. Works for server-side
 * (page + total from the API) and client-side tables. */
function pageWindow(page: number, pageCount: number): (number | "gap")[] {
  if (pageCount <= 7) return Array.from({ length: pageCount }, (_, i) => i + 1)
  const out: (number | "gap")[] = [1]
  const from = Math.max(2, page - 1)
  const to = Math.min(pageCount - 1, page + 1)
  if (from > 2) out.push("gap")
  for (let p = from; p <= to; p++) out.push(p)
  if (to < pageCount - 1) out.push("gap")
  out.push(pageCount)
  return out
}

export function Pagination({
  page,
  pageCount,
  total,
  pageSize,
  onPageChange,
  onPageSizeChange,
}: {
  page: number // 1-based
  pageCount: number
  total: number
  pageSize?: number
  onPageChange: (p: number) => void
  onPageSizeChange?: (n: number) => void
}) {
  if (pageCount <= 1 && !onPageSizeChange) return null
  return (
    <div className="flex flex-wrap items-center gap-3 px-3 pt-2 pb-1 text-xs text-muted-foreground">
      <span className="tabular-nums">
        {total.toLocaleString()} row{total === 1 ? "" : "s"}
        {pageCount > 1 && (
          <>
            {" · page "}
            <span className="font-medium text-foreground tabular-nums">{page}</span>
            /{pageCount}
          </>
        )}
      </span>
      <div className="flex-1" />
      {onPageSizeChange && (
        <Select
          value={String(pageSize ?? 20)}
          onValueChange={(v) => onPageSizeChange(Number(v))}
        >
          <SelectTrigger size="sm" aria-label="Rows per page" className="h-7 w-[108px] text-xs">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {[20, 50, 100, 200].map((n) => (
              <SelectItem key={n} value={String(n)}>
                {n} / page
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}
      {pageCount > 1 && (
        <div className="flex items-center gap-1">
          <Button
            variant="outline"
            size="icon-xs"
            aria-label="Previous page"
            disabled={page <= 1}
            onClick={() => onPageChange(page - 1)}
          >
            <ChevronLeftIcon />
          </Button>
          {pageWindow(page, pageCount).map((p, i) =>
            p === "gap" ? (
              <span key={`gap-${i}`} className="px-1 text-muted-foreground">
                …
              </span>
            ) : (
              <Button
                key={p}
                variant={p === page ? "default" : "ghost"}
                size="icon-xs"
                aria-current={p === page ? "page" : undefined}
                onClick={() => onPageChange(p)}
                className={cn("tabular-nums", p === page ? "pointer-events-none" : undefined)}
              >
                {p}
              </Button>
            )
          )}
          <Button
            variant="outline"
            size="icon-xs"
            aria-label="Next page"
            disabled={page >= pageCount}
            onClick={() => onPageChange(page + 1)}
          >
            <ChevronRightIcon />
          </Button>
        </div>
      )}
    </div>
  )
}

/** Client-side pagination hook: slice an array for the current page and
 * expose the control values. Filter changes should reset the page. */
export function useClientPagination<T>(items: T[], pageSize: number, page: number) {
  const pageCount = Math.max(1, Math.ceil(items.length / pageSize))
  const safePage = Math.min(page, pageCount)
  const slice = items.slice((safePage - 1) * pageSize, safePage * pageSize)
  return { slice, pageCount, page: safePage, total: items.length }
}
