# Mock server

Callman users can publish **mock APIs**: fake HTTP endpoints at
`<mock base URL>/mock/<mockId>/...` that answer with the responses they
configured. Mocks are called by applications under test, by CI, and often by
**load tests**. That traffic is served by the **mock server**, a container and
pod of its own, so a busy or misbehaving mock cannot slow the Callman API for
everyone else.

- Same image as the backend (`node dist/mock-server.js`), so there is nothing
  extra to pull.
- Uses the same MongoDB and Redis as the backend. Mocks, their state and data,
  request logs and limits live there, so the container holds nothing to back up
  and can be scaled out.
- Users still manage mocks through the API (desktop app, CLI, MCP). Only the
  public `/mock/*` traffic moves.

## How traffic reaches it

The mock server listens on `CALLMAN_MOCK_PORT` (default **8082**). Mock traffic
reaches it in one of two ways:

| | Proxy rule | `MOCK_PUBLIC_BASE_URL` | Mock URLs look like |
|---|---|---|---|
| **A. Mock domain** (recommended) | `mock.yourbank.local` → `:8082` | `https://mock.yourbank.local` | `https://mock.yourbank.local/mock/orders-api/...` |
| **B. Same host as the API** | `location /mock/` on the API host → `:8082` | leave unset (uses `PUBLIC_API_BASE_URL`) | `https://callman.yourbank.local/mock/orders-api/...` (unchanged) |

Option A lets you give mocks their own firewall, WAF and TLS policy, and keeps
anonymous mock callers off the API's hostname altogether.

Once mock traffic reaches the mock server, set **`MOCK_SERVE_ON_API=false`**.
From then on the API never executes a mock. A request that still arrives at
`<api host>/mock/...` gets a `307` redirect to the mock server (method and body
are kept). If the redirect would point back at the API itself because the proxy
rule is missing, the API answers `503 MOCK_SERVER_NOT_ROUTED` instead of
looping.

Until you do this, `MOCK_SERVE_ON_API` stays `true` (the default) and the API
keeps serving mocks exactly as before. Nothing breaks during the upgrade.

### Docker Compose

The `mock` service is always on (`callman-mock`, port `CALLMAN_MOCK_PORT`).
After `docker compose pull && docker compose up -d`:

1. Add the proxy rule (A or B). Example, nginx, option A:

   ```nginx
   server {
     listen 443 ssl;
     server_name mock.yourbank.local;
     # ssl_certificate … ;
     client_max_body_size 2m;          # mock request bodies go up to 1 MB
     proxy_read_timeout 120s;          # a mock may delay its answer by up to 60 s
     location / {
       proxy_pass http://127.0.0.1:8082;
       proxy_set_header Host $host;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
     }
   }
   ```

   Option B: inside the API's existing `server` block, add
   `location /mock/ { proxy_pass http://127.0.0.1:8082; proxy_read_timeout 120s; … }`
   above `location /`.
2. In `.env`: `MOCK_PUBLIC_BASE_URL=https://mock.yourbank.local` (option A only)
   and `MOCK_SERVE_ON_API=false`.
3. `docker compose up -d` again so the backend picks up the change.

Check it: `curl https://mock.yourbank.local/mock-server/version` should answer
`{"success":true,"data":{…,"service":"mock"}}`.

### Helm (Kubernetes / OpenShift)

`mock.enabled` is **true** by default, so `helm upgrade` creates a `<release>-mock`
Deployment and Service. Routing follows the backend:

- If the backend has an Ingress (or an OpenShift Route **with a host**), the
  chart adds a mock Ingress/Route on the **same host, path `/mock`**. The router
  sends `/mock/*` to the mock pods and everything else to the API. Mock URLs do
  not change, and `MOCK_SERVE_ON_API=false` is set for you. This is option B,
  with nothing for you to do.
- For option A, set `mock.ingress.host` (or `mock.route.host` on OpenShift) to
  the mock domain. `MOCK_PUBLIC_BASE_URL` is derived from it, or set it
  explicitly with `mock.publicUrl`.
- If the backend has neither an Ingress nor a named Route (you expose the
  Service yourself), the mock pods run but nothing routes to them, so the API
  keeps serving mocks. `helm status` (NOTES) says so. Give the mock server an
  entrance and upgrade again.

The chart sets the proxy timeouts (120 s) and body limit (2 MB) on the mock
Ingress/Route. Your own `mock.ingress.annotations` / `mock.route.annotations`
win. Scale with `mock.replicaCount` or `mock.hpa.enabled`. See
[HELM-INSTALL.md](HELM-INSTALL.md) for every value.

## Mock lifetime

