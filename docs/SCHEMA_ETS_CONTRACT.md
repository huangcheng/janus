# schema-ets agent contract (do not invent forks)

## Locked decisions
- Agent keys: **HMAC-SHA256 + pepper** (`JANUS_API_KEY_PEPPER`), constant-time compare, store hash + prefix.
- Secrets at rest: **AES-256-GCM**, envelope includes **`key_id`**; `JANUS_SECRETS_KEY` (or keyring map); missing key = boot fail.
- JSON: **thoas** (not jsx). Hot path: catalog ETS / `persistent_term` only.
- Multi-node: shared **Postgres** only; SQLite = single node (refuse multi-node SQLite).
- No Erlang distribution / master-slave LB sync. LB state is **node-local**.

## Tables
- `config_meta` — `config_generation BIGINT NOT NULL` (single row, CAS target)
- `api_keys` — `id`, `prefix`, `key_hash`, `enabled`, `created_at`, `rpm_limit` (nullable INT, mig 014), `tpm_limit` (nullable INT, mig 014), `daily_token_limit` (nullable, mig 014); NULL = unlimited
- `api_key_models` — `api_key_id`, `model_id` (allowlist join)
- `providers` — `id`, `name`, `base_url`, `protocol` (`openai_chat`|`anthropic_messages`|`openai_responses`|`openai_decisions`), `enabled`, `region_tag` (nullable TEXT, mig 015), `affinity_node` (nullable TEXT, mig 015)
- `worker_sticky_drained` — `node_name` (PK), `drained_at` (mig 016; master-only ops table — sticky-only drain marker per worker node)
- `provider_keys` — `id`, `provider_id`, `secret_ciphertext`, `key_id`, `weight`, `enabled`
- `models` — `id`, `name` (agent-facing model id), `enabled`
- `model_routes` — `model_id`, `provider_id`, `upstream_model_id` (nullable alias), `weight`, `priority`, `enabled`
- `usage_events` — `id`, `ts`, `agent_key_id` (nullable, FK SET NULL), `model_id` (nullable, FK SET NULL), `provider_id` (nullable, FK SET NULL), `provider_key_id` (nullable, FK SET NULL), `protocol`, `stream` (SMALLINT 0/1), `status` (HTTP status INTEGER), `prompt_tokens` (nullable), `completion_tokens` (nullable), `latency_ms` (nullable), `error_code` (nullable), `attempt`, `request_ref` (nullable), `is_terminal`, `request_id` (nullable), `modality` (nullable TEXT, mig 010), `units` (nullable NUMERIC, mig 010), `outcome` (nullable TEXT — lifecycle/result tag, **not** HTTP status; mig 010), `cache_read_input_tokens` (nullable, mig 012)
- `video_jobs` — `jvid` (PK), `provider_id`, `upstream_id`, `status`, `created_ts` (mig 011; async video lifecycle)

## ETS tables
- `janus_metrics` — named **public set** (`write_concurrency` + `read_concurrency`), created by `janus_metrics:init/0` from the `janus_http` app master at boot; init is idempotent and failure is logged, never fatal. Keys: `{counter, Name, Labels}` / `{hist, Name, Labels, LeBin}` / `{hist_sum_us, Name, Labels}` (integer µs) / `{hist_count, Name, Labels}`; `Labels` = sorted `[{K, V}]` binaries. All writes are `ets:update_counter/4` with a default tuple (atomic create-and-bump); readers `tab2list` via `snapshot/0`. Label values only from closed enums + operator-defined provider names — never request ids, key ids, or model names.

## Module APIs

### `janus_db` behaviour
```erlang
-callback start_link(Opts :: map()) -> {ok, pid()} | {error, term()}.
-callback migrate(Conn) -> ok | {error, term()}.
-callback query(Conn, Sql :: iodata(), Params :: [term()]) -> {ok, Rows} | {error, term()}.
-callback with_tx(Conn, fun((Conn) -> Result)) -> Result | {error, term()}.
-callback listen(Conn, Channel :: binary()) -> ok | {error, term()}.  %% no-op on sqlite
-callback get_generation(Conn) -> {ok, non_neg_integer()} | {error, term()}.
-callback cas_generation(Conn, Expected :: non_neg_integer()) ->
    {ok, NewGen :: non_neg_integer()} | {error, conflict | term()}.
```
Backends: `janus_db_postgres`, `janus_db_sqlite`. Keep `select_backend/0`, `sqlite_path/0`, `postgres_opts/0`.

### `janus_secrets`
```erlang
encrypt(Plain :: binary()) -> {ok, CipherEnvelope :: binary()} | {error, term()}.
decrypt(CipherEnvelope :: binary()) -> {ok, Plain :: binary()} | {error, term()}.
%% Envelope binary or map must carry key_id for rotation (read-old/write-new).
```

### `janus_agent_keys`
```erlang
hash_key(RawKey :: binary()) -> {Prefix :: binary(), Hash :: binary()}.
verify(RawKey :: binary(), StoredHash :: binary()) -> boolean().  %% constant-time
```

### `janus_snapshot`
```erlang
%% Path under JANUS_SNAPSHOT_DIR (default data/snapshots). HMAC under JANUS_SECRETS_KEY.
write(CatalogTerm) -> ok | {error, term()}.  %% temp + fsync + rename; retain last N
read_latest() -> {ok, CatalogTerm, Meta} | {error, missing | corrupt | term()}.
```

### `janus_catalog` / `janus_config`
- Build catalog ETS tables (or one table of records) from DB rows.
- Swap via `persistent_term:put({janus, catalog}, #{generation => N, tabs => ...})`.
- **Never** clear LB runtime ETS on publish.
- Reload: NOTIFY `janus_config` + poll interval default **2000 ms** (`JANUS_CONFIG_POLL_MS`).
- Cold-start: (a) DB ok → load DB + write snapshot; (b) DB down + valid snapshot → serve, mutations refused; (c) else `/readyz` fail.

### `janus_lb`
- Own ETS: cool-downs, in-flight, RR cursors. Node-local.
- Stubs OK: `pick_route(ModelId)`, `report_result/2`, `cooldown/2` — full weighted RR can be thin for this phase.

### Health
- `/healthz` — process up
- `/readyz` — catalog generation loaded AND (DB ok OR valid snapshot within max age)

## File ownership (parallel agents — DO NOT cross)
| Agent | May edit |
|-------|----------|
| db | `janus_db.erl`, `janus_db_postgres.erl`, `janus_db_sqlite.erl`, `apps/janus_core/priv/**` |
| crypto | `janus_secrets.erl`, `janus_agent_keys.erl`, `janus_snapshot.erl` only (new) |
| catalog | `janus_config.erl`, `janus_catalog.erl`, `janus_lb.erl`, `janus_core_sup.erl`, `janus_http_health.erl` |
| deps | `rebar.config`, `**/src/*.app.src`, `Dockerfile`, `docker-compose.yml`, `README.md`, `config/*` |

Wire modules into supervision only in **catalog** agent. Crypto/db agents export APIs; catalog calls them.
