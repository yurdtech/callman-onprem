# Installing Callman with Helm (Kubernetes / OpenShift)

The Helm chart in [`helm/callman/`](../helm/callman/) is the second supported
deployment option, equivalent to the docker-compose stack: backend API,
scenario worker, migrations, admin panel, optional UI-test runner, and
optional bundled MongoDB/Redis. LDAP needs nothing here — it is configured
inside the admin panel (see [AUTH_SETUP.md](AUTH_SETUP.md)).

Works on vanilla Kubernetes (Ingress) and OpenShift (Route, restricted-v2
SCC) from the same chart.

This guide describes Callman on-prem 1.0.6 — Helm chart 0.4.0, backend, admin
panel and UI-test runner 1.0.6, desktop 2.0.14, CLI (`callme-cli`) 1.11.0, MCP
(`callman-mcp`) 0.10.0.

---

## 0. Prerequisites

- Kubernetes 1.25+ or OpenShift 4.12+, `kubectl`/`oc`, Helm 3.12+.
- A default StorageClass (bundled Mongo 20Gi, Redis 5Gi, backups 10Gi).
- Access to `ghcr.io` (private images) — or the airgap bundle, section 7.
- Resource floor: 2 vCPU / 4 GB for the core tier; +2 GB memory per UI-runner
  replica.

## 1. Namespace and registry access

```bash
kubectl create namespace callman
kubectl -n callman create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=yurdtech \
  --docker-password=<token we provide>
```

## 2. Secrets

The chart never generates secrets. Create one Secret whose keys are the exact
env names (recommended — works with Vault/SealedSecrets pipelines):

```bash
kubectl -n callman create secret generic callman-secrets \
  --from-literal=JWT_SECRET=$(openssl rand -hex 32) \
  --from-literal=JWT_REFRESH_SECRET=$(openssl rand -hex 32) \
  --from-literal=SESSION_TOKEN_ENCRYPTION_SECRET=$(openssl rand -hex 32) \
  --from-literal=CONNECTION_ENCRYPTION_KEY=$(openssl rand -hex 32) \
  --from-literal=ADMIN_JWT_SECRET=$(openssl rand -hex 32) \
  --from-literal=ADMIN_JWT_REFRESH_SECRET=$(openssl rand -hex 32) \
  --from-literal=ADMIN_BOOTSTRAP_EMAIL=admin@example.com \
  --from-literal=ADMIN_BOOTSTRAP_PASSWORD='<strong password>' \
  --from-literal=MONGO_ROOT_PASSWORD=$(openssl rand -hex 16) \
  --from-literal=REDIS_PASSWORD=$(openssl rand -hex 16) \
  --from-literal=MONGODB_URI='mongodb://callman:<MONGO_ROOT_PASSWORD>@<release>-mongo:27017/callman?authSource=admin' \
  --from-literal=REDIS_URL='redis://:<REDIS_PASSWORD>@<release>-redis:6379' \
  --from-literal=CALLMAN_MONGODB_URI='<same as MONGODB_URI>'
```

Rules (the same ones `preflight.sh` enforces for compose):

- every `*_SECRET`/`*_KEY` ≥ 32 characters;
- the four backend secrets must be four **different** values;
- `CONNECTION_ENCRYPTION_KEY` is shared by backend and admin panel — one key;
- with an external Mongo/Redis put their URIs in `MONGODB_URI` / `REDIS_URL`
  (syntax and TLS options: [EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md);
  `host.docker.internal` does not apply in-cluster).

Alternative: inline values under `secrets.values.*` — then the chart renders
the Secret itself and validates all of the above at `helm template` time.

## 3. values file

