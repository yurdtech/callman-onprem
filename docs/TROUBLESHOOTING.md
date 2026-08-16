# Troubleshooting

Common problems with the on-prem stack, each as **symptom → cause → fix**.

First, three commands that answer most questions:

```bash
./scripts/preflight.sh      # checks your .env and host for known mistakes
docker compose ps           # what's running / exited / unhealthy
docker compose logs <name>  # logs for a service:
                            #   backend | worker | migrate | admin | mongo | redis
```

If you are setting up for the first time, run `preflight.sh` before anything
else — most of the problems below are things it catches up front.

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

## Callman is read-only — nothing can be saved

**Symptom:** users can browse everything, but every save / create / delete
fails with a message about the license. Backend log shows:
`Callman started WITHOUT a valid license — running in READ-ONLY mode`.

**Cause:** the deployment has no valid license certificate installed, or the
installed one expired and its grace period is over.

**Fix:** open the admin panel (`http://<host>:5100`) → **On-Prem → License** →
paste the certificate we provided → **Activate license**. Callman applies it
within a minute; no restart. If you do not have a current certificate, contact
info@yurdtech.com.

> The license is **not** an env var. Nothing to edit in `.env`, and no
> internet connection is used — the certificate is verified locally.

---

## The admin panel rejects my certificate

Each rejection names the reason:

| Message mentions | Cause | What to do |
|---|---|---|
| not a Callman license / payload corrupted | Partial copy/paste | Copy the WHOLE value, including the `CALLMAN-LICENSE-v1` prefix |
| signature is invalid | The text was altered in transit (e.g. auto-formatting) | Ask us to resend; paste as plain text |
| signed with key "…" which this Callman version does not know | Certificate newer than your Callman build | Upgrade Callman, or ask for a certificate signed with the key your version ships |
| issued for the "cloud" edition | Wrong certificate type | Ask for an on-prem certificate |
| becomes valid on … | Its start date is in the future | Wait, or ask for one starting today |
| expired on … | Dead on arrival | Ask for a renewed certificate |
| issued for a different company | Someone else's certificate | Check you pasted yours. If your company was renamed with us, press **Install anyway** |
| expires earlier than the installed one | An older certificate from a previous email | Find the latest one. To install it deliberately, press **Install anyway** |

**Emergency path** (panel unreachable): write the certificate straight into
Mongo, then wait a minute:

```bash
docker compose exec -T mongo sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
  -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin callman --eval "
    db.on_prem_license.updateOne(
      { _id: \"singleton\" },
      { \$set: { certificate: \"CALLMAN-LICENSE-v1....\" } },
      { upsert: true }
    )"'
```

> The credentials are read **inside** the container, where they already exist
> as environment variables — your host shell does not have them, so a bare
> `-u "$MONGO_ROOT_USERNAME"` would send an empty username. Using your own
> MongoDB? Connect to it directly with `mongosh "$MONGODB_URI"` instead.

The backend re-verifies the signature itself, so this shortcut cannot be used
to install anything we did not sign.

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

Verify the bundled one (the password is read inside the container — your host
shell does not have `$REDIS_PASSWORD`):
```bash
docker compose exec -T redis sh -c \
  'redis-cli --no-auth-warning -a "$REDIS_PASSWORD" config get maxmemory-policy'
# → should print: noeviction
```

Verify your own:
```bash
redis-cli -u "$REDIS_URL" config get maxmemory-policy
```

---

## I set `MONGODB_URI` / `REDIS_URL` but Callman still uses the bundled database

**Symptom:** you pointed `.env` at your company database, restarted, and
`docker compose logs backend | grep "MongoDB connection established"` still
names `mongo` (the bundled container).

**Cause A — the bundled profile is still on.** Setting the URI is only half of
it; you must also stop us from running our own database.

**Fix:** remove the matching profile in `.env`, then `docker compose up -d`:
```dotenv
COMPOSE_PROFILES=bundled-redis        # bundled-mongo removed → your MongoDB
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin
```
`./scripts/preflight.sh` reports this conflict explicitly.

**Cause B — you are on an older release of these deployment files.** Before
this version, `docker-compose.yml` hardcoded the bundled connection strings in
a way that silently overrode `.env`.

**Fix:** `git pull` in this folder to get the current `docker-compose.yml`,
then follow [EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md).

---

## `Authentication failed` — and the credentials in `.env` look correct

**Symptom:** `callman-migrate` exits 1 and the backend never starts.
`docker compose logs migrate` shows:

```
MongoServerError: Authentication failed.
```

