#!/usr/bin/env bash
# janus_deploy_lock.sh — the REPLICATED Postgres row CAS lock shared by
# deploys and promotes.
# Spec: docs/superpowers/specs/2026-10-15-maturity-hardening.md
#       H4-D1 / F4.1 (concurrent deploy guard) + H3-D3 (lock contract the
#       promote script will consume).
#
# Why a TABLE ROW and not a session advisory lock (H3-D3, r5): session
# locks die when the promote fence severs the connection — exactly
# mid-promote; a deploy_locks ROW lives in the LEADER's Postgres,
# replicates with the streaming stream, and survives failover. The H3
# promote script takes THIS lock first and re-acquires the row on the
# promoted DB after pg_promote().
#
# Table (single row, id=1 CHECK singleton):
#   deploy_locks (id, holder, acquired_at, expires_at)
# Created on first acquire (CREATE TABLE IF NOT EXISTS — same ops-table
# precedent as backup_canaries; NOT a schema migration).
#
# Holders: deploy:<host> / promote:<host> (H3-D3). TTL must cover the
# whole critical section — deploys use 4h (local gate ~90-120 min +
# image builds + rolling ship + follower waits) and RENEW at every phase
# boundary (deploy_lock_renew), so expiry is the crash backstop, not a
# wall-clock bet; the EXIT-trap release is the normal path.
#
# All DB access goes through topology_psql() from janus_topology.sh:
# JANUS_DEPLOY_PG overrides the psql target (local proofs point it at
# the e2e janus-pg container); production goes over SSH to the topology
# leader's postgres container.
#
# Functions (rc): acquire 0=acquired 4=held-by-other 1=error;
# release/renew/force_release/status 0 (idempotent where sensible) —
# release and renew return 1 when the leader Postgres is unreachable
# (release) or when the row is no longer ours (renew).

DEPLOY_LOCK_HOLDER=""

_deploy_lock_valid_holder() {  # $1 = holder
  case "$1" in
    ''|*[!A-Za-z0-9_.:@-]*) return 1 ;;
    *) return 0 ;;
  esac
}

deploy_lock_ensure_table() {
  topology_psql "CREATE TABLE IF NOT EXISTS deploy_locks (id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1), holder text NOT NULL, acquired_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL);" >/dev/null
}

# deploy_lock_acquire <holder> <ttl_sec>
# Single-statement CAS: INSERT the singleton row, or — only when the
# existing row is EXPIRED — take it over. A live row matches no rows and
# the acquire fails. One statement = atomic against concurrent acquirers
# (the PK conflict loser retries as the guarded UPDATE and loses again).
deploy_lock_acquire() {
  local holder="$1" ttl="$2" got rc=0
  _deploy_lock_valid_holder "$holder" || { echo "deploy lock: malformed holder '$holder'" >&2; return 1; }
  case "$ttl" in ''|*[!0-9]*) echo "deploy lock: ttl must be seconds, got '$ttl'" >&2; return 1 ;; esac
  deploy_lock_ensure_table || { echo "deploy lock: cannot ensure deploy_locks table (leader Postgres reachable?)" >&2; return 1; }
  got="$(topology_psql "INSERT INTO deploy_locks (id, holder, expires_at) VALUES (1, '$holder', now() + make_interval(secs => $ttl)) ON CONFLICT (id) DO UPDATE SET holder = EXCLUDED.holder, acquired_at = now(), expires_at = EXCLUDED.expires_at WHERE deploy_locks.expires_at <= now() RETURNING holder;")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "deploy lock: psql failed against the leader Postgres" >&2
    return 1
  fi
  # psql prints the returned row, then the command tag ("INSERT 0 1") —
  # compare only the first line.
  got="${got%%$'\n'*}"
  if [ "$got" = "$holder" ]; then
    DEPLOY_LOCK_HOLDER="$holder"
    echo "deploy lock: ACQUIRED by '$holder' (ttl ${ttl}s)"
    return 0
  fi
  # Held by someone else (F4.1): print the live row, refuse.
  echo "deploy lock: HELD — refusing." >&2
  deploy_lock_status >&2 || true
  return 4
}

# deploy_lock_status — prints one line: "FREE" (table absent or empty
# row), "holder|acquired_at|expires_at|held|expired", or "UNREADABLE"
# (leader Postgres unreachable — e.g. --plan from a host without prod SSH).
deploy_lock_status() {
  local reg row rc=0
  reg="$(topology_psql "SELECT to_regclass('public.deploy_locks');")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$reg" ]; then
    # Distinguish unreachable from merely-not-created.
    if [ "$rc" -ne 0 ]; then echo "UNREADABLE"; return 1; fi
    echo "FREE (deploy_locks not created yet — first acquire creates it)"
    return 0
  fi
  row="$(topology_psql "SELECT holder || '|' || acquired_at || '|' || expires_at || '|' || CASE WHEN expires_at <= now() THEN 'expired' ELSE 'held' END FROM deploy_locks WHERE id = 1;")" || { echo "UNREADABLE"; return 1; }
  if [ -z "$row" ]; then echo "FREE"; return 0; fi
  echo "$row"
}

