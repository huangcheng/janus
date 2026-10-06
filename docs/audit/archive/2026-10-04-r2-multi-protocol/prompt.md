# Role
Audit the attached Janus multi-protocol gateway plan only. Do not write code. Do not call tools.

Janus = Erlang AI gateway (Cowboy HTTP, ETS catalog, LB, provider adapters via gun) that already serves OpenAI Chat Completions and plans to add OpenAI Responses + Anthropic Messages with same-protocol passthrough (incl. streaming) and non-stream cross-protocol translation (incl. basic tools).

# Required output format
1. Verdict: GO / GO WITH FIXES / NO-GO — one sentence
2. Critical risks (protocol mismatch, SSE/streaming, tool translation fidelity, auth header confusion, auto-router interaction, silent feature drops, cooldown/error contracts)
3. Contradictions or stale claims
4. Missing first-ship requirements
5. Architecture/design notes (proxy core, adapters, translate matrix, Cowboy/gun streaming)
6. Top 5 concrete edits

Under 450 words. Be skeptical and specific.
