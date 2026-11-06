import * as React from "react"

import { cn } from "@/lib/utils"

import { useFieldControlProps } from "@/components/ui/field"

function Textarea({ className, autoComplete = "off", ...props }: React.ComponentProps<"textarea">) {
  const { id, "aria-describedby": describedBy, rest } = useFieldControlProps(props)
  return (
    <textarea
      autoComplete={autoComplete}
      id={id}
      aria-describedby={describedBy}
      // Stable names support native forms and autofill; explicit names win.
      name={rest.name ?? id}
      data-slot="textarea"
      className={cn(
        "border-input placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-ring aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive dark:bg-field-fill flex field-sizing-content min-h-16 w-full rounded-md border bg-transparent px-3 py-2 text-base shadow-xs transition-[color,box-shadow] outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
        className
      )}
      {...rest}
    />
  )
}

export { Textarea }
