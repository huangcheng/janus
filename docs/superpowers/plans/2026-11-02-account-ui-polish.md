# Account UI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the always-visible password form with an explicit, accessible change-password flow and verify the Account page in a real browser.

**Architecture:** Keep the change inside the existing `PasswordCard` React component. A local editing state controls progressive disclosure; the existing API, form validation, dialogs, and account-section structure remain unchanged. Other Account sections receive a read-only browser audit in this phase, with any unrelated fixes planned separately.

**Tech Stack:** React 18, TypeScript, Tailwind CSS 4, shadcn/ui, lucide-react, Vite, ego-browser.

---

### Task 1: Reproduce the current behavior and establish a browser baseline

**Files:**
- Inspect: `dashboard/spa/src/pages/account.tsx:338-432`
- Reference: `docs/superpowers/specs/2026-11-02-account-ui-polish-design.md`

- [ ] **Step 1: Open the local Account page with ego-browser**

Invoke the `ego-browser` skill, open the local dashboard in the user's real browser, and navigate to Account → Sign-in using actual clicks. Do not use or mutate production.

Expected: the Sign-in card immediately displays Current password, New password, and Confirm new password.

- [ ] **Step 2: Capture the initial responsive baseline**

At desktop width, record the visible password fields and the other Account navigation controls. Resize to a mobile viewport and confirm the current sections remain reachable.

Expected: the three password inputs are visible without an explicit operator action; this is the behavior to remove.

- [ ] **Step 3: Audit the other Account sections without editing**

Click through Two-factor, Recovery, and Passkeys. Open and cancel their non-destructive dialogs, check labels and keyboard focus, and look for horizontal overflow or clipped controls. Record only reproducible issues; do not submit disable, regenerate, remove, or passkey-registration actions during this baseline.

Expected: a concise issue list distinguishing confirmed problems from unchanged working flows.

### Task 2: Add progressive disclosure to the password card

**Files:**
- Modify: `dashboard/spa/src/pages/account.tsx:338-432`

- [ ] **Step 1: Replace only `PasswordCard` with the stateful closed/expanded flow**

Keep the surrounding `Account` component and all imports unchanged. `KeyRound` and `LoaderCircle` are already imported. Use this complete component:

```tsx
function PasswordCard({ status, onDone }: { status: Status | null; onDone: () => void }) {
  const [editing, setEditing] = useState(false)
  const [current, setCurrent] = useState("")
  const [next, setNext] = useState("")
  const [confirm, setConfirm] = useState("")
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  function close() {
    setEditing(false)
    setCurrent("")
    setNext("")
    setConfirm("")
    setErr(null)
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    setErr(null)
    if (next !== confirm) {
      setErr("the new passwords do not match")
      return
    }
    setBusy(true)
    try {
      await api("/auth/password", { method: "POST", body: { current, next } })
      toast.success("Password updated")
      close()
      onDone()
    } catch (e: any) {
      toast.error(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card className="w-full self-start overflow-hidden">
      <CardHeader>
        <CardTitle>Sign-in password</CardTitle>
        <CardDescription>
          {status?.has_password
            ? "Use a unique password with at least 8 characters."
            : "No password is set. Sign-in currently requires a passkey."}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {editing ? (
          <form onSubmit={submit} className="max-w-sm">
            {err && <ErrorFlash message={err} />}
            <div className="flex flex-col gap-4">
              <Field>
                <FieldLabel htmlFor="pw-current">Current password</FieldLabel>
                <Input
                  id="pw-current"
                  type="password"
                  autoComplete="current-password"
                  value={current}
                  onChange={(e) => setCurrent(e.target.value)}
                  required
                  autoFocus
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="pw-next">New password</FieldLabel>
                <Input
                  id="pw-next"
                  type="password"
                  autoComplete="new-password"
                  value={next}
                  onChange={(e) => setNext(e.target.value)}
                  required
                  minLength={8}
                />
                <FieldDescription>At least 8 characters.</FieldDescription>
              </Field>
              <Field>
                <FieldLabel htmlFor="pw-confirm">Confirm new password</FieldLabel>
                <Input
                  id="pw-confirm"
                  type="password"
                  autoComplete="new-password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  required
                  minLength={8}
                />
              </Field>
            </div>
            <FieldFooter className="mt-6">
              <Button type="button" variant="ghost" onClick={close} disabled={busy}>
                Cancel
              </Button>
              <Button type="submit" disabled={busy}>
                {busy && <LoaderCircle className="animate-spin" />}
                Update password
              </Button>
            </FieldFooter>
          </form>
        ) : (
          <div className="flex flex-col items-start gap-4">
            <p className="text-sm text-muted-foreground">
              {status?.has_password
                ? "Your password is active and ready to use."
                : "Add a password to enable password sign-in."}
            </p>
            <Button
              type="button"
              variant="outline"
              size="sm"
              onClick={() => {
                setErr(null)
                setEditing(true)
              }}
            >
              <KeyRound />
              Change password
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
```

