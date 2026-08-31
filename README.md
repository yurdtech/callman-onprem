# Callman — On-Prem Deployment

Everything needed to run **Callman** on your own infrastructure.

This repository contains **only deployment files** — Docker Compose, a Helm
chart, config templates and documentation. No application source: the images
are pre-built and versioned, and you pull them from our registry.

By default the stack is **all-in-one** — it brings its own MongoDB and Redis, so
one command gives you a working install. You can point it at your company's
existing databases instead, by editing `.env` only.

## Two ways to install

| | Docker Compose | Helm (Kubernetes / OpenShift) |
| --- | --- | --- |
| Best for | a single Linux VM | an existing cluster (banks: OpenShift) |
| Guide | [docs/INSTALL.md](docs/INSTALL.md) — and the quick start below | [docs/HELM-INSTALL.md](docs/HELM-INSTALL.md) |
| Config | `.env` file | `values.yaml` + a Kubernetes Secret |
| Exposure / TLS | host ports, your reverse proxy | Route (OpenShift) or Ingress + cert-manager |
| Scaling | `--scale worker=N` + cron autoscaler | `worker.replicaCount` / HPA |
| Air-gapped installs | copy images manually | `scripts/helm-airgap-bundle.sh` |

Both run the same images and the same feature set; pick one per environment.

---

## Quick start

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

## Bundled databases, or your own?

**Bundled (default).** Callman runs MongoDB and Redis for you; the data lives in
Docker volumes and survives restarts. Nothing to configure.

**Your own.** If your company already runs MongoDB and/or Redis, point Callman
at them by editing **`.env` only** — remove the matching profile from
`COMPOSE_PROFILES` and set `MONGODB_URI` / `REDIS_URL`:

```dotenv
COMPOSE_PROFILES=bundled-redis        # keep our Redis, drop our MongoDB
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin
```

Then `docker compose up -d`. You can mix freely, and you **never edit
`docker-compose.yml`** — that is what keeps updates painless.

Full guide, including replica sets, TLS with a private CA, and databases
running on the Docker host: **[docs/EXTERNAL-DATABASES.md](docs/EXTERNAL-DATABASES.md)**.

---

## What's in this repo

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | The stack: backend, worker, one-shot migrator, admin panel, optional bundled MongoDB + Redis |
| [`.env.example`](.env.example) | Configuration template — copy to `.env` and fill in. **The only file you edit.** |
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

> ⚠️ **Security.** Set a **strong** `ADMIN_BOOTSTRAP_PASSWORD` before first
> start and change it right after your first login. Do **not** expose this port
> to the internet — keep it behind your VPN or an authenticating reverse proxy;
> its API documentation page (`/admin/docs`) is readable by anyone who can reach
> the port. Leave `CALLMAN_DB_WRITE_ENABLED=false` unless you specifically need
> admin writes.

Full setup + verification: [docs/INSTALL.md](docs/INSTALL.md#8-activate-your-license).

---

## Updating

```bash
git pull                       # ALWAYS first — refresh these deployment files
# set the new CALLMAN_VERSION in .env, then:
docker compose pull && docker compose up -d
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
stuck, contact us with the output of `docker compose ps` and
`docker compose logs` (never send your `.env` — it contains secrets).

- 📧 [info@yurdtech.com](mailto:info@yurdtech.com)
- 📞 [+994 70 238 88 38](tel:+994702388838)
