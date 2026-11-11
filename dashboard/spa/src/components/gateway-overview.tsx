import { Bot, Server } from "lucide-react"
import { Skeleton } from "./ui/skeleton"

const OVERVIEW_SHELL_CLASS = "relative isolate grid grid-cols-1 gap-5 overflow-hidden rounded-3xl bg-sidebar p-5 text-sidebar-foreground shadow-[0_24px_60px_color-mix(in_oklch,var(--sidebar)_16%,transparent)] lg:grid-cols-[minmax(0,0.9fr)_minmax(390px,1.1fr)] lg:p-6"
const FIGURE_CLASS = "relative min-h-[280px] overflow-hidden rounded-2xl border border-sidebar-border bg-sidebar-accent/35"

type GatewayOverviewProps = {
  generation: number
  backend: string
  ready: boolean
  counts: {
    providers: number
    listings: number
    bindings: number
    agentKeys: number
  }
}

export function GatewayOverview({ generation, backend, ready, counts }: GatewayOverviewProps) {
  const stats = [
    { label: "Providers", value: counts.providers },
    { label: "Listings", value: counts.listings },
    { label: "Bindings", value: counts.bindings },
    { label: "Agent keys", value: counts.agentKeys },
  ]

  return (
    <section aria-label="Gateway overview" className={OVERVIEW_SHELL_CLASS}>
      <div className="pointer-events-none absolute inset-0 -z-10 opacity-35" aria-hidden>
        <div className="absolute top-0 bottom-0 left-[42%] w-px bg-sidebar-border/45" />
        <div className="absolute top-[38%] right-0 left-0 h-px bg-sidebar-border/35" />
      </div>

      <div className="flex flex-col px-1 py-3 sm:px-3 lg:py-4">
        <p className="mb-6 flex items-center gap-2 font-mono text-[9px] tracking-[0.13em] text-primary uppercase">
          <span className="size-1.5 bg-primary" aria-hidden />
          Gateway / control plane
        </p>
        <h2 className="max-w-[14ch] text-[clamp(2.1rem,3.2vw,2.75rem)] leading-[1.02] font-medium tracking-[-0.052em] text-balance">
          One front door.<br />Every protocol.
        </h2>
        <p className="mt-4 max-w-[43ch] text-[13px] leading-6 text-sidebar-foreground/75">
          OpenAI and Anthropic clients meet every configured upstream through one translating gateway.
        </p>

        <dl className="mt-9 grid grid-cols-2 gap-x-5 gap-y-6 border-t border-sidebar-border pt-6 sm:flex sm:flex-wrap sm:gap-x-8 lg:mt-auto">
          {stats.map((stat) => (
            <div key={stat.label} className="flex flex-col-reverse gap-1.5">
              <dt className="font-mono text-[10px] tracking-[0.07em] text-sidebar-foreground/65 uppercase">
                {stat.label}
              </dt>
              <dd className="font-mono text-[28px] leading-none font-normal tracking-[-0.06em] tabular-nums">
                {stat.value.toString().padStart(2, "0")}
              </dd>
            </div>
          ))}
        </dl>
      </div>

      <figure className={FIGURE_CLASS}>
        <div className="absolute top-4 right-4 font-mono text-[9px] tracking-[0.12em] text-sidebar-foreground/60 uppercase">
          Data plane / 01
        </div>
        <div className="absolute top-0 bottom-0 left-1/2 w-px bg-sidebar-foreground/5" aria-hidden />
        <div className="absolute top-1/2 right-0 left-0 h-px bg-sidebar-foreground/5" aria-hidden />
        <svg className="absolute inset-[15%_4%_18%] h-[67%] w-[92%]" viewBox="0 0 600 220" fill="none" aria-hidden>
          <path d="M92 110H278" stroke="var(--sidebar-primary)" strokeOpacity="0.55" strokeWidth="1.4" />
          <path d="M322 110H508" stroke="var(--sidebar-primary)" strokeOpacity="0.55" strokeWidth="1.4" />
          <circle cx="184" cy="110" r="3" fill="var(--sidebar-primary)" />
          <circle cx="416" cy="110" r="3" fill="var(--sidebar-primary)" />
        </svg>

        <div className="absolute top-1/2 left-[5%] flex w-[76px] -translate-y-1/2 flex-col items-center gap-2 text-center sm:left-[7%]">
          <span className="grid size-12 place-items-center rounded-xl border border-sidebar-border bg-sidebar text-primary shadow-sm">
            <Bot className="size-5" />
          </span>
          <div>
            <strong className="block text-[11px] font-semibold">Agents</strong>
            <span className="mt-1 block font-mono text-[9px] text-sidebar-foreground/60 uppercase">Any client</span>
          </div>
        </div>

        <div className="absolute top-1/2 left-1/2 flex -translate-x-1/2 -translate-y-1/2 flex-col items-center">
          <span className="relative grid size-[68px] place-items-center rounded-[20px] border border-primary/25 bg-sidebar shadow-[0_12px_30px_color-mix(in_oklch,var(--sidebar)_30%,transparent)]">
            <img src={`${import.meta.env.BASE_URL}icon.png`} alt="" width={54} height={54} className="size-[54px] rounded-[15px]" />
          </span>
          <strong className="mt-3 text-xs font-semibold">Janus</strong>
          <span className="mt-1 font-mono text-[9px] tracking-[0.08em] text-sidebar-foreground/60 uppercase">Translate</span>
        </div>

        <div className="absolute top-1/2 right-[5%] flex w-[76px] -translate-y-1/2 flex-col items-center gap-2 text-center sm:right-[7%]">
          <span className="grid size-12 place-items-center rounded-xl border border-sidebar-border bg-sidebar text-primary shadow-sm">
            <Server className="size-5" />
          </span>
          <div>
            <strong className="block text-[11px] font-semibold">Providers</strong>
            <span className="mt-1 block font-mono text-[9px] text-sidebar-foreground/60 uppercase">{counts.providers} configured</span>
          </div>
        </div>

        <figcaption className="absolute right-3 bottom-3 left-3 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 font-mono text-[10px] tracking-[0.04em] text-sidebar-foreground/70 uppercase">
          <span>{backend}</span>
          <span aria-hidden>·</span>
          <span>Generation {generation}</span>
          <span className="inline-flex items-center gap-1.5">
            <span className={`size-1.5 rounded-full ${ready ? "bg-sidebar-success" : "bg-sidebar-warning"}`} aria-hidden />
            {ready ? "Catalog ready" : "Catalog cold"}
          </span>
        </figcaption>
      </figure>
    </section>
  )
}

export function GatewayOverviewSkeleton() {
  return (
    <div role="status" aria-busy="true" aria-label="Loading gateway overview" className={`${OVERVIEW_SHELL_CLASS} min-h-[340px]`}>
      <div className="flex flex-col gap-5 px-1 py-3 sm:px-3">
        <Skeleton className="h-3 w-32 bg-sidebar-accent" />
        <Skeleton className="h-24 w-72 max-w-full bg-sidebar-accent" />
        <Skeleton className="h-4 w-56 max-w-full bg-sidebar-accent" />
        <div className="mt-auto grid grid-cols-2 gap-x-5 gap-y-6 border-t border-sidebar-border pt-6 sm:flex sm:flex-wrap sm:gap-x-8">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-12 w-14 bg-sidebar-accent" />
          ))}
        </div>
      </div>
      <Skeleton className={`${FIGURE_CLASS} border-0`} />
    </div>
  )
}
