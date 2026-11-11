# Janus Architectural Control Room Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the approved architectural control-room visual system to Janus while preserving every operational workflow and both themes.

**Architecture:** Implement the design through existing shared tokens and shadcn/Radix primitives, the common shell, one pure presentational Gateway overview component, and the shared authentication shell. Do not modify API calls, route definitions, backend files, or page-specific operational logic.

**Tech Stack:** React 18, TypeScript, Vite, Tailwind CSS 4, shadcn/Radix, lucide-react, Recharts.

**Workspace:** `architectural-control-room` worktree on branch `architectural-control-room`. Do not commit unless the user explicitly requests it.

---

### Task 1: Shared visual tokens and primitives

**Files:**
- Modify: `dashboard/spa/src/index.css`
- Modify: `dashboard/spa/src/components/ui/button.tsx`
- Modify: `dashboard/spa/src/components/ui/card.tsx`
- Modify: `dashboard/spa/src/components/ui/sidebar.tsx`
- Modify: `dashboard/spa/src/components/stat-card.tsx`

- [ ] **Step 1: Verify the clean baseline**

Run:

```bash
PYTHON=<existing-dashboard-venv>/bin/python bash dashboard/scripts/lint_all.sh
```

Expected: ruff, SPA typecheck/build, shell syntax, telemetry contracts, Docker check, and JSON/TOML checks pass. Erlang is skipped when its sibling checkout is unavailable.

- [ ] **Step 2: Replace the light/dark token values**

Set the light workspace to `oklch(0.975 0.004 220)`, cards to `oklch(0.997 0.002 220)`, chartreuse primary to `oklch(0.89 0.18 120)`, and dark primary foreground to `oklch(0.22 0.035 265)`. Use deep-ink sidebar tokens in both themes and retain readable semantic success/warning/destructive tokens. Add no gradient backgrounds.

- [ ] **Step 3: Align primitive geometry and active states**

Use chartreuse with dark foreground for selected sidebar items:

```tsx
"data-[active=true]:bg-sidebar-primary data-[active=true]:font-semibold data-[active=true]:text-sidebar-primary-foreground"
```

Keep existing button sizes and behavior. Increase card titles to `text-[17px]`, preserve dense content padding, and use restrained border/shadow tokens rather than new visual effects.

- [ ] **Step 4: Run the SPA checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`
Expected: TypeScript and Vite pass with no new dependencies.

### Task 2: Architectural application shell

**Files:**
- Modify: `dashboard/spa/src/components.tsx`
- Modify: `dashboard/spa/index.html`

- [ ] **Step 1: Restyle the sidebar brand and groups**

Retain the existing Janus icon and navigation arrays. Render the product descriptor in `font-mono text-[9px] tracking-[0.12em] text-sidebar-foreground/55` and group labels in `text-sidebar-foreground/55`. Do not alter navigation destinations or sign-out behavior.

- [ ] **Step 2: Separate utility navigation from page hierarchy**

Replace the header `h1` with a compact breadcrumb:

```tsx
<div className="flex items-center gap-2 font-mono text-[10px] text-muted-foreground">
  <span>Janus</span><span aria-hidden>/</span><strong className="font-medium text-foreground">{title}</strong>
</div>
```

Keep existing actions and `ThemeToggle` in the header. Inside `#main-content`, render one `h1` using `text-[clamp(2rem,3.2vw,3rem)] leading-[1.03] font-semibold tracking-[-0.055em]` and the existing description below it.

- [ ] **Step 3: Update browser chrome colors**

Set light `theme-color` to `#f3f5f7` and dark `theme-color` to `#11141b`, matching the new neutral surfaces. Keep the early theme script unchanged.

