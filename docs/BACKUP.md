# Backup and restore

Everything Callman stores lives in **MongoDB** — scenarios, runs, users,
workspaces, and the license certificate. Redis holds only in-flight background
jobs and cache, and is rebuilt automatically; it does not need backing up.

So: **back up MongoDB, and you have backed up Callman.**

---

## What we do for you

Every time the stack starts, the one-shot `migrate` service takes a `mongodump`
of the whole database *before* applying any schema change, and writes it into
the `backups` Docker volume as:

```
/backups/callman-backup-<timestamp>.archive.gz
```

This is an **upgrade safety net, not a backup policy.** It only runs on start,
it is never pruned, and it lives on the same host as the database. Set up the
scheduled backup below as well.

List what is there:

```bash
docker compose run --rm --entrypoint ls migrate -lh /backups
```

Copy one out to the host:

```bash
docker compose run --rm --entrypoint cat migrate \
  /backups/callman-backup-2026-08-16T09-30-00-000Z.archive.gz \
  > ./callman-backup.archive.gz
```

Related settings (see [ENVIRONMENT.md](ENVIRONMENT.md)):
`MONGODB_BACKUP_DIR`, `SKIP_MIGRATION_BACKUP`, `BACKUP_REQUIRED`.

> The automatic dump runs against whatever `MONGODB_URI` points at — so it
> works the same when you use [your own MongoDB](EXTERNAL-DATABASES.md).

---

## Taking a backup yourself

**Bundled MongoDB** — run the dump inside the container, where the credentials
already exist as environment variables:

```bash
docker compose exec -T mongo sh -c \
  'mongodump --username "$MONGO_INITDB_ROOT_USERNAME" \
             --password "$MONGO_INITDB_ROOT_PASSWORD" \
             --authenticationDatabase admin \
             --db callman --archive --gzip' \
  > "callman-$(date +%F-%H%M).archive.gz"
```

**Your own MongoDB** — use your existing tooling, or:

```bash
mongodump --uri "$MONGODB_URI" --archive --gzip \
  > "callman-$(date +%F-%H%M).archive.gz"
```

Both produce a single compressed file. Callman can be running while you do
this. Store it off this server, and treat it as sensitive — it contains your
users and their encrypted credentials.

### On a schedule

```cron
# crontab -e — daily at 02:30, keep 14 days
30 2 * * * cd /opt/callman-onprem && docker compose exec -T mongo sh -c 'mongodump --username "$MONGO_INITDB_ROOT_USERNAME" --password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --db callman --archive --gzip' > /var/backups/callman/callman-$(date +\%F).archive.gz 2>/var/log/callman-backup.log
0 3 * * * find /var/backups/callman -name 'callman-*.archive.gz' -mtime +14 -delete
```

---

## Restoring

> ⚠️ A restore **replaces** the current data. Take a fresh dump first, even if
> the current state looks broken — it is your only way back.

**1. Stop everything that writes:**

```bash
docker compose stop backend worker admin
```

**2. Restore into MongoDB.**

Bundled:

```bash
docker compose exec -T mongo sh -c \
  'mongorestore --username "$MONGO_INITDB_ROOT_USERNAME" \
                --password "$MONGO_INITDB_ROOT_PASSWORD" \
                --authenticationDatabase admin \
                --archive --gzip --drop' \
  < callman-2026-08-16-0230.archive.gz
```

Your own MongoDB:

```bash
mongorestore --uri "$MONGODB_URI" --archive --gzip --drop \
  < callman-2026-08-16-0230.archive.gz
```

`--drop` clears each collection before restoring it, so you get exactly the
backup's contents rather than a merge with what is there now.

**3. Start back up and check:**

```bash
docker compose up -d
curl http://localhost:8080/health/ready     # → 200
```

### The secrets in `.env` must match the backup

This is the part people get wrong. `SESSION_TOKEN_ENCRYPTION_SECRET` and
`CONNECTION_ENCRYPTION_KEY` encrypt data *inside* the database. Restoring a
backup into a deployment whose `.env` has different values leaves saved
connection credentials and AI keys undecryptable — the restore looks like it
worked, and those items fail later.

**Back up your `.env` together with the dump**, and store it somewhere at least
as safe. Restoring to a new server means copying both.

---

## Restoring an older Callman version

Database migrations are **not reversed** when you roll the image back. If you
restore a backup taken on an older version, run that older `CALLMAN_VERSION`:

```dotenv
CALLMAN_VERSION=1.0.1      # the version the backup came from
```

```bash
docker compose pull && docker compose up -d
```

Going forward again re-applies the migrations normally.

---

## Moving to a new server

1. Install per [INSTALL.md](INSTALL.md), but **do not start yet**.
2. Copy the old `.env` across (keeping the secrets identical) and update
   anything host-specific.
3. `docker compose up -d mongo` (bundled) or point `MONGODB_URI` at the new
   database.
4. Restore the dump as above.
5. `./scripts/preflight.sh && docker compose up -d`.
6. Verify `/health/ready`, then log in to the admin panel and confirm the
   license is still active.

The license certificate lives in the database, so it comes across with the
restore — no re-activation needed.

---

## What is *not* in a MongoDB backup

| Item | Where it lives | How to preserve it |
|---|---|---|
| Secrets and configuration | `.env` | Back it up alongside every dump |
| Private CA certificates | `certs/` | Copy the folder |
| Queued background jobs | Redis | Not needed — pending runs are re-queued or re-run |
| The images themselves | Registry | Pull again by `CALLMAN_VERSION` |

---

## Backups on Kubernetes (Helm deployment)

The model is identical — back up MongoDB and you have backed up Callman:

- **Automatic pre-migration dumps** land on the `backups` PVC (mounted only by
  the migrate Job; the PVC carries `helm.sh/resource-policy: keep`, so it
  survives `helm uninstall`). To browse or restore, start a throwaway pod that
  mounts the PVC — the exact command is in
  [HELM-INSTALL.md](HELM-INSTALL.md) §5.
- **Manual/scheduled dumps**: `kubectl -n callman exec <mongo pod> -- mongodump ...`
  for the bundled store, or your DBA's own tooling for an external one.
- A restore still requires the same `SESSION_TOKEN_ENCRYPTION_SECRET` and
  `CONNECTION_ENCRYPTION_KEY` values (now in your Kubernetes Secret rather
  than `.env`).
