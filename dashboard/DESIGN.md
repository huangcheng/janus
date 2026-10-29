# Design

## Visual Theme

Quiet precision: a restrained light or dark admin theme driven by cool-neutral OKLCH tokens and a single indigo accent. The page canvas, raised cards, and sidebar use separate surface levels so dense operational content stays easy to scan. Accent is reserved for primary actions, focus, selected state, and compact metric icons. Light and dark are deliberate operator preferences, not decorative themes.

## Color

- Use the semantic variables in `spa/src/index.css`; do not introduce page-specific hex colors.
- Keep muted text readable in both themes and preserve semantic success, warning, and destructive states.
- Floating layers use `popover`, `popover-foreground`, `border`, and `shadow-md`, with clear separation from the page.
- The log terminal uses the shared `terminal-*` semantic tokens for its surface, border, body text, and severity levels in both themes.

## Typography

- Geist Variable for interface text; Geist Mono Variable for model names, identifiers, endpoints, and metrics.
- Use 13–14px body text, 12px secondary text, `text-sm` controls, `text-xl` page titles, and `text-lg` dialog titles. Dense metadata may be smaller only when it remains readable.
- Use tabular numerals for metrics and timestamps. Long identifiers truncate with a tooltip, `title`, or expandable detail instead of forcing overflow.

## Components

- shadcn/Radix primitives through `components/ui/*`; shared pickers live in `components/combobox.tsx`.
- Dialogs keep a visible header and sticky footer, bound their height to the viewport, and scroll their own overflow.
- Popovers position against the viewport and remain operable inside modal dialogs.
- Icon actions use shared Button variants and a 32–36px comfortable target, not bare tiny glyphs. Small visual checkboxes keep a larger pseudo-element hit area.
- Account groups credential tasks into persistent sections, so switching sections does not discard unsaved input. Passkey removal requires explicit confirmation.
- Tables stay document-flow with `Table flush`; long cells truncate or use `ExpandableText` for full evidence. Secondary gateway metadata uses accessible row disclosures.
- Loading, empty, error, disabled, stale, and partial-data states are intentional compositions, not blank cards.

## Layout

- Preserve the existing sidebar and document-flow content column. Navigation groups are Overview, Configure, Observe, and System; Maintenance and Account live under System.
- Data-plane endpoints live in the compact API endpoints popover in the sidebar footer, not a permanently expanded endpoint list.
- Page descriptions wrap when useful. Dense tables stay fluid; forms and settings use intentional reading widths.
- Use predictable form groups and tier grids with consistent spacing. Responsive behavior is structural: grids collapse and dialog content remains within the viewport.
- Logs are the exception to document flow: `Layout fill` keeps the dedicated internal scroller, follow state, and live-tail behavior.
- Below the `sm` breakpoint, terminal log rows wrap the message onto its own full-width line so evidence stays readable on phones instead of starving the message column.

## Motion

- Use existing 150–250 ms state transitions only. Honor reduced motion. Do not animate layout properties or add decorative motion or orchestrated page-load sequences.