```yaml
# my-values.yaml
global:
  imagePullSecrets: [ghcr-pull]
secrets:
  existingSecret: callman-secrets

mongo:  { enabled: true }      # or false + externalMongo.uri
redis:  { enabled: true }      # or false + externalRedis.url
uiRunner: { enabled: false }   # opt-in, like the compose ui-runner profile

# OpenShift:
backend:
  route: { enabled: true, host: callman.apps.<cluster-domain> }
admin:
  route: { enabled: true, host: callman-admin.apps.<cluster-domain> }

# vanilla Kubernetes instead:
# backend:
#   ingress:
#     enabled: true
#     className: nginx
#     host: callman.example.com
#     annotations: { cert-manager.io/cluster-issuer: letsencrypt }
#     tls: [{ hosts: [callman.example.com], secretName: callman-tls }]
```

Neither Route nor Ingress is required — with both off, use
`kubectl port-forward` (the chart prints the commands after install).

## 4. Install

```bash
helm install callman oci://ghcr.io/yurdtech/charts/callman \
  --version <chart version> -n callman -f my-values.yaml
```

What happens: a `callman-migrate-1` Job runs the schema migrations (with a
pre-migration `mongodump` into the `backups` PVC); app pods may
CrashLoopBackOff for a minute until it completes — **that is the migration
gate, not an error**. Then:

```bash
kubectl -n callman get pods           # everything Running/Completed
helm test callman -n callman          # backend + admin /health/ready
```

First login with the bootstrap credentials, change the password, and paste
the license certificate (admin panel → On-Prem → License) — the platform is
read-only until then.

## 5. Upgrade / rollback

```bash
helm upgrade callman oci://ghcr.io/yurdtech/charts/callman \
  --version <newer chart> -n callman -f my-values.yaml
```

- Each revision runs a fresh migrate Job (idempotent, redlock-serialized).
- Backend/admin roll with `maxUnavailable: 0` — no downtime.
- **Migrations are irreversible.** `helm rollback callman` restores the
  previous images, but if the upgrade applied a migration you must also
  restore the automatic pre-upgrade dump:

```bash
# find the archive on the backups PVC
kubectl -n callman run backup-shell --rm -it --image=mongo:7 \
  --overrides='{"spec":{"containers":[{"name":"backup-shell","image":"mongo:7","stdin":true,"tty":true,"command":["bash"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"callman-backups"}}]}}'
# inside: mongorestore --uri="$MONGODB_URI" --archive=/backups/callman-backup-<stamp>.archive.gz --gzip --drop
```

