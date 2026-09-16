# Monitoring — metrics, diagnostics and logs for the DevOps team

This page is for the people who run Callman: what the deployment exposes,
where to scrape it, and what the numbers mean. Nothing here is about test
scenarios or business KPIs — that lives in the admin panel.

Two surfaces, both on the backend, both **without authentication** (the
deployment's internal network is the trust boundary; neither one returns a
secret):

| Surface | Format | For |
|---|---|---|
| `GET /metrics` | Prometheus text exposition | Prometheus / VictoriaMetrics / Grafana Agent scraping, alerting, dashboards |
| `GET /ops/*` | JSON | One-shot diagnostics, scripts, Grafana **Infinity** / JSON datasources, support bundles |

The `/ops/*` endpoints exist **only on the on-prem edition** (404 on cloud)
and keep answering while the deployment is unlicensed or in read-only mode.

---

## 1. Where to scrape

### Docker Compose

Only the backend publishes a port (`CALLMAN_PORT`, default `8080`). The worker
and the UI runner serve their own `/metrics` on `WORKER_HEALTH_PORT` (9090) /
`UITEST_HEALTH_PORT` (9091) **inside the Compose network** — they are not
published to the host on purpose.

- Scrape the backend at `http://<host>:8080/metrics`.
- To scrape workers too, run Prometheus **inside** the Compose network
  (attach it to the `callman` network) and use Docker service discovery, or
  simply read the fleet through the backend: every process registers itself
  in Redis and `GET /ops/instances` lists them all with memory, event-loop
  utilization, concurrency and active jobs.

Minimal `prometheus.yml` job for the backend:

```yaml
scrape_configs:
  - job_name: callman-backend
    scrape_interval: 30s
    static_configs:
      - targets: ["callman-host:8080"]
```

### Helm / Kubernetes

Set `serviceMonitor.enabled=true` (needs the Prometheus Operator CRDs). The
chart ships one `ServiceMonitor` that scrapes `/metrics` on the backend
(`http` port), the worker and the UI runner (`health` port) every
`serviceMonitor.interval` (30 s). The admin panel Service is excluded from
the selector — it serves no `/metrics`.

`METRICS_ENABLED` must stay `true` (the default). Setting it to `false` makes
`/metrics` answer 404 and turns every collector into a no-op.

---

## 2. Metric catalog

Every series carries `instance_id` (the container hostname / pod name, or
`WORKER_INSTANCE_ID` when set), so multi-replica deployments attribute
load and failures to a specific process.

### HTTP (backend)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `http_requests_total` | counter | `method`, `route`, `status_class` | Requests handled. `route` is the **route template** (`/api/scenarios/:id`), never a concrete id. Requests rejected before a handler ran (401 from auth, 403 from the licence gate, 404 inside a resource) are attributed as `/api/<resource>/*`; unknown top-level paths are `unmatched`; past 300 distinct templates new ones fold into `other`. |
| `http_request_duration_seconds` | histogram | `method`, `route` | Latency from arrival to response finish. Buckets 5 ms … 30 s. |
| `http_requests_in_flight` | gauge | — | Requests being processed right now. |

Health probes and scrapes are counted too (under their own route), they are
just not *logged*.

### Node.js process (backend, worker, ui-runner)

From prom-client's default collector: `process_cpu_*_seconds_total`,
`process_resident_memory_bytes`, `nodejs_heap_size_*_bytes`,
`nodejs_heap_space_*`, `nodejs_gc_duration_seconds`,
`nodejs_eventloop_lag_*_seconds`, `nodejs_active_handles_total`,
`nodejs_active_requests_total`, `process_open_fds`.

Added by Callman:

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `nodejs_eventloop_utilization` | gauge | — | Share of time (0..1) the event loop was busy **since the previous scrape**. Sustained > 0.8 on a worker = raise `BULLMQ_WORKER_CONCURRENCY` no further; add replicas. |
| `build_info` | gauge (=1) | `version`, `git_sha`, `edition`, `node_version` | Which build is running. |
| `worker_instance_info` | gauge (=1) | `instance_id`, `version` | Legacy per-process identity gauge (kept for existing dashboards). |

