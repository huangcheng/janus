/** Build-time feature flags for the console SPA.
 *
 * Kept in one module so every surface that mentions a gated feature agrees
 * about whether it exists. The Usage spend report used to tell operators to
 * "set prices on the Providers page" while the only price editor was hidden
 * behind VITE_FLAG_MODEL_PRICES — a dead end in the default build.
 */

/** Per-1M-token price editor on the Providers page.
 * Build with VITE_FLAG_MODEL_PRICES=1 to enable (hidden 2026-10-18 pending a
 * UX rework). The /prices API and the Usage spend report are unaffected by
 * this flag — operators can still price via the API, so the report stays
 * visible and only its "where to edit" copy is gated. */
const FLAG_TRUTHY = new Set(["1", "true", "yes", "on"])
export const SHOW_MODEL_PRICES = FLAG_TRUTHY.has(
  String(import.meta.env.VITE_FLAG_MODEL_PRICES ?? "")
    .trim()
    .toLowerCase(),
)

/** One source of truth for "where prices come from" copy, so every surface
 *  that mentions the (flag-gated) editor stays honest together. Full
 *  sentences, used verbatim everywhere. */
export const PRICES_HINT = SHOW_MODEL_PRICES
  ? "Per-1M-token prices are set on the Providers page."
  : "Prices are entered via the /prices API — the in-console price editor is not enabled in this build."
