"use client"

import * as React from "react"
import { CheckIcon, ChevronsUpDownIcon, PlusIcon } from "lucide-react"

import { Button } from "@/components/ui/button"
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import { useFieldDescribedBy } from "@/components/ui/field"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { cn } from "@/lib/utils"

/** Group a flat option list under CommandGroup headings (stable order). */
function grouped(options: string[], groupBy?: (v: string) => string) {
  if (!groupBy) return null
  const map = new Map<string, string[]>()
  for (const o of options) {
    const g = groupBy(o) ?? "Other"
    const items = map.get(g)
    if (items) items.push(o)
    else map.set(g, [o])
  }
  return [...map.entries()]
}

/** Single-select combobox (shadcn Popover + Command pattern). With
 * allowCreate, an unmatched query offers `Use "<query>"`. `id` lets a
 * FieldLabel's htmlFor associate with the trigger button. */
export function ComboboxSingle({
  value,
  options,
  onChange,
  placeholder = "Select…",
  allowCreate = false,
  groupBy,
  className,
  id,
  label,
}: {
  value: string | null
  options: string[]
  onChange: (v: string | null) => void
  placeholder?: string
  allowCreate?: boolean
  groupBy?: (v: string) => string
  className?: string
  id?: string
  /** Accessible name for the trigger. Placeholder is the fallback so an
   * external FieldLabel is never required for screen-reader users. */
  label?: string
}) {
  const [open, setOpen] = React.useState(false)
  const [query, setQuery] = React.useState("")
  const listId = React.useId()
  const describedBy = useFieldDescribedBy(undefined, id)
  const groups = grouped(options, groupBy)
  const trimmed = query.trim()
  const exact = trimmed !== "" && options.includes(trimmed)
  // An empty query must not offer `Use ""` — creating an empty option is
  // never meaningful.
  const showCreate = allowCreate && trimmed !== "" && !exact

  const pick = (v: string) => {
    onChange(v)
    setOpen(false)
    setQuery("")
  }

  return (
    <div className={className}>
      <Popover
        open={open}
        onOpenChange={(next) => {
          setOpen(next)
          if (!next) setQuery("")
        }}
      >
        <PopoverTrigger asChild>
          <Button
            id={id}
            type="button"
            variant="outline"
            role="combobox"
            aria-label={label ?? placeholder}
            aria-describedby={describedBy}
            aria-expanded={open}
            aria-haspopup="listbox"
            aria-controls={listId}
            className="w-full justify-between font-normal"
          >
            <span className={cn("truncate", !value && "text-muted-foreground")}>
              {value ?? placeholder}
            </span>
            <ChevronsUpDownIcon className="size-3.5 shrink-0 opacity-50" />
          </Button>
        </PopoverTrigger>
        <PopoverContent className="w-(--radix-popover-trigger-width)" style={{ padding: 0, minWidth: 208, maxWidth: "none" }} align="start" collisionPadding={8}>
          <Command>
            <CommandInput placeholder="Search…" aria-label="Search options" value={query} onValueChange={setQuery} />
            <CommandList id={listId}>
              {showCreate && (
                <CommandGroup>
                  <CommandItem value={`create:${trimmed}`} onSelect={() => pick(trimmed)}>
                    <PlusIcon />
                    <span className="min-w-0 flex-1 truncate">Use &quot;{trimmed}&quot;</span>
                  </CommandItem>
                </CommandGroup>
              )}
              {!showCreate && <CommandEmpty>No matching options.</CommandEmpty>}
              {groups
                ? groups.map(([g, items]) => (
                    <CommandGroup key={g} heading={g}>
                      {items.map((o) => (
                        <CommandItem key={o} value={o} onSelect={() => pick(o)}>
                          <CheckIcon className={cn(value === o ? "opacity-100" : "opacity-0")} />
                          <span className="min-w-0 flex-1 truncate" title={o}>{o}</span>
                        </CommandItem>
                      ))}
                    </CommandGroup>
                  ))
                : options.map((o) => (
                    <CommandItem key={o} value={o} onSelect={() => pick(o)}>
                      <CheckIcon className={cn(value === o ? "opacity-100" : "opacity-0")} />
                      <span className="min-w-0 flex-1 truncate" title={o}>{o}</span>
                    </CommandItem>
                  ))}
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>
    </div>
  )
}