### MongoDB driver (backend, worker, ui-runner)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `mongodb_connection_state` | gauge | — | Mongoose `readyState`: 0 disconnected, 1 connected, 2 connecting, 3 disconnecting. |
| `mongodb_connection_transitions_total` | counter | `event` | `disconnected` / `reconnected` / `connected` / `error` lifecycle events. Any `disconnected` increment is worth an alert. |
| `mongodb_pool_connections` | gauge | `state` = `total` / `in_use` / `available` | Driver pool connections seen since process start. `in_use` approaching `MONGODB_MAX_POOL_SIZE` (default 100) means the pool is saturated. |
| `mongodb_pool_connections_created_total` | counter | — | Pool connections opened. |
| `mongodb_pool_connections_closed_total` | counter | `reason` | Pool connections closed (`stale`, `idle`, `error`, `poolClosed`). |
| `mongodb_pool_checkout_wait_seconds` | histogram | — | How long a query waited for a free connection. Growth here = pool saturation (raise `MONGODB_MAX_POOL_SIZE` or add replicas). |
| `mongodb_pool_checkout_failed_total` | counter | `reason` | Checkouts that failed (`timeout`, `poolClosed`, …). |
| `mongodb_pool_cleared_total` | counter | — | Times the driver cleared the pool (server error / failover). |
| `mongodb_commands_total` | counter | `command` | Commands completed (success + failure). `command` is a fixed vocabulary (`find`, `aggregate`, `insert`, `update`, `delete`, `findAndModify`, `count`, `getMore`, `ping`, … or `other`). |
| `mongodb_commands_failed_total` | counter | `command` | Commands the server rejected. |
| `mongodb_command_duration_seconds` | histogram | `command` | Round-trip time as measured by the driver. |

The command metrics come from the driver's command monitoring
(`MONGODB_COMMAND_METRICS_ENABLED`, default `true`, restart to change). The
cost is two small event objects per command; turn it off on a worker only if
`nodejs_eventloop_lag_p99_seconds` visibly rises after enabling.

Pool gauges count from the moment the process attached (a handful of
connections opened during connect are not seen) and aggregate every server
of a replica set. The authoritative server-side view is
`serverStatus.connections` on `GET /ops/dependencies`.

### Redis (backend, worker, ui-runner)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `redis_client_state` | gauge | `client` = `queue` / `cache` / `ratelimit` | 1 when the ioredis client is `ready`. |
| `redis_ping_seconds` | gauge | `client` | Last sampled `PING` round-trip (every 10 s). |
| `redis_errors_total` | counter | `client` | ioredis `error` events. |

### Queues — BullMQ (backend reports both queues; each worker reports its own)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `bullmq_jobs_waiting` | gauge | `queue` | Backlog. **The number to scale on** (see [SCALING.md](SCALING.md)). |
| `bullmq_jobs_active` | gauge | `queue` | Being processed right now (cluster-wide). |
| `bullmq_jobs_delayed` | gauge | `queue` | Scheduled for later (schedules live here). |
| `bullmq_jobs_prioritized` / `bullmq_jobs_paused` | gauge | `queue` | Other BullMQ states. |
| `bullmq_jobs_completed` / `bullmq_jobs_failed` | gauge | `queue` | Jobs retained in the completed / failed sets (bounded by `BULLMQ_JOB_RETENTION_*`). |
| `bullmq_jobs_completed_total` / `bullmq_jobs_failed_total` | counter | `queue`, `job_name` | Jobs **this process** finished / failed. |
| `bullmq_jobs_stalled_total` | counter | `queue` | Lock expired mid-run (worker crash, event-loop starvation). Should stay flat. |
| `bullmq_worker_concurrency` | gauge | `queue` | Configured concurrency of this worker process. |
| `bullmq_worker_active_jobs` | gauge | `queue` | Jobs this process is running now. |
| `scenario_run_duration_seconds` | histogram | `queue`, `job_name`, `result` | Job duration from pickup to completion, both queues. |

Queues: `scenario-runs` (`BULLMQ_QUEUE_NAME`) and `ui-test-runs`
(`UITEST_QUEUE_NAME`).

### Fleet / licence / configuration (backend)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `worker_instances` | gauge | `role` = `api` / `worker` / `ui-runner` | Processes heartbeating in Redis right now. Drops when a container dies (within 30 s) or is stopped cleanly (immediately). |
| `license_status_info` | gauge | `status` | 1 for the current status (`active`, `expiring`, `expired_grace`, `expired`, `unlicensed`, `not_required`), 0 otherwise. |
| `license_expires_timestamp_seconds` | gauge | — | Unix time the certificate expires. `(license_expires_timestamp_seconds - time()) / 86400` = days left. |
| `license_seats_max` / `license_seats_used` | gauge | — | Seats allowed by the certificate / user accounts counted against it (60 s). |
| `schedules_enabled` | gauge | `kind` = `scenario` / `ui-test` | Enabled schedules (60 s). |
| `kafka_pool_entries` / `kafka_pool_max_entries` | gauge | — | Pooled Kafka client entries / the cap. |
| `kafka_pool_created_total` / `kafka_pool_evictions_total{reason}` | counter | — / `reason` | Pool churn (`idle`, `lru-cap`, `config-changed`, `connection-error`, `shutdown`). |
| `postgres_sessions_active` | gauge | — | Run-scoped Postgres sessions open (DB-function testing). |

