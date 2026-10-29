import { useLayoutEffect } from "react"

/** Radix only returns focus on close to a registered Trigger; dialogs opened
 * programmatically (controlled `open` state, no Trigger) strand keyboard focus
 * on <body> when the content unmounts. Capture the element focused at mount
 * and return focus to it on unmount — unless focus already moved somewhere
 * deliberate (connected and outside any closing modal). */
export function useRestoreFocus() {
  useLayoutEffect(() => {
    const previous = document.activeElement
    return () => {
      const active = document.activeElement
      if (!(previous instanceof HTMLElement) || previous === document.body || !previous.isConnected) return
      const stranded =
        active === document.body ||
        active?.closest(
          "[data-slot='dialog-content'], [data-slot='alert-dialog-content'], [data-slot='sheet-content']"
        )
      if (stranded) previous.focus({ preventScroll: true })
    }
  }, [])
}
