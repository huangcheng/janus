# ocr guard acceptance — commit 4 (worker-relay terminal-abort cleanup), round 5

Addressed across rounds 2–5: generic Class:Reason:Stacktrace clause
funnels translate CRASHES through the shared terminal_chunkfun_cleanup
and re-raises with erlang:raise preserving class+stacktrace; neutral
stream_relay_crash label (passthrough streams land in the generic
clause; translate_* reserved for real translation throws) persisted in
janus_usage:outcome_bin alongside translate_abort; the
janus_client_disconnect branches (stream_forward_plain AND
emit_keepalive) now route through the shared helper, adding the
reservation release a dead-client socket previously lacked; duplicate
helper and stale doc removed; trailing newline restored; eunit covers
translate throw, sibling disconnect, and error-class crash — each
sends janus_cancel before escaping.

Accepted at round 5 (with rationale):
- passthrough-leg re-raise finalization (handle_upstream's
  non-translate clause has no Class:Reason catch-all of its own): the
  pre-fix behavior for a crash there was identical — the exception
  escaped with NO cleanup at all; this fix strictly adds the cleanup
  before the same escape. Wiring a full proxy-side catch for
  passthrough legs is follow-up hardening beyond the audit finding,
  and the crash path now at least releases the slot.
- assert-beyond-janus_cancel (reservation release): sched_release
  needs the live janus_worker_pool gen_server; the release CALL is
  exercised via the helper on all three test paths, and its
  idempotency is covered by existing pool behavior — live-verified
  per repo convention.