Invariants: no request occurs when the form opens or closes; cancel and success clear every credential; a mismatch sends no request; an API failure leaves entered values available for correction; busy prevents duplicate submit and cancellation.

- [ ] **Step 2: Review the edited component for stale comments and unintended changes**

Confirm the old comments about an always-visible single-column form are gone, the rest of `account.tsx` is unchanged, and no API paths or request fields were renamed.

Expected: one contained component change with no stale description of the old behavior.

### Task 3: Run static verification

**Files:**
- Verify: `dashboard/spa/src/pages/account.tsx`

- [ ] **Step 1: Run TypeScript checks**

Run:

```bash
cd dashboard/spa && npm run typecheck
```

Expected: exit code 0 with no TypeScript errors.

- [ ] **Step 2: Build the production SPA**

Run:

```bash
cd dashboard/spa && npm run build
```

Expected: exit code 0 and a successful Vite production build. Do not commit generated `dist` output.

- [ ] **Step 3: Check the working tree for unintended artifacts**

Run:

```bash
git status --short
```

Expected: only the intended source, design, and plan files plus pre-existing untracked configuration directories; no new logs, screenshots, or build artifacts requiring cleanup.

### Task 4: Verify the new flow end to end

**Files:**
- Verify: `dashboard/spa/src/pages/account.tsx`
- Evidence: screenshots retained by the browser tooling, not added to the repository

- [ ] **Step 1: Verify closed, open, and cancel states**

Using ego-browser against the local stack, reload Account → Sign-in. Assert that no password input is initially present and exactly one Change password button is visible. Click it and assert that all three fields appear and Current password has focus. Enter representative values, click Cancel, and reopen.

Expected: the fields are hidden after Cancel and every reopened field is empty.

- [ ] **Step 2: Verify mismatch validation and request suppression**

Open Change password. Enter a current password, `new-password-1` as the new password, and `new-password-2` as confirmation. Click Update password while monitoring browser network requests.

Expected: the inline message `the new passwords do not match` appears and no `POST /api/auth/password` request is emitted.

- [ ] **Step 3: Verify server failure preserves the form**

With matching valid-length new passwords, submit an intentionally incorrect current password against the local stack.

Expected: one password-update request occurs, the existing error toast displays the server's message, the form stays open, and the new-password values remain available for correction. Never perform this check against production.

- [ ] **Step 4: Verify a successful update when a disposable local credential is available**

If the local credential is known, change it through the UI, confirm the success toast and closed/cleared form, then change it back through the same UI. If the credential is not available, do not ask for or inspect production secrets; report that the success path was not exercised and keep the confirmed failure-path evidence.

Expected when exercised: both updates succeed, status reloads, and the original local credential is restored.

- [ ] **Step 5: Run responsive and regression checks**

Repeat closed/open/cancel at a mobile viewport. Click through Two-factor, Recovery, and Passkeys; open and cancel safe dialogs and verify keyboard focus, labels, and no horizontal overflow.

Expected: all Account sections remain reachable and unchanged flows behave as in the baseline. Any newly confirmed unrelated issue is reported for a later page-scoped plan rather than fixed opportunistically.
