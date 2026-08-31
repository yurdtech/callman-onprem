# Callman — On-Prem Deployment

Everything needed to run **Callman** on your own infrastructure.

This repository contains **only deployment files** — Docker Compose, a Helm
chart, config templates and documentation. No application source: the images
are pre-built and versioned, and you pull them from our registry.

By default the stack is **all-in-one** — it brings its own MongoDB and Redis, so
one command gives you a working install. You can point it at your company's
existing databases instead.

---

## Choose your deployment

Callman ships as **two equal, fully supported deployment options**. Both run
the same images and the same feature set — pick whichever fits your
infrastructure:

| | **Option A — Docker Compose** | **Option B — Helm chart** |
| --- | --- | --- |
| Runs on | a single Linux VM with Docker | Kubernetes 1.25+ / OpenShift 4.12+ |
| Full guide | [docs/INSTALL.md](docs/INSTALL.md) | [docs/HELM-INSTALL.md](docs/HELM-INSTALL.md) |
| Config | `.env` file | `values.yaml` + a Kubernetes Secret |
| Exposure / TLS | host ports, your reverse proxy | Route (OpenShift) or Ingress + cert-manager |
| Scaling | `--scale worker=N` + cron autoscaler | `worker.replicaCount` / HPA |
| Air-gapped installs | copy images manually | `scripts/helm-airgap-bundle.sh` |

---

## Option A — Docker Compose quick start

> New to this? Follow the full step-by-step guide instead, which explains what
> each command should print: **[docs/INSTALL.md](docs/INSTALL.md)**.

```bash
# 0. Requirements: Docker + Docker Compose v2.20+, and the access token we gave you.

# 1. Get the deployment files
git clone https://github.com/yurdtech/callman-onprem.git
cd callman-onprem

# 2. Log in to the private image registry (one time)
echo <ACCESS_TOKEN> | docker login ghcr.io -u yurdtech --password-stdin

# 3. Create your config from the template
cp .env.example .env
chmod 600 .env
#    → edit .env: set CALLMAN_VERSION, CALLMAN_ADMIN_VERSION, passwords, and
#      the six secrets (generate each with:  openssl rand -hex 32)

# 4. Check it before starting anything
./scripts/preflight.sh

# 5. Pull and start
docker compose pull
docker compose up -d

# 6. Verify
docker compose ps
curl http://localhost:8080/health/ready   # backend + its databases
curl http://localhost:5100/health         # admin panel

# 7. Activate your license
#    Open http://<this-host>:5100 → log in → paste the certificate we gave you.
#    Callman is read-only until this is done. No .env edit, no restart, no
#    internet connection required.
```

A healthy install: all services `running`/`healthy`, the `callman-migrate`
service showing `Exited (0)`, and `/health` returning HTTP 200.

---

## Option B — Helm chart quick start

> Full guide with the secret recipe, OpenShift/Ingress examples, upgrades and
> the complete `.env` → values mapping: **[docs/HELM-INSTALL.md](docs/HELM-INSTALL.md)**.

```bash
# 0. Requirements: kubectl + Helm 3.12+, a cluster, and the access token we gave you.

# 1. Namespace + registry access (same token as Option A)
kubectl create namespace callman
kubectl -n callman create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=yurdtech --docker-password=<ACCESS_TOKEN>

# 2. Create the secrets (the .env secrets, as one Kubernetes Secret)
kubectl -n callman create secret generic callman-secrets \
  --from-literal=JWT_SECRET=$(openssl rand -hex 32) \
  --from-literal=JWT_REFRESH_SECRET=$(openssl rand -hex 32) \
  --from-literal=SESSION_TOKEN_ENCRYPTION_SECRET=$(openssl rand -hex 32) \
  --from-literal=CONNECTION_ENCRYPTION_KEY=$(openssl rand -hex 32) \
  --from-literal=ADMIN_JWT_SECRET=$(openssl rand -hex 32) \
  --from-literal=ADMIN_JWT_REFRESH_SECRET=$(openssl rand -hex 32) \
  --from-literal=ADMIN_BOOTSTRAP_EMAIL=admin@example.com \
  --from-literal=ADMIN_BOOTSTRAP_PASSWORD='<strong password>' \
  --from-literal=MONGO_ROOT_PASSWORD='<password>' \
  --from-literal=REDIS_PASSWORD='<password>' \
  --from-literal=MONGODB_URI='mongodb://callman:<mongo password>@callman-mongo:27017/callman?authSource=admin' \
  --from-literal=REDIS_URL='redis://:<redis password>@callman-redis:6379'

# 3. Minimal values file
cat > my-values.yaml <<'EOF'
global:  { imagePullSecrets: [ghcr-pull] }
secrets: { existingSecret: callman-secrets }
EOF

# 4. Install (migrations run automatically as a one-shot Job)
helm install callman oci://ghcr.io/yurdtech/charts/callman \
  -n callman -f my-values.yaml

# 5. Verify
kubectl -n callman get pods        # migrate Completed, everything else Running
helm test callman -n callman       # backend + admin /health/ready

# 6. Activate your license
kubectl -n callman port-forward svc/callman-admin 5100:5100
#    Open http://localhost:5100 → log in → paste the certificate we gave you.
```

