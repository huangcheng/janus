# Janus Architectural Control Room Design

## Context

Janus already has a complete operational console with dense tables, forms, dialogs, observability, and persistent light/dark preferences. The redesign must create a stronger product identity without changing routes, API contracts, editing behavior, or information architecture.

## Decision

Adapt the approved architectural control-room language to Janus: deep-ink navigation and operational signature panels, a light cool-gray workspace, near-white working surfaces, chartreuse actions and active states, and stronger editorial page introductions. Preserve a deliberate dark theme rather than forcing the light Portunus workspace onto Janus.

Alternatives considered:

- **Tokens only:** lowest risk, but would leave the shell and dashboard visually generic.
- **Page-by-page redesign:** could produce more variation, but would disrupt established dense workflows and create unnecessary regression risk.
- **Shared system plus signature surfaces (selected):** changes shared tokens, shell, cards, controls, dashboard, and authentication while leaving operational pages and their data behavior intact.

## Scope and invariants

- Preserve all routes, API calls, data shapes, forms, dialogs, tables, and theme persistence.
- Preserve desktop information density and mobile disclosures; do not hide operational functionality.
- Use real overview values only: generation, backend, readiness, provider/listing/binding/key counts.
- Keep decorative geometry out of reading surfaces and never invent health, traffic, or telemetry.
- Maintain semantic status colors, visible focus, keyboard behavior, and reduced-motion support.

## Visual system

The light workspace uses cool gray with near-white cards. The dark workspace uses deep ink with raised ink cards. Both themes share chartreuse primary actions and a deep-ink sidebar. Muted foregrounds are dark enough on light surfaces and bright enough on dark surfaces for readable supporting copy. No decorative gradients are introduced.

Geist Variable remains the interface face and Geist Mono remains reserved for identifiers, technical labels, counts, and timestamps. Page titles move from the compact utility header into a stronger in-content introduction. Card titles and stat values gain clearer scale without inflating dense tables.

## Shell and shared primitives

The desktop sidebar becomes a dark architectural frame with the existing Janus brand asset, chartreuse selected navigation, grouped links, API endpoints, and sign-out. The compact top bar contains the sidebar trigger, breadcrumb, existing page actions, and theme toggle. A responsive page introduction below it carries the page title and description.

Shared buttons, cards, stat cards, and sidebar active states receive the same tokens and slightly more deliberate geometry. Existing shadcn/Radix behavior remains unchanged.

## Dashboard

A dark Gateway overview replaces the repeated six-card stat row. Its left side explains the single front door and shows real catalog counts. Its right side depicts Agents → Janus → Providers and identifies the real backend, generation, and readiness. Activity, alerts, providers, and recent actions retain their existing data and layout below the overview.

Loading renders a shared Gateway overview skeleton with the same shell and responsive counter layout until overview data arrives. Errors and empty providers continue through the existing feedback components.

## Authentication

Login and setup use a split composition: a dark Janus brand/protocol panel and a focused authentication working area. Existing forms, passkeys, TOTP, Turnstile, footer content, and theme toggle remain unchanged. On narrow screens the brand panel compresses above the form.

## Verification

- Run `dashboard/scripts/lint_all.sh` with the existing Python environment.
- Exercise real dashboard routes in a browser at desktop and 390px widths.
- Check both themes, navigation, sidebar, theme toggle, dashboard data, login/setup, representative tables, dialogs, and horizontal overflow.
- Confirm no backend or API files changed and no new dependencies were introduced.
- Update `dashboard/DESIGN.md` and `.impeccable.md` to match the implemented system.
