import { ReactNode } from "react"
import { ArrowLeftRight } from "lucide-react"
import { BrandMark, ThemeToggle } from "../components"
import { protocolLabel, type JanusProtocol } from "@/lib/protocols"

const FEATURED_PROTOCOLS = (["openai_chat", "openai_responses", "anthropic_messages"] as const satisfies readonly JanusProtocol[]).map(
  (protocol) => ({ id: protocol, label: protocolLabel(protocol) }),
)

export function AuthShell({ children, footer, title }: { children: ReactNode; footer?: ReactNode; title: string }) {
  return (
    <div className="grid min-h-svh bg-background lg:grid-cols-[minmax(380px,0.9fr)_minmax(0,1.1fr)]">
      <section
        data-slot="auth-brand-panel"
        aria-label="Janus gateway"
        className="relative flex flex-col overflow-hidden border-b border-sidebar-border bg-sidebar px-6 py-7 text-sidebar-foreground sm:px-10 lg:min-h-svh lg:border-r lg:border-b-0 lg:px-12 lg:py-10"
      >
        <div className="pointer-events-none absolute inset-0 opacity-40" aria-hidden>
          <div className="absolute top-0 bottom-0 left-[72%] w-px bg-sidebar-border/50" />
          <div className="absolute right-0 bottom-[28%] left-0 h-px bg-sidebar-border/50" />
        </div>
        <a href={import.meta.env.BASE_URL} className="relative z-10 w-fit font-medium">
          <BrandMark subtitle="LLM gateway console" />
        </a>

        <div className="relative z-10 my-auto hidden py-8 lg:block lg:py-16" aria-hidden>
          <p className="mb-5 flex items-center gap-2.5 font-mono text-[9px] tracking-[0.14em] text-primary uppercase">
            <ArrowLeftRight className="size-3.5" />
            Protocol translation plane
          </p>
          <p className="text-[clamp(2.75rem,5vw,4.5rem)] leading-[0.98] font-medium tracking-[-0.062em]">
            Every model.<br />One front door.
          </p>
          <p className="mt-6 max-w-[38ch] text-[13px] leading-6 text-sidebar-foreground/70">
            Connect OpenAI and Anthropic clients through one dependable gateway. Configuration stays hot, explicit, and under your control.
          </p>
          <ol className="mt-9 hidden max-w-md flex-col border-t border-sidebar-border lg:flex">
            {FEATURED_PROTOCOLS.map(({ id, label }, index) => (
              <li key={id} className="flex items-center gap-4 border-b border-sidebar-border py-3 font-mono text-[10px] tracking-[0.04em] text-sidebar-foreground/75">
                <span className="text-primary">0{index + 1}</span>
                {label}
              </li>
            ))}
          </ol>
        </div>

        <p className="relative z-10 hidden font-mono text-[10px] tracking-[0.12em] text-sidebar-foreground/70 uppercase lg:block">
          Standard protocols · hot configuration · explicit state
        </p>
      </section>

      <main className="relative flex flex-col items-center justify-center px-5 py-10 sm:px-8 lg:min-h-svh lg:px-12 lg:py-14">
        <h1 className="sr-only">{title}</h1>
        <div className="w-full max-w-sm">{children}</div>
        <div className="mt-7 flex max-w-sm items-center justify-center gap-2 text-center text-xs leading-5 text-muted-foreground">
          {footer}
          <ThemeToggle />
        </div>
      </main>
    </div>
  )
}
