# Providers UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve Providers & keys state legibility and mobile density while preserving every operational behavior and the approved control-room design.

**Architecture:** Make targeted presentation-only edits in the existing Providers page and shared dialog primitive. Reuse current Button, Badge, Field, and semantic-token patterns; add no API, state, dependency, route, or backend changes. Leave all work uncommitted.

**Tech Stack:** React 18, TypeScript, Vite, Tailwind CSS 4, Radix/shadcn, lucide-react.

---

### Task 1: Legible endpoint feature controls

**Files:**
- Modify: `dashboard/spa/src/pages/providers.tsx:85-87,404-442`

- [ ] **Step 1: Add one presentational knob component**

Immediately after `isDecisionsProtocol`, add this component. It owns no state and preserves the parent handlers:

```tsx
type EndpointKnobProps = {
  label: string
  checked: boolean | null
  title: string
  onToggle: () => void
}

function endpointKnobText(checked: boolean | null) {
  if (checked === null) return "—"
  return checked ? "On" : "Off"
}

function EndpointKnob({ label, checked, title, onToggle }: EndpointKnobProps) {
  return (
    <Button
      type="button"
      variant={checked === true ? "secondary" : "outline"}
      size="xs"
      disabled={checked === null}
      aria-pressed={checked ?? undefined}
      aria-label={checked === null ? `${label}: state unavailable` : undefined}
      title={title}
      onClick={onToggle}
    >
      <span
        aria-hidden
        className={cn(
          "size-1.5 rounded-full",
          checked === true ? "bg-success" : "bg-muted-foreground/40",
        )}
      />
      <span>{label}</span>
      <span aria-hidden className="font-mono text-[9px] font-medium tracking-wide text-muted-foreground uppercase">
        {endpointKnobText(checked)}
      </span>
    </Button>
  )
}
```

- [ ] **Step 2: Replace the flat toggle row with labeled groups**

Replace the endpoint-features `<div>` and its contents with:

```tsx
<div className="flex flex-col gap-3 border-b bg-muted/20 px-5 py-3">
  <span className="text-xs font-medium text-muted-foreground">Endpoint features</span>
  <div className="flex flex-wrap gap-x-5 gap-y-3">
    <div role="group" aria-label="Translation features" className="flex flex-wrap items-center gap-2">
      <span className="font-mono text-[10px] text-muted-foreground uppercase">Translation</span>
      <EndpointKnob
        label="tools-stream"
        checked={toolsTranslate}
        title="Cross-protocol streaming tool-call translation (settings knob, default off)"
        onToggle={toggleToolsTranslate}
      />
      <EndpointKnob
        label="responses-stream"
        checked={responsesTranslate}
        title="Responses-client streaming translation to chat/anthropic providers (settings knob, default off)"
        onToggle={toggleResponsesTranslate}
      />
    </div>
    <div role="group" aria-label="Modality endpoints" className="flex flex-wrap items-center gap-2">
      <span className="font-mono text-[10px] text-muted-foreground uppercase">Modalities</span>
      {["image", "tts", "asr", "video", "embedding"].map((m) => (
        <EndpointKnob
          key={m}
          label={m}
          checked={modalityCfg ? modalityCfg[m] === true : null}
          title={`Serve /v1 modality endpoints for ${m} (settings knob, default off)`}
          onToggle={() => toggleModality(m)}
        />
      ))}
    </div>
  </div>
</div>
```

- [ ] **Step 3: Run the SPA static checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`

Expected: both commands exit 0; no unused imports or TypeScript errors.

### Task 2: Responsive expanded rows and affinity controls

**Files:**
- Modify: `dashboard/spa/src/pages/providers.tsx:628-739,803-912`

- [ ] **Step 1: Improve key-row wrapping and edit affordance**

Change the key-row container class from `flex flex-wrap items-center gap-3` to:

```tsx
className="flex flex-wrap items-center gap-x-3 gap-y-2"
```

In the weight-edit button, replace the hover-only pencil class with:

```tsx
className="size-3 opacity-60 transition-opacity group-hover:opacity-100"
```

Keep every key handler and the surrounding markup unchanged.

- [ ] **Step 2: Make the soft-region action resilient at narrow widths**

Change the region input/save container to `flex flex-wrap items-center gap-2`. Give the input this class and retain its existing id/value/handlers:

```tsx
className="h-9 min-w-0 grow basis-52"
```

Give Save `className="shrink-0"` while retaining `variant="outline"` and `size="sm"`.

- [ ] **Step 3: Bound long worker identifiers**

Replace the pinned-worker header span with:

```tsx
<span className="min-w-0 break-words whitespace-normal font-mono max-sm:basis-full sm:ml-auto" title={p.affinity_node}>
  pinned → {p.affinity_node}
</span>
```

Change its parent header row to `flex flex-wrap items-center gap-2 border-b border-border/60 px-3 py-1.5 text-xs font-medium text-muted-foreground`.

In each live-worker row, replace the node and note spans with:

```tsx
<span className="min-w-0 break-words whitespace-normal font-mono max-sm:basis-full" title={w.node}>
  {w.node}
</span>
<span className="min-w-0 grow basis-40 truncate text-muted-foreground" title={w.note || undefined}>
  {w.note || "no note"}
