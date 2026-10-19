# Load Testing Lab

The **Load Testing Lab** (admin panel → *Load Testing Lab*) answers one question
with real numbers: *what happens when N scenario runs hit our systems at the
same moment?*

You pick scenarios and a count for each — say **A × 100, B × 200, C × 400** —
and start the lab now or at a set time. Callman spreads the 700 runs over its
worker pods, every pod prepares its share, and all of them start **at the same
instant**. Every run is a normal server-side scenario run: HTTP, SOAP, DB
(Oracle / PostgreSQL / MySQL / MSSQL / Mongo), Kafka, Redis, script nodes all
execute exactly as in a scheduled run. When the last run ends you get the full
report.

> Labs put **real load on the systems under test**. Run them against test
> environments, and look at the *Targets* list on the preflight screen before
> you confirm.

---

## How a lab runs

```
scheduled ─► planning ─► arming ─► running ─► finalizing ─► completed
             (layout)    (prepare,   (t0: every   (merge the
                          arm)        shard fires)  shards)
```

1. **Planning** — the coordinator looks at the live worker fleet (every worker
   writes a heartbeat to Redis) and splits the runs into one *shard* per worker.
2. **Arming** — each shard loads its scenarios and resolves their connections
   **once**, then reports *armed*. Nothing has hit a target yet.
3. **t0** — when every shard is armed the coordinator publishes a start instant
   a few seconds ahead (Redis clock, so pod clock drift does not matter). Each
   shard sleeps until t0 and then starts all of its runs at once.
4. **Running** — shards record every run (no sampling) and publish live
   snapshots every second; the panel shows them live.
5. **Finalizing** — the coordinator merges the shards into the report.

Lab results live in their own collections (`load_lab_runs`,
`load_lab_run_items`, `load_lab_samples`, `load_lab_shards`). They do **not**
appear in scenario run history, KPIs or failure trends.

### Modes

| Mode | What happens | Use it for |
|---|---|---|
| **Burst** (default) | Every run starts at t0. Refused when the fleet cannot hold all runs at once. | "Can we take 700 at the same moment?" |
| **Waves** | Each worker keeps at most `LOAD_LAB_MAX_RUNS_PER_POD` runs in flight; the next run starts when one ends. | Labs bigger than the fleet; sustained throughput. |

### Content

*Approved* (default) runs each scenario's last approved version — the reviewed
one, like schedules and CI. A scenario with no approved version runs its live
content (the preflight says so). *Live* always runs the current content.

### Per-run variables

Every run gets these environment variables, so a scenario can make its data
unique per run (order references, idempotency keys, …):

| Variable | Value |
|---|---|
| `{{loadLab.index}}` | Run number in the lab (0 … total-1) |
| `{{loadLab.scenarioIndex}}` | Run number within its scenario (0 … count-1) |
| `{{loadLab.total}}` | Total runs in the lab |
| `{{loadLab.labId}}` | The lab's id |
| `{{loadLab.runId}}` | `<labId>-<index>` — unique per run |

---

## Capacity: how many runs at once

```
burst capacity = load-lab workers × LOAD_LAB_MAX_RUNS_PER_POD
pods needed    = ceil(total runs / LOAD_LAB_MAX_RUNS_PER_POD)
```

The preflight screen shows the live fleet, the capacity, and — when it is not
enough — the exact command that adds pods. Burst labs that do not fit are
refused before anything starts.

**Sizing `LOAD_LAB_MAX_RUNS_PER_POD`** (default 150): a typical API/DB scenario
holds ~2–8 MB of heap while it runs, so 150 runs fit a 1 GiB worker heap. For
scenarios with large responses lower it, or raise the pod memory.

**Oracle 11g (Thick mode):** every Oracle call runs on Node's libuv thread pool,
so `UV_THREADPOOL_SIZE` caps how many Oracle calls one pod has in flight. The
dedicated lab workers default to 32; the regular workers use 8.

**Database logins:** a DB step opens its own connection today. A burst of N
runs means up to N simultaneous logins to that database — check the target's
`PROCESSES`/`SESSIONS` (Oracle) or `max_connections` first.

Only one lab executes at a time; a second one waits for the first to finish.

---

## Kubernetes (Helm)

