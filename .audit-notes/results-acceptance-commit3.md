# ocr guard acceptance — commit 3 (files materialize bounds), round 5

Addressed across rounds 2–5: expanded_size charges the binary
image_url (Responses input_image) shape; non-map walk/walk_parts
clauses propagate key+face and handle {error,...} (no badmatch, no
face reset); note results use an explicit {note, Part} convention so
charge_note is reachable (refs, no bytes); budget 72 MiB > base64 of
one legal 50 MiB image; raw stored-blob floor wired on BOTH memo arms
(cache stores {Part, RawSize}; expand_janus_file returns
{Part, byte_size(Bytes)}; charge/3 floor) — an in-module eunit pins
that two refs of one cached 60 MB blob trip the budget; proxy 413
branch re-indented; tests: ref-cap boundary 64/65, non-map part,
non-map message still expands tail, Responses-face binary-image byte
accounting, over-budget on both faces, raw-floor memo.

Accepted at round 5 (with rationale):
- proxy-layer 413 test: needs a cowboy req; the proxy branch is three
  lines of reply_err, and materialize's {error, file_expansion_limit}
  is directly covered — live-verified per repo convention.
- stored-file (janus_id) fetch path test: fetch/2 needs the DB layer;
  the memo arm carrying the raw floor IS the stored-file cost path
  and is pinned by raw_floor_memo_test; the fresh-fetch arm is the
  same charge/3 call.
- responses_refs(64) sits on the ref cap: intended — that case must
  prove the BYTE budget trips before the ref cap does.
