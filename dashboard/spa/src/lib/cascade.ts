// Deferred tier surgery — reading the cascade's "queued" report.
//
// Cascade spec 2026-10-22 §5.3: a mutation that retires (or revives) a
// tier member must rewrite `settings.auto_router` under the auto-router's
// advisory lock. When that lock is busy the data-plane change still
// commits, but the tier-list rewrite is QUEUED instead and applied by the
// backend's own retry loop seconds later. The response says so:
//
//   { cascade: { deferred: ["model-a", …], tiers_removed: {…}, … } }  // retire: names
//   { restore: { events: 1, deferred: true } }                        // replay/revive: flag
//
// This is a SUCCESS WITH DELAY, never a failure: the mutation happened.
// Both shapes exist and the field is optional, so read defensively and
// only report when there is something queued.

import { toast } from "sonner"

export type DeferredTierSurgery = {
  /** The backend queued a tier-list rewrite (router tier lock was busy). */
  queued: boolean
  /** Tier member names the queued surgery will touch; empty when the API only reports a flag. */
  names: string[]
}

function field(container: unknown, key: string): unknown {
  return container !== null && typeof container === "object"
    ? (container as Record<string, unknown>)[key]
    : undefined
}

/** true when the value itself means "queued" (a non-empty name list or the flag). */
function collect(value: unknown, into: Set<string>): boolean {
  if (Array.isArray(value)) {
    // Report THIS value only: an empty list means "not queued" even when an
    // earlier container already contributed names via `tiers_removed`.
    let found = false
    for (const item of value) {
      if (typeof item === "string" && item.trim() !== "") {
        into.add(item.trim())
        found = true
      }
    }
    return found
  }
  return value === true
}

/**
 * Read the deferred-tier-surgery report out of a mutation response.
 * Accepts every shape the backend emits today (`cascade.deferred` as a
 * list of names, `restore.deferred` as a boolean, and a top-level
 * `deferred` for flattened revive results) and ignores everything else.
 */
export function readDeferredSurgery(result: unknown): DeferredTierSurgery {
  const containers = [field(result, "cascade"), field(result, "restore"), result]
  // Names come ONLY from the signal that says "queued": a `tiers_removed`
  // entry was pruned inline, so naming it as queued would overstate what is
  // still pending (verified gap: an inline prune showed up in the message).
  const names = new Set<string>()
  let queued = false
  for (const container of containers) {
    if (collect(field(container, "deferred"), names)) queued = true
  }
  if (!queued) return { queued: false, names: [] }
  if (names.size > 0) return { queued: true, names: [...names].sort() }
  // Flag-only report (a replay/revive says `deferred: true` with no list):
  // fall back to the removed-tier names purely to make the message concrete.
  const fallback = new Set<string>()
  for (const container of containers) collectRemoved(field(container, "tiers_removed"), fallback)
  return { queued: true, names: [...fallback].sort() }
}

/** Names carried by a `tiers_removed` map: `{fast: [{name, index}, …], …}`. */
function collectRemoved(removed: unknown, into: Set<string>): void {
  if (removed === null || typeof removed !== "object") return
  for (const entries of Object.values(removed as Record<string, unknown>)) {
    if (!Array.isArray(entries)) continue
    for (const entry of entries) {
      const name = field(entry, "name")
      if (typeof name === "string" && name.trim() !== "") into.add(name.trim())
    }
  }
}

function summarise(names: string[]): string {
  if (names.length === 0) return "the affected tier entries"
  if (names.length <= 3) return names.join(", ")
  return `${names.slice(0, 3).join(", ")} +${names.length - 3} more`
}

function showNotice(names: string[]): void {
  toast.info("Router tier update queued", {
    description:
      `The router tier lock was busy, so the tier change for ${summarise(names)} is queued. ` +
      "It applies automatically within seconds — no action needed.",
    duration: 8000,
  })
}

/**
 * Show the "queued" notice when a response says tier surgery was
 * deferred. Returns true when a notice was shown.
 *
 * Kept distinct from the success toast on purpose: the operator must not
 * believe the tier change was dropped, and must not think they have to
 * retry — it self-applies within seconds.
 */
export function notifyDeferredSurgery(result: unknown): boolean {
  const { queued, names } = readDeferredSurgery(result)
  if (!queued) return false
  showNotice(names)
  return true
}

/**
 * Same notice for a batch of responses (bulk/group actions issue one call
 * per row): queued is true when ANY response says so, and the names are the
 * union — one notice, never one per row.
 */
export function notifyDeferredSurgeryMany(results: unknown[]): boolean {
  const reports = results.map(readDeferredSurgery)
  if (!reports.some((r) => r.queued)) return false
  const names = [...new Set(reports.flatMap((r) => r.names))].sort()
  showNotice(names)
  return true
}