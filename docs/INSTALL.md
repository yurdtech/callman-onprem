# Installing Callman (on-prem)

A complete, copy-paste walkthrough. No prior Docker knowledge needed — follow
the steps in order. A first install takes about 15 minutes, most of it waiting
for downloads.

**What you will end up with:** the Callman API, a background worker, a web
admin panel, and (unless you bring your own) a MongoDB and Redis — all running
as containers on one server.

---

## 0. Before you start

**A 64-bit Linux server** with:

- **Docker** and **Docker Compose v2.20 or newer**:
  ```bash
  docker --version
  docker compose version
  ```
  Both must print a version, and Compose must be **v2.20+**. If not, install
  Docker Engine and the Compose plugin from
  <https://docs.docker.com/engine/install/>.
- **2 GB RAM** and **5 GB free disk** minimum for the all-in-one stack (more
  for heavy use). Enabling the optional **UI-test runner** (`ui-runner`
  profile — scheduled web UI tests in a headless browser) adds **~2 GB disk**
  for its image and **~2 GB RAM per replica** on top of that.
- Ports **8080** and **5100** free (both configurable).

**From us, before you begin:**

| What | Used for |
|---|---|
| **Access token** | Pulling the private images (step 2) |
| **Version numbers** | `CALLMAN_VERSION` and `CALLMAN_ADMIN_VERSION` (step 4) |
| **License certificate** | A single `CALLMAN-LICENSE-v1...` line, pasted into the admin panel (step 8). Not a secret, and it does not go in `.env`. |

---

## 1. Get the deployment files

```bash
git clone https://github.com/yurdtech/callman-onprem.git
cd callman-onprem
```

This repository holds **only** deployment files — Docker Compose, a config
template and these docs. There is no application source; the images come from
our registry.

Everything from here runs inside this folder. To update the deployment files
later, `git pull` here.

> No git on the server? Download the archive instead:
> ```bash
> curl -L https://github.com/yurdtech/callman-onprem/archive/refs/heads/main.tar.gz | tar xz
> cd callman-onprem-main
> ```

---

## 2. Log in to the image registry (one time)

Our images are private. Authenticate Docker with the token we gave you. The
username is always `yurdtech` (the image owner) — **not** your own GitHub
username.

```bash
echo <ACCESS_TOKEN> | docker login ghcr.io -u yurdtech --password-stdin
```

Expected output:

```
Login Succeeded
```

If you see `denied` or `unauthorized`, the token is wrong or expired — ask us
for a new one. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 3. Choose your databases

By default Callman runs **its own MongoDB and Redis** — nothing to decide, skip
to step 4.

If your company already runs MongoDB and/or Redis and you want Callman to use
them, that is configured entirely in `.env` (you never edit
`docker-compose.yml`). Read
[EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md) first, then continue — the
settings go into the same file you are about to create.

---

## 4. Create your configuration

```bash
cp .env.example .env
chmod 600 .env        # it will hold passwords — keep it private
```

Open `.env` in an editor and fill in every `<CHANGE_ME...>` value:

- **`CALLMAN_VERSION`** and **`CALLMAN_ADMIN_VERSION`** — the versions we told
  you to install (e.g. `1.0.1` and `0.1.0`).
- **`MONGO_ROOT_PASSWORD`** and **`REDIS_PASSWORD`** — strong passwords for the
  bundled databases. (Skip whichever you replaced in step 3.)
- **`ADMIN_BOOTSTRAP_EMAIL`** / **`ADMIN_BOOTSTRAP_PASSWORD`** — the first
  admin-panel login. Use a **strong** password; you will change it after first
  login.
- **Six secrets** — generate a separate random value for **each**:

  ```bash
  openssl rand -hex 32    # run this 6 times, paste one result per secret
  ```

  Backend (all four must differ from each other):
  `JWT_SECRET`, `JWT_REFRESH_SECRET`, `SESSION_TOKEN_ENCRYPTION_SECRET`,
  `CONNECTION_ENCRYPTION_KEY`
  Admin panel (must differ from each other):
  `ADMIN_JWT_SECRET`, `ADMIN_JWT_REFRESH_SECRET`

> The app **refuses to start** if a secret is shorter than 32 characters, or if
> any two of the four backend secrets are equal.

> **Keep a safe copy of `.env`.** Two of those secrets encrypt data *inside*
> the database — lose them and a restored backup cannot be decrypted. See
> [BACKUP.md](BACKUP.md).

Everything else has a safe default. Full reference:
[ENVIRONMENT.md](ENVIRONMENT.md).

---

## 5. Check your configuration

```bash
./scripts/preflight.sh
```

This reads your `.env` and the host and reports anything that would fail once
containers start — placeholders left in, secrets too short or duplicated, a
database that is unreachable, ports already taken. It changes nothing.

Expected ending:

```
✓ Ready to start.
```

Fix any `✗` lines and run it again before continuing.

---

## 6. Pull the images

```bash
docker compose pull
```

Downloads the backend and admin images for your configured versions, plus
MongoDB and Redis if you use the bundled ones. First time takes a few minutes.

---

## 7. Start everything

```bash
docker compose up -d
```

This starts the databases, runs the one-time migration, then starts the
backend, worker and admin panel.

### First-run checks

Run each command and compare with the expected result.

**a) All services up:**

```bash
docker compose ps
```

