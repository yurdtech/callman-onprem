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
| `COMPOSE_PROFILES` | ✅ | `bundled-mongo,bundled-redis` | Which bundled databases to run. Remove `bundled-mongo` to use your own MongoDB, `bundled-redis` for your own Redis, or leave it empty for both. Add `ui-runner` to also run the UI-test runner (scheduled web UI tests in a headless browser), and/or `storage` to run the storage gateway for large files — both described below. |

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

### Storage gateway (optional, profile `storage`)

Handles **large files** — mobile build artifacts, screen recordings, oversized
imports. It is a connector, not a store: the files go to the S3 / MinIO /
FileNet you connect in the admin panel under **Storage**, so they stay in your
own infrastructure and your own backup regime. It runs from the same image as
the backend, so there is nothing extra to pull, and it holds no state, so it is
safe to scale and adds nothing to back up.

Full guide, including connecting a provider and switching between them:
[`STORAGE.md`](./STORAGE.md).

| Variable | Required | Default | Description |
|---|---|---|---|
| `CALLMAN_STORAGE_PORT` | — | `8081` | The port the gateway listens on and is published on. Clients download hundreds of MB from it directly, which is why it is not proxied through the API. |
| `CALLMAN_STORAGE_PUBLIC_URL` | ⚠️ | unset | The address your users and CI reach the gateway on, e.g. `https://callman.yourbank.local` — no trailing slash, no `/storage` path. Callman puts it in every upload/download link, which is how your provider's endpoint and credentials never reach a client. Unset works only when clients talk to the published port directly. |
| `STORAGE_MAX_UPLOAD_BYTES` | — | `524288000` (500 MB) | Largest single file anyone may upload. Rejected from the request headers, so an oversized upload costs one round trip. **Raise your reverse proxy's body limit to match** or the proxy cuts the upload before it reaches Callman. |
| `CALLMAN_STORAGE_HEALTH_PORT` | — | `9092` | Health/metrics port, internal to the Compose network (not published) — like the worker's 9090 and the UI runner's 9091. |
| `STORAGE_SPILL_DIR` | — | `/tmp` | Scratch space for providers that cannot accept a stream and need the whole file first. A transfer buffer, not a cache — files are deleted as soon as the upload completes. Size it for (concurrent uploads × largest file). |
| `STORAGE_PROVIDER_CACHE_TTL_SECONDS` | — | `60` | How long a provider's settings are reused before being re-read. A change in the admin panel therefore takes effect within a minute; that delay is harmless, because every file records which provider holds it and a replaced provider keeps serving reads. |
| `STORAGE_UPLOAD_CLAIM_STALE_MS` | — | `1800000` (30 min) | How long an interrupted upload blocks a retry of the same file. Longer than the slowest plausible upload, so a transfer still in flight is never taken over. |

⚠️ `CONNECTION_ENCRYPTION_KEY` must be **the same value** in the backend and the
admin panel: the panel encrypts your storage credentials with it and the gateway
decrypts them. A mismatch shows up as "the active storage provider is not
usable" naming the key.

