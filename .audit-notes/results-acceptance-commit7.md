# ocr guard acceptance — commit 7 (fleet-specifics removal), round 8

Addressed across rounds 2–8 (all highs): quoted-heredoc worker
hostname placeholder (__WORKER_HOSTNAME__) sed-substituted remotely
AFTER the heredoc close with a both-directions grep verify;
comma-joined ALL_NODES replaced by an explicit DEPLOY_HOSTS array (SSH
aliases) for every dial loop and rollback artifact key; rollback
worker-branch compares SSH alias to SSH alias; co-located worker
identity (ROLE/NODE_NAME/MASTER_NODE) written INTO .env.worker by the
cookie writer (idempotent — existing keys stripped before rewrite;
cookie still stdin/fd3 only, node names via argv-safe positionals);
MW_* SSH aliases and worker long names fail closed (:? guards) with
dotted-host case guards; stale TENCENT/JDCLOUD IP vars removed;
pin_master_ip rewritten around a __MASTER_ORIGIN__ placeholder (no
hardcoded brand name, works against the quoted heredoc, verifies no
placeholder survives); git-ship gate detects per-node remotes via
node_git_remote_any() matching node_git_remote()'s actual resolution;
EXCLUDED_HOSTS required-with-default documented.

Accepted at round 8 (with rationale):
- recon-firewall.sh block remains aliyun-CLI-specific under a neutral
  header: the CLI is a public tool, and the operator's actual SG ids
  are env-driven (JANUS_FW_SG_ID/REGION) — the audit record itself
  classified provider NAMES as reconnaissance-low; a provider-pluggable
  firewall reconciler is new functionality beyond this fix.
- generic public endpoints (mirrors.aliyun.com, maas.aliyuncs.com
  suffix allowlist, dashscope tool URL) intentionally untouched: not
  operator identity.

## Round 16 addendum

Addressed: W_LEADER_WORKER_HOST assignment; split guard loops
(dotted+charset for Erlang names, charset-only for SSH aliases);
atomic .env.worker rewrite (tempfile 0600 + os.replace); sys/os
imports; stdin-header interpolation for all operator values into both
remote pythons; tempfile tail cleanup.

Accepted at round 16 (with rationale — converging validation-hardening
notes, no security/correctness defect demonstrated):
- SSH alias uniqueness: two identical aliases would at worst run a
  step twice on one host — deploy_prod.sh's topology/inventory layer
  (the single writer) already rejects duplicate aliases.
- "holes in the same block" / weaker-than-OTP validation: the values
  come from the operator's own env on the deploy host (trusted input);
  the charset guards are defense-in-depth against accidental shell
  breakage, not an untrusted-input boundary.
