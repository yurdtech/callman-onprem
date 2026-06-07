# Troubleshooting

Common problems with the on-prem stack, each as **symptom → cause → fix**.
First, two commands that answer most questions:

```bash
docker compose ps           # what's running / exited / unhealthy
docker compose logs <name>  # logs for a service: backend | worker | migrate | mongo | redis
```

---

## `docker compose pull` fails with `denied` / `unauthorized` / `manifest unknown`

**Cause:** not logged in to the private registry, the token expired, or
`CALLMAN_VERSION` points to a tag that doesn't exist.

**Fix:**
```bash
# Re-authenticate (username is always "yurdtech", not your own):
echo <ACCESS_TOKEN> | docker login ghcr.io -u yurdtech --password-stdin
```
- If it still fails, your token may be expired — ask us for a new one.
- `manifest unknown` → check `CALLMAN_VERSION` in `.env` matches a version
  we published.

---

## The app won't start / `callman-backend` keeps restarting

**First, check the migrator** — backend waits for it:
```bash
docker compose ps          # is callman-migrate "Exited (0)" or "Exited (1)"?
docker compose logs migrate
```

**Cause A — migration failed (`Exited (1)`):** backend never starts because
its prerequisite failed. Read `docker compose logs migrate` for the real
error (often a DB connection/credentials problem). Fix the cause, then
`docker compose up -d` again.

**Cause B — bad `.env`:**
```bash
docker compose logs backend
```
- `Environment validation failed` → a required value is missing/invalid.
  See the specific field in the log. Common ones below.

---

## `Environment validation failed` — secret too short / duplicated

**Symptom:** log shows a field error for `JWT_SECRET` (or another secret).

**Cause:** a secret is shorter than 32 characters, or two of the four
secrets are identical.

**Fix:** regenerate **four distinct** values and update `.env`:
```bash
openssl rand -hex 32   # run 4 times; one per secret, all different
```
Secrets: `JWT_SECRET`, `JWT_REFRESH_SECRET`,
`SESSION_TOKEN_ENCRYPTION_SECRET`, `CONNECTION_ENCRYPTION_KEY`.
Then `docker compose up -d`.

---

## `Environment validation failed` — Telegram

**Symptom:** error mentions `TELEGRAM_BOT_TOKEN` /
`TELEGRAM_ENABLED=true in production requires ...`.

**Cause:** the error reporter is enabled but has no credentials. Note that
setting `TELEGRAM_ENABLED=false` does **not** disable it (any non-empty
value counts as "on").

**Fix:** to disable it, set it **empty** in `.env`:
```
TELEGRAM_ENABLED=
```
Then `docker compose up -d`. (To enable it instead, set a value AND provide
`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`.)

---

## `/health` doesn't respond / connection refused

**Cause:** wrong port, or the backend isn't healthy yet.

**Fix:**
- Use the port from `.env` `CALLMAN_PORT` (default `8080`):
  ```bash
  curl http://localhost:8080/health
  ```
- Give it a moment after `up -d` (the migrator + DB warm-up take a bit);
  `docker compose ps` should show `callman-backend` as `healthy`.
- Check logs: `docker compose logs backend`.

---

## `pending DB migration(s) ... refusing to start`

**Symptom:** backend/worker log says it won't start because migrations are
pending.

**Cause:** the schema needs migrating and the one-shot migrator hasn't run
successfully (safety net — the app never runs against an un-migrated DB).

**Fix:** run the migrator, then bring the app up:
```bash
docker compose up -d migrate     # runs migrations (with a backup first)
docker compose logs migrate      # confirm success
docker compose up -d             # start backend + worker
```

---

## Background jobs / scheduled scenarios silently stop running

**Cause:** Redis evicted BullMQ's job data under memory pressure. BullMQ
requires `maxmemory-policy noeviction`.