</span>
```

Retain the region, status, draining, and pinned badge content exactly as before.

- [ ] **Step 4: Fit expanded details inside the mobile card**

Add `@container` to the Providers card. In `components/ui/table.tsx`, define `--flush-cell-pad` once inside the `flush` branch and use it for all first/last cell padding. On the expanded section wrapper in `providers.tsx`, use `w-full max-w-[calc(100cqw-2*var(--flush-cell-pad))] whitespace-normal` at every size: it fills a wide scrolling row while capping the panel at the provider card's content width. Reset the table cell's inherited nowrap so descriptions and warnings wrap inside the cap. The provider card owns the container width and the table owns its flush inset, so viewport width, breakpoints, card borders, page gutters, and duplicated padding constants cannot drift the layout apart.

- [ ] **Step 5: Wrap long model listings**

Make the model toolbar and rows wrap at narrow widths. Keep the listing pane `overflow-x-hidden` and give model names `min-w-0 max-w-full break-words whitespace-normal` so long identifiers remain readable without page-level overflow or unnecessary breaks at hyphen boundaries.

- [ ] **Step 6: Run the SPA static checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`

Expected: both commands exit 0 and the current soft-geo wording remains in the diff.

### Task 3: Mobile dialog spacing and title clearance

**Files:**
- Modify: `dashboard/spa/src/components/ui/dialog.tsx:86-100,125-130,157-168`
- Modify: `dashboard/spa/src/components/ui/alert-dialog.tsx:48-103`

- [ ] **Step 1: Use responsive content padding and preserve footer resets**

In both modal primitives, replace fixed `p-6` with a responsive padding variable: `--dialog-pad` and `--alert-dialog-pad`, defaulting to `1rem` and becoming `1.5rem` at `sm`. Keep the existing width, height, scrolling, and animation behavior. Retain the base footer `pb-0` reset: responsive variants only change the variable, not the padding shorthand, so they cannot override the reset. Match each footer's negative margins and padding to its content variable.

- [ ] **Step 2: Reserve close-button space through shared geometry variables**

Define `--dialog-close-size`, `--dialog-close-inset`, and responsive `--dialog-pad` on `DialogContent`; consume them for the content padding and both close-button insets. Set `--dialog-close-gutter` to `calc(var(--dialog-close-size) + var(--dialog-close-inset) - var(--dialog-pad))` only when `showCloseButton` is true. In `DialogHeader`, use `px-(--dialog-close-gutter,0px) sm:pl-0` in the base classes so adapter, composed, and nested headers share the clearance without selector specificity overrides, hand-derived gutter constants, or invalid fallback padding when the close button is absent.

- [ ] **Step 3: Match footer spacing to content padding**

Use this `DialogFooter` class and the corresponding `--alert-dialog-pad` consumers in `AlertDialogFooter`:

```tsx
"sticky bottom-0 z-10 -mx-[var(--dialog-pad)] mt-2 flex flex-col-reverse gap-2 border-t bg-background px-(--dialog-pad) pt-4 pb-(--dialog-pad) sm:flex-row sm:justify-end"
```

- [ ] **Step 4: Run the SPA static checks**

Run: `cd dashboard/spa && npm run typecheck && npm run build`

Expected: both commands exit 0.

### Task 4: Real-browser and repository verification

**Files:**
- Verify only; do not create test scaffolding. Screenshots, if retained, belong in the existing ignored verification-artifact location rather than source directories.

- [ ] **Step 1: Start or identify the local dashboard**

Use the documented Vite/FastAPI development path and existing dependencies only. Do not install packages, submit provider keys, or mutate production. If only an existing authenticated local dashboard is available, use read-only navigation.

- [ ] **Step 2: Verify Providers at desktop and 390px**

With `ego-browser`, inspect the endpoint groups, an expanded key row, and the affinity panel in light and dark themes. Confirm each knob shows `On` or `Off` matching `aria-pressed`, long worker names stay inside the panel, the pencil edit affordance is visible, and no operational controls are missing.

Run this assertion at both widths:

```js
document.documentElement.scrollWidth <= window.innerWidth
```

Expected: `true`. Table-internal scrolling, if needed, must not become page-level overflow.

- [ ] **Step 3: Verify a representative dialog**

Open Add provider and another existing dialog without saving. Check close-button/title clearance, sticky footer actions, Escape dismissal, focus restoration, and mobile padding. Toggle the theme and confirm readable surfaces. Do not submit either form.

- [ ] **Step 4: Run the final static gates**

Run:

```bash
cd dashboard && bash scripts/lint_all.sh
cd .. && git diff --check
```

Expected: lint exits 0 and `git diff --check` prints nothing. If an unrelated pre-existing lint failure remains, record its exact output rather than changing unrelated files.

- [ ] **Step 5: Inspect delivery scope**

Run `git status --short` and `git diff -- dashboard/spa/src/pages/providers.tsx dashboard/spa/src/components/ui/dialog.tsx docs/superpowers/specs/2026-11-16-providers-ui-polish-design.md docs/superpowers/plans/2026-11-16-providers-ui-polish.md`.

Expected: only the two intended UI source files plus this design/plan are changed by this pass; pre-existing worker/geo changes remain untouched. Report verification evidence and any unverified scenario. Do not commit.
