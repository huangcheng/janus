import {
  createContext,
  forwardRef,
  useCallback,
  useContext,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentProps,
  type MutableRefObject,
} from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "@/lib/utils"

import { Label } from "@/components/ui/label"

/** What a <Field> publishes to the controls and messages inside it.
 *
 *  The association between a control and the field's error / helper messages
 *  is built DECLARATIVELY: FieldError and FieldDescription register their ids,
 *  FieldLabel registers the controls it names via htmlFor, and each control
 *  merges those ids into its own aria-describedby at render time. No DOM
 *  probing, no observers — the attribute is always exactly what React
 *  rendered. */
type FieldContextValue = {
  /** Messages from enclosing group-level fields (a Field whose labels name no
   *  single control). These describe the whole group, nested fields included,
   *  so every control merges them unconditionally. */
  groupIds: readonly string[]
  /** This field's own error + description ids, announced only on the control
   *  its labels name (or on all controls when no label names one). */
  scopedIds: readonly string[]
  /** Ids named by this field's FieldLabels via htmlFor. When non-empty, only
   *  those controls announce the field's scoped messages; when empty
   *  (checkbox/radio groups, where the label wraps its controls) every
   *  control does. Contract: a labelled control must live directly inside its
   *  Field (a control inside a NESTED Field is announced by that field's own
   *  group-level messages instead). */
  labelledIds: ReadonlySet<string>
  registerError: (id: string) => void
  unregisterError: (id: string) => void
  registerDescription: (id: string) => void
  unregisterDescription: (id: string) => void
  /** Controls report their own id (DEV only) so a FieldLabel whose htmlFor
   *  matches nothing rendered (typo, or a control that does not forward id)
   *  can be flagged by the dev warning. Production deliberately does NOT
   *  fall back to broadcasting: an unmatched label leaves its message
   *  unassociated rather than announcing it on unrelated controls. */
  registerControl: (id: string) => void
  unregisterControl: (id: string) => void
  /** Owner-token based so several labels in one field cannot clobber each
   *  other and unmounting one does not clear another's association. */
  setLabelled: (forId: string | null, owner: object, remove?: boolean) => void
}

/** Shared control-side wiring: merge the enclosing Field's error and
 *  description ids into the control's own aria-describedby, keeping any
 *  explicit association. */
export function useFieldControlProps<
  P extends { id?: string; "aria-describedby"?: string },
>(props: P) {
  const { id, "aria-describedby": describedBy, ...rest } = props
  const describedByMerged = useFieldDescribedBy(describedBy, id)
  return { id, "aria-describedby": describedByMerged, rest }
}

const FieldContext = createContext<FieldContextValue | null>(null)

/** "Does this message render anything" for components that ALWAYS render
 *  their element (FieldDescription): falsy-but-renderable values (0, arrays)
 *  count as content; undefined/null/false/true/"" do not. Components with a
 *  null render guard (FieldError) mirror that guard instead (Boolean(content))
 *  — the invariant is "visibility == what actually renders", one rule per
 *  render strategy, both kept next to their guard. */
function hasFieldMessageContent(children: unknown): boolean {
  // Arrays (multiple sibling expressions) count only if some element renders.
  if (Array.isArray(children)) return children.some(hasFieldMessageContent)
  // Whitespace-only strings render a visually empty message, so they must not
  // register an id that aria-describedby then points at.
  if (typeof children === "string") return children.trim() !== ""
  return (
    children !== undefined &&
    children !== null &&
    children !== false &&
    children !== true &&
    children !== ""
  )
}

/** Shared by FieldError and FieldDescription: generate/accept an id and
 *  register it with the enclosing Field only while the message renders.
 *  The effect depends on the STABLE callbacks, never the context object —
 *  its identity changes on every registration and would loop. */
function useFieldMessageId(
  callerId: string | undefined,
  register: ((id: string) => void) | undefined,
  unregister: ((id: string) => void) | undefined,
  visible: boolean,
): string {
  const generatedId = useId()
  // `??` would let an empty-string caller id through and produce a malformed
  // aria-describedby token; treat "" like "absent".
  const id = callerId || generatedId
  useLayoutEffect(() => {
    if (!register || !unregister || !visible) return
    register(id)
    return () => unregister(id)
  }, [register, unregister, id, visible])
  return id
}

/** Ref-counted id registry shared by the error and description paths.
 *  Counting (not a bare Set) keeps an id announced while ANY message using it
 *  is still rendered, even if two messages share a caller-supplied id. */