Mocks expire on their own, and their request logs and data go with them.
**How long they live is set in the admin panel:** Mocks → **Mock lifetime** (2 days by
default, 10 or 20 days, or a custom 1–365 days).

- Every new mock gets that lifetime, and the desktop app preselects it.
- Users may pick a shorter lifetime, or renew a mock later, but never past it.
- Changing it does not touch existing mocks. An admin can renew one from the
  Mocks list (**Extend**). That needs `CALLMAN_DB_WRITE_ENABLED=true` on the
  admin panel.
- The backend picks a change up within a minute.

## Mock engine v2: data, sign-in, faults, sessions, imports

Backend releases with **mock engine v2** let a mock do much more than answer
fixed responses. It is the same engine the desktop app runs for local mocks.
Mocks created before it keep working unchanged, and older desktop apps can still
edit a mock's routes without touching its new parts.

- **Resources and data.** A mock can define resources (say `users`, `orders`):
  small tables with typed fields, unique fields and references between them.
  Each resource answers CRUD endpoints under its base path —
  `GET|POST /mock/<id>/orders`, `GET|PUT|PATCH|DELETE /mock/<id>/orders/:id`,
  nested `GET|POST /mock/<id>/users/:userId/orders` — with json-server style
  filtering, sorting and paging (`?status=open&_sort=-createdAt&_page=2`,
  `X-Total-Count`). Seed records are written when the mock is saved. Invalid fields answer
  `400`, a taken unique value `409`, a limit `409` / `413`.
- **Sign-in simulation.** `POST /auth/login`, `POST /auth/register` and
  `GET /auth/me` (paths configurable) issue and check JWTs signed with a
  per-mock secret, so the app under test can log in against the mock and
  routes can require a signed-in user or a role (`401` / `403`). Mock users
  are test fixtures, not accounts: their passwords are stored hashed and never
  returned. The mock's own access token (`X-Mock-Token`) is still checked
  first.
