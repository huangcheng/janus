from pathlib import Path

p = Path(r"F:\Janus\docs\superpowers\specs\2026-10-05-next-phase-design.md")
t = p.read_text(encoding="utf-8")
start = t.find("`sse_events/2` lexical rules")
end = t.find("#### 4.1.3")
assert start != -1 and end != -1, (start, end)
new = """Handler owns `#sse_st{}`. Drain: `sse_events` then fold `translate_sse/4`.
Drain EOF with `terminal_sent=false` calls `finalize_sse(..., normal, St)`.
`sse_events` leftover_cap (502) at 1 MiB Rest or single `data:` line.
Response `n>1` is mid-stream `invalid_request`. Request `n` not 1 is 400
before upstream. Provider-origin tools after 200 are **502** + gun cancel.
`include_usage` only if provider=`openai_chat` and client=`anthropic_messages`.
DB usage row is `capture_usage_chunk` only; `#sse_st{}` tokens synthesize
the client SSE usage chunk. janus-auto sets `janus_stats_counted` before
inner `do_proxy` so `inc_total` is once. Same-protocol stream is
byte-identical except optional `x-accel-buffering: no`. Other mismatched
pairs still 400 `stream_requires_native_protocol`.

"""
p.write_text(t[:start] + new + t[end:], encoding="utf-8")
print("spliced", start, end)
