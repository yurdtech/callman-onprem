# Mock server

Callman users can publish **mock APIs**: fake HTTP endpoints at
`<mock base URL>/mock/<mockId>/...` that answer with the responses they
configured. Mocks are called by applications under test, by CI, and often by
**load tests**. That traffic is served by the **mock server**, a container and
pod of its own, so a busy or misbehaving mock cannot slow the Callman API for
everyone else.

- Same image as the backend (`node dist/mock-server.js`), so there is nothing
  extra to pull.
- Uses the same MongoDB and Redis as the backend. Mocks, their state, request
  logs and limits live there, so the container holds nothing to back up and can
  be scaled out.
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

Mocks expire on their own, and their request logs go with them. **How long
they live is set in the admin panel:** Mocks → **Mock lifetime** (2 days by
default, 10 or 20 days, or a custom 1–365 days).

- Every new mock gets that lifetime, and the desktop app preselects it.
- Users may pick a shorter lifetime, or renew a mock later, but never past it.
- Changing it does not touch existing mocks. An admin can renew one from the
  Mocks list (**Extend**). That needs `CALLMAN_DB_WRITE_ENABLED=true` on the
  admin panel.
- The backend picks a change up within a minute.

## Limits and protection

| What | Default | Where |
|---|---|---|
| Requests per second, per mock | 30 | `MOCK_DEFAULT_RATE_LIMIT_PER_SECOND` (for new mocks), counted in Redis across all mock-server replicas |
| Total requests, per mock | 20 000 | `MOCK_DEFAULT_TOTAL_REQUEST_LIMIT` |
| Requests per second, per client IP, per mock-server process | 300 | `MOCK_IP_RATE_LIMIT_PER_SECOND` (`0` = off). Counted before the mock is looked up, so floods of random ids are cut off cheaply |
| Mocks per workspace | 20 | `MOCK_MAX_PER_WORKSPACE` |
| Regex conditions (`matches`) | 50 ms per evaluation | `MOCK_REGEX_TIMEOUT_MS`. Patterns that can backtrack catastrophically are refused when saved; one that still times out is disabled for 10 minutes |
| Request logs | newest 500 per mock | `MOCK_MAX_LOGS_PER_MOCK`, written in batches every second (`MOCK_LOG_FLUSH_INTERVAL_MS`) |

Rejected requests answer `429` with `X-Mock-Limit-Reason: ip-rate-limit`,
`rate-limit` or `total-limit`.

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
