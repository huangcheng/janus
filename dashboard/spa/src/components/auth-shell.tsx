import { ReactNode } from "react"
import { ThemeToggle } from "../components"

export function AuthShell({ children, footer }: { children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted/35 p-6 md:p-10">
      <div className="flex w-full max-w-sm flex-col gap-6">
        <a href="/" className="flex items-center justify-center gap-3 font-medium">
          <img
            src={`${import.meta.env.BASE_URL}icon.png`}
            alt="Janus"
            className="size-10 rounded-xl shadow-sm ring-1 ring-border"
          />
          <span className="text-lg font-semibold tracking-[-0.02em]">Janus</span>
        </a>
        {children}
        <div className="flex items-center justify-center gap-2 text-center text-xs leading-5 text-muted-foreground">
          {footer}
          <ThemeToggle />
        </div>
      </div>
    </div>
  )
}