For an S3/MinIO endpoint with a privately-signed certificate, put the CA bundle
in `certs/` and set `NODE_EXTRA_CA_CERTS=/certs/<bundle>.pem` — Node trusts it
process-wide, and one bundle can hold several CAs.

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
| `CALLMAN_DB_WRITE_ENABLED` | optional | `false` | Keep `false` for a read-only panel: with it the panel can READ Callman data but never MODIFY it, and **revoking a token, ending a session, disabling a schedule, restoring a version, or deleting a user or workspace answers 403 *write disabled***. Set `true` when operators need those actions (a pilot usually does), and review the audit log. |
| `ADMIN_API_DOCS_ENABLED` | optional | off in production | Serves the Swagger page at `/admin/docs` (it lists every route and is readable by anyone who reaches the port; calling a route still needs a login). Set `true` to turn it on. |
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
| `RATE_LIMIT_STORE` | `redis` | Leave unset — every limiter counts in Redis. `mongo` still works but is deprecated (a MongoDB write per throttled request) and warns at boot. |
| `RATE_LIMIT_LOGIN_MAX_PER_EMAIL` | `5` | Failed logins per email before throttling. |
| `RATE_LIMIT_LOGIN_WINDOW_MS` | `900000` | Login throttle window (ms, default 15 min). |
| `MONGODB_MAX_POOL_SIZE` | `100` | Mongo connection pool max. |
| `MONGODB_MIN_POOL_SIZE` | `10` | Mongo connection pool min (≤ max). |
| `BULLMQ_WORKER_CONCURRENCY` | `50` | Parallel background jobs per worker. Concurrency is the only memory backpressure on the worker — at 50, keep the container above 2 GB or lower it to 20 (the Helm chart's default). To add *more* worker containers, see [SCALING.md](SCALING.md). |
| `NODE_OPTIONS` | compose: `--max-old-space-size=768` (backend, ui-runner), `1024` (worker) | V8 heap cap per container (`BACKEND_NODE_OPTIONS` / `WORKER_NODE_OPTIONS` / `UI_RUNNER_NODE_OPTIONS` in `.env` override). Node sizes its heap from the HOST's RAM, so without it a memory-limited container is OOM-killed before V8 collects. Keep ~25% under the container's memory limit. |
| `WORKER_SHUTDOWN_TIMEOUT_MS` | `300000` | How long a worker waits for the runs in flight when it is stopped or restarted (`docker compose up -d`, an upgrade). A scenario run may last up to `SCENARIO_RUN_MAX_DURATION_MS` (5 min); the default lets it finish instead of ending a CI pipeline's run half-way. Compose's `stop_grace_period` is set just above it (330 s). |
| `SCENARIO_RUN_MAX_DURATION_MS` / `SCENARIO_NODE_MAX_DURATION_MS` / `SCENARIO_REQUEST_TIMEOUT_MS` | `300000` / `60000` / `30000` | Hard caps: one scenario run, one node, one HTTP request. A longer run is stopped by the worker, whatever `callme scenario run --max-runtime` or `--timeout` say. |
| `SCENARIO_DATASET_MAX_ROWS` | `500` | Most data-driven rows one scenario run executes. A dataset can hold more; the report says how many ran (`callme scenario run` prints `Dataset: N of M rows run`). |
| `RATE_LIMIT_PAT_READ_MAX_PER_TOKEN` / `RATE_LIMIT_PAT_WRITE_MAX_PER_TOKEN` | `600` / `120` per window | Requests per API token (CI token, personal token). `callme scenario run` polls every 2 s per scenario, so a *parallel* folder of N scenarios makes about 30·N reads a minute — keep it well under 600 or give each pipeline its own token. Exceeding it returns `429` (the CLI retries). Window: `RATE_LIMIT_PAT_READ_WINDOW_MS` / `RATE_LIMIT_PAT_WRITE_WINDOW_MS`. |
| `WORKER_HEAP_HIGH_WATERMARK` | `0.85` | Above this fraction of the heap cap the worker pauses picking up new jobs for a few seconds (nothing fails). |
| `SCRIPT_WORKER_POOL_SIZE` | `2` | Warm script threads per worker; every scenario script runs there, off the worker's event loop, capped at `SCRIPT_WORKER_HEAP_MB` (128) each. |
| `SCENARIO_MAX_RESPONSE_BYTES` | `10485760` | Largest HTTP response a request node buffers; bigger responses fail the node. |
| `SCENARIO_REPORT_RETENTION_DAYS` | `0` (keep forever) | Auto-delete scenario run reports older than this. Applied by the `migrate` step on every start; `0` never deletes. `UITEST_RESULT_RETENTION_DAYS` and `NOTIFICATION_RETENTION_DAYS` work the same way. |
| `AUDIT_LOG_ENABLED` | `true` | Records the workspace event history (`workspace_events`): who created, changed or deleted what, and when. Read in the app under **Workspace settings → Activity** by any workspace member, and platform-wide in the admin panel's **Activity Log**. Accepts `true/false`, `1/0`, `yes/no`, `on/off`; anything else fails at startup rather than being guessed. Turning it off stops the recording — the product keeps working and the Activity tab simply shows nothing. |
| `WORKSPACE_EVENT_RETENTION_DAYS` | `0` (keep forever) | Auto-delete workspace event rows older than this. Applied by the `migrate` step on every start; `0` never deletes, which is the documented default for the audit trail. Set a window only if your retention policy requires one — the trail is append-only otherwise, and this TTL is the only thing in the system that removes a row from it. |
| `SCHEDULE_MONITOR_CACHE_TTL_SECONDS` | `20` | How long the desktop's **Scheduled runs** view caches a page of results, per user and per filter set. Every open view polls, so this is what keeps N desktops from becoming N cross-collection aggregations per tick. `0` disables the cache — useful only while investigating staleness. |
| `SCHEDULE_MONITOR_STALE_GRACE_MINUTES` | `15` | How far a schedule's next run may slip into the past before **Scheduled runs** flags it as overdue. A run is legitimately "due" for a moment while a worker picks it up; past this, the queued job was probably lost (no worker running, or Redis was flushed). |
| `SCHEDULE_MONITOR_SEARCH_MAX_TARGETS` | `500` | Cap on scenarios matched by name when searching in **Scheduled runs**, so a one-letter search stays bounded. |
| `SCHEDULE_MONITOR_MAX_SCENARIO_IDS` | `2000` | Cap on the scenario set used to authorize run totals in **Scheduled runs**. Above it the totals count only runs attached to a schedule and the view says they are partial, rather than quietly under-reporting. Raise it only if a single user can see more scenarios than this. |
| `UI_RUNNER_SHUTDOWN_TIMEOUT_MS` | `120000` | How long in-flight browser runs may finish when the ui-runner container stops (compose `stop_grace_period` is 150 s). |
| `METRICS_ENABLED` | `true` | Expose Prometheus `/metrics` (incl. `bullmq_jobs_waiting`) and the collectors behind `/ops/*`. Set `false` to disable. See [MONITORING.md](MONITORING.md). |
| `LOG_LEVEL` | `info` | Minimum log level (`debug` / `info` / `warn` / `error`). Health probes, `/metrics` scrapes and `/ops/*` are logged at `debug`, so they are invisible by default; set `debug` only while investigating. |
| `HTTP_LOG_SKIP_PATHS` | `/health,/health/live,/health/ready,/version,/api/system-info,/metrics,/ops/*` | Paths the request logger writes at `debug` instead of `info` (CSV; a trailing `*` makes it a prefix). |
| `HTTP_LOG_SLOW_MS` | `2000` | Requests at or above this many ms are logged at `warn` (`HTTP request slow`) even when on the skip list; `0` disables. |
| `MONGODB_COMMAND_METRICS_ENABLED` | `true` | MongoDB command metrics (`mongodb_commands_total`, `mongodb_command_duration_seconds`). Restart to change. |
| `CALLMAN_RELEASE_REMINDERS_ENABLED` | `true` | Release-calendar **in-app reminders** to desktop users, delivered by the backend worker from the admin panel's Release Calendar. This is a process-level kill switch only — the admin-facing on/off switch and the reminder rules live in the admin panel (Release Calendar → Notifications, channel "In-app (desktop users)"). Desktop users also see the calendar itself (profile menu → Release calendar). |
| `WORKER_HEALTH_PORT` | `9090` | Port the worker serves its own health probes on, inside its container. Not published to the host; change only on a port conflict. |
| `MONGODB_BACKUP_DIR` | `/backups` | Where the pre-migration `mongodump` is written (a volume is mounted here — leave as-is). See [BACKUP.md](BACKUP.md). |

### Queue dashboard (optional)

| Variable | Default | Description |
|---|---|---|
| `BULL_BOARD_USERNAME` | _(unset)_ | Set **both** to enable the `/admin/queues` dashboard (basic-auth). Disabled when unset. |
| `BULL_BOARD_PASSWORD` | _(unset)_ | — |

### Public URLs

| Variable | Default | Description |
|---|---|---|
| `PUBLIC_API_BASE_URL` | _(unset)_ | **Set this.** The absolute URL your users' desktops reach this backend on — scheme included, no trailing slash. See the warning below. |
| `MOCK_PUBLIC_BASE_URL` | _(unset → `PUBLIC_API_BASE_URL`)_ | Where mock APIs are published (`<base>/mock/<id>`): the mock server's own domain, or leave unset when `/mock/` on the API host is routed to it. See [MOCK-SERVER.md](MOCK-SERVER.md). |
| `MOCK_SERVE_ON_API` | `true` | Set `false` once your proxy sends mock traffic to the mock server: the API then redirects `/mock/*` there and never runs a mock. |
| `CALLMAN_MOCK_PORT` | `8082` | The mock server's port (published by compose). |
| `MOCK_IP_RATE_LIMIT_PER_SECOND` | `300` | Per-IP flood fuse on the mock server, per process (`0` = off). |
| `CLIENT_ORIGIN` | _(unset)_ | Comma-separated browser origins allowed by CORS. |

> ⚠️ **`PUBLIC_API_BASE_URL` stopped being optional when desktop auto-update
> arrived.** It is what every desktop is told to fetch its updates from, so a
> wrong value sends the whole fleet at the wrong host. Leaving it unset is worse
> than it looks: the backend then falls back to the scheme and host of the
> incoming request, and behind a reverse proxy that does not forward
> `X-Forwarded-Proto` that yields `http://` — which the macOS updater refuses.

### Desktop auto-update

Your administrator uploads the installers we deliver in the admin panel
(**Desktop Releases → Upload a build**), and every Callman desktop in the
deployment then updates itself from your own storage. The full runbook is
[`DESKTOP-APP.md`](./DESKTOP-APP.md).

| Variable | Default | Description |
|---|---|---|
| `ONPREM_COMPANY_SLUG` | _(unset)_ | Your company slug, exactly as it appears in the delivered `build-manifest.json`. The **second half** of the foreign-build check: because a build also carries the API address it was made for, `PUBLIC_API_BASE_URL` alone already refuses a build belonging to another deployment. This adds the company name on top, which is what catches the case where two deployments answer on the same host. Worth setting. |
| `HTTP_REQUEST_TIMEOUT_MS` | `120000` | **Raise to `1800000`.** Node applies this to the WHOLE request, body included, so at the default a 400 MB installer upload is cut off after two minutes with a 408 — most of the way through the progress bar. The upload endpoint refuses up front when this is too small for the file, naming the value to set. |
| `DESKTOP_RELEASE_MAX_ARTIFACT_BYTES` | `2147483648` (2 GiB) | Per-installer ceiling, checked against the size the build's own update file declares before a byte moves. |
| `RATE_LIMIT_DESKTOP_FEED_MAX_PER_USER` | `120` | Update checks per user per window. Keyed on the user, not the IP — a few hundred desktops behind one NAT share an address. The installer download itself is not throttled. |
| `RATE_LIMIT_DESKTOP_FEED_WINDOW_MS` | `3600000` (1 h) | Window for the above. The desktop polls hourly. |

> ⚠️ **Your reverse proxy needs two changes if you run Compose**, and they are
> the most likely cause of a failed first upload. The admin panel carries installer
> uploads of up to 2 GB, so its own vhost needs `client_max_body_size 0;`,
> `proxy_request_buffering off;` and `proxy_read_timeout 1800s;` — nginx's 1 MB
> default rejects an installer with a 413 before Callman ever sees it, and the
> backend vhost needs the timeouts too because the desktops download from it.
>
> On **Kubernetes the chart does this for you**: the admin, backend and storage
> Ingresses and OpenShift Routes carry the body-limit and timeout annotations by
> default (an OpenShift router otherwise cuts every transfer off after 30
> seconds). Anything you put in `*.ingress.annotations` / `*.route.annotations`
> overrides them.

### Error reporting (Telegram) — usually OFF on-prem

The desktop app can forward crash reports to a Telegram channel run by the
vendor. On-prem installs normally disable this (no outbound internet
required).

| Variable | Default | Description |
|---|---|---|
| `TELEGRAM_ENABLED` | `true` | **To disable, set it EMPTY** (`TELEGRAM_ENABLED=`) — that works on every version. Newer backends also read `false`, `0`, `no`, `off` as off (older ones read *any* non-empty text, `false` included, as ON). When enabled in production you MUST also set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`, or the app won't start. Enabled, it sends error reports to `api.telegram.org` (outbound internet). |
| `TELEGRAM_BOT_TOKEN` | _(unset)_ | Required only if Telegram is enabled. |
| `TELEGRAM_CHAT_ID` | _(unset)_ | Required only if Telegram is enabled. |

### Migrations (advanced)

| Variable | Default | Description |
|---|---|---|
| `SKIP_MIGRATION_CHECK` | `false` | Emergency override: let the app boot even with pending migrations. Leave `false`. |
| `SKIP_MIGRATION_BACKUP` | `false` | Skip the pre-migration `mongodump`. Leave `false`. |
| `BACKUP_REQUIRED` | `false` | If `true`, a failed backup aborts the migration (default: warn + continue). |

### Connecting to old Oracle databases

Callman connects to Oracle **12.1 and newer** without any setup. Older
servers (**11.2 / 11g**) need the Oracle **Instant Client**, which Oracle's
license does not let us ship inside the image. Install it once from the
admin panel:

1. **Admin panel → On-Prem → Database drivers.**
2. Click **Download from Oracle** (the server needs internet access), or
   download the *Instant Client Basic Light* zip for your servers yourself
   (Linux x86-64 or ARM64, version 19) and upload it. Upload the Windows
   and macOS (Intel) packages too if your users run old-Oracle scenarios
   in the desktop app — the app then installs it from your server instead
   of from oracle.com.
3. Click **Apply now.** The backend, workers and UI-test runner restart one
   by one (running jobs finish first) and come back with the client. The
   page shows each process as *thick* once it is active.

Users change nothing: connections stay the same and simply start working.
Nothing needs to be set in `.env`; the variables below are optional.

| Variable | Default | Description |
|---|---|---|
| `ORACLE_CLIENT_RELOAD_POLL_MS` | `30000` | How often each service checks whether a new client was applied. `0` turns the automatic restart off — restart the services yourself after **Apply now**. |
| `ORACLE_CLIENT_MAX_PACKAGE_BYTES` | `250000000` | Largest Instant Client package the admin panel accepts. |
| `ORACLE_CLIENT_PROVISION` | _(unset)_ | `0` stops the services from installing the client at start (Oracle 12.1+ only). |

Oracle 10g and older are not supported. Until a client is installed you may
see a benign `Oracle Thick mode not enabled — staying in Thin mode` line in
the logs; it only matters if you use a very old Oracle server.

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
