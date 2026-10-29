/**
 * Display labels for `country-city` region codes (e.g. `cn-shanghai`,
 * `us-san-francisco`, `jp-tokyo`). Not vendor AZ ids (`us-west-1`).
 *
 * Wire value unchanged; SPA shows the city part only.
 */

/** Irregular city slugs where naive title-case is wrong. */
const CITY_OVERRIDES: Record<string, string> = {
  hongkong: "Hong Kong",
  "hong-kong": "Hong Kong",
  sanfrancisco: "San Francisco",
  "san-francisco": "San Francisco",
  huhehaote: "Hohhot",
  wulanchabu: "Ulanqab",
  siliconvalley: "Silicon Valley",
  "silicon-valley": "Silicon Valley",
}

function titleToken(tok: string): string {
  return tok.charAt(0).toUpperCase() + tok.slice(1).toLowerCase()
}

/**
 * Human city label for a `country-city` region code.
 * Empty / null / `unknown` → null (caller renders "—").
 */
export function formatRegionLabel(raw: string | null | undefined): string | null {
  if (raw == null) return null
  const key = String(raw).trim().toLowerCase()
  if (!key || key === "unknown") return null

  const parts = key.split("-").filter(Boolean)
  // country-city: drop the country segment; single token is already the city.
  const cityParts = parts.length >= 2 ? parts.slice(1) : parts
  if (cityParts.length === 0) return null

  const cityKey = cityParts.join("-")
  const override = CITY_OVERRIDES[cityKey] ?? CITY_OVERRIDES[cityParts.join("")]
  if (override) return override

  return cityParts.map(titleToken).join(" ")
}