Pods may restart a few times right after install while the migrate Job
finishes — that is the migration gate, not an error. On OpenShift add Route
values (on plain Kubernetes, Ingress values) to expose the services — examples
in [docs/HELM-INSTALL.md](docs/HELM-INSTALL.md).

---

## Bundled databases, or your own?

**Bundled (default).** Callman runs MongoDB and Redis for you; the data lives
in Docker volumes (Compose) or PersistentVolumeClaims (Helm) and survives
restarts. Nothing to configure.

**Your own.** If your company already runs MongoDB and/or Redis, point Callman
at them — you can mix freely (e.g. your Mongo, our Redis):

```dotenv
# Option A: edit .env only — remove the profile, set the URI
COMPOSE_PROFILES=bundled-redis        # keep our Redis, drop our MongoDB
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin
```

```yaml
# Option B: the same choice in values.yaml
mongo: { enabled: false }
externalMongo:
  uri: mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin
```

Then `docker compose up -d` / `helm upgrade`. You **never edit
`docker-compose.yml` or the chart templates** — that is what keeps updates
painless.

Full guide, including replica sets, TLS with a private CA, and databases
running on the Docker host: **[docs/EXTERNAL-DATABASES.md](docs/EXTERNAL-DATABASES.md)**.

---

## What's in this repo

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | **Option A** — the stack: backend, worker, one-shot migrator, admin panel, optional bundled MongoDB + Redis |
| [`.env.example`](.env.example) | Option A configuration template — copy to `.env` and fill in. **The only file you edit.** |
| [`helm/callman/`](helm/callman/) | **Option B** — the Helm chart: the same stack for Kubernetes / OpenShift |
| [`docs/HELM-INSTALL.md`](docs/HELM-INSTALL.md) | Helm install guide: secrets, OpenShift/Ingress, upgrades, airgap, `.env` → values mapping |
| [`scripts/helm-airgap-bundle.sh`](scripts/helm-airgap-bundle.sh) | Build an offline bundle (chart + all images) for air-gapped clusters |
| [`scripts/helm-airgap-load.sh`](scripts/helm-airgap-load.sh) | Load that bundle into an internal registry (runs inside your network) |
| [`certs/`](certs/) | Drop private-CA certificates here; mounted read-only at `/certs` in every container |
| [`docs/INSTALL.md`](docs/INSTALL.md) | Step-by-step install, first-run checks, updating |
| [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) | Every `.env` setting: required/optional, default, meaning |
| [`docs/EXTERNAL-DATABASES.md`](docs/EXTERNAL-DATABASES.md) | Use your own MongoDB / Redis |
| [`docs/BACKUP.md`](docs/BACKUP.md) | Backing up and restoring your data |
| [`docs/AUTH_SETUP.md`](docs/AUTH_SETUP.md) | How people sign in — email + password, or your corporate LDAP / Active Directory (configured in the admin panel) |
| [`docs/UI-RUNNER.md`](docs/UI-RUNNER.md) | Optional UI-test runner: scheduled web UI tests in a headless browser |
| [`docs/SCALING.md`](docs/SCALING.md) | Watch the job backlog and add worker containers under load |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Common errors and how to fix them |
| [`scripts/preflight.sh`](scripts/preflight.sh) | Config check — run it before `docker compose up -d` |
| [`scripts/autoscale-worker.sh`](scripts/autoscale-worker.sh) | Optional autoscaler — adjusts the worker count from the live backlog |

