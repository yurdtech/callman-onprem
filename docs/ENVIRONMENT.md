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
| `CALLMAN_ADMIN_VERSION` | ✅ | — | Admin panel image version (e.g. `0.1.0`). Separate from `CALLMAN_VERSION`. |
| `SESSION_TOKEN_ENCRYPTION_SECRET` | ✅ | — | Encrypts stored sessions. ≥ 32 chars, **different**. |
| `CONNECTION_ENCRYPTION_KEY` | ✅ | — | Encrypts saved DB/connection credentials. ≥ 32 chars, **different**. **Shared with the admin panel** — see below. |

> The four secrets must be **four distinct values**, each **≥ 32
> characters**, or the app exits at startup. Generate each with
> `openssl rand -hex 32`. Run `./scripts/preflight.sh` to check them before
> you start the stack.

> ⚠️ **`CONNECTION_ENCRYPTION_KEY` is read by BOTH the backend and the admin
> panel** from this one `.env`. The admin panel encrypts AI provider keys with
> it; the backend decrypts them. They must stay identical — do not give the
> admin panel a different value.

> ⚠️ **Two of these secrets encrypt data inside the database**
> (`SESSION_TOKEN_ENCRYPTION_SECRET`, `CONNECTION_ENCRYPTION_KEY`). Keep a safe
> copy of `.env`: a database backup restored against different values cannot be
> decrypted. See [BACKUP.md](BACKUP.md).

> **The license is NOT an environment variable.** It is a signed certificate
> installed once through the admin panel (**On-Prem → License**) and stored in
> the database — so renewing it needs no `.env` edit and no restart. See
> [INSTALL.md § 7](INSTALL.md). (`CALLMAN_LICENSE_KEY` is a leftover from an
> older design and is ignored; you can delete it from your `.env`.)

## Databases

`COMPOSE_PROFILES` decides which databases this stack runs for you. Everything
here is set in `.env` — **`docker-compose.yml` is never edited**.

| Variable | Required | Default | Description |
|---|---|---|---|
| `COMPOSE_PROFILES` | ✅ | `bundled-mongo,bundled-redis` | Which bundled databases to run. Remove `bundled-mongo` to use your own MongoDB, `bundled-redis` for your own Redis, or leave it empty for both. Add `ui-runner` to also run the UI-test runner (scheduled web UI tests in a headless browser — see below). |

### UI-test runner (optional, profile `ui-runner`)

Runs users' **web UI test flows on the server on a schedule** (headless
Chromium). Opt-in because it is heavy: the image is ~2 GB on disk and every
replica should be budgeted ~2 GB RAM. Without it, everything else works —
the app just answers "UI runner unavailable" to schedule/run requests.

| Variable | Required | Default | Description |
|---|---|---|---|
| `UITEST_WORKER_CONCURRENCY` | — | `2` | Browsers per runner replica (1–5). Parallel web tests = replicas × this. |
| `UITEST_RUN_MAX_DURATION_MS` | — | `900000` | Per-run time limit (ms). A run over the limit is stopped and reported failed. |
| `UITEST_REPORT_RETENTION_DAYS` | — | `90` | How long server run reports are kept. |
| `UITEST_FAILURE_SCREENSHOT_MAX_BYTES` | — | `300000` | Failure screenshot size budget; `0` disables screenshots. |

### Bundled MongoDB + Redis (default)

Needed only for whichever bundled database is enabled above. The app's
connection strings are **built automatically** from these — you do not write a
connection URI yourself.

| Variable | Required | Default | Description |
|---|---|---|---|
| `MONGO_ROOT_USERNAME` | ✅ | `callman` | Username for the bundled MongoDB. |
| `MONGO_ROOT_PASSWORD` | ✅ | — | Password for the bundled MongoDB. Choose a strong one. |
| `REDIS_PASSWORD` | ✅ | — | Password for the bundled Redis. Choose a strong one. |

> ⚠️ `MONGO_ROOT_USERNAME` / `MONGO_ROOT_PASSWORD` are applied **only when the
> data volume is first created**. Changing them later does not update the
> existing database user — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Your own MongoDB / Redis

Set these **only** for a database you run yourself, after removing the matching
profile from `COMPOSE_PROFILES`. Your value always wins over the bundled
default. Full guide: **[EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md)**.

| Variable | Required | Default | Description |
|---|---|---|---|
| `MONGODB_URI` | when `bundled-mongo` is off | _(built from the bundled credentials)_ | Full MongoDB connection URI. Everything — auth source, replica set, TLS — rides as a query parameter. |
| `REDIS_URL` | when `bundled-redis` is off | _(built from `REDIS_PASSWORD`)_ | Full Redis URI. Your Redis **must** run with `maxmemory-policy noeviction`. |
| `CALLMAN_MONGODB_URI` | optional | _(follows `MONGODB_URI`)_ | Admin panel's MongoDB. Leave unset — it follows the backend automatically. Set it only if the admin panel must use a *different* database, which is unusual. |

## Network & edition