- **Faults.** Errors, delays, timeouts and dropped connections, on the whole
  mock, a route or a resource endpoint — by probability, by call count ("fail
  the first 3 calls") or as a sequence. Call counts are kept in Redis, so they
  hold across mock-server replicas. See [behind a proxy](#faults-behind-a-proxy)
  for what a caller actually receives.
- **Test sessions.** A caller that sends `X-Mock-Session: <id>` gets its own
  copy of the mock's data, seeded on first use, so parallel test runs never see
  each other's writes. An unused session is dropped after
  `MOCK_SESSION_IDLE_TTL_MINUTES`; more than `MOCK_MAX_SESSIONS_PER_MOCK`
  active sessions answer `429` with `X-Mock-Limit-Reason: session-limit`.
  `GET /mock/<id>/__callman/session` shows the caller's session and
  `POST /mock/<id>/__callman/session/reset` resets it (its own only).
  `/__callman` is a reserved path in every mock.
- **Imports.** `POST /api/import/mocks` builds a mock — or merges into an
  existing one — from an OpenAPI, Postman or Callman file, or from a collection
  in the workspace. The server never fetches a URL: the desktop app, CLI or MCP
  client reads the file and sends its content. This is an **API** endpoint,
  not mock traffic.

### Where the data lives

In the same MongoDB, in two collections the backend owns:

- `mockRecords` — one document per record, per namespace.
- `mockNamespaces` — one per mock for its shared data, plus one per active
  test session.

Both carry a TTL on `expiresAt`, which always equals the mock's: the data lives
exactly as long as its mock. Renewing or deleting a mock in the app, and
**Extend**, **Force-expire** or deleting a user in the admin panel, move or
remove its data with it. The pre-migration `mongodump` and your own backups
include both collections like every other one. The admin panel's Mocks list
shows how many resources and records each mock holds; it never shows the records
themselves (they may contain personal test data).

Mocks without resources never touch these collections. For the ones that do,
every data query is bounded (`MOCK_DATA_QUERY_TIMEOUT_MS`) and so is the number
of data operations per request (`MOCK_MAX_DATA_OPS_PER_REQUEST`). If MongoDB is
unreachable, data endpoints answer `503 Mock data store unavailable` instead of
a made-up success.

### Faults behind a proxy

A fault is simulated by the mock server itself, so whatever sits in front of it
— your nginx, a Kubernetes Ingress, the OpenShift router — shapes what the
caller finally sees:

| Fault | What the mock server does | What a caller behind a proxy receives |
|---|---|---|
| `error` | Answers with the configured status and body | That response, unchanged |
| `delay` | Answers after the configured delay (up to 60 s) | The response, late |
| `timeout` | Holds the connection (up to 60 s), then answers `504` | `504` — the **proxy's own** `504`, earlier, if its read timeout is shorter than the hang |
| `drop` | Closes the connection without any response | **`502 Bad Gateway`** from the proxy (called directly: a connection reset) |

Keep the 120 s read timeout on the mock route (the nginx example above; the
Helm chart sets it) so a configured hang reaches the caller as configured.
Tests that assert on a dropped connection should expect a `502` when they go
through the proxy.

### Imports and the proxy body limit

The import request carries the file as JSON, about 1.5× the file size. nginx
rejects bodies over **1 MB** by default, so with the default
`MOCK_MAX_IMPORT_BYTES` (2 MB) raise the limit for the **API's** host:

- Compose / your own nginx: `client_max_body_size 4m;` in the API's `server`
  block.
- Helm with an nginx Ingress: `backend.ingress.annotations:
  nginx.ingress.kubernetes.io/proxy-body-size: "4m"`. OpenShift Routes have no
  body limit.

A file over the limit answers `413 MOCK_IMPORT_TOO_LARGE` from Callman; a `413`
page from the proxy itself means the proxy limit is the one to raise.

## Limits and protection

| What | Default | Where |
|---|---|---|
| Requests per second, per mock | 30 | `MOCK_DEFAULT_RATE_LIMIT_PER_SECOND` (for new mocks), counted in Redis across all mock-server replicas |
| Total requests, per mock | 20 000 | `MOCK_DEFAULT_TOTAL_REQUEST_LIMIT` |
| Requests per second, per client IP, per mock-server process | 300 | `MOCK_IP_RATE_LIMIT_PER_SECOND` (`0` = off). Counted before the mock is looked up, so floods of random ids are cut off cheaply |
| Mocks per workspace | 20 | `MOCK_MAX_PER_WORKSPACE` |
| Regex conditions (`matches`) | 50 ms per evaluation | `MOCK_REGEX_TIMEOUT_MS`. Patterns that can backtrack catastrophically are refused when saved; one that still times out is disabled for 10 minutes |
| Request logs | newest 500 per mock | `MOCK_MAX_LOGS_PER_MOCK`, written in batches every second (`MOCK_LOG_FLUSH_INTERVAL_MS`) |
| Resources per mock | 20 | `MOCK_MAX_RESOURCES_PER_MOCK` |
| Records per resource / per namespace | 1 000 / 5 000 | `MOCK_MAX_RECORDS_PER_RESOURCE` / `MOCK_MAX_RECORDS_PER_NAMESPACE` — a namespace is the shared data or one test session |
| Size of one record / of a mock's seed records | 16 KB / 512 KB | `MOCK_MAX_RECORD_BYTES` / `MOCK_MAX_SEED_BYTES` |
| Active test sessions per mock | 20, dropped after 60 idle minutes | `MOCK_MAX_SESSIONS_PER_MOCK` / `MOCK_SESSION_IDLE_TTL_MINUTES` |
| Data work per request | 25 operations, 2 s per query | `MOCK_MAX_DATA_OPS_PER_REQUEST` / `MOCK_DATA_QUERY_TIMEOUT_MS` |
| Import file | 2 MB | `MOCK_MAX_IMPORT_BYTES` (see [the proxy body limit](#imports-and-the-proxy-body-limit)) |

Compose: set them in `.env`. Helm: `mock.limits.*` (they go to every pod — the
API checks definitions and imports against them too). Details for each:
[ENVIRONMENT.md](ENVIRONMENT.md#mock-data-sessions-and-imports-mock-engine-v2).

Rejected requests answer `429` with `X-Mock-Limit-Reason: ip-rate-limit`,
`rate-limit`, `total-limit` or `session-limit`.

**Load-testing against a mock?** Raise `MOCK_DEFAULT_RATE_LIMIT_PER_SECOND`
(and `MOCK_IP_RATE_LIMIT_PER_SECOND` if the load comes from one machine) on the
mock server. Compose: `.env`. Helm: `mock.ipRateLimitPerSecond` and
`mock.extraEnv`. Scale the mock server out rather than up.

## Monitoring

- Health: `/health/live` and `/health/ready` on `CALLMAN_MOCK_HEALTH_PORT`
  (9093, not published). The instance appears with role `mock` on
  `GET /ops/instances`.
- Metrics on the same port: `mock_requests_total{status_class}` and
  `rate_limit_rejections_total{limiter="mock:ip|mock:rate|mock:total"}`.
  The Helm ServiceMonitor scrapes it.
- Successful mock calls are logged at `debug`. Slow ones and 5xx are logged at
  `warn`.
