# Scaling workers under load

The **worker** service runs Callman's background jobs — scenario runs and
scheduled scenarios. One worker is enough for most installs, but under heavy
load (large bursts of runs, many schedules firing at once) the job backlog can
grow faster than a single worker drains it. This guide shows how to **see** the
backlog and **add capacity**, manually or automatically.

> TL;DR — watch `queue.waiting` from `GET /health`, and add workers with
> `docker compose up -d --scale worker=N`. The script in
> [`scripts/autoscale-worker.sh`](../scripts/autoscale-worker.sh) does both for you.

---

## Two ways to add capacity

| Approach | What it does | How | When to use |
|---|---|---|---|
| **Vertical** — more jobs per worker | Raises in-flight jobs inside the existing worker | Set `BULLMQ_WORKER_CONCURRENCY` in `.env` (default `50`), then `docker compose up -d worker` | First step. Cheap, no extra containers. Limited by one container's CPU/RAM. |
| **Horizontal** — more workers | Runs N worker containers that share the queue | `docker compose up -d --scale worker=N` | When one worker (even at high concurrency) can't keep up, or you want headroom that grows/shrinks with load. |

Total jobs processed in parallel ≈ **`N workers × BULLMQ_WORKER_CONCURRENCY`**.
Start by raising concurrency; reach for more workers when a single container is
saturated.

## Scaling the UI-test runner (profile `ui-runner`)

The `ui-runner` service executes web UI tests in headless Chromium — a very
different cost profile from the worker's HTTP jobs. Scale it **manually**:

```bash
docker compose up -d --scale ui-runner=2 ui-runner
```

Rules of thumb:

- Parallel browser runs = **replicas × `UITEST_WORKER_CONCURRENCY`** (default
  2 per replica; 1–5 allowed). One browser session uses ~400–800 MB RSS —
  budget **~2 GB RAM per replica** and keep concurrency low rather than high.
- `scripts/autoscale-worker.sh` is hardcoded to the **worker** service and its
  queue math (hundreds of cheap jobs per worker) — do **not** point it at
  `ui-runner`.
- Long-lived browser containers slowly accumulate memory; a periodic restart
  (`docker compose restart ui-runner`, e.g. nightly via cron) is a cheap
  hygiene measure.

## Why running many workers is safe

- All workers consume the **same** Redis/BullMQ queue, and BullMQ hands each job
  to exactly one worker — jobs are spread across the pool automatically.
- Scheduled scenarios are guarded by a **per-schedule distributed lock**
  (`redlock`): even if many workers wake up for the same schedule at the same
  second, only one runs it. Long runs keep the lock alive with a heartbeat, and
  a crashed worker's lock expires so another can take over.
- The bundled Redis already runs with `--maxmemory-policy noeviction` (required
  by BullMQ) — no change needed when you add workers. If you use
  [your own Redis](EXTERNAL-DATABASES.md), confirm it has that policy *and*
  enough memory headroom before scaling up: more workers means a deeper queue.

So scaling `worker` up or down is safe at any time. **No duplicate runs.**

---

## Seeing the load (the metric API)

The backend exposes the live queue depth on its **`/health`** endpoint — no auth,
already published on `CALLMAN_PORT` (default `8080`):

```bash
curl -s http://localhost:8080/health | jq .data.queue
```

```json
{
  "waiting": 0,      // jobs queued, not yet picked up  ← the backlog signal
  "active": 0,       // jobs being processed right now
  "delayed": 0,      // scheduled for later
  "completed": 1234,
  "failed": 2
}
```

`waiting` (plus `active`) is the number you scale on: a sustained high `waiting`
means workers can't keep up — add capacity. Near-zero `waiting` means you can
scale back down.

> **Prometheus users:** the same numbers are exported as gauges on `/metrics`
> (same port) — `bullmq_jobs_waiting`, `bullmq_jobs_active`, `bullmq_jobs_delayed`.
> Wire these into your existing Prometheus/Grafana and alert/scale on
> `bullmq_jobs_waiting`. Set `METRICS_ENABLED=false` in `.env` to turn `/metrics`
> off.

---

## Scaling manually

Add workers (e.g. to 3):

```bash
docker compose up -d --scale worker=3 worker
```

Verify — you should see `callman-worker-1`, `callman-worker-2`, `callman-worker-3`:

```bash
docker compose ps worker
```

Scale back down (minimum `1`):

```bash
docker compose up -d --scale worker=1 worker
```

> The trailing `worker` and `--no-recreate` keep the action scoped to the worker
> service — your `backend`, `admin`, `mongo`, and `redis` containers are not
> touched or restarted:
> ```bash
> docker compose up -d --no-recreate --scale worker=3 worker
> ```

---

## Scaling automatically

[`scripts/autoscale-worker.sh`](../scripts/autoscale-worker.sh) reads the backlog
from `/health` and adjusts the worker count for you. It runs **once per
invocation** ("evaluate and adjust"), so you schedule it with cron or a systemd
timer.