**Fix:** the bundled Redis is already configured with `noeviction`. If you
switched to your **own** Redis, set `maxmemory-policy noeviction` there.
Verify the bundled one:
```bash
docker compose exec redis redis-cli --no-auth-warning -a "$REDIS_PASSWORD" config get maxmemory-policy
# → should print: noeviction
```

---

## Mongo errors mentioning transactions / replica set

**Cause:** an old/edited compose tried to use transactions against a
standalone MongoDB.

**Fix:** the shipped stack does **not** use MongoDB transactions, so the
bundled Mongo runs standalone by design — no replica set needed. Use the
unmodified `docker-compose.yml` from this repo. If you customized it,
revert the `mongo` service to the original.

---

## I changed `.env` but nothing changed

**Cause:** containers keep their environment from when they started.

**Fix:** re-apply:
```bash
docker compose up -d
```
For image/version changes also run `docker compose pull` first.

---

## Admin panel: `callman-admin` won't start

**Cause:** it waits for MongoDB to be healthy and for the one-shot `migrate`
to finish. If Mongo is unhealthy or `migrate` failed, admin never starts.

**Fix:**
```bash
docker compose ps                  # is mongo healthy? did migrate Exit (0)?
docker compose logs admin          # the real error
docker compose logs migrate        # if migrate failed, fix that first
```

## Admin panel: `/health` not 200 / can't reach Mongo

**Symptom:** `curl http://localhost:5100/health` is not 200, or admin logs show
a Mongo connection/auth error.

**Cause:** the admin's `CALLMAN_MONGODB_URI` must match the bundled Mongo
credentials. In the shipped compose it is built automatically from
`MONGO_ROOT_USERNAME` / `MONGO_ROOT_PASSWORD` with `authSource=admin`, so this
only breaks if you edited it or pointed it at an external Mongo.

**Fix:** ensure `MONGO_ROOT_USERNAME` / `MONGO_ROOT_PASSWORD` in `.env` are set
and that you didn't override `CALLMAN_MONGODB_URI` incorrectly. Then:
```bash
docker compose up -d
curl http://localhost:5100/health   # → {"status":"ok","mongo":{"callman":true,...}}
```

> ⚠️ **Changed `MONGO_ROOT_PASSWORD` after the first start?** The bundled Mongo
> only applies `MONGO_ROOT_USERNAME` / `MONGO_ROOT_PASSWORD` when it
> **initialises an empty data volume**. Changing them later does NOT update the
> existing user, so backend AND admin then fail with `Authentication failed`.
> Either set the password back to the original, or wipe the volume and start
> fresh (**destroys data**): `docker compose down -v && docker compose up -d`.

## Admin panel: can't log in

**Cause:** no admin user was seeded, or the JWT secret is invalid.

**Fix:**
- Make sure `ADMIN_BOOTSTRAP_EMAIL` + `ADMIN_BOOTSTRAP_PASSWORD` were set in
  `.env` **before first start** (the first admin is seeded only when the
  `admin_users` collection is empty). If you set them late:
  ```bash
  docker compose up -d --force-recreate admin
  docker compose logs admin        # look for the bootstrap message
  ```
- `ADMIN_JWT_SECRET` and `ADMIN_JWT_REFRESH_SECRET` must each be **≥ 32
  characters** and different from each other, or admin token issuance fails.

## Admin panel: can't change Callman data

**Not a bug — intended.** `CALLMAN_DB_WRITE_ENABLED=false` (the safe default)
makes the admin panel **read-only** over core Callman data, so it can't
accidentally corrupt the main app's database. Only set it to `true` if you
specifically need admin writes.

---

## Start over from scratch (⚠ deletes all data)

```bash
docker compose down -v    # removes containers AND data volumes
docker compose up -d
```

---

## Still stuck?

Collect this and send it to your Callman vendor:

```bash
docker compose ps
docker compose logs --no-color --tail=200 backend worker migrate
curl -i http://localhost:8080/version
```
(Do **not** include your `.env` — it contains secrets.)
