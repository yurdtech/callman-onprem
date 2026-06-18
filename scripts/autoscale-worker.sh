#!/usr/bin/env bash
#
# autoscale-worker.sh — grow/shrink the Callman `worker` service based on the
# live BullMQ backlog.
#
# It runs ONCE per invocation ("evaluate and adjust"), so it is meant to be
# called on a schedule (cron every minute, or a systemd timer). Each run:
#   1. reads the backlog from the backend's /health API  (queue.waiting + .active)
#   2. computes the desired worker replica count
#   3. calls `docker compose up -d --scale worker=N` only when the count changes
#
# Why this is safe: every worker consumes the SAME Redis/BullMQ queue and
# BullMQ spreads jobs across them; a per-schedule redlock guarantees a given
# scheduled run never executes on two workers at once. See docs/SCALING.md.
#
# Prerequisites on the host: bash, curl, jq, and Docker Compose v2.
#
# Configuration (all optional — override via env):
#   HEALTH_URL                 Backend health endpoint.
#                              Default: http://localhost:<CALLMAN_PORT|8080>/health
#   MIN_WORKERS                Never scale below this.            Default: 1
#   MAX_WORKERS                Never scale above this.            Default: 10
#   TARGET_PER_WORKER          Target backlog handled per worker. Default: 100
#                              desired = ceil((waiting+active) / TARGET_PER_WORKER)
#   SCALE_DOWN_COOLDOWN_SECONDS  Min seconds between scale-DOWNs. Default: 300
#                              (scale-UP is always immediate; this only damps
#                              flapping when the backlog drains.)
#   COMPOSE_DIR                Directory holding docker-compose.yml + .env.
#                              Default: the repo root (parent of this script).
#   STATE_FILE                 Where the last-action timestamp is kept.
#                              Default: /tmp/callman-autoscale.state
#
# Exit codes: 0 = success (scaled or no-op), non-zero = hard error.

set -euo pipefail

log() { printf '%s autoscale-worker: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# --- locate the compose project -------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
[[ -f "$COMPOSE_DIR/docker-compose.yml" ]] \
  || die "no docker-compose.yml in COMPOSE_DIR=$COMPOSE_DIR (set COMPOSE_DIR)"

# --- dependencies ----------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v jq   >/dev/null 2>&1 || die "jq not found (install jq, or see docs/SCALING.md for a python fallback)"
command -v docker >/dev/null 2>&1 || die "docker not found"

# --- configuration ---------------------------------------------------------
MIN_WORKERS="${MIN_WORKERS:-1}"
MAX_WORKERS="${MAX_WORKERS:-10}"
TARGET_PER_WORKER="${TARGET_PER_WORKER:-100}"
SCALE_DOWN_COOLDOWN_SECONDS="${SCALE_DOWN_COOLDOWN_SECONDS:-300}"
STATE_FILE="${STATE_FILE:-/tmp/callman-autoscale.state}"

[[ "$MIN_WORKERS" -ge 1 ]] || die "MIN_WORKERS must be >= 1"
[[ "$MAX_WORKERS" -ge "$MIN_WORKERS" ]] || die "MAX_WORKERS must be >= MIN_WORKERS"
[[ "$TARGET_PER_WORKER" -ge 1 ]] || die "TARGET_PER_WORKER must be >= 1"

if [[ -z "${HEALTH_URL:-}" ]]; then
  # Mirror the API port from .env (CALLMAN_PORT) so the default matches the deploy.
  port="$(grep -E '^[[:space:]]*CALLMAN_PORT=' "$COMPOSE_DIR/.env" 2>/dev/null \
            | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  HEALTH_URL="http://localhost:${port:-8080}/health"
fi

# Run docker compose against the right project directory regardless of cwd.
dc() { docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.yml" "$@"; }

# --- read the backlog from the metric API ----------------------------------
health="$(curl -fsS --max-time 10 "$HEALTH_URL")" \
  || die "could not reach health API at $HEALTH_URL"

# queue can be null when Redis is briefly unreachable — treat as 0 backlog.
waiting="$(jq -r '(.data.queue.waiting // 0) | floor' <<<"$health" 2>/dev/null || echo 0)"
active="$(jq -r '(.data.queue.active // 0) | floor' <<<"$health" 2>/dev/null || echo 0)"
[[ "$waiting" =~ ^[0-9]+$ ]] || waiting=0
[[ "$active"  =~ ^[0-9]+$ ]] || active=0
backlog=$((waiting + active))

# --- compute desired replica count -----------------------------------------
# ceil(backlog / TARGET_PER_WORKER), then clamp to [MIN_WORKERS, MAX_WORKERS].
desired=$(( (backlog + TARGET_PER_WORKER - 1) / TARGET_PER_WORKER ))
(( desired < MIN_WORKERS )) && desired="$MIN_WORKERS"
(( desired > MAX_WORKERS )) && desired="$MAX_WORKERS"

current="$(dc ps -q worker 2>/dev/null | grep -c . || true)"
current="${current:-0}"

log "backlog=$backlog (waiting=$waiting active=$active) current_workers=$current desired=$desired [min=$MIN_WORKERS max=$MAX_WORKERS per=$TARGET_PER_WORKER]"

if [[ "$desired" -eq "$current" ]]; then
  log "no change needed."
  exit 0
fi

# --- anti-flap: scale up now, scale down only after the cooldown ------------
now="$(date +%s)"
if [[ "$desired" -lt "$current" ]]; then
  last="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  elapsed=$(( now - last ))
  if [[ "$elapsed" -lt "$SCALE_DOWN_COOLDOWN_SECONDS" ]]; then
    log "scale-down to $desired held: ${elapsed}s since last change < ${SCALE_DOWN_COOLDOWN_SECONDS}s cooldown."
    exit 0
  fi
fi

# --no-recreate leaves existing workers running; trailing `worker` keeps the
# action scoped so the backend/admin containers are never touched.
log "scaling worker $current -> $desired"
dc up -d --no-recreate --scale "worker=$desired" worker

# Record the action time (used by the scale-down cooldown).
printf '%s\n' "$now" >"$STATE_FILE" 2>/dev/null || log "warning: could not write STATE_FILE=$STATE_FILE"
log "done."
