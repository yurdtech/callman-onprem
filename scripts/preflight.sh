#!/usr/bin/env bash
#
# preflight.sh — check your `.env` and host BEFORE `docker compose up -d`.
#
# Every check here corresponds to something that would otherwise fail later
# as a container exit, an unhealthy service, or a confusing log line. It is
# READ-ONLY: it never starts, stops, or changes anything.
#
# Usage:
#     ./scripts/preflight.sh
#
# Exit codes: 0 = ready to start, 1 = at least one blocking problem.
# Warnings alone do not fail the run.
#
# Prerequisites: bash, docker. (openssl/redis-cli are used only if present.)

set -uo pipefail

# --- output helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

ERRORS=0
WARNINGS=0

ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; ERRORS=$((ERRORS + 1)); }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; WARNINGS=$((WARNINGS + 1)); }
info() { printf '    %s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

# --- locate the compose project -------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="$COMPOSE_DIR/.env"

printf '%sCallman on-prem — preflight check%s\n' "$B" "$N"
printf 'project: %s\n' "$COMPOSE_DIR"

# --- .env reader -----------------------------------------------------------
# Reads a value without sourcing the file (values may contain characters that
# a shell would interpret). Last definition wins, matching dotenv.
env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null \
    | tail -n1 | cut -d= -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

env_defined() {
  [[ -f "$ENV_FILE" ]] || return 1
  grep -qE "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════
head_ "1. Host requirements"

if ! command -v docker >/dev/null 2>&1; then
  bad "docker not found — install Docker Engine: https://docs.docker.com/engine/install/"
else
  ok "docker $(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')"
fi

compose_ver="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
if [[ -z "$compose_ver" ]]; then
  bad "Docker Compose v2 not found — install the Compose plugin"
else
  # `depends_on: required:` (which makes the bundled databases optional)
  # needs Compose v2.20 or newer.
  major="${compose_ver%%.*}"
  rest="${compose_ver#*.}"
  minor="${rest%%.*}"
  if [[ "$major" -gt 2 ]] || { [[ "$major" -eq 2 ]] && [[ "$minor" -ge 20 ]]; }; then
    ok "docker compose v$compose_ver"
  else
    bad "docker compose v$compose_ver is too old — v2.20+ required"
    info "Upgrade the Compose plugin, then re-run this script."
  fi
fi

# ══════════════════════════════════════════════════════════════════════
head_ "2. Configuration file"

if [[ ! -f "$ENV_FILE" ]]; then
  bad ".env not found in $COMPOSE_DIR"
  info "Create it:  cp .env.example .env    then edit it and re-run this script."
  printf '\n%s%d problem(s) found.%s\n' "$R" "$ERRORS" "$N"
  exit 1
fi
ok ".env found"

# Only ACTIVE assignments matter — commented-out optional settings may keep
# their placeholder text indefinitely.
placeholder_re='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*<CHANGE_ME'
placeholders="$(grep -cE "$placeholder_re" "$ENV_FILE" 2>/dev/null || true)"
if [[ "${placeholders:-0}" -gt 0 ]]; then
  bad "$placeholders setting(s) still hold a <CHANGE_ME…> placeholder — fill them in:"
  grep -nE "$placeholder_re" "$ENV_FILE" | sed 's/=.*/=<CHANGE_ME…>/' | while read -r l; do info "$l"; done
else
  ok "no <CHANGE_ME…> placeholders left"
fi

# A variable defined twice silently resolves to the LAST definition — an easy
# way to end up pointed at the wrong database after uncommenting an example.
dupes="$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" 2>/dev/null \
          | tr -d ' =' | sort | uniq -d || true)"
if [[ -n "$dupes" ]]; then
  bad "these settings are defined more than once — only the LAST one takes effect:"
  printf '%s\n' "$dupes" | while read -r d; do
    info "$d  (lines: $(grep -nE "^[[:space:]]*$d=" "$ENV_FILE" | cut -d: -f1 | tr '\n' ' '))"
  done
  info "Delete the duplicates, keeping the definition you actually want."
else
  ok "no setting is defined twice"
fi

perms="$(stat -f '%OLp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "")"
if [[ -n "$perms" && "${perms: -2}" != "00" ]]; then
  warn ".env is readable by other users on this host (mode $perms)"
  info "It holds passwords and secrets. Restrict it:  chmod 600 .env"
fi

for v in CALLMAN_VERSION CALLMAN_ADMIN_VERSION; do
  val="$(env_get "$v")"
  if [[ -z "$val" ]]; then
    bad "$v is not set — we tell you which version to run"
  elif [[ "$val" == *"<CHANGE_ME"* ]]; then
    bad "$v is still the placeholder — set the version we gave you"
  else
    ok "$v=$val"
  fi
done

# ══════════════════════════════════════════════════════════════════════
head_ "3. Secrets"

# Mirrors the backend's own startup validation, so you see the problem here
# instead of as a container that exits seconds after starting.
check_secret_set() {
  local label="$1"; shift
  local names=("$@")
  local values=() n v short=0
  for n in "${names[@]}"; do
    v="$(env_get "$n")"
    if [[ -z "$v" ]]; then
      bad "$n is not set"
      continue
    fi
    if [[ "${#v}" -lt 32 ]]; then
      bad "$n is ${#v} characters — must be at least 32"
      short=1
    fi
    values+=("$v")
  done
  [[ "$short" -eq 1 ]] && info "Generate with:  openssl rand -hex 32"
  local uniq
  uniq="$(printf '%s\n' "${values[@]}" | sort -u | grep -c . || true)"
  if [[ "${#values[@]}" -gt 1 && "$uniq" -ne "${#values[@]}" ]]; then
    bad "$label secrets are not all different — each must be a distinct value"
    info "Affected: ${names[*]}"
  elif [[ "$short" -eq 0 && "${#values[@]}" -eq "${#names[@]}" ]]; then
    ok "$label secrets: ${#names[@]} distinct values, all ≥ 32 chars"
  fi
}

check_secret_set "backend" JWT_SECRET JWT_REFRESH_SECRET \
  SESSION_TOKEN_ENCRYPTION_SECRET CONNECTION_ENCRYPTION_KEY
check_secret_set "admin panel" ADMIN_JWT_SECRET ADMIN_JWT_REFRESH_SECRET

admin_pw="$(env_get ADMIN_BOOTSTRAP_PASSWORD)"
if [[ -n "$admin_pw" && "${#admin_pw}" -lt 12 ]]; then
  warn "ADMIN_BOOTSTRAP_PASSWORD is short (${#admin_pw} chars)"
  info "The admin panel can read all Callman data. Use a strong password and"
  info "change it right after your first login."
fi

# ══════════════════════════════════════════════════════════════════════
head_ "4. Databases"

profiles="$(env_get COMPOSE_PROFILES)"
bundled_mongo=0; bundled_redis=0
[[ ",$profiles," == *",bundled-mongo,"* ]] && bundled_mongo=1
[[ ",$profiles," == *",bundled-redis,"* ]] && bundled_redis=1

# Split a connection URI into host and port, ignoring credentials.
#   mongodb://user:pass@db.acme.local:27017/callman?x=y  →  db.acme.local 27017
uri_host() {
  local uri="${1#*://}"
  uri="${uri##*@}"          # drop credentials
  uri="${uri%%/*}"          # drop path
  uri="${uri%%\?*}"         # drop query
  uri="${uri%%,*}"          # first host of a seed list
  printf '%s' "${uri%%:*}"
}
uri_port() {
  local hostport="${1#*://}" default="$2"
  hostport="${hostport##*@}"; hostport="${hostport%%/*}"
  hostport="${hostport%%\?*}"; hostport="${hostport%%,*}"
  if [[ "$hostport" == *:* ]]; then printf '%s' "${hostport##*:}"; else printf '%s' "$default"; fi
}

# Best-effort TCP reachability from THIS host. Containers resolve
# host.docker.internal to the host, which the host itself cannot resolve —
# so probe 127.0.0.1 in that case.
tcp_probe() {
  local host="$1" port="$2"
  [[ "$host" == "host.docker.internal" ]] && host="127.0.0.1"
  (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1
}

# ── MongoDB ──
if [[ "$bundled_mongo" -eq 1 ]]; then
  if env_defined MONGODB_URI && [[ -n "$(env_get MONGODB_URI)" ]]; then
    bad "MONGODB_URI is set AND 'bundled-mongo' is in COMPOSE_PROFILES"
    info "Pick one: remove bundled-mongo from COMPOSE_PROFILES to use your own"
    info "MongoDB, or comment out MONGODB_URI to use the bundled one."
  elif [[ -z "$(env_get MONGO_ROOT_PASSWORD)" ]]; then
    bad "MONGO_ROOT_PASSWORD is empty but the bundled MongoDB is enabled"
  else
    ok "MongoDB: bundled (we run it for you)"
  fi
else
  mongo_uri="$(env_get MONGODB_URI)"
  if [[ -z "$mongo_uri" ]]; then
    bad "No MongoDB: 'bundled-mongo' is not in COMPOSE_PROFILES and MONGODB_URI is not set"
    info "Set one or the other. See docs/EXTERNAL-DATABASES.md"
  else
    mh="$(uri_host "$mongo_uri")"; mp="$(uri_port "$mongo_uri" 27017)"
    ok "MongoDB: your own — $mh:$mp"
    if tcp_probe "$mh" "$mp"; then
      info "reachable from this host"
    else
      warn "cannot open a TCP connection to $mh:$mp from this host"
      info "If your database only allows connections from the Docker network,"
      info "this warning is expected. Otherwise check firewall/DNS/bind address."
    fi
    case "$mongo_uri" in
      *tlsCAFile=/certs/*)
        pem="${mongo_uri##*tlsCAFile=}"; pem="${pem%%&*}"
        if [[ -f "$COMPOSE_DIR/certs/$(basename "$pem")" ]]; then
          ok "CA certificate present: certs/$(basename "$pem")"
        else
          bad "MONGODB_URI references $pem but certs/$(basename "$pem") does not exist"
          info "Copy the PEM into $COMPOSE_DIR/certs/"
        fi
        ;;
    esac
  fi
fi

# ── Redis ──
if [[ "$bundled_redis" -eq 1 ]]; then
  if env_defined REDIS_URL && [[ -n "$(env_get REDIS_URL)" ]]; then
    bad "REDIS_URL is set AND 'bundled-redis' is in COMPOSE_PROFILES"
    info "Pick one: remove bundled-redis from COMPOSE_PROFILES to use your own"
    info "Redis, or comment out REDIS_URL to use the bundled one."
  elif [[ -z "$(env_get REDIS_PASSWORD)" ]]; then
    bad "REDIS_PASSWORD is empty but the bundled Redis is enabled"
  else
    ok "Redis: bundled (we run it for you, already set to noeviction)"
  fi
else
  redis_uri="$(env_get REDIS_URL)"
  if [[ -z "$redis_uri" ]]; then
    bad "No Redis: 'bundled-redis' is not in COMPOSE_PROFILES and REDIS_URL is not set"
    info "Set one or the other. See docs/EXTERNAL-DATABASES.md"
  else
    rh="$(uri_host "$redis_uri")"; rp="$(uri_port "$redis_uri" 6379)"
    ok "Redis: your own — $rh:$rp"
    if tcp_probe "$rh" "$rp"; then
      info "reachable from this host"
    else
      warn "cannot open a TCP connection to $rh:$rp from this host"
    fi
    # BullMQ stores queued jobs in Redis; an eviction policy silently drops
    # them and background jobs stop running with no error anywhere.
    if command -v redis-cli >/dev/null 2>&1; then
      pol="$(redis-cli -u "$redis_uri" --no-auth-warning config get maxmemory-policy 2>/dev/null | tail -n1)"
      if [[ "$pol" == "noeviction" ]]; then
        ok "maxmemory-policy=noeviction"
      elif [[ -n "$pol" ]]; then
        bad "your Redis has maxmemory-policy=$pol — it MUST be noeviction"
        info "Otherwise queued background jobs get evicted and silently vanish."
      else
        warn "could not read maxmemory-policy — verify it is 'noeviction'"
      fi
    else
      warn "redis-cli not installed — could not verify maxmemory-policy"
      info "Your Redis MUST run with maxmemory-policy=noeviction."
    fi
  fi
fi

if [[ ! -d "$COMPOSE_DIR/certs" ]]; then
  warn "certs/ directory is missing — recreate it if you need a private CA"
fi

# ══════════════════════════════════════════════════════════════════════
head_ "5. Ports"

port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
}

for pair in "CALLMAN_PORT:8080:backend API" "CALLMAN_ADMIN_PORT:5100:admin panel"; do
  var="${pair%%:*}"; rest="${pair#*:}"; default="${rest%%:*}"; label="${rest#*:}"
  p="$(env_get "$var")"; p="${p:-$default}"
  if port_in_use "$p"; then
    warn "port $p ($label) is already in use on this host"
    info "If that is a previous Callman install, this is fine — it will be replaced."
    info "Otherwise set a different $var in .env."
  else
    ok "port $p free for the $label"
  fi
done

# ══════════════════════════════════════════════════════════════════════
head_ "6. Optional integrations"

tg="$(env_get TELEGRAM_ENABLED)"
if [[ -z "$tg" ]]; then
  ok "Telegram error reporting disabled (no outbound internet needed)"
else
  if [[ -z "$(env_get TELEGRAM_BOT_TOKEN)" || -z "$(env_get TELEGRAM_CHAT_ID)" ]]; then
    bad "TELEGRAM_ENABLED=$tg but TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are missing"
    info "The backend refuses to start in production without both."
    info "To DISABLE it, set an EMPTY value:  TELEGRAM_ENABLED="
    info "(The literal text 'false' does NOT disable it.)"
  else
    ok "Telegram error reporting enabled, credentials present"
  fi
fi

# Login methods (local / LDAP) are NOT configured in .env — they live in the
# admin panel. Flag leftovers so an upgrading install is not silently relying
# on settings that no longer do anything.
stale_auth="$(grep -oE '^[[:space:]]*(AUTH_PROVIDERS|PASSWORD_PROVIDER_ORDER|AUTH_PASSWORD_RESET_URL|LDAP_[A-Z_]*)=' "$ENV_FILE" 2>/dev/null \
                | tr -d ' =' | sort -u || true)"
if [[ -n "$stale_auth" ]]; then
  warn "these settings are no longer used and can be deleted from .env:"
  printf '%s\n' "$stale_auth" | while read -r v; do info "$v"; done
  info "Login methods and LDAP are now configured in the admin panel:"
  info "  http://localhost:$(env_get CALLMAN_ADMIN_PORT || echo 5100) → On-Prem → Authentication"
  info "See docs/AUTH_SETUP.md"
fi

# ══════════════════════════════════════════════════════════════════════
head_ "7. Compose file"

if cfg_err="$(docker compose --project-directory "$COMPOSE_DIR" config -q 2>&1)"; then
  ok "docker-compose.yml is valid and every referenced variable resolves"
else
  bad "docker compose could not read the configuration:"
  printf '%s\n' "$cfg_err" | while read -r l; do info "$l"; done
fi

# ══════════════════════════════════════════════════════════════════════
printf '\n'
if [[ "$ERRORS" -gt 0 ]]; then
  printf '%s✗ %d problem(s) must be fixed before starting.%s' "$R" "$ERRORS" "$N"
  [[ "$WARNINGS" -gt 0 ]] && printf ' %s(%d warning(s))%s' "$Y" "$WARNINGS" "$N"
  printf '\n\nFix the ✗ lines above and run this script again.\n'
  exit 1
fi

printf '%s✓ Ready to start.%s' "$G" "$N"
[[ "$WARNINGS" -gt 0 ]] && printf ' %s%d warning(s) — review them above.%s' "$Y" "$WARNINGS" "$N"
printf '\n\n  docker compose pull\n  docker compose up -d\n\n'
exit 0
