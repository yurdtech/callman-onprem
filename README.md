# Callman — On-Prem Deployment

Everything needed to run **Callman** on your own server with Docker. This
repository contains **only deployment files** (Docker Compose + config
templates + docs) — no application source. The backend runs from a
pre-built, versioned image we provide via GitHub Container Registry (GHCR).

By default this stack is **all-in-one**: it brings its own MongoDB and
Redis, so one command gives you a working install. You can switch to your
own databases later (see [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md)).

---

## Quick start

> Full step-by-step (with what each command should print):
> **[docs/INSTALL.md](docs/INSTALL.md)**.

```bash
# 0. Requirements: Docker + Docker Compose v2, and the access token we gave you.

# 1. Log in to the private image registry (one time)
echo <ACCESS_TOKEN> | docker login ghcr.io -u yurdtech --password-stdin

# 2. Create your config from the template
cp .env.example .env
#    → edit .env: set CALLMAN_VERSION, passwords, and the secrets
#      (generate each secret with:  openssl rand -hex 32)

# 3. Pull and start
docker compose pull
docker compose up -d

# 4. Verify
docker compose ps
curl http://localhost:8080/health
```

A healthy install: all services `running`/`healthy`, the `callman-migrate`
service shows `Exited (0)`, and `/health` returns HTTP 200.

---

## What's in this repo

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | The stack: backend, worker, one-shot migrator, bundled MongoDB + Redis |
| [`.env.example`](.env.example) | Configuration template — copy to `.env` and fill in |
| [`docs/INSTALL.md`](docs/INSTALL.md) | Step-by-step install + first-run checks + updating |
| [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) | Every `.env` setting: required/optional, default, meaning |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Common errors and how to fix them |

---

## How it works (30-second tour)

- **backend** — the Callman HTTP API (the port you curl / point clients at).
- **worker** — runs background jobs (scenario runs, schedules).
- **migrate** — runs once on every start: backs up the database, applies any
  new schema migrations, then exits. backend + worker start **only after**
  it succeeds.
- **mongo / redis** — bundled data stores (your data lives in Docker
  volumes and survives restarts).

## Updating

Set the new `CALLMAN_VERSION` in `.env`, then `docker compose pull &&
docker compose up -d`. Migrations apply automatically. Details +
rollback notes: [docs/INSTALL.md](docs/INSTALL.md#updating).

## Admin panel

A web admin panel is **coming soon**. A placeholder is already wired in
`docker-compose.yml` (commented out) and will be enabled in a future
release — nothing to do today.

## Need help?

Start with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). If you're
still stuck, contact your Callman vendor with the output of
`docker compose ps` and `docker compose logs`.
