# Installing Callman with Helm (Kubernetes / OpenShift)

The Helm chart in [`helm/callman/`](../helm/callman/) is the second supported
deployment option, equivalent to the docker-compose stack: backend API,
scenario worker, migrations, admin panel, optional UI-test runner, and
optional bundled MongoDB/Redis. LDAP needs nothing here — it is configured
inside the admin panel (see [AUTH_SETUP.md](AUTH_SETUP.md)).

Works on vanilla Kubernetes (Ingress) and OpenShift (Route, restricted-v2
SCC) from the same chart.

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

The `backups` PVC carries `helm.sh/resource-policy: keep` — it survives even
`helm uninstall`.

## 6. Scaling

| compose | helm |
| --- | --- |
| `docker compose up -d --scale worker=3` | `--set worker.replicaCount=3` |
| `scripts/autoscale-worker.sh` (cron) | `worker.hpa.enabled=true` (CPU-based) |
| ui-runner replicas | `uiRunner.replicaCount` / `uiRunner.hpa.enabled` |
| `BULLMQ_WORKER_CONCURRENCY` | `worker.concurrency` |

Worker scale-out is safe (shared BullMQ queue + per-schedule redlock — see
[SCALING.md](SCALING.md)). `admin.replicaCount > 1` additionally requires
`admin.extraEnv.RELEASE_REMINDERS_ENABLED: "false"` (the chart enforces it).
UI-runner: budget ~2 GB memory per replica; its in-memory `/dev/shm`
(`uiRunner.shmSize`, default 2Gi) counts against the container memory limit.

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
| `SHUTDOWN_TIMEOUT_MS` | `worker.shutdownTimeoutMs` (grace period derives from it) |
| `UITEST_WORKER_CONCURRENCY` | `uiRunner.concurrency` |
| `UITEST_RUN_MAX_DURATION_MS` | `uiRunner.runMaxDurationMs` |
| `METRICS_ENABLED` | `backend.metricsEnabled` |
| `CLIENT_ORIGIN` | `backend.clientOrigin` |
| `PUBLIC_API_BASE_URL` | `backend.publicApiBaseUrl` |
| `MOCK_PUBLIC_BASE_URL` | `backend.mockPublicBaseUrl` |
| `SKIP_MIGRATION_BACKUP` | `migrate.backup.enabled: false` |
| `MONGODB_BACKUP_DIR` | fixed `/backups` on the backups PVC |
| any other [ENVIRONMENT.md](ENVIRONMENT.md) var | `backend.extraEnv` / `worker.extraEnv` / `uiRunner.extraEnv` / `admin.extraEnv` |

## 11. Troubleshooting quick hits

- **Pods CrashLoopBackOff right after install/upgrade** — check
  `kubectl logs job/<release>-migrate-<revision>`; the apps gate on it.
- **`/health/ready` 503** — Mongo or Redis unreachable; the response body
  names the failing check.
- **Bundled Mongo auth failures after changing the password** — root
  credentials only apply to an **empty** volume (same drift as compose, see
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md)); fix the URI or reset the PVC.
- **UI-runner OOMKilled** — raise `uiRunner.resources.limits.memory`
  (remember `/dev/shm` counts against it).
- **Image pull errors on OpenShift** — confirm the pull secret is in the
  release namespace and listed under `global.imagePullSecrets`.
