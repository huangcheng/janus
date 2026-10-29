import { ComponentProps, ComponentType, CSSProperties } from "react"
import NumberFlow from "@number-flow/react"
import { cn } from "@/lib/utils"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"

/**
 * KPI stat card. Numeric values animate through NumberFlow on every update
 * (polls, reloads); string values render as-is. The subtitle slot is always
 * rendered so heights and value baselines stay aligned across a row.
 */
export function StatCard({
  label,
  value,
  icon: Icon,
  suffix,
  subtitle,
  format,
  className,
  style,
}: {
  label: string
  value: number | string
  icon: ComponentType<{ className?: string }>
  /** Appended to numeric values (e.g. " ms"); ignored for string values. */
  suffix?: string
  subtitle?: string
  format?: ComponentProps<typeof NumberFlow>["format"]
  className?: string
  style?: CSSProperties
}) {
  return (
    <Card className={cn("gap-2 overflow-hidden py-4", className)} style={style}>
      <div className="flex items-center justify-between gap-2 px-4">
        <span className="truncate text-[11px] font-medium tracking-wide text-muted-foreground uppercase">
          {label}
        </span>
        <span className="grid size-7 shrink-0 place-items-center rounded-lg bg-primary/8 text-primary">
          <Icon className="size-3.5" />
        </span>
      </div>
      <div
        className={cn(
          "truncate px-4 font-semibold tracking-[-0.035em] tabular-nums",
          // Long string values (e.g. "Postgres") would ellipsize at the
          // numeric size — step down a level and pin the line box so all
          // cards in a row keep equal heights.
          typeof value === "string" && value.length > 6
            ? "text-xl leading-8"
            : "text-[1.75rem] leading-8",
        )}
      >
        {typeof value === "number" ? (
          <NumberFlow value={value} locales="en-US" format={format} suffix={suffix} />
        ) : (
          value
        )}
      </div>
      <div className="truncate px-4 text-xs text-muted-foreground">{subtitle ?? " "}</div>
    </Card>
  )
}

/** Matches StatCard's exact layout so loading rows don't pop when data lands. */
export function StatCardSkeleton() {
  return (
    <Card className="gap-2 py-4">
      <div className="flex items-center justify-between gap-2 px-4">
        <Skeleton className="h-3.5 w-16" />
        <Skeleton className="size-7 rounded-lg" />
      </div>
      <div className="px-4">
        <Skeleton className="h-7 w-20" />
      </div>
      <div className="px-4">
        <Skeleton className="h-3.5 w-24" />
      </div>
    </Card>
  )
}
