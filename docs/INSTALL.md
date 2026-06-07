# Installing Callman (on-prem)

A complete, copy-paste walkthrough. No prior Docker knowledge needed —
follow the steps in order.

---

## 0. Requirements

- A 64-bit Linux server.
- **Docker** and **Docker Compose v2**. Check they're installed:
  ```bash
  docker --version
  docker compose version
  ```
  Both should print a version. If not, install Docker Engine + the Compose
  plugin from <https://docs.docker.com/engine/install/>.
- **Resources:** at least **2 GB RAM** and **5 GB free disk** for the
  all-in-one stack (more if you expect heavy use).
- The **access token** we provided to pull the private image.

---

## 1. Log in to the image registry (one time)

The Callman image is private. Authenticate Docker with the token we gave
you. The username is always `yurdtech` (the image owner) — **not** your own
GitHub username.

```bash
echo <ACCESS_TOKEN> | docker login ghcr.io -u yurdtech --password-stdin
```

Expected output:

```
Login Succeeded
```

If you see `denied` or `unauthorized`, the token is wrong or expired —
ask us for a new one. (See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).)

---

## 2. Get these deployment files

Download/extract this `callman-onprem` folder onto the server, then open a
terminal **inside it** (the folder containing `docker-compose.yml`):

```bash
cd callman-onprem
```

---

## 3. Create your configuration

```bash
cp .env.example .env
```

Open `.env` in an editor and fill in every `<CHANGE_ME...>` value:

- **`CALLMAN_VERSION`** — the version we told you to install (e.g. `1.0.1`).
- **`MONGO_ROOT_PASSWORD`** and **`REDIS_PASSWORD`** — choose strong
  passwords for the bundled databases.
- **The four secrets** — generate a separate random value for EACH:

  ```bash
  openssl rand -hex 32    # run this 4 times, paste one result per secret
  ```

  Set them on these lines (each must be **different**):
  `JWT_SECRET`, `JWT_REFRESH_SECRET`, `SESSION_TOKEN_ENCRYPTION_SECRET`,
  `CONNECTION_ENCRYPTION_KEY`.

> The app **refuses to start** if a secret is shorter than 32 characters,
> or if any two of the four secrets are equal.

Everything else has safe defaults. (Full reference:
[ENVIRONMENT.md](ENVIRONMENT.md).)

---

## 4. Pull the image

```bash
docker compose pull
```

Downloads the backend image for your `CALLMAN_VERSION` plus MongoDB and
Redis. (First time takes a few minutes.)

---

## 5. Start everything

```bash
docker compose up -d
```

This starts the databases, runs the one-time migration, then starts the
backend and worker.

---

## 6. First-run checks

Run each command and compare to the expected result.

**a) All services up:**

```bash
docker compose ps
```

Expected: `callman-backend`, `callman-worker`, `callman-mongo`,
`callman-redis` show **`running`** (and `healthy` once warmed up), and
`callman-migrate` shows **`Exited (0)`** — that’s correct, the migrator is
a one-shot job that finishes and stops.

**b) Migration succeeded:**

```bash
docker compose logs migrate
```

Expected: ends with something like
`Migrations applied` or `No pending migrations — database is up to date`.

**c) API health (replace 8080 if you changed `CALLMAN_PORT`):**

```bash
curl http://localhost:8080/health
```

Expected: HTTP 200 and JSON like:

```json
{"success":true,"data":{"status":"ok","version":"1.0.1","gitSha":"<sha>","edition":"onprem","queue":{...}}}
```

**d) Version probe:**

```bash
curl http://localhost:8080/version
```

Expected: `{"success":true,"data":{"version":"1.0.1","gitSha":"...","edition":"onprem"}}`.

If all four pass, you’re done. 🎉

To watch logs live:

```bash
docker compose logs -f backend worker
```

---

## Updating

When we publish a new version:

1. Edit `.env` and set the new `CALLMAN_VERSION` (e.g. `1.1.0`).
2. Pull and restart:
   ```bash
   docker compose pull
   docker compose up -d
   ```

The `migrate` service runs first (it also takes a backup), applies the new
schema migrations automatically, and only then do the backend and worker
start on the new version. Confirm with `curl http://localhost:8080/version`.

### Rollback note

To roll back, set the previous `CALLMAN_VERSION` and `docker compose up -d`
again. **Important:** database migrations are **not** automatically
reversed — rolling the app back does not undo schema changes. Before every
update the `migrate` service writes a `mongodump` backup into the `backups`
volume; restore from there if you need to fully revert data. Always take
your own backup before a major upgrade.

---

## Stopping / removing

```bash
docker compose down        # stop everything (your DATA is preserved)
docker compose down -v      # stop AND DELETE all data (destructive!)
```

---

## Admin panel (coming soon)

A web-based admin panel will ship in a future release. The
`docker-compose.yml` already contains a commented-out `admin` service as a
placeholder — there is nothing to configure today. When it’s available
we’ll update these docs with the exact steps.

---

## Using your own MongoDB / Redis

The default install bundles MongoDB and Redis. If you’d rather use your own
existing databases, see
[ENVIRONMENT.md → Using your own MongoDB / Redis](ENVIRONMENT.md#using-your-own-mongodb--redis).