### Application counters (backend)

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `app_errors_total` | counter | `code`, `status` | Requests that ended in the error handler, by error code and HTTP status. |
| `auth_failures_total` | counter | `reason` | 401s: `AUTH_TOKEN_MISSING`, `AUTH_TOKEN_INVALID`, `AUTH_SESSION_NOT_FOUND`. A burst = a broken client or a probe. |
| `rate_limit_rejections_total` | counter | `limiter` | 429s by limiter (`login:email`, `oauth:start:ip`, …). |
| `mock_requests_total` | counter | `status_class` | Traffic served by the public mock router. |
| `error_reports_submitted_total` | counter | `severity`, `category`, `delivered`, `deduped` | Desktop crash reports received (and whether Telegram accepted them). |

Deliberately **not** exposed: a response-size metric (compression makes
`Content-Length` unreliable) and anything keyed by user, workspace or
scenario (cardinality, and it is not infrastructure).

---

## 3. Useful PromQL

```promql
# Request rate and error rate (5xx) over 5 minutes
sum(rate(http_requests_total[5m]))
sum(rate(http_requests_total{status_class="5xx"}[5m])) / sum(rate(http_requests_total[5m]))

# p95 latency per route
histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))

# Queue backlog (alert when sustained)
max by (queue) (bullmq_jobs_waiting) > 100

# Stalled jobs appearing at all
increase(bullmq_jobs_stalled_total[15m]) > 0

# Mongo pool saturation
max(mongodb_pool_connections{state="in_use"}) / 100     # divide by MONGODB_MAX_POOL_SIZE
histogram_quantile(0.99, sum by (le) (rate(mongodb_pool_checkout_wait_seconds_bucket[5m]))) > 0.1

# Mongo dropped a connection
increase(mongodb_connection_transitions_total{event="disconnected"}[10m]) > 0

# Redis unreachable / slow
min by (client) (redis_client_state) == 0
max by (client) (redis_ping_seconds) > 0.05

# Worker fleet smaller than expected
sum(worker_instances{role="worker"}) < 2

# Event loop saturated on any process
max by (instance_id) (nodejs_eventloop_utilization) > 0.8

# Licence expiring within 14 days
(license_expires_timestamp_seconds - time()) / 86400 < 14
```

---

## 4. The `/ops` JSON API

All endpoints are `GET`, return the standard `{ "success": true, "data": … }`
envelope, and are logged at `debug` (a polling dashboard adds no log noise).
Every section is **best-effort**: a dependency that cannot be reached shows
up as `{ "ok": false, "error": "…" }` inside an otherwise complete document.

| Endpoint | Contents | Cost |
|---|---|---|
| `/ops/snapshot` | Everything below in one document. Cached for 5 s. | one Mongo ping + `dbStats` + `serverStatus`, one Redis `PING` + `INFO` per client, BullMQ counts, a Redis `SCAN` |
| `/ops/process` | pid, uptime, Node version, memory (`rss`, heap, external), CPU utilization since the previous call, event-loop utilization and delay percentiles (`p50`, `p99`, `max` in ms), active handle counts by type, `logLevel`. | none |
| `/ops/dependencies` | **mongo**: `readyState`, host, database, pool (`connectionsInUse` / `connectionsTotal` / `maxPoolSize`), `pingMs`, `dbStats` (collections, objects, data / storage / index size), `serverStatus` (version, uptime, `connections.current/available`, `opcounters`, resident memory). **redis[]**: per client status, `pingMs`, `INFO` subset (version, uptime, clients, memory, evicted keys). **kafkaPool**, **postgresSessions**. | as above |
| `/ops/queues` | Per queue: every BullMQ state count, `paused`, connected workers (id, address, age, idle), `oldestWaitingAgeMs`, rate limiter, configured concurrency. | BullMQ |
| `/ops/instances` | Every backend / worker / ui-runner process heartbeating in Redis: role, version, git sha, hostname, pid, started / last beat, queue, concurrency, `activeJobs`, `rssBytes`, `heapUsedBytes`, `eventLoopUtilization`, health port. | Redis `SCAN` |
| `/ops/http` | Rolling **1 / 5 / 15 minute** windows computed in-process from the last 50 000 requests: total, rps, error rate, status classes, `p50/p95/p99`, and the top routes with per-route percentiles. `coveredSeconds` tells you how much of the window the buffer actually holds. | none |
| `/ops/config` | The **effective, non-secret** configuration (ports, pool sizes, concurrency, timeouts, retention, feature switches) plus `derived` booleans (`redisConfigured`, `bullBoardEnabled`, `telegramConfigured`). Never a URI, secret, token or password — a unit test rejects such keys. | none |
| `/ops/license` | Status, read-only flag, warning level, days remaining, validity window, company, seats max / used, rejection reason. | Mongo (60 s cached) |