function useIdRegistry(): [
  readonly string[],
  (id: string) => void,
  (id: string) => void,
] {
  const [ids, setIds] = useState<readonly string[]>([])
  const counts = useRef(new Map<string, number>())
  const register = useCallback((id: string) => {
    const n = (counts.current.get(id) ?? 0) + 1
    counts.current.set(id, n)
    // Publish only on the 0->1 transition: shared ids and StrictMode's
    // mount/cleanup/mount cycle must not re-render the whole field subtree.
    if (n === 1) setIds([...counts.current.keys()])
  }, [])
  const unregister = useCallback((id: string) => {
    if (!counts.current.has(id)) return
    const n = (counts.current.get(id) ?? 0) - 1
    if (n <= 0) {
      counts.current.delete(id)
      setIds([...counts.current.keys()])
    } else {
      counts.current.set(id, n)
    }
  }, [])
  return [ids, register, unregister]
}

/** Merge a control's own aria-describedby with the enclosing Field's error
 *  and description ids. Returns undefined when there is nothing to describe,
 *  so the attribute is omitted rather than rendered empty. */
export function useFieldDescribedBy(
  explicit: string | undefined,
  id: string | undefined,
): string | undefined {
  const field = useContext(FieldContext)
  const registerControl = field?.registerControl
  const unregisterControl = field?.unregisterControl
  useLayoutEffect(() => {
    if (!registerControl || !unregisterControl || id === undefined) return
    registerControl(id)
    return () => unregisterControl(id)
  }, [registerControl, unregisterControl, id])
  const ids = explicit ? explicit.split(/\s+/).filter(Boolean) : []
  if (field) {
    for (const extra of field.groupIds) {
      if (!ids.includes(extra)) ids.push(extra)
    }
    const targeted =
      field.labelledIds.size === 0 ||
      (id !== undefined && field.labelledIds.has(id))
    if (targeted) {
      for (const extra of field.scopedIds) {
        if (!ids.includes(extra)) ids.push(extra)
      }
    }
  }
  return ids.length ? ids.join(" ") : undefined
}

function FieldGroup({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="field-group"
      className={cn(
        "group/field-group @container/field-group flex w-full flex-col gap-7 data-[slot=checkbox-group]:gap-3 [&>[data-slot=field-group]]:gap-4",
        className
      )}
      {...props}
    />
  )
}

const fieldVariants = cva(
  "group/field flex w-full gap-3 data-[invalid=true]:text-destructive",
  {
    variants: {
      orientation: {
        vertical: ["flex-col [&>*]:w-full [&>.sr-only]:w-auto"],
        horizontal: [
          "flex-row items-center",
          "[&>[data-slot=field-label]]:flex-auto",
          "has-[>[data-slot=field-content]]:items-start has-[>[data-slot=field-content]]:[&>[role=checkbox],[role=radio]]:mt-px",
        ],
        responsive: [
          "flex-col @md/field-group:flex-row @md/field-group:items-center [&>*]:w-full @md/field-group:[&>*]:w-auto [&>.sr-only]:w-auto",
          "@md/field-group:[&>[data-slot=field-label]]:flex-auto",
          "@md/field-group:has-[>[data-slot=field-content]]:items-start @md/field-group:has-[>[data-slot=field-content]]:[&>[role=checkbox],[role=radio]]:mt-px",
        ],
      },
    },
    defaultVariants: {
      orientation: "vertical",
    },
  }
)

const Field = forwardRef<
  HTMLDivElement,
  ComponentProps<"div"> & VariantProps<typeof fieldVariants>
