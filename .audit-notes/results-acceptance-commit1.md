# ocr guard acceptance — commit 1 (echo prune fix), round 11

Addressed across rounds 2–10: deprecated ets:test_ms -> match_spec_test
with fallback; cap derived from bucket_cap/0; hand-copied spec removed
(test drives production prune_stale/0); -spec added; per-insert
O(n log n) sweep -> hysteresis (cap+128/cap-64); snapshot-derived
eviction count with max(0,..) guard against negative sublist; single-
flight marker; killed-sweeper marker leak -> TTL reclaim via exact
delete_object; binary-key-only stale/eviction passes; cleanup
asymmetry -> winner deletes its own exact marker; exception detail in
the catch-all warning; multi-wave + concurrent-wave + marker-state
coverage; TTL settle before the self-heal assertion.

Accepted at round 11 (design-level, not defects):
- barrier counts DOWN as completion: intended — a dead worker's
  allows are finished for test purposes; timeout still fails loudly.
- intermediate bound Cap-256+Wave is a sanity bound; the real guard is
  the post-settle assert (=< Cap+128) after TTL reclaim.
- prune_once runs after bucket_step: by design — admission uses the
  pre-insert state; the sweep is bookkeeping, never admission input.
