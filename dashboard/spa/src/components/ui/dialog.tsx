import * as React from "react"
import { Dialog as DialogPrimitive } from "radix-ui"
import { XIcon } from "lucide-react"

import { cn } from "@/lib/utils"
import { useRestoreFocus } from "@/hooks/use-restore-focus"

/** Radix floating layers (Popover, Select, menus) portal to <body> so their
 * coordinates stay viewport-correct. They are still part of the current
 * dialog workflow, not an outside-dismiss gesture. */
function isFloatingLayer(target: EventTarget | null): boolean {
  return (
    target instanceof Element &&
    Boolean(target.closest("[data-radix-popper-content-wrapper]"))
  )
}

function Dialog({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Root>) {
  return <DialogPrimitive.Root data-slot="dialog" {...props} />
}

function DialogTrigger({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Trigger>) {
  return <DialogPrimitive.Trigger data-slot="dialog-trigger" {...props} />
}

function DialogPortal({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Portal>) {
  return <DialogPrimitive.Portal data-slot="dialog-portal" {...props} />
}

function DialogClose({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Close>) {
  return <DialogPrimitive.Close data-slot="dialog-close" {...props} />
}

const DialogOverlay = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Overlay>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(function DialogOverlay({ className, ...props }, ref) {
  return (
    <DialogPrimitive.Overlay
      ref={ref}
      data-slot="dialog-overlay"
      className={cn(
        "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/50",
        className
      )}
      {...props}
    />
  )
})
DialogOverlay.displayName = "DialogOverlay"

const DialogContent = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content> & {
    showCloseButton?: boolean
    /** Adapter kept from the Arc call sites: header fields as props. */
    title?: string
    description?: React.ReactNode
    /** Adapter: sm (default 512) / md (560) / lg (768) widths. */
    size?: "sm" | "md" | "lg"
  }
>(function DialogContent({
  className,
  children,
  showCloseButton = true,
  title,
  description,
  size,
  onPointerDownOutside,
  onFocusOutside,
  onInteractOutside,
  ...props
}, ref) {
  useRestoreFocus()
  return (
    <DialogPortal data-slot="dialog-portal">
      <DialogOverlay />
      <DialogPrimitive.Content
        ref={ref}
        data-slot="dialog-content"
        className={cn(
          "bg-background data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 fixed top-[50%] left-[50%] z-50 grid max-h-[calc(100dvh-2rem)] w-full max-w-[calc(100%-2rem)] translate-x-[-50%] translate-y-[-50%] gap-4 overflow-y-auto overscroll-contain rounded-lg border [--dialog-close-inset:0.75rem] [--dialog-close-size:2rem] [--dialog-pad:1rem] p-(--dialog-pad) shadow-lg duration-200 sm:max-w-lg sm:[--dialog-pad:1.5rem]",
          // A sticky footer owns its bottom padding and sits flush with the
          // content edge; its responsive margins mirror --dialog-pad above.
          "has-[[data-slot=dialog-footer]]:pb-0",
          showCloseButton &&
            "[--dialog-close-gutter:calc(var(--dialog-close-size)+var(--dialog-close-inset)-var(--dialog-pad))]",
          size === "md" && "sm:max-w-[560px]",
          size === "lg" && "sm:max-w-[768px]",
          className
        )}
        onPointerDownOutside={(event) => {
          if (isFloatingLayer(event.target)) {
            event.preventDefault()
            return
          }
          onPointerDownOutside?.(event)
        }}
        onFocusOutside={(event) => {
          if (isFloatingLayer(event.target)) {
            event.preventDefault()
            return
          }
          onFocusOutside?.(event)
        }}
        onInteractOutside={(event) => {
          if (isFloatingLayer(event.target)) {
            event.preventDefault()
            return
          }
          onInteractOutside?.(event)
        }}
        {...props}
      >
        {(title || description) && (
          <DialogHeader>
            {title && <DialogTitle>{title}</DialogTitle>}
            {description && <DialogDescription>{description}</DialogDescription>}
          </DialogHeader>
        )}
        {children}
        {/* The header gutter derives from the same close-button geometry variables. */}
        {showCloseButton && (
          <DialogPrimitive.Close
            data-slot="dialog-close"
            className="ring-offset-background focus:ring-ring data-[state=open]:bg-accent data-[state=open]:text-muted-foreground absolute top-(--dialog-close-inset) right-(--dialog-close-inset) flex size-(--dialog-close-size) cursor-pointer items-center justify-center rounded-md opacity-70 transition-opacity hover:opacity-100 focus:ring-2 focus:ring-offset-2 focus:outline-hidden disabled:pointer-events-none [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4"
          >
            <XIcon />
            <span className="sr-only">Close</span>
          </DialogPrimitive.Close>
        )}
      </DialogPrimitive.Content>
    </DialogPortal>
  )
})
DialogContent.displayName = "DialogContent"

function DialogHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-header"
      className={cn(
        "flex flex-col gap-2 px-(--dialog-close-gutter,0px) text-center sm:pl-0 sm:text-left",
        className,
      )}
      {...props}
    />
  )
}

function DialogFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-footer"
      className={cn(
        "sticky bottom-0 z-10 -mx-[var(--dialog-pad)] mt-2 flex flex-col-reverse gap-2 border-t bg-background px-(--dialog-pad) pt-4 pb-(--dialog-pad) sm:flex-row sm:justify-end",
        className,
      )}
      {...props}
    />
  )
}

function DialogTitle({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Title>) {
  return (
    <DialogPrimitive.Title
      data-slot="dialog-title"
      className={cn("text-lg leading-none font-semibold", className)}
      {...props}
    />
  )
}

function DialogDescription({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Description>) {
  return (
    <DialogPrimitive.Description asChild>
      <div data-slot="dialog-description" className={cn("text-muted-foreground text-sm", className)} {...props} />
    </DialogPrimitive.Description>
  )
}

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogOverlay,
  DialogPortal,
  DialogTitle,
  DialogTrigger,
}