---

## How it works (30-second tour)

- **backend** — the Callman HTTP API (the port you curl / point desktop clients at).
- **worker** — runs background jobs (scenario runs, schedules). Under heavy load
  you can run several worker containers at once — see
  [docs/SCALING.md](docs/SCALING.md).
- **migrate** — runs once on every start: backs up the database, applies any new
  schema migrations, then exits. Everything else starts **only after** it
  succeeds.
- **admin** — the web admin panel (its own UI + API on one port). It reads the
  same MongoDB directly, has its own login, and never calls the backend API.
- **ui-runner** *(optional, off by default)* — runs your team's **web UI test
  flows** on a schedule, in a headless browser on this server. Separate,
  larger image; enabled with one `.env` line — see
  [docs/UI-RUNNER.md](docs/UI-RUNNER.md).
- **mongo / redis** — the bundled data stores, unless you brought your own.

---

## Admin panel

One image serving both its UI and API on a single port. It connects to the
**same** MongoDB as the backend — bundled or yours, it follows automatically —
and has its own login, independent of the backend's. By default it can only
**read** Callman data (`CALLMAN_DB_WRITE_ENABLED=false`).

Configure it in `.env` (already in `.env.example`):

- `CALLMAN_ADMIN_VERSION` — the admin image version we tell you (e.g. `0.1.0`).
- `CALLMAN_ADMIN_PORT` — port to reach it on (default `5100`).
- `ADMIN_JWT_SECRET`, `ADMIN_JWT_REFRESH_SECRET` — each `openssl rand -hex 32`
  (separate from the backend secrets).
- `ADMIN_BOOTSTRAP_EMAIL`, `ADMIN_BOOTSTRAP_PASSWORD` — the first admin user,
  created automatically on first start.

After `docker compose up -d`, open `http://<this-host>:5100` and log in.
(Helm: the same settings live in the `callman-secrets` Secret and the `admin.*`
values; expose it with a Route/Ingress or `kubectl port-forward`.)

> ⚠️ **Security.** Set a **strong** `ADMIN_BOOTSTRAP_PASSWORD` before first
> start and change it right after your first login. Do **not** expose this port
> to the internet — keep it behind your VPN or an authenticating reverse proxy;
> its API documentation page (`/admin/docs`) is readable by anyone who can reach
> the port. Leave `CALLMAN_DB_WRITE_ENABLED=false` unless you specifically need
> admin writes.

Full setup + verification: [docs/INSTALL.md](docs/INSTALL.md#8-activate-your-license).

---

## Updating

**Option A — Docker Compose:**

```bash
git pull                       # ALWAYS first — refresh these deployment files
# set the new CALLMAN_VERSION in .env, then:
docker compose pull && docker compose up -d
```

**Option B — Helm:**

```bash
helm upgrade callman oci://ghcr.io/yurdtech/charts/callman \
  --version <new chart version> -n callman -f my-values.yaml
# or stay on the same chart and bump only the app image:
#   helm upgrade callman ... --set backend.image.tag=<new version>
```

> **`git pull` is part of every update, not optional.** This cloned folder
> holds the deployment itself — `docker-compose.yml`, scripts, docs. New
> releases regularly change these files too (new optional services such as
> the [UI-test runner](docs/UI-RUNNER.md), healthcheck and script fixes,
> updated docs). Skipping `git pull` means those changes never reach you,
> even though the app images update.

Migrations apply automatically. Details + rollback notes:
[docs/INSTALL.md](docs/INSTALL.md#updating).

---

## Need help?

Start with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). If you're still
stuck, contact us with the output of `docker compose ps` + `docker compose logs`
(Compose) or `kubectl -n callman get pods` + the failing pod's logs (Helm) —
never send your `.env` or Secret contents, they contain credentials.

- 📧 [info@yurdtech.com](mailto:info@yurdtech.com)
- 📞 [+994 70 238 88 38](tel:+994702388838)
