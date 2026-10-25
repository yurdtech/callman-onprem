#!/usr/bin/env bash
#
# check-realtime.sh — does the path from a desktop to the backend carry the
# live-updates stream (GET /api/realtime/stream) unbuffered?
#
# Run it from a machine on the users' network, against the SAME address the
# desktops use (through your reverse proxy / load balancer), e.g.
#
#     ./scripts/check-realtime.sh https://callman.yourcompany.local
#
# It opens the backend's 3-second probe stream (no sign-in needed) and times
# when the first event arrives:
#   • right away       → the stream passes through; desktops get live updates
#   • only after ~3 s  → something in between buffers responses; desktops
#                        still work but keep polling (see docs/REALTIME.md)
#   • 404              → the backend is older than 1.0.6 or REALTIME_ENABLED=false
#
# READ-ONLY. Prerequisites: bash, curl. Exit codes: 0 = streams, 1 = buffered
# or unreachable, 2 = usage.

set -uo pipefail

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

# Milliseconds since the epoch, on GNU/Linux, macOS (bash 3.2, BSD date) and
# minimal images alike.
now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local t="${EPOCHREALTIME/[.,]/}"
    echo "${t:0:13}"
    return
  fi
  local t
  t=$(date +%s%3N 2>/dev/null)
  if [[ "$t" =~ ^[0-9]+$ ]]; then echo "$t"; return; fi
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import time; print(int(time.time()*1000))'; return; fi
  if command -v perl >/dev/null 2>&1; then perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; return; fi
  echo $(( $(date +%s) * 1000 ))
}

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  echo "Usage: $0 <backend URL, e.g. https://callman.yourcompany.local>" >&2
  exit 2
fi
BASE="${BASE%/}"
# Accept the desktop's API address too (…/api).
BASE="${BASE%/api}"
URL="$BASE/api/realtime/probe"

printf '%sCallman — live updates check%s\n  %s\n\n' "$B" "$N" "$URL"

STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Accept: text/event-stream' "$URL" || true)
if [[ "$STATUS" == "404" ]]; then
  printf '  %s!%s The backend answered 404: it is older than 1.0.6, or REALTIME_ENABLED=false.\n' "$Y" "$N"
  printf '    Desktops keep polling as before — nothing is broken.\n'
  exit 1
fi
if [[ "$STATUS" != "200" ]]; then
  printf '  %s✗%s Could not open the probe (HTTP %s). Check the address and the proxy route for /api/.\n' "$R" "$N" "${STATUS:-none}"
  exit 1
fi

# Time from request start to the line carrying the first event.
START=$(now_ms)
FIRST_MS=""
while IFS= read -r line; do
  if [[ "$line" == event:\ hello* ]]; then
    FIRST_MS=$(( $(now_ms) - START ))
    break
  fi
done < <(curl -sN --max-time 10 -H 'Accept: text/event-stream' "$URL")

if [[ -z "$FIRST_MS" ]]; then
  printf '  %s✗%s The stream opened but no event arrived within 10 s.\n' "$R" "$N"
  printf '    A proxy holds the response back. See docs/REALTIME.md › "Behind your proxy".\n'
  exit 1
fi

if (( FIRST_MS < 1500 )); then
  printf '  %s✓%s First event after %d ms — the stream passes through unbuffered.\n' "$G" "$N" "$FIRST_MS"
  printf '    Desktops on this path get live updates.\n'
  exit 0
fi

printf '  %s✗%s First event only after %d ms — something between here and the backend buffers responses.\n' "$R" "$N" "$FIRST_MS"
printf '    Desktops still work but keep polling. Turn response buffering off for /api/realtime/\n'
printf '    on that hop (docs/REALTIME.md › "Behind your proxy").\n'
exit 1