>(function Field(
  { className, orientation = "vertical", children, ...props },
  forwardedRef,
) {
  // Merged callback ref: the DEV diagnostic needs the DOM root, and a
  // caller-supplied ref must keep working (forwardRef delivers it for real).
  const internalRef = useRef<HTMLDivElement | null>(null)
  const setRefs = useCallback(
    (node: HTMLDivElement | null) => {
      internalRef.current = node
      if (typeof forwardedRef === "function") forwardedRef(node)
      else if (forwardedRef)
        (forwardedRef as MutableRefObject<HTMLDivElement | null>).current =
          node
    },
    [forwardedRef],
  )
  const parent = useContext(FieldContext)
  const [errorIds, registerError, unregisterError] = useIdRegistry()
  const [descriptionIds, registerDescription, unregisterDescription] =
    useIdRegistry()
  const [labelledIds, setLabelledIds] = useState<ReadonlySet<string>>(
    () => new Set(),
  )
  // DEV-only diagnostic registry: production mounts pay no state updates.
  const [controlIds, setControlIds] = useState<ReadonlySet<string>>(
    () => new Set(),
  )
  const labelOwners = useRef(new Map<object, string | null>())
  const controlSet = useRef(new Set<string>())

  const registerControl = useCallback((id: string) => {
    if (!import.meta.env.DEV) return
    if (controlSet.current.has(id)) return
    controlSet.current.add(id)
    setControlIds(new Set(controlSet.current))
  }, [])
  const unregisterControl = useCallback((id: string) => {
    if (!import.meta.env.DEV) return
    if (!controlSet.current.delete(id)) return
    setControlIds(new Set(controlSet.current))
  }, [])

  const publishLabelled = useCallback(
    (forId: string | null, owner: object, remove = false) => {
      if (remove) labelOwners.current.delete(owner)
      else labelOwners.current.set(owner, forId)
      const next = new Set<string>()
      for (const v of labelOwners.current.values()) {
        if (v) next.add(v)
      }
      // Bail out when the contents are unchanged: labels without htmlFor
      // publish null on every mount, and a fresh Set identity would schedule a
      // needless re-render of the whole (context-consuming) field subtree.
      setLabelledIds((prev) => {
        if (prev.size === next.size) {
          let same = true
          for (const v of next) {
            if (!prev.has(v)) {
              same = false
              break
            }
          }
          if (same) return prev
        }
        return next
      })
    },
    [],
  )

  const ownIds = useMemo(
    () => [...errorIds, ...descriptionIds],
    [errorIds, descriptionIds],
  )

  // Group-level ids: this field's own messages when NO label names a single
  // control (they describe the group, nested fields included), plus everything
  // an enclosing group-level field already published. A label whose htmlFor
  // matches no rendered control is a call-site bug: the DEV warning below
  // flags it, and production deliberately does NOT broadcast (that would
  // announce the message on unrelated controls).
  const parentGroupIds = parent?.groupIds
  const groupIds = useMemo(() => {
    const own = labelledIds.size === 0 ? ownIds : []
    const inherited = parentGroupIds ?? []
    if (own.length === 0) return inherited
    return [...inherited, ...own.filter((id) => !inherited.includes(id))]
  }, [parentGroupIds, labelledIds.size, ownIds])

  // Scoped ids: this field's messages when a label names a control; nested
  // fields never inherit another field's scoped messages.
  const scopedIds = useMemo(
    () => (labelledIds.size > 0 ? ownIds : []),
    [labelledIds.size, ownIds],
  )

  // Dev-only diagnostic: a FieldLabel whose htmlFor matches no rendered
  // control silently loses its association. Warn after registrations settle.
  useLayoutEffect(() => {
    if (!import.meta.env.DEV || labelledIds.size === 0) return
    // Defer: a labelled control behind a loading branch registers in a later
    // commit, and warning in the same tick would be a false positive.
    const root = internalRef.current
    const t = setTimeout(() => {
      for (const id of labelledIds) {
        // A control registered with THIS field is fine. So is one rendered
        // inside a nested <Field> (it registers with the inner field and the
        // outer label's message is delivered there via group composition) —
        // resolve in the DOM subtree to avoid warning on that valid setup.
        const inRegistry = controlIds.has(id)
        const inSubtree = root?.querySelector(`#${CSS.escape(id)}`) != null
        if (!inRegistry && !inSubtree) {
          console.warn(
            `<Field> label htmlFor="${id}" matches no rendered control; ` +
              "its error/description will not be announced. Fix the htmlFor " +
              "or give the control an id.",
          )
        }
      }
    }, 0)
    return () => clearTimeout(t)
  }, [labelledIds, controlIds])

  const ctx = useMemo(
    () => ({
      groupIds,
      scopedIds,
      labelledIds,
      registerError,
      unregisterError,
      registerDescription,
      unregisterDescription,
      registerControl,
      unregisterControl,
      setLabelled: publishLabelled,
    }),
    [
      groupIds,
      scopedIds,
      labelledIds,
      registerError,
      unregisterError,
      registerDescription,
      unregisterDescription,
      registerControl,
      unregisterControl,
      publishLabelled,
    ],
  )

  return (
    <FieldContext.Provider value={ctx}>
      <div
        ref={setRefs}
        role="group"
        data-slot="field"
        data-orientation={orientation}
        className={cn(fieldVariants({ orientation }), className)}
        {...props}
      >
        {children}
      </div>
    </FieldContext.Provider>
  )
})
Field.displayName = "Field"

