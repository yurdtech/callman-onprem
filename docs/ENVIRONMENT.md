# Configuration reference (`.env`)

Every setting Callman reads, grouped by what you need to touch. Copy
`.env.example` to `.env` and edit. Values shown as `<CHANGE_ME...>` are
placeholders you must replace.

> **You only need the "Required" + "Bundled databases" sections for a
> normal install.** Everything else has a safe default.

---

## Required — you must set these

| Variable | Required | Default | Description / how to create |
|---|---|---|---|
| `CALLMAN_VERSION` | ✅ | — | Image version to run (e.g. `1.0.1`). We tell you which. |
| `JWT_SECRET` | ✅ | — | Signs access tokens. ≥ 32 chars. `openssl rand -hex 32` |
| `JWT_REFRESH_SECRET` | ✅ | — | Signs refresh tokens. ≥ 32 chars, **different** from the others. |
| `SESSION_TOKEN_ENCRYPTION_SECRET` | ✅ | — | Encrypts stored sessions. ≥ 32 chars, **different**. |
| `CONNECTION_ENCRYPTION_KEY` | ✅ | — | Encrypts saved DB/connection credentials. ≥ 32 chars, **different**. |

> The four secrets must be **four distinct values**, each **≥ 32
> characters**, or the app exits at startup. Generate each with
> `openssl rand -hex 32`.

## Bundled databases — you must set these (default install)

These configure the bundled MongoDB + Redis. The app's connection strings
(`MONGODB_URI`, `REDIS_URL`) are **built automatically** from them by
`docker-compose.yml` — you do not write a connection URI yourself.

| Variable | Required | Default | Description |
|---|---|---|---|
| `MONGO_ROOT_USERNAME` | ✅ | `callman` | Username for the bundled MongoDB. |
| `MONGO_ROOT_PASSWORD` | ✅ | — | Password for the bundled MongoDB. Choose a strong one. |
| `REDIS_PASSWORD` | ✅ | — | Password for the bundled Redis. Choose a strong one. |

## Network & edition

| Variable | Required | Default | Description |
|---|---|---|---|
| `CALLMAN_PORT` | optional | `8080` | The port the API listens on **and** is published on. Browse `http://<host>:<CALLMAN_PORT>`. |
| `CALLMAN_EDITION` | optional | `onprem` | Keep `onprem`. Shown on `/version`. |
| `NODE_ENV` | optional | `production` | Keep `production`. |

---

## Optional knobs (safe defaults — change only if needed)

| Variable | Default | Description |
|---|---|---|
| `JWT_EXPIRES_IN` | `1h` | Access-token lifetime. |
| `JWT_REFRESH_EXPIRES_IN` | `30d` | Refresh-token lifetime. |
| `BCRYPT_ROUNDS` | `12` | Password hashing cost (10–14 typical). |
| `SESSION_MAX_SESSIONS_PER_USER` | `5` | Concurrent sessions per user. |
| `CACHE_TTL_SECONDS` | `3000` | Workspace/membership cache TTL (seconds). |
| `RATE_LIMIT_STORE` | `mongo` | `mongo` or `redis` (redis needs Redis, which you have). |
| `RATE_LIMIT_LOGIN_MAX_PER_EMAIL` | `5` | Failed logins per email before throttling. |
| `RATE_LIMIT_LOGIN_WINDOW_MS` | `900000` | Login throttle window (ms, default 15 min). |
| `MONGODB_MAX_POOL_SIZE` | `100` | Mongo connection pool max. |
| `MONGODB_MIN_POOL_SIZE` | `10` | Mongo connection pool min (≤ max). |
| `BULLMQ_WORKER_CONCURRENCY` | `50` | Parallel background jobs per worker. |
| `METRICS_ENABLED` | `true` | Expose Prometheus `/metrics`. Set `false` to disable. |
| `MONGODB_BACKUP_DIR` | `/backups` | Where the pre-migration `mongodump` is written (a volume is mounted here — leave as-is). |

### Queue dashboard (optional)

| Variable | Default | Description |
|---|---|---|
| `BULL_BOARD_USERNAME` | _(unset)_ | Set **both** to enable the `/admin/queues` dashboard (basic-auth). Disabled when unset. |
| `BULL_BOARD_PASSWORD` | _(unset)_ | — |

### Public URLs (optional — only if you expose the API publicly)

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_API_BASE_URL` | _(unset)_ | Absolute public URL of this backend, used to build links it hands to clients. |
| `MOCK_PUBLIC_BASE_URL` | `http://localhost:4000` | Base URL embedded in generated Mock-API URLs — set to your public URL if you use Mock APIs. |
| `CLIENT_ORIGIN` | _(unset)_ | Comma-separated browser origins allowed by CORS. |

### Error reporting (Telegram) — usually OFF on-prem

The desktop app can forward crash reports to a Telegram channel run by the
vendor. On-prem installs normally disable this (no outbound internet
required).

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_ENABLED` | `true` | **To disable, set it to an EMPTY value** (`TELEGRAM_ENABLED=`). ⚠ Setting it to the text `false` does **not** disable it. When enabled in production you MUST also set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`, or the app won't start. |
| `TELEGRAM_BOT_TOKEN` | _(unset)_ | Required only if Telegram is enabled. |
| `TELEGRAM_CHAT_ID` | _(unset)_ | Required only if Telegram is enabled. |

### Migrations (advanced)

| Variable | Default | Description |
|---|---|---|
| `SKIP_MIGRATION_CHECK` | `false` | Emergency override: let the app boot even with pending migrations. Leave `false`. |
| `SKIP_MIGRATION_BACKUP` | `false` | Skip the pre-migration `mongodump`. Leave `false`. |
| `BACKUP_REQUIRED` | `false` | If `true`, a failed backup aborts the migration (default: warn + continue). |

### Connecting to old Oracle databases

Not supported by this image yet (it speaks to Oracle 12.1+ only). Old-Oracle
(Thick-mode) support is planned for a future release. You may see a benign
`Oracle Thick mode not enabled — staying in Thin mode` line in the logs;
it does not affect anything unless you use an Oracle data source on a very
old server.

---

## Using your own MongoDB / Redis

The default stack bundles MongoDB + Redis. To use your **own** databases
instead:

1. In `.env`, set the full connection strings (uncomment the lines at the
   bottom of `.env.example`):
   ```
   MONGODB_URI=mongodb://user:pass@your-mongo-host:27017/callman?authSource=admin
   REDIS_URL=redis://:pass@your-redis-host:6379
   ```
2. In `docker-compose.yml`:
   - Remove (or comment out) the `mongo:` and `redis:` **services** and the
     `mongo_data` / `redis_data` **volumes**.
   - In the `x-db-env` block near the top, remove the `MONGODB_URI` and
     `REDIS_URL` lines so your `.env` values are used instead of the
     auto-built bundled ones.
   - Remove the `mongo`/`redis` entries from each service's `depends_on`.

> Your Redis must use `maxmemory-policy noeviction` (BullMQ requires that
> jobs are never evicted).