Examples:

```bash
BASE=http://localhost:8080

curl -s $BASE/ops/snapshot | jq '{build, process: .process.memory, mongo: .dependencies.mongo.pingMs, queues: .queues.queues[].counts}'
curl -s $BASE/ops/instances | jq '.data.instances[] | {role, instanceId, activeJobs, rssBytes}'
curl -s $BASE/ops/http | jq '.data.last5m | {rps, errorRate, p95Ms, routes: .routes[:5]}'
curl -s $BASE/ops/queues | jq '.data.queues[] | {name, counts, paused, oldestWaitingAgeMs}'
```

`serverStatus` needs the MongoDB `clusterMonitor` role. The bundled Mongo
user is root, so it works out of the box; with an external database and a
`readWrite`-only user that section reports `{ "ok": false, "error": "not
authorized …" }` while `dbStats` (needs only `read`) keeps working.

### Grafana without Prometheus

Install the **Infinity** datasource, point it at
`http://<backend>:8080/ops/snapshot`, and use JSONPath selectors such as
`$.data.queues.queues[*].counts.waiting` or
`$.data.http.last5m.p95Ms`. Poll every 10–30 s; the snapshot is cached for
5 s server-side, so a dashboard with many panels is still one query per
5 s.

---

## 5. Health probes (unchanged)

| Endpoint | Where | Checks | Used by |
|---|---|---|---|
| `GET /health/live` | backend `:8080`, worker `:9090`, ui-runner `:9091` | process answers | Docker `healthcheck`, K8s liveness / startup |
| `GET /health/ready` | same | Mongo `readyState` + Redis `PING` (503 when degraded) | K8s readiness, `helm test` |
| `GET /health` | backend | queue counts + build info | `scripts/autoscale-worker.sh` (`.data.queue.waiting/.active` — this shape is frozen), humans |
| `GET /version` | backend | build info | release tooling |

---

## 6. Logs

The backend writes one JSON line per event to stdout; Compose and
Kubernetes collect it. Relevant knobs:

| Setting | Default | Effect |
|---|---|---|
| `LOG_LEVEL` | `info` | Minimum level emitted (`debug` / `info` / `warn` / `error`). |
| `HTTP_LOG_SKIP_PATHS` | probes, `/metrics`, `/ops/*` | Requests on these paths are logged at `debug` — invisible at the default level. This is why health checks no longer flood the logs. |
| `HTTP_LOG_SLOW_MS` | `2000` | Any request at or above this is logged at `warn` as `HTTP request slow`, skip list or not. 5xx responses are always `warn`. |
| Compose `x-logging` | `20m` × `5` files | json-file rotation per container (100 MB cap). |

Each request line carries `method`, `path`, `statusCode`, `durationMs`,
`userId`, `ip` and `instanceId`; ship them to your log stack as JSON. To
see every request temporarily:

```bash
# .env
LOG_LEVEL=debug
docker compose up -d backend      # re-create only the backend
```

Remember to set it back — at `debug` the probe lines return.

---

## 7. What to alert on (starting point)

| Condition | Why |
|---|---|
| `up == 0` for the backend, or `worker_instances{role="worker"} == 0` | nothing is serving / consuming |
| `bullmq_jobs_waiting > N` for 10 min | workers cannot keep up — scale (see SCALING.md) |
| `increase(bullmq_jobs_stalled_total[15m]) > 0` | a worker crashed mid-job or is starved |
| `mongodb_connection_state != 1` or any `disconnected` transition | database link lost |
| `mongodb_pool_connections{state="in_use"}` near `MONGODB_MAX_POOL_SIZE` | pool saturation |
| `redis_client_state == 0` | queue / cache backend unreachable |
| 5xx ratio > 1 % for 5 min, or p95 > 2 s on a hot route | user-visible degradation |
| `nodejs_eventloop_utilization > 0.8` on a worker | CPU-bound; lower concurrency or add replicas |
| `process_resident_memory_bytes` climbing without plateau | leak — restart and report |
| licence expiring in < 14 days | renewal |