Expected — `callman-backend`, `callman-admin`, `callman-worker-1` and (with the
bundled databases) `callman-mongo`, `callman-redis` all show **`running`**, and
`healthy` once warmed up. `callman-migrate` shows **`Exited (0)`** — that is
correct, the migrator is a one-shot job that finishes and stops.

**b) Migration succeeded:**

```bash
docker compose logs migrate
```

Expected: ends with `Migrations applied` or
`No pending migrations — database is up to date`.

**c) API health** (replace 8080 if you changed `CALLMAN_PORT`):

```bash
curl http://localhost:8080/health
```

Expected: HTTP 200 and JSON like:

```json
{"success":true,"data":{"status":"ok","version":"1.0.1","gitSha":"<sha>","edition":"onprem","queue":{...}}}
```

**d) Dependencies reachable:**

```bash
curl http://localhost:8080/health/ready
```

Expected: HTTP 200, `{"status":"ok","checks":{"mongo":true,"redis":true}}`.
A **503** here names which database failed.

**e) Admin panel:**

```bash
curl http://localhost:5100/health
```

Expected: HTTP 200.

If all five pass, the stack is up. One step left — the license.

To watch logs live:

```bash
docker compose logs -f backend worker
```

---

## 8. Activate your license

Callman starts **read-only** until a license is installed: everything is
readable, but nothing can be saved. Activating takes about ten seconds.

1. Open the admin panel at `http://<this-host>:5100` (or your
   `CALLMAN_ADMIN_PORT`).
2. Log in with the `ADMIN_BOOTSTRAP_EMAIL` / `ADMIN_BOOTSTRAP_PASSWORD` you set
   in step 4.
3. A **license activation** dialog appears (also reachable any time at
   **On-Prem → License**).
4. Paste the `CALLMAN-LICENSE-v1...` certificate we sent you and press
   **Activate license**.

The panel verifies the signature locally — **no internet connection is used or
required**. Callman picks up the new license within a minute; nothing to
restart.

Verify from the API if you like:

```bash
curl -H "Authorization: Bearer <your token>" \
  http://localhost:8080/api/license
# → {"licensed":true,"status":"active","companyName":"...","seatsUsed":3,"seatsMax":50,...}
```

**Renewing later** is the same flow: paste the new certificate over the old
one. The panel warns you 30 days before expiry, and Callman keeps working for
14 days after it (the grace period) before going read-only.

---

## 9. Choose how people sign in (optional)

By default users sign in to Callman with an email and password and can create
their own accounts.

To use your **corporate LDAP / Active Directory** instead, or to stop people
self-registering, go to the admin panel → **On-Prem → Authentication**. You
can test the directory connection before saving, and changes apply within
about 30 seconds — nothing to restart, and no `.env` edit.

Full guide: [AUTH_SETUP.md](AUTH_SETUP.md).

---

## 10. Secure the install

Do these before handing the system to users.

- **Change the bootstrap admin password.** Create your own admin account in the
  panel and disable the bootstrap one. It can read all Callman data.
- **Do not expose the admin panel to the internet.** Put it behind your VPN or
  a reverse proxy with authentication. Its API documentation page
  (`/admin/docs`) is reachable by anyone who can reach the port.
- **Keep `CALLMAN_DB_WRITE_ENABLED=false`** (the default) so the admin panel can
  read Callman data but never modify it.
- **`chmod 600 .env`**, and keep it out of any repository.
- **Bind to an internal interface** if the server has a public IP. In `.env`,
  a `CALLMAN_PORT` of `8080` publishes on all interfaces; restrict it with your
  firewall.
- **Set up backups** — [BACKUP.md](BACKUP.md).

---

## Updating

When we publish a new version:

1. Refresh the deployment files: `git pull`
2. Edit `.env` and set the new `CALLMAN_VERSION` (and `CALLMAN_ADMIN_VERSION`
   if we gave you one).
3. Pull and restart:
   ```bash
   docker compose pull
   docker compose up -d
   ```

The `migrate` service runs first (taking a backup), applies the new schema
migrations automatically, and only then do the backend, worker and admin panel
start on the new version. Confirm with `curl http://localhost:8080/version`.

> Since backend **1.0.1** an optional **UI-test runner** is available —
> scheduled web UI tests executed on this server in a headless browser. It is
> off by default and enabled with one `.env` line; see
> [UI-RUNNER.md](UI-RUNNER.md).

### Rollback note

To roll back, set the previous `CALLMAN_VERSION` and `docker compose up -d`
again. **Important:** database migrations are **not** automatically reversed —
rolling the app back does not undo schema changes. Before every update the
`migrate` service writes a `mongodump` into the `backups` volume; restore from
there if you need to fully revert data ([BACKUP.md](BACKUP.md)). Always take
your own backup before a major upgrade.

---

## Stopping / removing

```bash
docker compose stop         # pause everything, keep containers and data
docker compose down         # remove containers (your DATA is preserved)
docker compose down -v      # remove containers AND DELETE all data (destructive!)
```

---

## Where to go next

| Task | Guide |
|---|---|
| Every `.env` setting explained | [ENVIRONMENT.md](ENVIRONMENT.md) |
| Use your own MongoDB / Redis | [EXTERNAL-DATABASES.md](EXTERNAL-DATABASES.md) |
| Back up and restore | [BACKUP.md](BACKUP.md) |
| Corporate LDAP / Active Directory login | [AUTH_SETUP.md](AUTH_SETUP.md) |
| Handle heavy load | [SCALING.md](SCALING.md) |
| Something is wrong | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
