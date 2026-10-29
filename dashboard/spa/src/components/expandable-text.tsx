import { ChevronDown } from "lucide-react"
import { cn } from "@/lib/utils"

export function ExpandableText({
  text,
  summary,
  className,
}: {
  text: string
  summary?: string
  className?: string
}) {
  return (
    <details className={cn("group min-w-0", className)}>
      <summary className="flex min-h-8 cursor-pointer list-none items-center gap-2 rounded-md px-1 text-xs text-muted-foreground marker:hidden focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/60">
        <span className="min-w-0 flex-1 truncate" title={summary ?? text}>
          {summary ?? text}
        </span>
        <span className="shrink-0 text-primary">Details</span>
        <ChevronDown className="size-3.5 shrink-0 transition-transform group-open:rotate-180" />
      </summary>
      <pre className="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted/45 p-3 font-mono text-xs leading-5 text-foreground [overflow-wrap:anywhere]">
        {text}
      </pre>
    </details>
  )
}
