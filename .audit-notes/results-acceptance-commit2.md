# ocr guard acceptance — commit 2 (quota charge nonce), round 4

Addressed across rounds 2–4: single mint_charge_id/0 helper for both
entry points (preamble read/2, modality run_enabled/3) with direct
eunit coverage of shape/storage/freshness; files face erases the
stale nonce on keep-alive reuse; mint also resets the per-request
charge latch (full state reset in one place); contract renamed
ChargeId end-to-end with narrowed spec binary() and module doc
updated; charge test made hermetic (deletes its rows from the shared
named tables).

Accepted at round 4 (with rationale):
- entry-point wiring test (preamble/modality store the nonce, charge
  sites read it): eunit cannot construct cowboy req objects; the
  mint helper + charge site are each covered, and runtime behavior
  is live-verified per repo convention (AGENTS.md Verification).
- the two "tests call charge_nonce directly" comments reduce to the
  same wiring-test point above.
