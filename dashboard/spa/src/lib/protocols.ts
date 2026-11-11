export type JanusProtocol =
  | "openai_chat"
  | "anthropic_messages"
  | "openai_responses"
  | "openai_decisions"

export const PROTOCOL_LABELS: Record<string, string> = {
  openai_chat: "OpenAI Chat",
  openai_responses: "OpenAI Responses",
  anthropic_messages: "Anthropic Messages",
  openai_decisions: "OpenAI Decisions",
}

export function protocolLabel(protocol: string): string {
  return PROTOCOL_LABELS[protocol] ?? protocol
}
