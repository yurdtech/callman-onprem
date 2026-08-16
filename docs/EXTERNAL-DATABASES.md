# Using your own MongoDB / Redis

By default Callman runs its own MongoDB and Redis for you. If your company
already runs these — with its own backups, monitoring and HA — you can point
Callman at them instead.

**You never edit `docker-compose.yml`.** Everything below is done in `.env`.
That matters: an edited compose file drifts away from the one we ship and has
to be re-patched on every update.

You can mix. Your MongoDB with our Redis is a perfectly normal setup.

---

## The two settings

Each database is controlled by a pair:

| Database | Turn OFF ours | Turn ON yours |
|---|---|---|
| MongoDB | remove `bundled-mongo` from `COMPOSE_PROFILES` | set `MONGODB_URI` |
| Redis | remove `bundled-redis` from `COMPOSE_PROFILES` | set `REDIS_URL` |

Set both halves, or neither. `./scripts/preflight.sh` fails if you do only one.

---

## Example: your MongoDB, our Redis

In `.env`:

```dotenv
# was: COMPOSE_PROFILES=bundled-mongo,bundled-redis
COMPOSE_PROFILES=bundled-redis

MONGODB_URI=mongodb://callman_user:s3cr3t@mongo.acme.local:27017/callman?authSource=admin
```

Apply it:

```bash
./scripts/preflight.sh
docker compose up -d
```

Compose removes the bundled `callman-mongo` container and every service now
talks to `mongo.acme.local`. The admin panel follows automatically — it reads
the same database and needs no separate setting.

> `docker compose up -d` does **not** delete the old `mongo_data` volume. Your
> previous bundled data is still on disk if you need to go back or migrate it
> across. Remove it deliberately with `docker volume rm callman_mongo_data`.

## Example: both databases yours

```dotenv
COMPOSE_PROFILES=

MONGODB_URI=mongodb://callman_user:s3cr3t@mongo.acme.local:27017/callman?authSource=admin
REDIS_URL=redis://:r3d1sp4ss@redis.acme.local:6379
```

`MONGO_ROOT_USERNAME`, `MONGO_ROOT_PASSWORD` and `REDIS_PASSWORD` are then
unused — they only ever configured the bundled containers. Leave or delete them.

---

## Writing the MongoDB URI

Callman takes one full connection URI. There are no separate host/port/user
settings — anything extra rides as a query parameter, exactly as the standard
MongoDB drivers expect.

```dotenv
# Username + password, credentials stored in the admin database (most common)
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin

# Replica set (list every member; the driver finds the primary itself)
MONGODB_URI=mongodb://user:pass@m1.acme.local:27017,m2.acme.local:27017,m3.acme.local:27017/callman?authSource=admin&replicaSet=rs0

# MongoDB Atlas / any SRV record
MONGODB_URI=mongodb+srv://user:pass@cluster0.abcde.mongodb.net/callman?retryWrites=true&w=majority

# TLS with a certificate from a public CA
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin&tls=true
```

Requirements:

- **Database name.** Put it in the path (`/callman` above). Any name works,
  but everything — backend, worker and admin panel — must use the same one.
- **Permissions.** The user needs `readWrite` **and** the ability to create
  indexes on that database (Callman creates its own indexes at startup).
- **A replica set is not required.** Callman uses no multi-document
  transactions, so a standalone server is fully supported.
- **Percent-encode special characters** in the password. A password containing
  `@ : / ? # [ ] %` will break URI parsing — `p@ss/w0rd` must be written
  `p%40ss%2Fw0rd`.

### TLS with a private / internal CA

Put the CA certificate in the `certs/` folder next to `docker-compose.yml`. It
is mounted read-only at `/certs` inside every container, so no compose edit is
needed:

```bash
cp /path/to/your-ca.pem certs/mongo-ca.pem
```

```dotenv
MONGODB_URI=mongodb://user:pass@mongo.acme.local:27017/callman?authSource=admin&tls=true&tlsCAFile=/certs/mongo-ca.pem
```

`preflight.sh` checks that the file you reference actually exists.

---

## Writing the Redis URL

```dotenv
# Password only (the usual Redis setup — no username)
REDIS_URL=redis://:yourpassword@redis.acme.local:6379

# Username + password (Redis 6+ ACLs)
REDIS_URL=redis://callman:yourpassword@redis.acme.local:6379

# TLS
REDIS_URL=rediss://:yourpassword@redis.acme.local:6380

# Specific database number
REDIS_URL=redis://:yourpassword@redis.acme.local:6379/3
```

