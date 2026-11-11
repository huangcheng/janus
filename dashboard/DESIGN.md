# Design

## Visual Theme

Janus uses an architectural control-room visual system for its LLM gateway management plane. Deep-ink navigation and operational signature panels frame a readable workspace, chartreuse identifies actions and selected states, and strong editorial page introductions give each route a clear hierarchy. The interface remains a dense operational tool, not a marketing dashboard or a collection of decorative analytics.

The detailed redesign direction is recorded in `docs/superpowers/specs/2026-11-11-architectural-control-room-design.md` and persistent design context in `.impeccable.md`.

## Color and Contrast

- Use the semantic variables in `spa/src/index.css`; do not introduce page-specific hex colors.
- The light theme uses a cool-gray workspace with near-white working cards. The deliberate dark theme uses deep-ink surfaces with raised ink cards. Both themes share a dark sidebar and chartreuse primary actions.
- Use the dedicated `--link` / `text-link` token for text links. Light-theme links use dark olive rather than the filled-button chartreuse; dark-theme links retain bright chartreuse. Do not use `text-primary` for links on pale surfaces.
- Keep muted text readable in both themes and preserve semantic success, warning, and destructive states. Target WCAG AA contrast: 4.5:1 for normal text and 3:1 for large text.
- Do not place decorative gradients, grids, or textures behind reading content. Low-opacity geometry is confined to dark structural or illustrative panels.
- Floating layers use `popover`, `popover-foreground`, `border`, and `shadow-md`, with clear separation from the page.

## Typography

- Geist Variable for interface text; Geist Mono Variable for model names, identifiers, endpoints, technical labels, metrics, and timestamps.
- Page titles use a fluid 36–48px editorial scale. Shared card titles are 17px; dense operational body copy remains 13–14px with 12–13px supporting text.
- Use tabular numerals for metrics and timestamps. Long identifiers truncate with a tooltip, `title`, or expandable detail instead of forcing overflow.
- Uppercase mono labels provide technical context sparingly; they do not replace readable page or section titles.

## Components

- shadcn/Radix primitives through `components/ui/*`; shared pickers live in `components/combobox.tsx`.
- The sidebar uses the official Janus asset, chartreuse selected navigation, grouped operational links, and a compact API endpoints popover. Do not substitute generated brand artwork.
- The dashboard Gateway overview uses only real generation, backend, readiness, and catalog counts. Its Agents → Janus → Providers diagram is contextual architecture, not telemetry.
- Dialogs keep a visible header and sticky footer, bound their height to the viewport, and scroll their own overflow. Popovers position against the viewport and remain operable inside modal dialogs.
- Icon actions use shared Button variants and a 32–36px comfortable target, not bare tiny glyphs. Small visual checkboxes keep a larger pseudo-element hit area.
- Account groups credential tasks into persistent sections, so switching sections does not discard unsaved input. Passkey removal requires explicit confirmation.
- Tables stay document-flow with `Table flush`; long cells truncate or use `ExpandableText` for full evidence. Secondary gateway metadata uses accessible row disclosures.
- Usage and Failures use compact event lists below desktop widths and fixed, truncated tables on larger screens. Provider errors expand inline, and summary tables move secondary metadata into compact rows on smaller screens.
- Loading, empty, error, disabled, stale, and partial-data states are intentional compositions, not blank cards.

## Layout

- Preserve the sidebar and document-flow content column. Navigation groups are Overview, Configure, Observe, and System; Maintenance and Account live under System.
- A compact utility header contains the sidebar trigger, breadcrumb, existing page actions, and theme toggle. The single page `h1` and description live in the content introduction; avoid duplicate page headers.
- Data-plane endpoints live in the compact API endpoints popover in the sidebar footer, not a permanently expanded endpoint list.
- Page descriptions wrap when useful. Dense tables stay fluid; forms and settings use intentional reading widths.
- Use predictable form groups and tier grids with consistent spacing. Responsive behavior is structural: grids collapse and dialog content remains within the viewport. Content must fit a 390px viewport without horizontal scrolling.
- Logs use the same document-flow `Table flush` and shared client pagination as Audit. OTP and Ops events keep separate sources, filters, expandable details, and two-second refresh. OTP rows expand into structured key/value fields.
- Log and Audit tables use fixed columns. Secondary node, actor, and target metadata moves beneath timestamps on phones, preserving the information without horizontal scrolling. Log details use the full phone row beneath time and severity.
- Login and setup use a split brand/authentication composition. The dark Janus protocol panel compresses above the working form on narrow screens so the sign-in action remains easy to reach.

## Motion and Accessibility

- Use existing 150–250ms state transitions with natural deceleration. Honor reduced motion. Do not animate layout properties or add decorative continuous motion or orchestrated page-load sequences.
- Preserve semantic controls, visible keyboard focus, accessible dialogs, reduced-motion support, and status communication that does not rely on color alone.
- Keep light/dark theme persistence and ensure interactive controls remain readable throughout theme transitions.