# deploy_lock_release — releases OUR row (set by a successful acquire);
# never touches another holder's row. Idempotent.
deploy_lock_release() {
  local out first rc=0
  if [ -z "$DEPLOY_LOCK_HOLDER" ]; then
    echo "deploy lock: release skipped (nothing held by this process)"
    return 0
  fi
  out="$(topology_psql "DELETE FROM deploy_locks WHERE id = 1 AND holder = '$DEPLOY_LOCK_HOLDER' RETURNING holder;")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Keep DEPLOY_LOCK_HOLDER: this process DOES still own a row (whose
    # remaining TTL is the backstop) — clearing it would hide that.
    echo "deploy lock: release FAILED for '$DEPLOY_LOCK_HOLDER' (leader Postgres unreachable or DELETE failed) — the row may persist until expires_at; break glass with deploy_prod.sh --force-lock" >&2
    return 1
  fi
  first="${out%%$'\n'*}"
  if [ "$first" = "$DEPLOY_LOCK_HOLDER" ]; then
    echo "deploy lock: released by '$DEPLOY_LOCK_HOLDER'"
  else
    echo "deploy lock: release matched no row for '$DEPLOY_LOCK_HOLDER' (already released, TTL-takeover, or --force-lock)"
  fi
  DEPLOY_LOCK_HOLDER=""
  return 0
}

# deploy_lock_renew <ttl_sec> — extend OUR row's expires_at by <ttl> and
# prove the row is still ours (rc 0 = still held by this holder, 1 =
# lost/unreachable). The single acquire at deploy start is not enough:
# a run that overruns its TTL loses the CAS, and a second operator's
# deploy can then take the row over mid-rollout. Callers renew at phase
# boundaries and ABORT when this fails.
deploy_lock_renew() {
  local ttl="$1" out first rc=0
  case "$ttl" in ''|*[!0-9]*) echo "deploy lock: renew: ttl must be seconds, got '$ttl'" >&2; return 1 ;; esac
  if [ -z "$DEPLOY_LOCK_HOLDER" ]; then
    echo "deploy lock: renew: nothing held by this process" >&2
    return 1
  fi
  out="$(topology_psql "UPDATE deploy_locks SET expires_at = now() + make_interval(secs => $ttl) WHERE id = 1 AND holder = '$DEPLOY_LOCK_HOLDER' RETURNING holder;")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "deploy lock: renew FAILED for '$DEPLOY_LOCK_HOLDER' (leader Postgres unreachable or UPDATE failed)" >&2
    return 1
  fi
  first="${out%%$'\n'*}"
  if [ "$first" = "$DEPLOY_LOCK_HOLDER" ]; then
    echo "deploy lock: renewed by '$DEPLOY_LOCK_HOLDER' (ttl ${ttl}s)"
    return 0
  fi
  echo "deploy lock: LOST — row is no longer held by '$DEPLOY_LOCK_HOLDER' (expired + taken over, or force-released)" >&2
  return 1
}

# deploy_lock_force_release <holder> — BREAK-GLASS: removes the lock row
# held by <holder> regardless of expiry, bypassing the CAS. The caller
# MUST audit the break (this function echoes an AUDIT line to the deploy
# log; deploy_prod.sh --force-lock is the sanctioned entry point).
deploy_lock_force_release() {
  local target="$1" had rc=0 first
  _deploy_lock_valid_holder "$target" || { echo "deploy lock: force-release: malformed holder '$target'" >&2; return 1; }
  had="$(topology_psql "DELETE FROM deploy_locks WHERE id = 1 AND holder = '$target' RETURNING holder;")" || rc=$?
  first="${had%%$'\n'*}"   # row first, then the "DELETE n" command tag
  if [ "$first" = "$target" ]; then
    echo "AUDIT: deploy lock FORCE-RELEASED (was held by '$target') at $(date -u +%Y-%m-%dT%H:%M:%SZ) — break-glass via deploy_lock_force_release"
  elif printf '%s\n' "$had" | grep -q '^DELETE 0'; then
    echo "AUDIT: deploy lock force-release for '$target' matched no row (already free or holder mismatch)"
  elif [ "$rc" -ne 0 ]; then
    echo "AUDIT: deploy lock force-release for '$target' could not reach the leader Postgres" >&2
    return 1
  else
    echo "AUDIT: deploy lock force-release for '$target' — unexpected psql output: '$had'" >&2
    return 1
  fi
  DEPLOY_LOCK_HOLDER=""
  return 0
}
