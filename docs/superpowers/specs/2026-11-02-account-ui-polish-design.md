# Account UI Polish Design

## Context

The Account page currently displays the current-password, new-password, and
confirmation fields as soon as the Sign-in section opens. This gives a routine
security overview the visual weight of an active credential-change workflow.
The dashboard-wide polish effort will proceed as separate page-scoped phases;
this design covers only Account.

## Goals

- Make password status and the available action clear before editing begins.
- Reveal credential fields only when the operator chooses to change the
  password.
- Preserve existing password rules, API contracts, and authentication behavior.
- Audit the remaining Account sections for concrete interaction, accessibility,
  and responsive-layout problems without broad visual redesign.
- Verify every changed flow in a real browser at desktop and mobile widths.

## Password Card

The initial card retains its title, description, and password status. It shows
a single **Change password** action instead of the form.

Activating that action expands the existing form inline below the summary and
moves focus to **Current password**. The expanded form contains:

- Current password, using `autocomplete="current-password"`.
- New password, using `autocomplete="new-password"` and the existing minimum
  length of eight characters.
- Confirm new password, with the same autocomplete and minimum-length rules.
- **Update password** as the primary action and **Cancel** as a secondary
  action.

Cancel hides the form and clears all three values and the local mismatch error.
A successful update does the same, retains the existing success toast, and
reloads account status. Reopening the form always starts with empty fields.

The closed and expanded states use the same card rather than a modal, avoiding
an additional overlay for a single short form.

## Validation and Failure Behavior

The existing client-side confirmation check remains. A mismatch displays the
existing inline error without sending the API request. API failures retain the
existing toast behavior and leave the form open so the operator can correct or
retry the submission. The submit button keeps its busy state and prevents
duplicate submission.

No backend endpoint, request body, password policy, or status schema changes.

## Remaining Account Audit

Inspect Sign-in, Two-factor, Recovery, and Passkeys through their real controls.
Limit additional edits to reproducible problems in the following categories:

- hidden or unclear next actions;
- missing labels, focus handling, or keyboard operability;
- destructive actions without adequate confirmation;
- overflow, clipping, or unreadable layouts at mobile width;
- stale sensitive values after a dialog closes.

Do not change unrelated visual tokens, component APIs, routes, or feature
behavior. Any issue requiring broader design or backend work is reported rather
than folded into this phase.

## Verification

Run the SPA typecheck and production build. Against the local running stack,
use ego-browser to verify:

1. The initial Sign-in section has no password inputs and exposes Change
   password.
2. Change password reveals all three fields and focuses Current password.
3. Cancel hides the fields and discards entered values.
4. A confirmation mismatch stays inline and sends no password-update request.
5. Closing and reopening never retains sensitive field values.
6. Existing Two-factor, Recovery, and Passkeys flows still open, close, and
   validate as before.
7. Account navigation and changed layouts remain usable at desktop and mobile
   widths, with no horizontal overflow or clipped controls.

A real successful password update is optional only when it would require
changing the operator's actual credential; in that case, verify the request
path with a deliberately rejected local test credential and report the limit.
