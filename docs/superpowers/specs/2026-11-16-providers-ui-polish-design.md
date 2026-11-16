# Providers UI Polish Design

## Context

The architectural control-room redesign is implemented. The remaining work is a focused refinement of the Providers & keys workflow, especially its dense expanded rows and affinity controls, plus small mobile improvements to the shared dialog primitive. This pass preserves the approved visual system and the uncommitted soft-geo wording already present in the worktree.

## Approaches

- **Focused Providers polish (selected):** improve hierarchy, state legibility, and responsive behavior where the current workflow is densest. Limit shared changes to dialog spacing and title clearance. This offers visible value with a small verification surface.
- **Cross-page shared sweep:** normalize every dense table and form at once. This could produce broader consistency, but would mix unrelated pages and require much wider browser regression coverage.
- **New visual direction:** replace the current control-room language. Reject: it contradicts the approved redesign and the hardening-phase restriction on broad visual redesign.

## Scope and invariants

- Preserve every route, API call, data shape, mutation, and optimistic-update rule.
- Preserve the current `domestic` / `overseas` and fine-region-tag behavior and explanatory meaning.
- Use existing semantic color, typography, spacing, and component tokens. Add no dependencies, gradients, decorative surfaces, pages, or controls with new backend behavior.
- Keep operational state visible without relying on color alone.
- Preserve keyboard operation, accessible names, focus restoration, reduced motion, and both themes.
- Do not alter the uncommitted Erlang worker/geo files or unrelated dashboard files.

## Components and presentation

### Endpoint feature controls

Group the existing translation and modality toggles into clearly labeled clusters. Keep the existing buttons and handlers, but make enabled/disabled state readable as text as well as through `aria-pressed`, button variant, and the status dot. An unread setting shows a neutral placeholder and omits `aria-pressed`; it never appears as Off. Use compact labels that wrap without stretching the provider table or changing the knobs' default-off meaning.

### Provider expanded rows

Tighten alignment and wrapping in key rows while leaving weight editing, probing, enable/disable, and removal unchanged. Keep identifiers readable and actions reachable on narrow screens. Size expanded details from the main-content container query rather than viewport width so classic scrollbar gutters cannot reintroduce overflow. Avoid restructuring the page into nested cards or adding decorative elements.

### Affinity panel

Retain separate controls for the absolute worker pin and soft region preference. Improve responsive layout for the region input/save action and live-worker list. Long Erlang node names must truncate or wrap inside their containers with the full name still available through existing text or a tooltip/title. Keep the unmatched-pin warning prominent and unchanged in meaning.

### Shared dialogs

Reduce mobile padding while retaining desktop density. Match footer negative margins and padding to the content padding. Reserve space for the close button so long titles cannot render beneath it. Keep the existing sticky footer, scrolling behavior, floating-layer handling, and focus restoration.

## Failure modes to guard against

- A presentation edit accidentally changes a mutation handler or optimistic rollback.
- A long provider, worker, or node name forces page-level horizontal overflow.
- A knob's visual state disagrees with its `aria-pressed` value.
- Dialog footer or close-button spacing regresses desktop layouts or floating-layer interaction.
- The current uncommitted Providers edits are overwritten rather than incorporated.

## Verification

- Run `npm run typecheck` and `npm run build` in `dashboard/spa`.
- Run `bash scripts/lint_all.sh` in `dashboard` with the existing Python environment; report unrelated pre-existing failures separately.
- Run `git diff --check` and inspect the final diff for unrelated changes.
- Exercise the real dashboard in a browser at desktop and 390px widths in light and dark themes. Inspect Providers, an expanded key row, the affinity panel, and a representative dialog without saving operational changes.
- Assert no page-level horizontal overflow, visible knob state text, accessible expansion state, working dialog dismissal, and preserved navigation/theme behavior.

## Assumptions

- "Continue polish UI" refers to the existing dashboard control-room redesign, with Providers & keys as the current focus.
- Auto permission mode authorizes proceeding without additional design-review prompts; no git commit will be created without an explicit request.
- The existing local dashboard may be used read-only if available. No production mutation or provider-key submission is part of verification.
