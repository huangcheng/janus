/** Display-only time helpers — APIs and storage stay UTC; labels use the browser zone. */

export function pad2(n: number): string {
  return String(n).padStart(2, "0")
}

/** Parse backend ISO timestamps (Z, offset, or naive UTC wall clock). */
export function parseBackendInstant(iso: string): Date {
  const trimmed = iso.trim()
  if (!trimmed) return new Date(Number.NaN)
  if (/[zZ]|[+-]\d{2}:\d{2}$/.test(trimmed)) return new Date(trimmed)
  if (/^\d{4}-\d{2}-\d{2}T/.test(trimmed)) return new Date(`${trimmed}Z`)
  return new Date(trimmed)
}

/** UTC bucket key aligned with usage/spend SQL (`AT TIME ZONE 'UTC'`). */
export function utcUsageBucketKey(tsSec: number, stepSec: number): string {
  const d = new Date(tsSec * 1000)
  if (Number.isNaN(d.getTime())) return ""
  if (stepSec === 3600) {
    return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}T${pad2(d.getUTCHours())}:00`
  }
  return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}T00:00`
}

/** Local wall-clock label for a UTC usage bucket key ("2026-10-04T13:00"). */
export function fmtUtcBucketLabel(bucket: string, range: string): string {
  const t = Date.parse(`${bucket}Z`)
  if (Number.isNaN(t)) {
    return range === "24h" ? bucket.slice(11, 16) : bucket.slice(5, 10)
  }
  const d = new Date(t)
  if (range === "24h") return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`
}

/** Unix seconds → local "MM-DD HH:MM:SS" (tables, timelines). */
export function fmtUnixTsLocal(ts: number): string {
  const d = new Date(ts * 1000)
  if (Number.isNaN(d.getTime())) return "—"
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`
}

/** ISO instant → local "YYYY-MM-DD HH:MM". */
export function fmtIsoLocalCompact(iso: string): string {
  const d = parseBackendInstant(iso)
  if (Number.isNaN(d.getTime())) return iso
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`
}

/** ISO instant → local "YYYY-MM-DD HH:MM:SS". */
export function fmtIsoLocalSeconds(iso: string): string {
  const d = parseBackendInstant(iso)
  if (Number.isNaN(d.getTime())) return iso
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`
}

/** ISO instant → local "MM-DD HH:MM" (compact alert-style cells). */
export function fmtIsoLocalMonthDayHm(iso: string): string {
  const d = parseBackendInstant(iso)
  if (Number.isNaN(d.getTime())) return iso
  return `${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`
}
