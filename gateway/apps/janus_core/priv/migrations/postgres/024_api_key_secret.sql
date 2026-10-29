-- Dashboard-only JSEC envelope for recoverable agent-key plaintext.
-- Never catalog-loaded — gateway auth stays hash-only.
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS secret_ciphertext BYTEA;