By default the regular `worker` pods also take lab shards
(`loadLab.onRegularWorkers: true`). For real bursts give labs their own pods:

```yaml
# values.yaml
loadLab:
  maxRunsPerPod: 150
  onRegularWorkers: false      # keep labs off the production workers
loadLabWorker:
  enabled: true
  replicaCount: 5              # 5 × 150 = 750 runs at once
  heapMb: 2048
  uvThreadpoolSize: 32
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { memory: 3Gi }
```

Scale before a lab, and back down after it:

```bash
helm upgrade callman ./callman --reuse-values --set loadLabWorker.replicaCount=5
# … run the lab …
helm upgrade callman ./callman --reuse-values --set loadLabWorker.replicaCount=1
```

Wait until the new pods are *Ready* (they appear in the lab's fleet strip
within ~10 s) before starting a burst.

All `loadLab.*` values map to the `LOAD_LAB_*` variables below.

## Docker Compose

By default the `worker` replicas take lab shards too. For a dedicated lab
fleet use the `load-lab` profile:

```bash
# .env
WORKER_QUEUES=scenarios          # regular workers: scenario runs only
LOAD_LAB_MAX_RUNS_PER_POD=150

COMPOSE_PROFILES=load-lab docker compose up -d --scale load-lab-worker=5
```

Or, without the profile, add regular workers:
`docker compose up -d --no-recreate --scale worker=5 worker`.

---

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `LOAD_LAB_ENABLED` | `true` | Lab API + lab consumers on/off |
| `WORKER_QUEUES` | `scenarios,load-lab` | Queues a worker consumes (`scenarios`, `load-lab`) |
| `LOAD_LAB_MAX_TOTAL_RUNS` | `2000` | Largest lab |
| `LOAD_LAB_MAX_RUNS_PER_POD` | `150` | Runs one worker fires at once |
| `LOAD_LAB_ARM_TIMEOUT_MS` | `60000` | Wait for shards to arm; late shards' runs count as *not started* |
| `LOAD_LAB_START_LEAD_MS` | `3000` | Gap between "all armed" and t0 |
| `LOAD_LAB_SAMPLES_PER_GROUP` | `3` | Full-detail runs kept per group (first / slowest / per error) |
| `SCENARIO_RUN_MAX_DURATION_MS` | `300000` | Upper bound for a lab's per-run timeout |

---

## Reading the report

| Section | What it tells you |
|---|---|
| **Overview** | Verdict against your thresholds, success rate, run time p50/p95/p99/max, wall clock (t0 → last run), throughput, **start skew** (how simultaneous the start really was: % of runs started within 100 ms / 1 s of t0), time to first failure, and the **insights**. |
| **Scenarios** | The same figures per scenario, plus a table per step: time, failure rate, HTTP status classes, and its share of the run time (the step that dominates is flagged). |
| **Errors** | Failures grouped by cause (`ORA-12519`, `ECONNREFUSED`, `HTTP_503`, timeouts, assertions …) with who is likely at fault: the **target**, **Callman**, or the **scenario config**. |
| **Timeline** | Per second since t0: active runs, starts, finishes, failures, p50/p95. A rising p95 shows a queue building up. |
| **Infrastructure** | Per worker pod: CPU, memory, heap, event-loop delay, active runs; plus Mongo/Redis latency and the regular `scenario-runs` queue. If the workers' event loop was overloaded the report says the measured times are inflated by Callman itself. |
| **Runs** | Every run (also as CSV): status, start skew, duration, failed step, error. Sampled runs open with full step detail. |
| **Compare** | Any two labs side by side — e.g. before and after an optimisation (*Re-run* compares against the original automatically). |

Typical findings and what to do:

- **Start skew p95 > 1 s** — the pods were too busy starting runs; add pods or
  lower `LOAD_LAB_MAX_RUNS_PER_POD`.
- **Event loop delay > 200 ms** — durations include Callman's own queueing;
  spread the lab over more pods for clean numbers.
- **`ORA-12519` / "too many connections"** — the database ran out of sessions.
- **`HTTP_429` / `HTTP_503`** — the target or a gateway in front of it is
  throttling.
- **Regular runs queued during the lab** — use the dedicated lab workers.
