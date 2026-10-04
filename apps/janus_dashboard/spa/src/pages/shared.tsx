import { Badge } from "@/components/ui/badge"

export type KeyMeta = { id: number; key_id: string; weight: number; enabled: boolean }
export type ProviderModel = { id: number; provider_id: number; name: string; enabled: boolean }
export type Provider = {
  id: number
  name: string
  base_url: string
  protocol: string
  enabled: boolean
  keys: KeyMeta[]
  models?: ProviderModel[]
}
export type Model = { id: number; name: string; enabled: boolean; routes: Route[] }
export type Route = { model_id: number; provider_id: number; provider_name: string | null; upstream_model_id: string | null; weight: number; priority: number; enabled: boolean }
export type AgentKey = {
  id: number
  prefix: string
  enabled: boolean
  created_at: string
  /** `"all"` = unrestricted; otherwise explicit model id grants */
  model_ids: number[] | "all"
  model_names: (string | null)[]
}
export type AuditEvent = { ts: string; actor: string; action: string; target: string | null; detail: string | null }

export function StateBadge({ enabled }: { enabled: boolean }) {
  return (
    <Badge variant={enabled ? "success" : "secondary"}>
      <span
        className={
          "size-1.5 rounded-full " + (enabled ? "bg-success" : "bg-muted-foreground/50")
        }
      />
      {enabled ? "enabled" : "disabled"}
    </Badge>
  )
}

/** Unique providers from a model's routes, for the models table. */
export function ProviderBadges({ routes }: { routes: Route[] }) {
  const byId = new Map<number, { name: string; enabled: boolean }>()
  for (const r of routes) {
    const name = r.provider_name ?? String(r.provider_id)
    const prev = byId.get(r.provider_id)
    byId.set(r.provider_id, {
      name,
      enabled: (prev?.enabled ?? false) || r.enabled,
    })
  }
  const providers = [...byId.entries()]
  if (providers.length === 0) {
    return <span className="text-muted-foreground">—</span>
  }
  return (
    <div className="flex flex-wrap gap-1">
      {providers.map(([id, p]) => (
        <Badge key={id} variant={p.enabled ? "outline" : "secondary"} className="font-mono">
          {p.name}
        </Badge>
      ))}
    </div>
  )
}

export function ActionBadge({ action }: { action: string }) {
  const verb = action.split(".").pop() ?? ""
  const variant = /delete|revoke|disable/.test(verb)
    ? "destructive"
    : /add|create|enable/.test(verb)
      ? "default"
      : "secondary"
  return (
    <Badge variant={variant} className="font-mono text-[11px]">
      {action}
    </Badge>
  )
}
