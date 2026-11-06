/** Clipboard write with an execCommand fallback.
 *
 * The Clipboard API is unavailable in non-secure contexts (plain-HTTP dev
 * origins, embedded webviews) and can be denied even when present
 * (NotAllowedError). Callers that wrote `await navigator.clipboard.writeText`
 * directly silently lost the copy in exactly those cases, so every copy site
 * in the console goes through this helper instead.
 */
export async function copyText(text: string): Promise<void> {
  // An empty value would silently clear the clipboard on the API path while
  // the fallback path reports a misleading "denied" error — reject up front.
  if (typeof text !== "string" || text === "") {
    // Call sites feed values from untyped api<T = any> responses; a missing
    // field would otherwise be coerced to the literal "undefined" and copied.
    throw new Error("nothing to copy — the value is missing or empty")
  }
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return
    } catch (apiError) {
      // Keep the real cause diagnosable (NotAllowedError vs SecurityError vs
      // missing API) without surfacing raw browser text to the operator.
      console.debug("[clipboard] Clipboard API rejected, trying fallback", apiError)
    }
  }
  const prevFocus =
    document.activeElement instanceof HTMLElement ? document.activeElement : null
  const ta = document.createElement("textarea")
  ta.value = text
  ta.setAttribute("readonly", "")
  ta.style.position = "fixed"
  ta.style.left = "-9999px"
  // iOS Safari zooms the visual viewport when focusing a control below 16px;
  // the helper must not move the operator's viewport mid-copy.
  ta.style.fontSize = "16px"
  // Mount inside an open dialog when possible: Radix's focus trap pulls focus
  // back into the dialog on `focusin` if the active element is outside its
  // content node, which would leave the textarea unselected and the
  // execCommand copy empty — precisely in the modals where the Clipboard API
  // is most likely denied (e.g. the "key created" reveal dialog).
  // Safari does not focus a <button> on pointer click, so activeElement can
  // be <body> while a modal is open; fall back to the open dialog itself.
  // querySelectorAll + last: Radix portals append in mount order, so the LAST
  // open dialog is the topmost one — the first match would be the outermost.
  const openDialogs = document.querySelectorAll<HTMLElement>(
    '[role="dialog"][data-state="open"], [role="alertdialog"][data-state="open"]',
  )
  const openDialog = openDialogs[openDialogs.length - 1] ?? null
  const host =
    prevFocus?.closest('[role="dialog"], [role="alertdialog"]') ??
    openDialog ??
    document.body
  try {
    try {
      host.appendChild(ta)
      ta.focus({ preventScroll: true })
      // iOS Safari cannot select inside a readonly textarea (readonly exists
      // to suppress the on-screen keyboard), so lift it for the selection and
      // restore it before execCommand reads the control's selection. A
      // document Range would NOT work here: ta.value sets the dirty value and
      // creates no text node, so selectNodeContents yields an empty range.
      ta.readOnly = false
      ta.setSelectionRange(0, ta.value.length)
      ta.readOnly = true
    } catch {
      throw new Error(
        "copy to clipboard failed — the browser denied or lacks clipboard access",
      )
    }
    // execCommand is deprecated and absent in some embedders; feature-detect
    // so the failure message stays actionable instead of a TypeError.
    let copied = false
    try {
      // execCommand may THROW (SecurityError in sandboxed frames) rather than
      // return false; treat a throw as "not copied" so the friendly message
      // survives instead of raw browser text reaching the operator.
      copied =
        typeof document.execCommand === "function" &&
        document.execCommand("copy")
    } catch {
      copied = false
    }
    if (!copied) {
      // Covers both "no clipboard support here" and "the Clipboard API was
      // denied and the legacy fallback also failed" — one honest message.
      throw new Error(
        "copy to clipboard failed — the browser denied or lacks clipboard access",
      )
    }
  } finally {
    ta.remove()
    // The textarea stole focus from the trigger (a copy button in a table,
    // say); without restoring it a keyboard user's next Tab restarts from
    // the top of the page.
    prevFocus?.focus({ preventScroll: true })
  }
}