**Prerequisite:** `jq` on the host (`apt install jq` / `yum install jq`).

It computes `desired = ceil((waiting + active) / TARGET_PER_WORKER)`, clamps it
between `MIN_WORKERS` and `MAX_WORKERS`, and only calls `docker compose` when the
count actually changes. Scale-**up** is immediate; scale-**down** waits out a
cooldown so the pool doesn't flap as the backlog drains.

### Configuration (environment variables)

| Variable | Default | Description |
|---|---|---|
| `HEALTH_URL` | `http://localhost:<CALLMAN_PORT>/health` | Backend health endpoint to read the backlog from. |
| `MIN_WORKERS` | `1` | Never scale below this. |
| `MAX_WORKERS` | `10` | Never scale above this (cap to your host's CPU/RAM). |
| `TARGET_PER_WORKER` | `100` | Backlog each worker should absorb. Lower = scales up sooner. |
| `SCALE_DOWN_COOLDOWN_SECONDS` | `300` | Minimum seconds between scale-downs (anti-flap). |
| `COMPOSE_DIR` | repo root | Directory holding `docker-compose.yml` + `.env`. |
| `STATE_FILE` | `/tmp/callman-autoscale.state` | Where the last-action timestamp is kept. |

Try it once by hand first (safe — it only acts when the count must change):

```bash
MAX_WORKERS=5 ./scripts/autoscale-worker.sh
```

### Run it every minute with cron

```cron
# crontab -e  (use the absolute path to your checkout)
* * * * * MAX_WORKERS=5 TARGET_PER_WORKER=100 /opt/callman-onprem/scripts/autoscale-worker.sh >> /var/log/callman-autoscale.log 2>&1
```

### Or run it with a systemd timer

`/etc/systemd/system/callman-autoscale.service`:

```ini
[Unit]
Description=Callman worker autoscaler (one shot)
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/callman-onprem
Environment=MAX_WORKERS=5
Environment=TARGET_PER_WORKER=100
ExecStart=/opt/callman-onprem/scripts/autoscale-worker.sh
```

`/etc/systemd/system/callman-autoscale.timer`:

```ini
[Unit]
Description=Run the Callman worker autoscaler every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now callman-autoscale.timer
journalctl -u callman-autoscale.service -f   # watch its decisions
```

### Tuning guidance

- **`TARGET_PER_WORKER`** controls how aggressively you scale. With the default
  concurrency of 50, a value around `100` means each worker carries ~2× its
  in-flight capacity as queued work before another worker is added. Lower it to
  react sooner; raise it to be more conservative.
- **`MAX_WORKERS`** must fit the host. Each worker uses CPU + RAM
  (~0.5–1 GB under load); don't set a cap your server can't run.
- **Redis** holds the whole queue — make sure it has memory headroom; it must
  stay `noeviction` (the bundled Redis already is).

### No `jq` on the host?

The script needs `jq` to read the backlog. If you can't install it, read the
backlog with Python instead and pass a count to the manual scale command:

```bash
backlog=$(curl -s http://localhost:8080/health \
  | python3 -c 'import sys,json,math; q=json.load(sys.stdin)["data"]["queue"] or {}; print((q.get("waiting",0))+(q.get("active",0)))')
docker compose up -d --no-recreate --scale "worker=$(( (backlog + 99) / 100 > 1 ? (backlog + 99)/100 : 1 ))" worker
```

---

## Troubleshooting

**Symptom:** `docker compose up --scale worker=N` fails with *"container name
'/callman-worker' is already in use"*.
**Cause:** an old `container_name: callman-worker` line is still set on the
`worker` service — a fixed name allows only one container.
**Fix:** remove the `container_name:` line from the `worker` service in
`docker-compose.yml` (replicas are auto-named `callman-worker-1`, `-2`, …), then
re-run the scale command.

**Symptom:** backlog (`queue.waiting`) stays high even after scaling.
**Cause:** the cap is too low, the threshold too high, or the host is out of
CPU/RAM.
**Fix:** raise `MAX_WORKERS`, lower `TARGET_PER_WORKER`, and check
`docker stats` for CPU/RAM saturation. If the host is the bottleneck, also try a
higher `BULLMQ_WORKER_CONCURRENCY` only if CPU allows.

**Symptom:** workers get OOM-killed / restart repeatedly under load.
**Cause:** too many workers (or too-high concurrency) for the host's memory.
**Fix:** lower `MAX_WORKERS` and/or `BULLMQ_WORKER_CONCURRENCY`; give the host
more RAM.

**Symptom:** background jobs silently stop running.
**Cause:** Redis evicted BullMQ's job data under memory pressure.
**Fix:** ensure Redis runs with `maxmemory-policy noeviction` (the bundled Redis
already does) and has enough memory. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

**Symptom:** the worker count keeps flapping up and down.
**Cause:** scale-down cooldown too short for your traffic pattern.
**Fix:** raise `SCALE_DOWN_COOLDOWN_SECONDS` (e.g. `600`).