Note the empty slot before `:` in the password-only form — that is the
(absent) username, and it is required.

### Your Redis must use `noeviction` — this one is not optional

Callman stores queued background jobs in Redis. Under any other
`maxmemory-policy`, Redis quietly deletes them when memory gets tight: your
scenario runs and schedules simply stop happening, with **no error anywhere**.

```bash
redis-cli -u "$REDIS_URL" config get maxmemory-policy
# → noeviction
```

Set it permanently in your `redis.conf`:

```
maxmemory-policy noeviction
```

`preflight.sh` verifies this for you when `redis-cli` is available on the host.

### Not supported

Redis **Sentinel** and **Cluster** are not supported yet — Callman connects to
a single endpoint. A Sentinel-managed primary works if you point Callman at a
stable address in front of it (proxy or VIP), but failover behaviour is
untested. Redis must also not be shared with another application that flushes
it.

---

## If the database runs on this same server

A very common case: MongoDB is installed directly on the host, not in Docker.

`localhost` **will not work**. Inside a container, `localhost` is the container
itself — not your server. Use `host.docker.internal`, which we map to the host
for you:

```dotenv
MONGODB_URI=mongodb://user:pass@host.docker.internal:27017/callman?authSource=admin
```

Also make sure the database actually accepts connections from the Docker
bridge network — MongoDB's default `bindIp: 127.0.0.1` refuses them. Set
`bindIp: 0.0.0.0` (with a firewall) or add the Docker bridge address.

---

## Verify it worked

The point of this check is to prove the app reached **your** server and not a
leftover bundled one.

```bash
# 1. The bundled containers should be gone.
docker compose ps
#    No callman-mongo / callman-redis for whichever you replaced.

# 2. The backend logs the host and database it connected to.
docker compose logs backend | grep "MongoDB connection established"
#    → ... "database":"callman","host":"mongo.acme.local" ...

# 3. Both dependencies confirmed healthy by the app itself.
curl -s http://localhost:8080/health/ready
#    → {"status":"ok","checks":{"mongo":true,"redis":true}}   (HTTP 200)

# 4. The admin panel reached the same database.
curl -s http://localhost:5100/health
```

If `/health/ready` returns **503**, the `checks` object names which one failed.

---

## Switching back to the bundled databases

Restore the profiles and comment out the URIs:

```dotenv
COMPOSE_PROFILES=bundled-mongo,bundled-redis
# MONGODB_URI=...
# REDIS_URL=...
```

Then `docker compose up -d`. If the old `mongo_data` volume still exists, the
bundled MongoDB starts with that data — **not** a copy of your external one.
To bring your data over, see [BACKUP.md](BACKUP.md).

---

## Things that go wrong

| Symptom | Cause | Fix |
|---|---|---|
| Backend log: `MongoDB connection established` naming the wrong host | You set `MONGODB_URI` but left `bundled-mongo` in `COMPOSE_PROFILES` on an older release, where compose overrode your value | Update to this release; run `preflight.sh`, which flags the conflict |
| `MongoServerSelectionError` / timeouts | Container cannot reach the host, or the DB binds only to `127.0.0.1` | Use `host.docker.internal` for a DB on this machine; check `bindIp` and firewall |
| `Authentication failed` | Wrong `authSource`, or unencoded special characters in the password | Add `?authSource=admin`; percent-encode the password |
| `self signed certificate in certificate chain` | Private CA not trusted | Put the PEM in `certs/` and add `tlsCAFile=/certs/<name>.pem` |
| Scheduled scenarios stop running, no errors | Your Redis is evicting BullMQ jobs | `maxmemory-policy noeviction` |
| Admin panel healthy, backend not (or vice versa) | They use different databases | Leave `CALLMAN_MONGODB_URI` unset so admin follows `MONGODB_URI` |

More in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## What you take on

With your own databases, these become your responsibility:

- **Backups.** Our pre-migration `mongodump` still runs against your MongoDB
  (see [BACKUP.md](BACKUP.md)), but it is a safety net for upgrades — not a
  backup policy.
- **`noeviction` on Redis**, forever, including after any config reload.
- **Availability.** Callman stops serving writes when MongoDB is unreachable.
- **Upgrades** of your MongoDB/Redis. Callman supports MongoDB 6+ and Redis 6+.
