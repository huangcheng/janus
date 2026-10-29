"use client"

import * as React from "react"
import { CheckIcon, ChevronDownIcon, ChevronsUpDownIcon, ChevronUpIcon, PlusIcon, XIcon } from "lucide-react"

import { Button, buttonVariants } from "@/components/ui/button"
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
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
  const groups = grouped(options, groupBy)
  const trimmed = query.trim()
  const exact = trimmed !== "" && options.includes(trimmed)
  // An empty query must not offer `Use ""` (mirrors ComboboxMulti below).
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

/** Multi-select combobox: selected values render as removable chips
 * INSIDE the trigger (Ant Design / shadcn multiple pattern) — the
 * trigger grows with its content; the popover stays open while
 * toggling. The trigger is a div (chips hold their own buttons, so a
 * <button> wrapper would be invalid nesting); keyboard open/close is
 * wired by hand below, and the trigger takes aria-label because a
 * <label htmlFor> cannot associate with a non-labelable element. */
export function ComboboxMulti({
  selected,
  options,
  onToggle,
  onMove,
  placeholder = "Add…",
  allowCreate = false,
  className,
  label,
}: {
  selected: string[]
  options: string[]
  onToggle: (v: string) => void
  /** Optional per-chip up/down move buttons. When provided, order is
   * meaningful (the caller owns the positional semantics, e.g. failover
   * walk order on the Router page). Absent = plain multi-select. */
  onMove?: (v: string, dir: -1 | 1) => void
  placeholder?: string
  allowCreate?: boolean
  className?: string
  /** Accessible name for the trigger (a div can't take htmlFor). */
  label?: string
}) {
  const [open, setOpen] = React.useState(false)
  const [query, setQuery] = React.useState("")
  const listId = React.useId()
  const trimmed = query.trim()
  const exact = trimmed !== "" && options.includes(trimmed)
  const showCreate = allowCreate && trimmed !== "" && !exact

  const addCustom = () => {
    onToggle(trimmed)
    setQuery("")
  }

  // Keyboard: Enter/Space/ArrowDown toggle the popover — a div never
  // synthesizes click from keys, and Radix only wires onClick. Events
  // from the nested chip-remove buttons are ignored (their own click
  // handles them; a bubbling Enter must not also toggle the popover).
  const onTriggerKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget) return
    if (e.key === "Enter" || e.key === " " || e.key === "ArrowDown") {
      e.preventDefault()
      setOpen((o) => !o)
    }
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
          <div
            role="combobox"
            aria-label={label ?? placeholder}
            aria-expanded={open}
            aria-haspopup="listbox"
            aria-controls={listId}
            tabIndex={0}
            onKeyDown={onTriggerKeyDown}
            className={cn(
              buttonVariants({ variant: "outline" }),
              // h-auto overrides the variant's fixed h-9 — the trigger
              // must grow as chips wrap to more lines.
              "h-auto min-h-9 w-full cursor-text flex-wrap items-center justify-start gap-1 py-1.5 font-normal"
            )}
          >
            {selected.length === 0 && (
              <span className="text-muted-foreground">{placeholder}</span>
            )}
            {selected.map((n, i) => (
              <span
                key={n}
                className="inline-flex max-w-full items-center gap-1 rounded bg-primary/10 px-1.5 py-0.5 font-mono text-[11px]"
              >
                <span className="truncate">{n}</span>
                {onMove && (
                  <>
                    <button
                      type="button"
                      aria-label={`Move ${n} up`}
                      disabled={i === 0}
                      className="-m-0.5 shrink-0 rounded p-0.5 opacity-60 hover:opacity-100 disabled:opacity-20"
                      onClick={(e) => {
                        e.stopPropagation()
                        onMove(n, -1)
                      }}
                    >
                      <ChevronUpIcon className="size-3" />
                    </button>
                    <button
                      type="button"
                      aria-label={`Move ${n} down`}
                      disabled={i === selected.length - 1}
                      className="-m-0.5 shrink-0 rounded p-0.5 opacity-60 hover:opacity-100 disabled:opacity-20"
                      onClick={(e) => {
                        e.stopPropagation()
                        onMove(n, 1)
                      }}
                    >
                      <ChevronDownIcon className="size-3" />
                    </button>
                  </>
                )}
                <button
                  type="button"
                  aria-label={`Remove ${n}`}
                  className="-m-0.5 shrink-0 rounded p-0.5 opacity-60 hover:opacity-100"
                  onClick={(e) => {
                    e.stopPropagation()
                    onToggle(n)
                  }}
                >
                  <XIcon className="size-3" />
                </button>
              </span>
            ))}
            <ChevronsUpDownIcon className="ml-auto size-3.5 shrink-0 opacity-50" />
          </div>
        </PopoverTrigger>
        <PopoverContent className="w-(--radix-popover-trigger-width)" style={{ padding: 0, minWidth: 208, maxWidth: "none" }} align="start" collisionPadding={8}>
          <Command>
            <CommandInput placeholder="Search…" aria-label="Search options" value={query} onValueChange={setQuery} />
            <CommandList id={listId}>
              {showCreate && (
                <CommandGroup>
                  <CommandItem value={`add:${trimmed}`} onSelect={addCustom}>
                    <PlusIcon />
                    <span className="min-w-0 flex-1 truncate">Add &quot;{trimmed}&quot;</span>
                  </CommandItem>
                </CommandGroup>
              )}
              {!showCreate && <CommandEmpty>No matching options.</CommandEmpty>}
              {options.map((o) => {
                const on = selected.includes(o)
                return (
                  <CommandItem key={o} value={o} onSelect={() => onToggle(o)}>
                    <span
                      className={cn(
                        "flex size-4 shrink-0 items-center justify-center rounded-[4px] border",
                        on ? "border-primary bg-primary text-primary-foreground" : "opacity-50"
                      )}
                    >
                      {on && <CheckIcon className="size-3" />}
                    </span>
                    <span className="min-w-0 flex-1 truncate" title={o}>{o}</span>
                  </CommandItem>
                )
              })}
            </CommandList>
          </Command>
        </PopoverContent>
      </Popover>
    </div>
  )
}