function FieldLabel({ className, ...props }: ComponentProps<typeof Label>) {
  const field = useContext(FieldContext)
  const htmlFor = props.htmlFor ?? null
  // Lazy state, not a render-phase mutation: the token only needs a stable
  // identity for the label-ownership map.
  const [owner] = useState<object>(() => ({}))
  // Publish which control this label names, so the error association can be
  // scoped to it (and so wrapped checkbox/radio groups, which have no htmlFor,
  // associate with every control instead). Depends on the STABLE setter, not
  // the context object (see FieldError for why).
  const setLabelled = field?.setLabelled
  useLayoutEffect(() => {
    if (!setLabelled) return
    const token = owner
    setLabelled(htmlFor, token)
    return () => setLabelled(null, token, true)
  }, [setLabelled, htmlFor])
  return (
    <Label
      data-slot="field-label"
      className={cn(
        "group/field-label peer/field-label flex w-fit gap-2 leading-snug group-data-[disabled=true]/field:opacity-50",
        "has-[>[data-slot=field]]:w-full has-[>[data-slot=field]]:flex-col has-[>[data-slot=field]]:rounded-md has-[>[data-slot=field]]:border [&>*]:data-[slot=field]:p-4",
        "has-data-[state=checked]:border-primary has-data-[state=checked]:bg-primary/5 dark:has-data-[state=checked]:bg-primary/10",
        className
      )}
      {...props}
    />
  )
}

function FieldDescription({ className, ...props }: ComponentProps<"p">) {
  const field = useContext(FieldContext)
  // Helper text is part of the control's accessible description; register it
  // alongside errors so useFieldDescribedBy merges it onto the control.
  // Mirror FieldError: a conditionally empty description must not register
  // an id that points at an empty <p>.
  const id = useFieldMessageId(
    props.id,
    field?.registerDescription,
    field?.unregisterDescription,
    hasFieldMessageContent(props.children),
  )
  return (
    <p
      data-slot="field-description"
      className={cn(
        "text-sm leading-normal font-normal text-muted-foreground group-has-[[data-orientation=horizontal]]/field:text-balance",
        "last:mt-0 nth-last-2:-mt-1 [[data-variant=legend]+&]:-mt-1.5",
        "[&>a]:underline [&>a]:underline-offset-4 [&>a:hover]:text-primary",
        className
      )}
      {...props}
      // After the spread: an explicitly-undefined caller id must not dangle
      // the association the enclosing Field maintains.
      id={id}
    />
  )
}

function FieldError({
  className,
  children,
  errors,
  ...props
}: ComponentProps<"div"> & {
  errors?: Array<{ message?: string } | undefined>
}) {
  const field = useContext(FieldContext)
  const content = useMemo(() => {
    if (children) {
      return children
    }

    if (!errors?.length) {
      return null
    }

    const uniqueErrors = [
      ...new Map(errors.map((error) => [error?.message, error])).values(),
    ]

    if (uniqueErrors?.length == 1) {
      return uniqueErrors[0]?.message
    }

    return (
      <ul className="ml-4 flex list-disc flex-col gap-1">
        {uniqueErrors.map(
          (error, index) =>
            error?.message && <li key={index}>{error.message}</li>
        )}
      </ul>
    )
  }, [children, errors])

  // Register only while this error actually renders: an empty FieldError
  // returns null below, and wiring a dangling id would point
  // aria-describedby at nothing. Truthiness, not a null check: `{cond &&
  // "msg"}` yields `false`, which the render guard treats as "nothing to show".
  const id = useFieldMessageId(
    props.id,
    field?.registerError,
    field?.unregisterError,
    // Mirrors this component's render guard (`if (!content) return null`):
    // falsy content renders nothing, so nothing may be registered.
    Boolean(content),
  )

  if (!content) {
    return null
  }

  return (
    <div
      role="alert"
      data-slot="field-error"
      className={cn("text-sm font-normal text-destructive", className)}
      {...props}
      // After the spread: a caller-supplied `id` must not be detached from the
      // association the enclosing Field maintains.
      id={id}
    >
      {content}
    </div>
  )
}

function FieldFooter({ className, ...props }: ComponentProps<"div">) {
  return (
    <div
      data-slot="field-footer"
      className={cn("flex items-center justify-end gap-2", className)}
      {...props}
    />
  )
}

export {
  Field,
  FieldLabel,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldFooter,
}
