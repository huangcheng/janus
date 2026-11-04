import { useEffect, useId, useRef, useState, type ReactNode } from "react"
import { ChevronDown } from "lucide-react"
import { cn } from "@/lib/utils"

const DETAILS_SCROLL_CLASS =
  "mt-1 max-h-64 overflow-auto rounded-md font-mono text-xs leading-5 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60"

export function ExpandableText({
  text,
  summary,
  className,
  children,
}: {
  text: string
  summary?: ReactNode
  className?: string
  /** Structured children provide their own padding and layout. */
  children?: ReactNode
}) {
  const summaryId = useId()
  const contentRef = useRef<HTMLDivElement>(null)
  const [scrollable, setScrollable] = useState(false)
  const hasStructuredContent = children !== undefined && children !== null && children !== false

  useEffect(() => {
    const element = contentRef.current
    if (!element) return
    const updateScrollable = () => setScrollable(element.scrollHeight > element.clientHeight)
    updateScrollable()
    const observer = new ResizeObserver(updateScrollable)
    observer.observe(element)
    return () => observer.disconnect()
  }, [hasStructuredContent, text])

  return (
    <details className={cn("group min-w-0", className)}>
      <summary className="flex min-h-8 cursor-pointer list-none items-center gap-2 rounded-md px-1 text-xs text-muted-foreground marker:hidden focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60">
        <span
          id={summaryId}
          className="min-w-0 flex-1 truncate"
          title={typeof summary === "string" ? summary : text}
        >
          {summary ?? text}
        </span>
        <span
          aria-hidden="true"
          className="shrink-0 transition-colors group-hover:text-foreground max-sm:sr-only"
        >
          <span className="group-open:hidden">Expand</span>
          <span className="hidden group-open:inline">Collapse</span>
        </span>
        <ChevronDown className="size-3.5 shrink-0 transition-transform group-open:rotate-180" />
      </summary>
      <div
        ref={contentRef}
        tabIndex={scrollable ? 0 : undefined}
        role={scrollable ? "region" : undefined}
        aria-labelledby={summaryId}
        className={cn(
          DETAILS_SCROLL_CLASS,
          hasStructuredContent
            ? "border border-border/60 bg-muted/25"
            : "bg-muted/45 p-3 text-foreground",
        )}
      >
        {hasStructuredContent ? (
          children
        ) : (
          <pre className="m-0 whitespace-pre-wrap break-words [overflow-wrap:anywhere]">{text}</pre>
        )}
      </div>
    </details>
  )
}
