import * as React from "react"

import { cn } from "@/lib/utils"

import { useFieldControlProps } from "@/components/ui/field"

const Input = React.forwardRef<
  HTMLInputElement,
  React.ComponentProps<"input">
>(function Input(
  { className, type, autoComplete = "off", ...props },
  ref,
) {
  const { id, "aria-describedby": describedBy, rest } = useFieldControlProps(props)
  return (
    <input
      ref={ref}
      type={type}
      autoComplete={autoComplete}
      // Stable names support native forms and password managers; explicit names win.
      name={rest.name ?? id}
      id={id}
      aria-describedby={describedBy}
      data-slot="input"
      className={cn(
        "file:text-foreground placeholder:text-muted-foreground selection:bg-primary selection:text-primary-foreground dark:bg-field-fill border-input h-9 w-full min-w-0 rounded-md border bg-transparent px-3 py-1 text-base shadow-xs transition-[color,box-shadow] outline-none file:inline-flex file:h-7 file:border-0 file:bg-transparent file:text-sm file:font-medium disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
        "focus-visible:border-ring focus-visible:ring-ring focus-visible:ring-[3px]",
        "aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive",
        className
      )}
      {...rest}
    />
  )
})
Input.displayName = "Input"

export { Input }
