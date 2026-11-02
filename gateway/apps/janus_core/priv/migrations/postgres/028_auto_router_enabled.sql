-- Auto-router existence switch (auto-router-prompt-only spec, release B).
--
-- The gateway now treats `enabled` as the family's existence gate: when it is
-- absent or false, the virtual model is not advertised and a direct call
-- answers 404. The CODE default is false, because a capability must not
-- switch itself on.
--
-- But this family already exists on every deployed fleet, and defaulting it
-- off on upgrade would take a working router out of service — a regression
-- dressed as a safety default. So the migration marks it enabled for exactly
-- the installs that were already routing: those with at least one configured
-- tier member. An install that has never configured this router keeps the
-- code default (off) and is unaffected.
--
-- Additive and idempotent: it only fills a missing key, so re-running it, or
-- running it against a row an operator has already set explicitly, changes
-- nothing.
UPDATE settings
SET value = jsonb_set(value, '{enabled}', 'true'::jsonb, true)
WHERE key = 'auto_router'
  AND jsonb_typeof(value) = 'object'
  AND NOT (value ? 'enabled')
  AND (
      coalesce(jsonb_array_length(value -> 'tiers' -> 'fast'), 0)
    + coalesce(jsonb_array_length(value -> 'tiers' -> 'big'), 0)
    + coalesce(jsonb_array_length(value -> 'tiers' -> 'flagship'), 0)
  ) > 0;