# UI-test runner — scheduled web UI tests on your server

The **ui-runner** is an optional service that executes your team's **web UI
test flows** (authored in the Callman desktop app) on this server, in a
headless Chrome, on the schedules your team sets. Results — every step, the
error, and a screenshot of the failing page — appear in the desktop app's
History and in the admin panel under **UI Testing**.

It ships as a **separate container image** (~2 GB — it carries a real
browser; the normal backend image cannot) and is **opt-in**: nothing runs,
and nothing is even downloaded, until you enable it. With the runner off,
everything else works exactly as before — users who try to create a UI-test
schedule just see "UI runner unavailable".

## Requirements

- Callman backend **1.0.1 or newer** (`CALLMAN_VERSION`).
- **~2 GB free disk** for the image, **~2 GB free RAM per replica**.
- Nothing else: it uses the same MongoDB, Redis and `.env` as the backend —
  bundled or your own, no difference. (Your Redis must already be
  `maxmemory-policy=noeviction`, which the worker requires anyway.)

## Enable it (one-time)

All steps happen in your `callman-onprem` folder.

```bash
# 1. Refresh the deployment files (brings the ui-runner service definition)
git pull

# 2. Edit .env — add "ui-runner" to the profiles line.
#    Keep whatever is already there; examples:
#      bundled databases:  COMPOSE_PROFILES=bundled-mongo,bundled-redis,ui-runner
#      your own databases: COMPOSE_PROFILES=ui-runner
#    Optional tuning (defaults are fine):
#      UITEST_WORKER_CONCURRENCY=2        # browsers per replica (1–5)
#      UITEST_RUN_MAX_DURATION_MS=900000  # per-run limit, 15 min

# 3. Sanity-check the configuration (warns if RAM looks tight)
./scripts/preflight.sh

# 4. Pull the new image and start everything
docker compose pull
docker compose up -d

# 5. Verify
docker compose ps            # ...-ui-runner-1 should become "healthy"
docker compose logs ui-runner | tail -5   # look for "UI-test runner ready"
```

That's it — from now on every normal version update
(`CALLMAN_VERSION=1.0.2` → `pull` → `up -d`) updates the runner too.

To confirm end-to-end: in the desktop app open a **web** UI test flow →
**Schedules** tab → create a schedule (pick a time a few minutes ahead) →
after it fires, the run appears in the flow's **History** with a
"Scheduled" tag; a failed run carries a screenshot of the failing page.

## Day-2 operations

- **Scale under load:** `docker compose up -d --scale ui-runner=2` —
  parallel browser runs = replicas × `UITEST_WORKER_CONCURRENCY`. Budget
  ~2 GB RAM per replica. Full guidance: [SCALING.md](SCALING.md); every setting: [ENVIRONMENT.md](ENVIRONMENT.md).
- **Hygiene:** long-lived browser containers slowly accumulate memory — a
  nightly `docker compose restart ui-runner` (cron) is cheap insurance.
- **Retention:** server run reports auto-delete after
  `UITEST_REPORT_RETENTION_DAYS` (default 90). Failure screenshots are
  size-capped by `UITEST_FAILURE_SCREENSHOT_MAX_BYTES` (`0` disables them).
- **Disable again:** remove `ui-runner` from `COMPOSE_PROFILES`, then
  `docker compose up -d --remove-orphans`. Already-created schedules stay
  stored and resume when you re-enable it.

## If something's off

| Symptom | Cause / fix |
|---|---|
| `docker compose pull` says `denied` / `manifest unknown` for `callman-ui-runner` | Your registry token may not cover the (newer) ui-runner package — re-run `docker login ghcr.io` with the token we gave you; if it persists, contact us so we grant the package to your token. |
| Desktop shows "No UI test runner is available…" (503) | The runner isn't running (profile not enabled, container down) or died >30 s ago. Check `docker compose ps` and `docker compose logs ui-runner`. |
| `ui-runner` is `unhealthy` or restarts | Usually RAM. Check `docker stats`; lower `UITEST_WORKER_CONCURRENCY` to `1`, scale replicas instead, or give the host more memory. |
| Runs fail with a browser/sandbox launch error | The container ships with the correct flags (`CALLMAN_WEB_DRIVER_NO_SANDBOX=1`, `shm_size: 2gb` are set in docker-compose.yml) — if you overrode compose settings, restore them. |
| A run is `failed` with "exceeded the … minute limit" | The flow ran longer than `UITEST_RUN_MAX_DURATION_MS` (or the schedule's own max-runtime). Raise the limit or split the flow. |

More general issues: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