**Cause:** you changed `MONGO_ROOT_USERNAME` or `MONGO_ROOT_PASSWORD` after the
first start. The bundled MongoDB applies those **only when it initialises an
empty data volume**. Your database already exists, so it still expects the
values it was *originally* created with — the new ones were never applied.

Nothing is broken and no data is lost. The database and your `.env` simply
disagree about the password.

**⚠️ Do not run `docker compose down -v` as a first move.** It erases the
volume — including your activated license, admin users and all Callman data.

**Fix — pick one:**

**1. Restore the original credentials** (simplest, if you know them).
Put them back in `.env` and `docker compose up -d`.

**2. Reset the password on the existing volume, keeping all data.** Use this
when the original password is lost — MongoDB stores a one-way hash, so it
cannot be read back:

```bash
docker compose stop

# Temporary server with authentication disabled, on the same volume.
docker run --rm -d --name mongo-fix -v callman_mongo_data:/data/db mongo:7 --noauth
sleep 8

# Create (or update) the user named in your .env.
docker exec mongo-fix mongosh --quiet admin --eval '
  db.createUser({ user: "<MONGO_ROOT_USERNAME>", pwd: "<MONGO_ROOT_PASSWORD>",
                  roles: [{ role: "root", db: "admin" }] })'

docker stop mongo-fix
docker compose up -d
```

If the user already exists, use `db.changeUserPassword("<user>", "<password>")`
instead of `createUser`.

Confirm it worked:

```bash
docker compose logs migrate     # → "No pending migrations" / "Migrations applied"
curl http://localhost:8080/health/ready
```

**3. Start completely over — destroys everything:**

```bash
docker compose down -v && docker compose up -d
```

Only do this if the install is disposable. You will have to activate your
license again.

> `./scripts/preflight.sh` checks this before you start the stack and reports
> the mismatch instead of letting the migrator fail.

---

## Can't connect to my own MongoDB / Redis

**Symptom:** `MongoServerSelectionError`, connection timeouts, or
`/health/ready` returning 503 with `{"checks":{"mongo":false}}`.

**Fix, in order:**

1. **Is it a database on this same server, outside Docker?** `localhost` in the
   URI means *the container itself*. Use `host.docker.internal`:
   ```dotenv
   MONGODB_URI=mongodb://user:pass@host.docker.internal:27017/callman?authSource=admin
   ```
2. **Does the database accept remote connections?** MongoDB's default
   `bindIp: 127.0.0.1` refuses the Docker network. Check firewall rules too.
3. **Test from inside a container**, which is what actually matters:
   ```bash
   docker compose exec -T backend sh -c 'nc -zv mongo.acme.local 27017'
   ```
4. **`Authentication failed`?** Add `?authSource=admin` (or whichever database
   holds the user), and percent-encode special characters in the password —
   `p@ss/w0rd` must be written `p%40ss%2Fw0rd`.
5. **Certificate errors?** Put your CA's PEM in `certs/` and add
   `&tls=true&tlsCAFile=/certs/your-ca.pem` to the URI.

Full reference: [EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md).

---

## A worker container shows `unhealthy`

**Cause:** the worker serves its health probes on its own internal port
(`WORKER_HEALTH_PORT`, default `9090`), not on the API port. On older
deployment files the worker inherited the API's probe and reported `unhealthy`
forever while processing jobs perfectly.

**Fix:** `git pull` here to get the current `docker-compose.yml`, then
`docker compose up -d`. To confirm the worker is genuinely fine either way:
```bash
docker compose logs worker | tail -20      # should show jobs being processed
curl -s http://localhost:8080/health | jq .data.queue
```

---

## Mongo errors mentioning transactions / replica set

**Cause:** an edited compose file tried to use transactions against a
standalone MongoDB.

**Fix:** the shipped stack does **not** use MongoDB transactions, so the
bundled Mongo runs standalone by design — no replica set needed, and none is
required if you bring your own. Use the unmodified `docker-compose.yml` from
this repo; if you customized it, `git checkout docker-compose.yml` to restore
it. Everything configurable lives in `.env`.

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

**Cause:** the admin panel follows the same MongoDB as the backend
automatically. This only breaks if you set `CALLMAN_MONGODB_URI` by hand and
pointed it somewhere else.

**Fix:** leave `CALLMAN_MONGODB_URI` unset (commented out) so it follows
`MONGODB_URI` — bundled or your own. If the backend is healthy and only admin
is not, that mismatch is almost always the cause. Then:
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

**Contact us:**
- 📧 Email: [info@yurdtech.com](mailto:info@yurdtech.com)
- 📞 Phone: [+994 70 238 88 38](tel:+994702388838)
