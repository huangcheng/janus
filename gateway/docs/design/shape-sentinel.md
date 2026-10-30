# Shape sentinel (2026-10-28)

## Origin

A live debugging session (2026-10-28): an unknown client shape kept
tripping strict upstreams. Six candidate shapes were probed blind
before a one-off capture hook caught the real one — an orphan tool
result (an ID mismatch no position analysis could find; dashscope:
"The tool_call_id in the response message does not match the
tool_call_id in the tool_call"). This document generalizes that hook
into a platform mechanism: `janus_shape_capture`.

## Mechanism

When a SHAPE-CLASS failure fires, the gateway logs the structural
fingerprint of the offending request. The next occurrence of any
unknown shape self-documents; diagnosis becomes log-reading instead
of blind probing.

- **Trigger**: upstream 4xx with tool-adjacency or invalid-parameter
  semantics, and gateway `translate_unsupported` rejects. Business
  errors (auth, quota, routing) stay out — the sentinel diagnoses
  request SHAPES, not traffic.
- **Payload**: BOTH sides — the client shape (harness bugs read
  clearest there) and the provider-bound shape (translation bugs).
- **Storage**: the existing log ring (`logger:warning` → docker logs
  → the dashboard nodes poller drains into `gateway_log_events`).
  Queryable history that survives container rebuilds.

## Disciplines

1. **STRUCTURE ONLY, never content.** Roles, part types, opaque call
   ids — never prompts, tool arguments, or any user bytes. The hard
   privacy invariant.
2. **Dedup**: the same {class, shape hash} logs once per 10-minute
   window; a retry-looping bad harness must not flood the ring.
3. **Never in the request path**: every entry point is fail-safe; a
   sentinel crash is silently swallowed.
4. **The phrase table is the learning surface**: when a new failure
   class is diagnosed, add its trigger phrase in the same commit as
   the fix, with the live sentence in the commit message.

## Operating

Query captured shapes:

```sql
SELECT ts, fields->>'class' AS class, fields->'shape' AS shape
FROM gateway_log_events
WHERE fields->>'what' = 'janus_shape_sentinel'
ORDER BY id DESC LIMIT 20;
```