- [ ] **Step 4: Run the SPA checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`
Expected: one page `h1`, all existing actions present, and a successful build.

### Task 3: Real-data Gateway overview

**Files:**
- Create: `dashboard/spa/src/components/gateway-overview.tsx`
- Modify: `dashboard/spa/src/pages/dashboard.tsx`

- [ ] **Step 1: Add the pure presentational component**

Define props using only existing overview values:

```tsx
type GatewayOverviewProps = {
  generation: number
  backend: string
  ready: boolean
  counts: { providers: number; listings: number; bindings: number; agentKeys: number }
}
```

Render a dark two-column `<section aria-label="Gateway overview">` with the headline `One front door. Every protocol.`, four real counts, and an Agents → Janus → Providers diagram built from CSS and inline SVG. Use the existing Janus icon. The figcaption displays backend, generation, and `Catalog ready` or `Catalog cold`; do not add fabricated metrics.

- [ ] **Step 2: Add responsive structure**

Use `grid-cols-1 lg:grid-cols-[minmax(0,0.9fr)_minmax(390px,1.1fr)]`, `rounded-3xl`, and `bg-sidebar text-sidebar-foreground`. Stack on smaller screens, reduce padding at mobile widths, and keep the diagram within its container. Confine the low-opacity grid to this decorative panel.

- [ ] **Step 3: Replace only the loaded stat grid**

Render the shared `GatewayOverviewSkeleton` while overview data loads, using the same shell and responsive counter layout as the loaded component. After data loads, render:

```tsx
<GatewayOverview
  generation={data.generation}
  backend={data.backend}
  ready={data.ready}
  counts={{
    providers: data.counts.providers,
    listings: data.counts.listings ?? data.counts.models ?? 0,
    bindings: data.counts.routes,
    agentKeys: data.counts.agent_keys,
  }}
/>
```

Remove the now-unused loaded `stats` mapping and icon imports. Keep reload, activity, alerts, providers, recent actions, errors, and empty states unchanged.

- [ ] **Step 4: Run the SPA checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`
Expected: no unused imports or type errors; Vite builds successfully.

### Task 4: Split authentication composition

**Files:**
- Modify: `dashboard/spa/src/components/auth-shell.tsx`

- [ ] **Step 1: Add the brand panel**

Wrap the existing form and footer in a two-column shell. Add a dark left panel with the Janus icon, `Every model. One front door.`, protocol labels `OpenAI Chat`, `OpenAI Responses`, and `Anthropic Messages`, and concise translation copy. Keep the logo asset and product name unchanged.

- [ ] **Step 2: Preserve authentication behavior**

Render `{children}` without wrapping it in another form or changing its width unexpectedly. Place the existing `{footer}` and `<ThemeToggle />` in the right working area. On screens below `md`, use one column with a compact brand panel above the form.

- [ ] **Step 3: Run the SPA checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`
Expected: login and setup children retain their existing behavior and TypeScript passes.

### Task 5: Browser verification and documentation

**Files:**
- Modify: `dashboard/DESIGN.md`
- Modify: `.impeccable.md`
- Create: verification screenshots under the worktree's ignored `.superpowers/` directory

- [ ] **Step 1: Start the real local dashboard**

Use the documented FastAPI/Vite development path with temporary local credentials and a throwaway database. Do not connect to or mutate production. If the existing local instance is available, use read-only navigation only and do not create or edit operational data.

- [ ] **Step 2: Verify desktop and mobile behavior**

Use ego-browser to inspect Dashboard, Providers & keys, Usage, Login, and the theme toggle at desktop and 390px widths. Assert `document.documentElement.scrollWidth <= window.innerWidth`, visible page headings, working navigation, readable theme surfaces, and no broken images. Exercise the mobile sidebar and a representative existing dialog without saving changes.

- [ ] **Step 3: Run the final repository checks**

Run:

```bash
PYTHON=<existing-dashboard-venv>/bin/python bash dashboard/scripts/lint_all.sh
git diff --check
```

Expected: the same gates as baseline pass and only presentation/documentation files changed.

- [ ] **Step 4: Update repository design guidance**

Document the cool-gray/deep-ink/chartreuse tokens, stronger page introductions, real-data Gateway overview, split authentication composition, preserved dark theme, responsive behavior, and prohibition against decorative gradients behind content.

- [ ] **Step 5: Report delivery**

List changed files, verification evidence, screenshot paths, worktree path, and any unverified scenario. Leave all changes uncommitted unless the user explicitly asks for a commit.