| Variable | Required | Default | Description |
|---|---|---|---|
| `CALLMAN_PORT` | optional | `8080` | The port the API listens on **and** is published on. Browse `http://<host>:<CALLMAN_PORT>`. |
| `CALLMAN_EDITION` | optional | `onprem` | Keep `onprem`. Shown on `/version`. |
| `NODE_ENV` | optional | `production` | Keep `production`. |

---

## Admin panel

The `admin` service (separate image + version) connects to the **same** MongoDB
as the backend — bundled or your own, it follows `MONGODB_URI` automatically.
Do **not** point it at a separate database. Its login is **independent** of the
backend's (own JWT secrets, always local email + password — it does not support
LDAP even when the backend does).

| Variable | Required | Default | Description / how to create |
|---|---|---|---|
| `CALLMAN_ADMIN_VERSION` | ✅ | — | Admin image version to run (e.g. `0.1.0`). Separate from `CALLMAN_VERSION`. |
| `CALLMAN_ADMIN_PORT` | optional | `5100` | Port to reach the admin UI + API on (same origin). |
| `CALLMAN_BACKEND_API_URL` | optional* | `http://backend:<CALLMAN_PORT>` | Base URL of the Callman **backend** API, used by the managed-connections **Test** action — see below. Defaults to the bundled backend service; set it only when the backend runs outside this compose file. |
| `ADMIN_JWT_SECRET` | ✅ | — | Signs admin access tokens. ≥ 32 chars. `openssl rand -hex 32`. Separate from backend secrets. |
| `ADMIN_JWT_REFRESH_SECRET` | ✅ | — | Signs admin refresh tokens. ≥ 32 chars, different from `ADMIN_JWT_SECRET`. |
| `ADMIN_BOOTSTRAP_EMAIL` | optional* | _(unset)_ | Email of the first admin user, seeded on first start if no admins exist. |
| `ADMIN_BOOTSTRAP_PASSWORD` | optional* | _(unset)_ | Password for that first admin. ⚠ Use a STRONG value; change it right after first login. |
| `ADMIN_JWT_EXPIRES_IN` | optional | `1h` | Admin access-token lifetime. |
| `ADMIN_JWT_REFRESH_EXPIRES_IN` | optional | `7d` | Admin refresh-token lifetime. |
| `ADMIN_BCRYPT_ROUNDS` | optional | `12` | Admin password hashing cost. |
| `CALLMAN_DB_WRITE_ENABLED` | optional | `false` | Keep `false`: the admin panel can READ Callman data but never MODIFY it. Only enable if you specifically need admin writes. |
| `CORS_ORIGINS` | optional | `http://localhost:5173` | Admin API allowed browser origins — only needed if the UI is served cross-origin. |
| `RATE_LIMIT_MAX` | optional | `300` | Admin API request rate cap. |

\* `ADMIN_BOOTSTRAP_EMAIL` + `ADMIN_BOOTSTRAP_PASSWORD` are needed only to seed
the **first** admin. Once an admin exists you can remove them.

\* `CALLMAN_BACKEND_API_URL` is **required by the admin panel itself** (it
refuses to boot without a valid URL) — it is "optional" here only because
`docker-compose.yml` already fills it with the bundled backend
(`http://backend:<CALLMAN_PORT>`). If you deploy the admin panel outside this
compose file, or your backend runs on another host, you MUST set it in `.env`.

> **Why the admin panel needs the backend URL:** the managed-connections
> **Test** button in the admin UI does not test from the panel — the real
> DB/Kafka/Redis/Slack drivers live only in the backend, so the panel calls
> `POST <CALLMAN_BACKEND_API_URL>/api/internal/connections/test` and shows the
> backend's result. The connection config travels **encrypted** with the shared
> `CONNECTION_ENCRYPTION_KEY` (never plaintext), which is also why that key
> must be identical for the backend and the admin panel. If Test fails with a
> network error while saving connections still works, this URL (or the shared
> key) is the first thing to check.

> `CALLMAN_MONGODB_URI` follows `MONGODB_URI` automatically, for both the
> bundled and an external MongoDB. Leave it unset.

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
| `BULLMQ_WORKER_CONCURRENCY` | `50` | Parallel background jobs per worker. Raise this first under load; to add *more* worker containers, see [SCALING.md](SCALING.md). |
| `METRICS_ENABLED` | `true` | Expose Prometheus `/metrics` (incl. `bullmq_jobs_waiting`). Set `false` to disable. See [SCALING.md](SCALING.md). |
| `WORKER_HEALTH_PORT` | `9090` | Port the worker serves its own health probes on, inside its container. Not published to the host; change only on a port conflict. |
| `MONGODB_BACKUP_DIR` | `/backups` | Where the pre-migration `mongodump` is written (a volume is mounted here — leave as-is). See [BACKUP.md](BACKUP.md). |

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

Two lines in `.env` — remove the bundled profile, set the URI. You never edit
`docker-compose.yml`:

```dotenv
COMPOSE_PROFILES=bundled-redis        # our Redis, your MongoDB
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin
```

Then `./scripts/preflight.sh && docker compose up -d`.

Replica sets, TLS with a private CA, databases running on the Docker host,
verification steps and common errors are all covered in
**[EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md)**.

> Your Redis must use `maxmemory-policy noeviction` (queued background jobs
> live in Redis and must never be evicted).
