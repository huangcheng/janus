import { Badge } from "@/components/ui/badge"

export type Provider = { id: number; name: string; base_url: string; protocol: string; enabled: boolean; keys: KeyMeta[] }
export type KeyMeta = { id: number; key_id: string; weight: number; enabled: boolean }
export type Model = { id: number; name: string; enabled: boolean; routes: Route[] }
export type Route = { model_id: number; provider_id: number; provider_name: string | null; upstream_model_id: string | null; weight: number; priority: number; enabled: boolean }
export type AgentKey = { id: number; prefix: string; enabled: boolean; created_at: string; model_ids: number[]; model_names: (string | null)[] }
export type AuditEvent = { ts: string; actor: string; action: string; target: string | null; detail: string | null }

export function StateBadge({ enabled }: { enabled: boolean }) {
  return <Badge variant={enabled ? "default" : "secondary"}>{enabled ? "enabled" : "disabled"}</Badge>
}

export function ActionBadge({ action }: { action: string }) {
  const verb = action.split(".").pop() ?? ""
  const variant = /delete|revoke|disable/.test(verb)
    ? "destructive"
    : /add|create|enable/.test(verb)
      ? "default"
      : "secondary"
  return <Badge variant={variant}>{action}</Badge>
}