- **Old Oracle (11g).** Release 1.0.6 adds it and moves the backend images
  from Alpine to Debian slim: values do not change, the first pull is ~60–80 MB
  larger (so is the airgap `images.tar`). The Oracle client itself is installed
  from the admin panel (see
  [ENVIRONMENT.md](ENVIRONMENT.md#connecting-to-old-oracle-databases)), not
  from the chart. After **Apply now** the backend, worker and ui-runner pods
  exit one by one and Kubernetes starts them again, so their restart count goes
  up by one — expected, not a crash loop. No PVC is needed; on OpenShift the
  client directory is writable by the assigned UID.

The `backups` PVC carries `helm.sh/resource-policy: keep` — it survives even
`helm uninstall`.

### Upgrading to chart 0.4.0

- **Mock engine v2.** Mocks gain resources with their own data, sign-in
  simulation, faults, `X-Mock-Session` test sessions and imports
  (`POST /api/import/mocks`) — see
  [MOCK-SERVER.md](MOCK-SERVER.md#mock-engine-v2-data-sign-in-faults-sessions-imports).
  This needs **backend 1.0.6** (the first release with mock engine v2) and
  **admin panel 1.0.6**, which moves and deletes mock data with its mock: the
  chart's `appVersion` (the default image tag) and `admin.image.tag` point at
  them. If you pin `backend.image.tag` yourself, pin 1.0.6 or newer — an older
  backend simply ignores the new settings.
- **New values `mock.limits.*`** (resources, records, sessions, imports). The
  defaults suit every install; they are rendered into the shared ConfigMap
  for every pod, because the API checks definitions and imports against them
  and keeps serving `/mock/*` until the mock pods are routed. Setting one to
  `null` leaves the backend default.
- **Import size vs. your Ingress.** The nginx Ingress controller rejects
  request bodies over 1 MB by default; the chart does not raise that for the
  backend. To import mock files up to the default 2 MB, add
  `nginx.ingress.kubernetes.io/proxy-body-size: "4m"` to
  `backend.ingress.annotations`. OpenShift Routes have no body limit.
- **New collections, no action.** Mock data lives in `mockRecords` and
  `mockNamespaces` in the same MongoDB and expires with its mock. The migrate
  Job creates their indexes.

### Upgrading to chart 0.3.0

- **Mock server (new, on by default).** `helm upgrade` adds a `<release>-mock`
  Deployment and Service that serve the public `/mock/*` surface, so mock
  traffic and load tests against mocks no longer share the API's pods. It needs
  a backend image that ships `dist/mock-server.js` — use the app version this
  chart release pins (do not pin `backend.image.tag` to an older release with
  `mock.enabled=true`).
  - With a backend Ingress, or an OpenShift Route **with a host**, the mock
    Ingress/Route joins that host on `/mock`. Mock URLs do not change and the
    API hands mock traffic over automatically (`MOCK_SERVE_ON_API=false`).
  - For a mock domain of its own, set `mock.ingress.host` / `mock.route.host`.
  - Without either, the mock pods run idle and the API keeps serving mocks.
    The NOTES say so. Details: [MOCK-SERVER.md](MOCK-SERVER.md).
- **Mock lifetime moves to the admin panel** (Mocks → Mock lifetime: 2 days
  unless changed, 10 / 20 days or custom).
- **Rate limiting counts in Redis everywhere.** The chart already pinned
  `RATE_LIMIT_STORE=redis`, so there is nothing to change.

### Upgrading to chart 0.2.0 (app 1.0.5)

Read this before running the upgrade; one item can stop the chart rendering.

- ⚠️ **`storage.localVolume` now requires `ReadWriteMany`.** The claim is mounted
  by the backend Deployment as well as the storage gateway, because desktop
  release artifacts are written and served by the API process. With
  `ReadWriteOnce` the chart **fails to render** and tells you so. Either switch
  `storage.localVolume.accessModes` to `[ReadWriteMany]`, or — better — connect
  S3/MinIO in the admin panel and leave `storage.localVolume.enabled=false`.
  Nothing to do if you never enabled the local volume.
- **Desktop auto-update arrives.** Your admins upload the installers we deliver in
  **Desktop Releases → Upload a build**, and every desktop then updates itself
  from your own storage. See [`DESKTOP-APP.md`](./DESKTOP-APP.md). Two values are
  worth setting, both optional in the sense that the chart renders without them:
  - `backend.publicApiBaseUrl` — **effectively required.** It is the address every
    desktop is told to fetch updates from; unset, the backend guesses it per
    request and behind a router that does not forward `X-Forwarded-Proto` that
    yields `http://`, which the macOS updater refuses.
  - `backend.onpremCompanySlug` — the company name in the build we deliver, as a
    second guard against publishing another customer's build.
- **Nothing to do about proxy limits.** The admin, backend and storage Ingresses
  and Routes now carry the body-limit and timeout annotations themselves — an
  OpenShift router otherwise cuts a release upload off after 30 seconds. Your own
  `*.route.annotations` / `*.ingress.annotations` still override them.
- `backend.httpRequestTimeoutMs` defaults to 30 minutes, which is what an
  installer upload needs. Override only if yours take longer.

## 6. Scaling

| compose | helm |
| --- | --- |
| `docker compose up -d --scale worker=3` | `--set worker.replicaCount=3` |
| `scripts/autoscale-worker.sh` (cron) | `worker.hpa.enabled=true` (CPU-based) |
| ui-runner replicas | `uiRunner.replicaCount` / `uiRunner.hpa.enabled` |
| storage gateway replicas | `storage.replicaCount` (stateless — no shared volume needed) |
| `BULLMQ_WORKER_CONCURRENCY` | `worker.concurrency` |

Worker scale-out is safe (shared BullMQ queue + per-schedule redlock — see
[SCALING.md](SCALING.md)). `admin.replicaCount > 1` additionally requires
`admin.extraEnv.RELEASE_REMINDERS_ENABLED: "false"` (the chart enforces it).
UI-runner: budget ~4 GiB memory per replica at concurrency 2 (the chart
default limit); its in-memory `/dev/shm` (`uiRunner.shmSize`, default 1Gi)
counts against the container memory limit.

Memory knobs (chart 0.2.0+): every Node container gets a V8 heap cap from
`backend.heapMb` / `worker.heapMb` / `uiRunner.heapMb` (rendered as
`NODE_OPTIONS=--max-old-space-size`) — keep it ~25% under the container's
memory limit — and a per-replica Mongo pool from `*.mongoPool`. The worker
runs at `worker.concurrency: 20` by default; raise it together with
`worker.heapMb` and the memory limit. `worker.shutdownTimeoutMs` (120 s) and
`uiRunner.drainTimeoutMs` (120 s; up to 900000 with backend ≥ 1.1) are the
rollout drain budgets — the pods' `terminationGracePeriodSeconds` derive from
them.

### Storage gateway

The gateway is stateless, so `storage.replicaCount` scales without any shared
volume — the one exception being the *Local volume* provider, where every replica
must mount the same PVC and `storage.localVolume.accessModes` must therefore
include `ReadWriteMany` (the chart refuses the unsafe pairing).

Exposing it needs one deliberate step, because the defaults of every ingress
controller are wrong for large files. With the nginx controller:

```yaml
storage:
  enabled: true
  publicUrl: https://callman.bank.local     # what clients see; required
  ingress:
    enabled: true
    className: nginx
    host: callman.bank.local                # may be the backend's host
    annotations:
      # The controller's default body limit is 1 MB — a build artifact would be
      # rejected with 413 before it reached Callman.
      nginx.ingress.kubernetes.io/proxy-body-size: "0"
      nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
      nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

On OpenShift use `storage.route` instead (the chart rejects both at once) and
raise the router timeout with
`haproxy.router.openshift.io/timeout: 1h` in `storage.route.annotations`.

Where the files actually go is **not** chart configuration: connect your S3 /
MinIO / FileNet in the admin panel under **Storage**. See
[STORAGE.md](STORAGE.md).

## 7. Airgap installation

On an internet host (logged in to ghcr.io):

```bash
scripts/helm-airgap-bundle.sh --platform linux/amd64
# -> dist/callman-helm-airgap-<version>.tar.gz
```

Inside the customer network:

```bash
tar -xzf callman-helm-airgap-<version>.tar.gz -C bundle && cd bundle
./helm-airgap-load.sh registry.bank.local     # verifies checksums, loads, retags, pushes
helm install callman ./callman-<chartver>.tgz -n callman --create-namespace \
  --set global.imageRegistry=registry.bank.local -f my-values.yaml
```

`global.imageRegistry` re-points **every** image (app + bundled mongo/redis)
at the internal registry. Telegram error reporting stays disabled by default,
so no outbound internet is needed.

## 8. OpenShift notes

- The chart runs under the default **restricted-v2 SCC**: no pinned UIDs, no
  privilege escalation, all capabilities dropped. App images already run as
  non-root users.
- Bundled Mongo/Redis run under an SCC-assigned arbitrary UID with the
  SCC-injected `fsGroup` making the data volumes writable. If your cluster
  policy blocks that, either grant `anyuid` to the release ServiceAccount or
  (the usual bank posture) use external databases.
- TLS: `route.tls.termination: edge` (default) terminates at the router;
  `reencrypt`/`passthrough` are available if you front the pods with your own
  certs.

## 9. Private CA certificates

Compose's `./certs` directory maps to:

```yaml
certs:
  files:
    mongo-ca.pem: |
      -----BEGIN CERTIFICATE-----
      ...
```

(or `certs.existingConfigMap`). Mounted read-only at `/certs` in every app
container, so URIs like `...&tls=true&tlsCAFile=/certs/mongo-ca.pem` work
exactly as documented in [EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md).

## 10. `.env` → values mapping

| compose `.env` | chart values |
| --- | --- |
| `CALLMAN_VERSION` | chart `appVersion` (override: `backend.image.tag`) |
| `CALLMAN_ADMIN_VERSION` | `admin.image.tag` |
| `CALLMAN_PORT` | `backend.port` |
| `COMPOSE_PROFILES=bundled-mongo` | `mongo.enabled: true` |
| `COMPOSE_PROFILES=bundled-redis` | `redis.enabled: true` |
| `COMPOSE_PROFILES=ui-runner` | `uiRunner.enabled: true` |
| `COMPOSE_PROFILES=storage` | `storage.enabled: true` (+ `storage.publicUrl`, required) |
| `MONGO_ROOT_USERNAME` | `mongo.auth.rootUsername` |
| `MONGO_ROOT_PASSWORD` | Secret key `MONGO_ROOT_PASSWORD` |
| `REDIS_PASSWORD` | Secret key `REDIS_PASSWORD` |
| `MONGODB_URI` | `externalMongo.uri` or Secret key `MONGODB_URI` |
| `REDIS_URL` | `externalRedis.url` or Secret key `REDIS_URL` |
| `JWT_SECRET`, `JWT_REFRESH_SECRET`, `SESSION_TOKEN_ENCRYPTION_SECRET`, `CONNECTION_ENCRYPTION_KEY` | Secret keys, same names |
| `ADMIN_JWT_SECRET`, `ADMIN_JWT_REFRESH_SECRET` | Secret keys, same names |
| `ADMIN_BOOTSTRAP_EMAIL` / `ADMIN_BOOTSTRAP_PASSWORD` | Secret keys, same names |
| `CALLMAN_ADMIN_PORT` | fixed 5100 in-cluster (expose via Route/Ingress) |
| `CALLMAN_BACKEND_API_URL` | `admin.backendApiUrl` (default: in-cluster backend service — leave empty) |
| `CALLMAN_MONGODB_URI` | `admin.mongodbUri` (default: backend's URI) |
| `CALLMAN_DB_WRITE_ENABLED` | `admin.dbWriteEnabled` |
| `CORS_ORIGINS` | `admin.corsOrigins` |
| `RATE_LIMIT_MAX` | `admin.rateLimitMax` |
| `BULLMQ_WORKER_CONCURRENCY` | `worker.concurrency` |
| `WORKER_HEALTH_PORT` | `worker.healthPort` |
| `SHUTDOWN_TIMEOUT_MS` | `worker.shutdownTimeoutMs` (worker grace period derives from it); `uiRunner.drainTimeoutMs` for the ui-runner; `storage.drainTimeoutMs` for the gateway; `mock.drainTimeoutMs` for the mock server |
| `NODE_OPTIONS` (`--max-old-space-size`) | `backend.heapMb` / `worker.heapMb` / `uiRunner.heapMb` / `storage.heapMb` / `mock.heapMb` |
| `MONGODB_MAX_POOL_SIZE` / `MONGODB_MIN_POOL_SIZE` | `backend.mongoPool` / `worker.mongoPool` / `uiRunner.mongoPool` / `storage.mongoPool` / `mock.mongoPool` |
| `RATE_LIMIT_STORE` | fixed `redis` (Redis is always present) |
| `UV_THREADPOOL_SIZE` | fixed `8` |
| `BULLMQ_LOCK_DURATION_MS` | fixed `120000` |
| `UITEST_WORKER_CONCURRENCY` | `uiRunner.concurrency` |
| `UITEST_RUN_MAX_DURATION_MS` | `uiRunner.runMaxDurationMs` |
| `UITEST_BROWSER_CHANNEL` | fixed `bundled` on the ui-runner |
| `CALLMAN_STORAGE_PORT` | `storage.port` |
| `CALLMAN_STORAGE_HEALTH_PORT` | `storage.healthPort` |
| `CALLMAN_STORAGE_PUBLIC_URL` | `storage.publicUrl` (required when `storage.enabled`) |
| `STORAGE_MAX_UPLOAD_BYTES` | `storage.maxUploadBytes` |
| `METRICS_ENABLED` | `backend.metricsEnabled` |
| `CLIENT_ORIGIN` | `backend.clientOrigin` |
| `PUBLIC_API_BASE_URL` | `backend.publicApiBaseUrl` |
| `MOCK_PUBLIC_BASE_URL` | `mock.publicUrl` (legacy `backend.mockPublicBaseUrl`); derived from the mock Ingress/Route host when unset |
| `MOCK_SERVE_ON_API` | derived: `false` when an Ingress/Route sends `/mock/*` to the mock pods |
| `CALLMAN_MOCK_PORT` / `CALLMAN_MOCK_HEALTH_PORT` | `mock.port` / `mock.healthPort` |
| `MOCK_IP_RATE_LIMIT_PER_SECOND` | `mock.ipRateLimitPerSecond` |
| `MOCK_MAX_RESOURCES_PER_MOCK` | `mock.limits.maxResourcesPerMock` |
| `MOCK_MAX_RECORDS_PER_RESOURCE` / `MOCK_MAX_RECORDS_PER_NAMESPACE` | `mock.limits.maxRecordsPerResource` / `mock.limits.maxRecordsPerNamespace` |
| `MOCK_MAX_RECORD_BYTES` / `MOCK_MAX_SEED_BYTES` | `mock.limits.maxRecordBytes` / `mock.limits.maxSeedBytes` |
| `MOCK_MAX_SESSIONS_PER_MOCK` / `MOCK_SESSION_IDLE_TTL_MINUTES` | `mock.limits.maxSessionsPerMock` / `mock.limits.sessionIdleTtlMinutes` |
| `MOCK_MAX_DATA_OPS_PER_REQUEST` / `MOCK_DATA_QUERY_TIMEOUT_MS` | `mock.limits.maxDataOpsPerRequest` / `mock.limits.dataQueryTimeoutMs` |
| `MOCK_MAX_IMPORT_BYTES` | `mock.limits.maxImportBytes` |
| `SKIP_MIGRATION_BACKUP` | `migrate.backup.enabled: false` |
| `MONGODB_BACKUP_DIR` | fixed `/backups` on the backups PVC |
| any other [ENVIRONMENT.md](ENVIRONMENT.md) var | `backend.extraEnv` / `worker.extraEnv` / `uiRunner.extraEnv` / `storage.extraEnv` / `mock.extraEnv` / `admin.extraEnv` |

## 11. Troubleshooting quick hits

- **Pods CrashLoopBackOff right after install/upgrade** — check
  `kubectl logs job/<release>-migrate-<revision>`; the apps gate on it.
- **`/health/ready` 503** — Mongo or Redis unreachable; the response body
  names the failing check.
- **Bundled Mongo auth failures after changing the password** — root
  credentials only apply to an **empty** volume (same drift as compose, see
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md)); fix the URI or reset the PVC.
- **UI-runner OOMKilled** — raise `uiRunner.resources.limits.memory`
  (remember `/dev/shm` counts against it) or lower `uiRunner.concurrency`.
- **Worker / ui-runner restarts with nothing in the logs** — that is the
  kernel OOM killer: check `kubectl describe pod` for `OOMKilled`, then raise
  the memory limit AND the matching `heapMb` (or lower `worker.concurrency`).
  A restart with `Uncaught exception` / `shutdown timed out` in the logs is a
  code path, not memory — file it with the log line.
- **Image pull errors on OpenShift** — confirm the pull secret is in the
  release namespace and listed under `global.imagePullSecrets`.
