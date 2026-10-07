-- OpenAI Decisions face (spec 2026-10-07, D2/D6): extend the providers
-- protocol enum with 'openai_decisions'. One protocol per provider row
-- stays (D6); the CHECK only constrains future INSERTs/UPDATEs — old
-- beams without the normalize_protocol clause skip such rows on read
-- (fail closed via the catch-all {error, unknown_protocol}).
ALTER TABLE providers DROP CONSTRAINT IF EXISTS providers_protocol_check;
ALTER TABLE providers ADD CONSTRAINT providers_protocol_check
    CHECK (protocol IN ('openai_chat', 'anthropic_messages', 'openai_responses', 'openai_decisions'));
