# Public API — Callman data for Grafana, SIEM and BI

The Public API lets your company systems read Callman's data over HTTPS with a
token an administrator creates in the admin panel: team KPIs for Grafana, test runs
and the test inventory for quality dashboards and Jira, licence and usage figures
for management, and one audit stream for the security team's SIEM.

- **Read-only.** Every endpoint is `GET`; nothing can be changed through it.
- **Organization-owned tokens.** A token belongs to the company, not to a person:
  it keeps working when someone leaves, and only an admin creates, rotates or
  revokes it.
- **Limited by design.** Each token carries *scopes* (which data) and a *boundary*
  (which groups), and can be tied to IP addresses and a request rate.
- **On-prem only.** On Callman Cloud every `/api/public/…` path answers 404.

Base URL: `https://<your-callman-host>/api/public/v1`. The contract is the OpenAPI
3.1 document at [`/api/public/v1/openapi.json`](#11-openapi) (no token needed).
Grafana step by step: [GRAFANA.md](GRAFANA.md).

Contents: [1. Create a token](#1-create-a-token) · [2. Scopes](#2-scopes) ·
[3. Boundary](#3-boundary-which-groups) · [4. Limits, rotation, revocation](#4-limits-rotation-revocation) ·
[5. Conventions](#5-conventions) · [6. Errors](#6-errors) · [7. Endpoints](#7-endpoints) ·
[8. Recipes](#8-recipes) · [9. Network and Helm](#9-network-and-helm) ·
[10. Security notes](#10-security-notes) · [11. OpenAPI](#11-openapi)

---

## 1. Create a token

Admin panel → **Integration → Public API → New token**. You need the
`integration-tokens:manage` permission (roles **admin** and **super admin**).

| Step | What you choose |
|---|---|
| **Name** | What uses it, e.g. `Grafana — QA KPI`, `Splunk — audit`. It appears in the usage chart and in the audit stream. |
| **Access** | The scopes (§2). Start from a preset — *Grafana — KPI*, *Grafana — KPI + people*, *Quality dashboards*, *SIEM*, *Management* — and tick or untick scopes; any change makes it *Custom*. |
| **Data** | *The whole organization* (super admin only) or chosen tribes / squads (§3). |
| **Limits** | Expiry (30 / 90 / 180 / 365 days), allowed IP addresses or CIDR ranges (empty = any), requests per minute (10–1200, default 120). |
| **Review** | Check and **Create**. |

The token (`cm_int_` + 43 characters) is shown **once** — copy it into the
consuming system's secret store. Callman stores only its SHA-256 hash.

The token's page shows its status (*active*, *grace*, *expired*, *revoked*), when
and from which IP it was last used, a 30-day call chart and the calls per endpoint.

## 2. Scopes

| Scope | Label in the panel | Gives |
|---|---|---|
| `org:read` | always on | `/me`, `/org/groups`, `/org/users` — the directory Grafana variables need |
| `kpi:read` | Team KPIs | `/kpi/*` except per-person, `/metrics/kpi` |
| `kpi:users:read` | KPIs per person — **sensitive** | `/kpi/users`, `/kpi/scorecards` |
| `tests:read` | Test inventory | `/tests`, `/tests/by-key/{testKey}`, `/tests/{kind}/{id}` (`…/runs` also needs `runs:read`) |
| `runs:read` | Test runs | `/runs`, `/runs/stats`, `/runs/failures`, `/runs/flaky` |
| `usage:read` | Usage and licence | `/usage/licence`, `/usage/active-users`, `/usage/desktop-versions`, `/usage/adoption` |
| `audit:read` | Audit events — **sensitive** | `/audit/events` |

**Sensitive** scopes return data about individual people or security events.
Every call under them is recorded (token, endpoint, row count, IP — kept a year)
and appears in the audit stream as `source: integration`.

## 3. Boundary (which groups)

- **The whole organization** — every tribe and squad, the organization-wide rows,
  and tests that belong to no group.
- **Chosen groups** — the picked tribes and squads. A picked **tribe also covers
  its squads**, resolved on every call, so a squad created later is included.
  Organization-wide rows and ungrouped tests are not visible.

A group outside the boundary answers **404** (`INT_GROUP_NOT_FOUND`), never 403, so
a token cannot probe which groups exist. Some data is organization-wide by nature
and needs an organization-wide token: the licence, and the admin / integration / AI
parts of the audit stream (403 `INT_ORG_TOKEN_REQUIRED`).

## 4. Limits, rotation, revocation

| | |
|---|---|
| **IP allowlist** | IPv4 / IPv6 addresses or CIDR ranges (≤ 50). Checked against the caller's address: behind your ingress / reverse proxy, the `X-Forwarded-For` entry that proxy added (the rightmost; with two proxies set `PUBLIC_API_PROXY_HOPS=2`, [ENVIRONMENT.md](ENVIRONMENT.md)) — entries a caller writes into the header themselves are ignored. Outside → 403 `INT_IP_FORBIDDEN`. |
| **Rate limit** | Requests per minute per token, cluster-wide (Redis). Every answer carries `X-RateLimit-Limit` / `X-RateLimit-Remaining`; over the limit → 429 `INT_RATE_LIMITED` with `Retry-After` (seconds). |
| **Expiry** | At most 365 days. An expired token answers 401 `INT_TOKEN_INVALID`. |
| **Rotate** | **Rotate** on the token's page issues a new secret; the **old one keeps working for 24 hours** (status *grace*) while you replace it. |
| **Revoke** | Immediate in the panel; every Callman pod stops accepting it within 30 seconds. |

## 5. Conventions

```sh
export CALLMAN=https://callman.bank.local     # your Callman address, no trailing slash
export TOKEN=cm_int_…                          # the token from §1
curl -s "$CALLMAN/api/public/v1/me" -H "Authorization: Bearer $TOKEN"
```

`/me` answers the token's name, prefix, scopes, boundary, expiry and rate limit —
use it as the health check of a data source.

**Lists** answer one envelope:

```json
{
  "success": true,
  "data": { "rows": [ { "…": "…" } ] },
  "meta": { "count": 1, "nextCursor": null, "generatedAt": "2026-11-09T12:51:53.006Z", "boundary": { "type": "org", "groups": 5 } }
}
```

In Grafana Infinity set the root selector to `data.rows`. Single objects (`/me`,
`/usage/licence`, `/tests/{kind}/{id}`, `/kpi/status`) answer `{ success, data, meta }`.

| Convention | Rule |
|---|---|
| **Formats** | `format=json` (default), `format=csv` (same columns, header line, UTF-8, RFC 4180), and `format=jsonl` on `/audit/events` (one JSON object per line). |
| **Time** | `from` / `to` take ISO 8601 (`2026-11-01T00:00:00Z`) or epoch milliseconds (Grafana `${__from}` / `${__to}`); 10-digit numbers are read as seconds. Every endpoint states its default and longest range. Time-bucketed data is cut in the **KPI timezone** (admin panel → KPI settings); weeks start on Monday. |
| **Several values** | Repeat the parameter or separate with commas: `groupId=a,b` = `groupId=a&groupId=b`. Grafana's *All* (`$__all`, `All`, `*`) means "no filter". |
| **Groups** | `groupId` of a tribe also selects its squads (`includeSquads=false` to turn that off where offered). |
| **Paging** | `limit` (≤ 5000) and an opaque `cursor`: pass `meta.nextCursor` back until it is `null`. |
| **Grafana helpers** | `/org/groups` and `/org/users` add `__value` / `__text` columns for variables. |
| **Compatibility** | Fields are only ever added. A breaking change would be a new `/api/public/v2`. |

## 6. Errors

```json
{ "success": false, "message": "This integration token is missing the 'usage:read' scope", "data": null, "error": "…", "code": "INT_SCOPE_MISSING", "details": { "required": "usage:read" } }
```

| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `INT_BAD_PARAM` | A parameter is wrong; `details.param` names it. |
| 401 | `INT_TOKEN_MISSING` | No `Authorization: Bearer cm_int_…` header. |
| 401 | `INT_TOKEN_INVALID` | Unknown, expired or revoked token — or a user's login / personal token (they do not work here). |
| 403 | `INT_IP_FORBIDDEN` | The caller's IP is not in the token's allowlist. |
| 403 | `INT_SCOPE_MISSING` | The token lacks the scope; `details.required` names it. |
| 403 | `INT_ORG_TOKEN_REQUIRED` | The data is organization-wide; a group token cannot read it. |
| 404 | `INT_GROUP_NOT_FOUND` | The group does not exist or is outside the boundary. |
| 404 | `INT_NOT_FOUND` | No such endpoint or item. |
| 429 | `INT_RATE_LIMITED` | Over the token's per-minute limit; wait `Retry-After` seconds. |

## 7. Endpoints

Every endpoint, its parameters and every field are in the OpenAPI document (§11);
below, what each is for and a working request. The examples use `$CALLMAN` /
`$TOKEN` from §5 and `$TRIBE` / `$SQUAD` for group ids taken from `/org/groups`.

### 7.1 Directory — `org:read`

| Endpoint | What |
|---|---|
| `GET /me` | The calling token. |
| `GET /org/groups` | Tribes and squads in the boundary: `id`, `name`, `path` (`Tribe/Squad`), `level`, `tribeId`, `tribeName`, `memberCount`. Filters `level`, `parentId`, `search`. |
| `GET /org/users` | Members of those groups with their memberships and when they were last seen. Filters `groupId`, `search`, `approver=true`. |

```sh
curl -s "$CALLMAN/api/public/v1/org/groups?level=squad" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/org/users?groupId=$TRIBE&format=csv" -H "Authorization: Bearer $TOKEN"
```

```json
{ "id": "6aecc8c4dc8949dde261c11c", "name": "Trade Finance", "path": "Corporate Banking/Trade Finance", "level": "squad",
  "parentId": "6aecc8b9dc8949dde261c114", "tribeId": "6aecc8b9dc8949dde261c114", "tribeName": "Corporate Banking",
  "memberCount": 2, "__value": "6aecc8c4dc8949dde261c11c", "__text": "Corporate Banking/Trade Finance" }
```

### 7.2 Team KPIs — `kpi:read` (per person: `kpi:users:read`)

The numbers the admin panel's KPI pages show ([KPI.md](KPI.md)), per week or
quarter, for the organization, tribes and squads.

| Endpoint | What |
|---|---|
| `GET /kpi/definitions` | The KPI catalog: id, name, template, formula, unit, direction, status. |
| `GET /kpi/targets` | Targets per quarter and group; `effective=true` resolves inheritance (org → tribe → squad). |
| `GET /kpi/results` | One row per KPI × group × period: `value`, `numerator`, `denominator`, `target`, `status` (`on_track` / `at_risk` / `off_track` / `no_data`), `partial` (period still running), `frozen`. Filters `periodType`, `level`, `groupId`, `kpiId` (id, template key or name), `from` / `to`, `status`. |
| `GET /kpi/measures` | The raw measures behind the formulas, `shape=wide` (one column per measure) or `long`. |
| `GET /kpi/users` | The same KPIs per person, from the tests they own. **Sensitive.** |
| `GET /kpi/scorecards` | Personal quarterly scorecards. **Sensitive.** |
| `GET /kpi/live` | Runs queued / running now and today's finished ones (`shape=rows` or `summary`). |
| `GET /kpi/status` | When the KPI engine last ran and whether it is `stale`. |
| `GET /metrics/kpi` | The current values in Prometheus text format (§8.2). |

```sh
curl -s "$CALLMAN/api/public/v1/kpi/results?periodType=week&level=tribe&from=2026-10-01T00:00:00Z" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/kpi/results?periodType=quarter&groupId=$TRIBE&kpiId=regression_automation_coverage&format=csv" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/kpi/measures?periodType=week&level=squad&shape=long" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/kpi/users?periodType=quarter&groupId=$SQUAD" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/kpi/live?shape=summary&level=tribe" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/kpi/status" -H "Authorization: Bearer $TOKEN"
```

```json
{ "time": "2026-10-25T20:00:00.000Z", "periodType": "week", "periodKey": "2026-W44",
  "kpiId": "6aecc991dc8949dde261c276", "kpi": "Regression automation coverage", "templateKey": "regression_automation_coverage",
  "unit": "percent", "direction": "higher_better", "level": "tribe", "groupId": "6aecc8a4dc8949dde261c0fd",
  "group": "Retail Banking", "groupPath": "Retail Banking", "tribe": "Retail Banking",
  "value": 72.5, "numerator": 29, "denominator": 40, "targetMin": 60, "target": 80, "targetSource": "org",
  "status": "at_risk", "partial": false, "frozen": true, "computedAt": "2026-11-09T10:53:57.444Z" }
```

`time` is the period start (local midnight in the KPI timezone, as UTC). Values are
percentages with one decimal, or counts for count KPIs.

### 7.3 Test runs — `runs:read`

Scenario, UI test and pipeline runs in one shape (`kind` = `scenario` /
`ui_test` / `pipeline`). Load-test runs are never included; desktop runs only with
`includeDesktop=true`.

| Endpoint | What |
|---|---|
| `GET /runs` | One row per run: test, group, who started it, `triggerType` (`schedule` / `manual` / `ci` / `api` / `desktop`), `result` (`passed` / `failed` / `other` / `running`), duration, CI provider / branch / commit / job URL. `from` and `to` required (≤ 92 days); newest first (`order=asc` for oldest first). |
| `GET /runs/stats` | Counts, pass rate and duration percentiles per day / week / month, `by=org,tribe,squad,user,kind,triggerType` (combinable). ≤ 366 days, default 30. |
| `GET /runs/failures` | The tests that failed most, with the last error (credentials scrubbed). |
| `GET /runs/flaky` | Tests whose result keeps flipping pass ↔ fail (`minFlips`). |

```sh
curl -s "$CALLMAN/api/public/v1/runs?from=2026-10-01T00:00:00Z&to=2026-11-01T00:00:00Z&kind=scenario,ui_test&limit=100" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/runs/stats?interval=week&by=tribe,kind" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/runs/failures?top=20" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/runs/flaky?minFlips=2" -H "Authorization: Bearer $TOKEN"
```

```json
{ "time": "2026-11-01T20:00:00.000Z", "level": "tribe", "groupId": "6aecc8b9dc8949dde261c114", "group": "Corporate Banking",
  "groupPath": "Corporate Banking", "tribe": "Corporate Banking", "runs": 8, "passed": 6, "failed": 2, "other": 0,
  "passRate": 75, "avgDurationMs": 7, "p50DurationMs": 2, "p95DurationMs": 24, "distinctItems": 4 }
```

### 7.4 Test inventory — `tests:read`

Every scenario, UI test and pipeline collection with the KPI fields (regression,
automation state, excluded), approval, Jira test key and last run.

| Endpoint | What |
|---|---|
| `GET /tests` | The inventory. Filters `kind`, `groupId`, `state`, `regression`, `automation`, `hasTestKey`, `testKey`, `ownerId`, `search`. **Sync:** `updatedSince=<meta.syncCursor of the last pull>` returns only what changed since (fields, approval or a new run). |
| `GET /tests/by-key/{testKey}` | The tests linked to a Jira test key — for a Jira / Xray status sync. |
| `GET /tests/{kind}/{id}` | One test in full (`kind` = `scenario`, `ui_test`, `pipeline`). |
| `GET /tests/{kind}/{id}/runs` | Its runs (also needs `runs:read`), same rows as `/runs`. |

```sh
curl -s "$CALLMAN/api/public/v1/tests?groupId=$TRIBE&regression=true&limit=500" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/tests/by-key/$TEST_KEY" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/tests/scenario/$TEST_ID" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/tests/scenario/$TEST_ID/runs?from=2026-10-01T00:00:00Z&to=2026-11-01T00:00:00Z" -H "Authorization: Bearer $TOKEN"
```

```json
{ "kind": "scenario", "id": "6aecc8ed3a48c3de3c930e73", "name": "Card issuance — happy path", "level": "squad",
  "groupId": "6aecc8a8dc8949dde261c105", "groupPath": "Retail Banking/Cards", "tribe": "Retail Banking",
  "ownerId": "6aecc8c53a48c3de3c930dd2", "ownerName": "aysel.cards@kpi.qa", "testKey": "CARD-104", "regression": true,
  "automation": "automated", "excluded": false, "approved": true, "state": "valid",
  "lastRunAt": "2026-11-09T11:13:24.847Z", "lastRunStatus": "passed", "changedAt": "2026-11-09T11:13:24.847Z" }
```

### 7.5 Usage and licence — `usage:read`

| Endpoint | What |
|---|---|
| `GET /usage/licence` | Seats used / licensed / free, expiry, days left, `status` and one `health` value to alert on (`valid` / `expiring` / `over_seats` / `expired` / `unlicensed`). A seat is one Callman account — the count the licence gate and the panel's License page use. **Organization-wide tokens only.** |
| `GET /usage/active-users` | Active people per `interval=day|week|month`, `by=org|tribe|squad`, with new and total accounts. `shape=summary`: DAU / WAU / MAU (trailing 1 / 7 / 30 days) and stickiness per group. |
| `GET /usage/desktop-versions` | Desktops per version (`by=version`), operating system (`by=platform`) or both, against the latest release; `meta.usersOnOlderVersions` for an upgrade campaign. |
| `GET /usage/adoption` | Per group: collections, requests, scenarios, AI-assistant tests, UI tests, mocks, diagrams — what exists, what was created, run and approved in the period — and members / active people. |

**Active** means the person did something themselves: sent a request, started a
scenario or UI test run by hand, or changed something in a workspace. Scheduled,
CI and load-test runs do not make anyone active. Only append-only records are read,
so a past day's number never changes. Group rows are people-based: a tribe counts
the members of the tribe and its squads; a person in two squads counts in both.

```sh
curl -s "$CALLMAN/api/public/v1/usage/licence" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/usage/active-users?interval=week&by=tribe" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/usage/active-users?shape=summary" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/usage/desktop-versions?by=version_platform&seenWithinDays=30" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/usage/adoption?by=squad&format=csv" -H "Authorization: Bearer $TOKEN"
```

```json
{ "installed": true, "status": "active", "health": "valid", "readOnly": false, "company": "Bank",
  "validFrom": "2026-08-16T00:00:00.000Z", "expiresAt": "2027-08-16T00:00:00.000Z", "daysLeft": 280, "graceDays": 14,
  "seatsLicensed": 2000, "seatsUsed": 1412, "seatsFree": 588, "seatsUsedPct": 70.6, "overSeats": false }
```

### 7.6 Audit stream — `audit:read`

One stream of everything a security team audits, oldest first:

| `source` | What |
|---|---|
| `admin` | Admin panel actions (sign-ins, users, groups, settings, licence …). |
| `integration` | Integration-token actions (create, rotate, revoke …) and every sensitive Public API read. |
| `workspace` | What Callman users changed: collections, requests, scenarios, UI tests, environments, approvals, tokens … |
| `ai` | AI calls: feature, provider, model, token counts, masking — **metadata only**, never prompt or answer text. |

Each row: `id` (`<source>:<id>`), `time`, `source`, `action`, `actor` `{ type:
admin | user | token | system, id, name }`, `target` `{ type, id, name }`,
`workspaceId`, `actorGroups`, `ip`, `userAgent`, `result` (`success` / `failure`),
`details` (attribution only — secrets masked, content left out).

**Incremental pull.** Start with `from` (default: the last 24 hours); afterwards
always pass the previous `meta.nextCursor` as `cursor` (alias `since`). The cursor
is set on every page, also an empty one; `meta.hasMore=true` means "call again now".
The stream stops 5 seconds before the present, so an event written a moment late
lands in a later page — **no row is skipped and none is returned twice**, and the
same cursor always returns the same rows. With `format=jsonl` the cursor is in the
`X-Next-Cursor` header and `hasMore` in `X-Has-More`.

Filters: `source` (several), `action` (exact or a prefix ending in `*`, e.g.
`scenario.*`), `actorId`, `to`, `limit` (≤ 5000). A group token sees only the
workspace events of its groups' members. The calling token's own reads of
`/audit/events` are left out of its own stream (other tokens see them).

```sh
curl -s "$CALLMAN/api/public/v1/audit/events?from=2026-11-01T00:00:00Z&limit=1000" -H "Authorization: Bearer $TOKEN"
curl -s "$CALLMAN/api/public/v1/audit/events?source=workspace&action=scenario.*,collection.approved&format=jsonl" -H "Authorization: Bearer $TOKEN"
```

```json
{ "id": "workspace:6af1bf757f172244aed542f4", "time": "2026-11-09T12:39:31.207Z", "source": "workspace",
  "action": "environment.updated", "actor": { "type": "user", "id": "6aecc8c53a48c3de3c930dd2", "name": "aysel.cards@bank.az" },
  "target": { "type": "environment", "id": "e1", "name": "prod" }, "workspaceId": "6aecc8cd3a48c3de3c930dde",
  "actorGroups": "Retail Banking/Cards", "ip": "10.0.0.5", "userAgent": "Callman/2.0.15", "result": "success",
  "details": { "password": "[redacted]", "note": "used Authorization: Bearer [redacted]", "count": 3 } }
```

## 8. Recipes

### 8.1 Grafana

The Infinity data source, a ready KPI dashboard and the bank's panel mapping are in
[GRAFANA.md](GRAFANA.md). For any other endpoint: Infinity → *JSON*, URL
`/api/public/v1/<endpoint>`, root selector `data.rows`, time range
`from=${__from}&to=${__to}`, a group variable from `/org/groups` (`__value` /
`__text`).

### 8.2 Prometheus

`/metrics/kpi` serves the current week's / quarter's KPI values as gauges —
`callman_kpi_value`, `callman_kpi_target`, `callman_kpi_target_min`,
`callman_kpi_numerator`, `callman_kpi_denominator` (labels `kpi`, `kpi_id`,
`level`, `group`, `group_path`, `tribe`, `period_type`, `period_key`, `unit`),
`callman_kpi_status` (one series per status, 1 for the current one),
`callman_kpi_last_refresh_timestamp_seconds`, and `callman_runs_queued` /
`callman_runs_running` per group.

```yaml
scrape_configs:
  - job_name: callman-kpi
    scheme: https
    metrics_path: /api/public/v1/metrics/kpi
    scrape_interval: 5m          # the KPI engine refreshes every 30 min by default (KPI settings)
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/callman-token   # the cm_int_ token, kpi:read
    static_configs:
      - targets: [callman.bank.local]
```

```sh
curl -s "$CALLMAN/api/public/v1/metrics/kpi?level=tribe" -H "Authorization: Bearer $TOKEN"
```

### 8.3 SIEM — Splunk HEC

A token with the **SIEM** preset (`audit:read`, organization-wide). Run the script
every minute (cron or a systemd timer). It sends each page to the HTTP Event
Collector and saves the cursor only after Splunk accepted the page, so an outage
on either side delays events but never loses them.

```sh
#!/usr/bin/env bash
# callman-audit-to-splunk.sh — needs curl and jq.
#   CALLMAN=https://callman.bank.local  CALLMAN_TOKEN=cm_int_…
#   HEC_URL=https://splunk.bank.local:8088  HEC_TOKEN=…
set -euo pipefail
STATE=${STATE:-/var/lib/callman-audit/cursor}
mkdir -p "$(dirname "$STATE")"
CURSOR=$(cat "$STATE" 2>/dev/null || true)
while :; do
  page=$(curl -fsS -H "Authorization: Bearer $CALLMAN_TOKEN" \
    "$CALLMAN/api/public/v1/audit/events?limit=1000${CURSOR:+&cursor=$CURSOR}")
  if [ "$(jq '.data.rows | length' <<<"$page")" -gt 0 ]; then
    jq -c '.data.rows[] | {time: ((.time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)), host: "callman", source: "callman:public-api", sourcetype: "callman:audit", event: .}' <<<"$page" \
      | curl -fsS -H "Authorization: Splunk $HEC_TOKEN" --data-binary @- "$HEC_URL/services/collector/event" >/dev/null
  fi
  CURSOR=$(jq -r '.meta.nextCursor' <<<"$page")
  printf '%s' "$CURSOR" > "$STATE"
  [ "$(jq -r '.meta.hasMore' <<<"$page")" = "true" ] || break
done
```

### 8.4 SIEM — JSON Lines to a file

For a SIEM that ships log files (Splunk Universal Forwarder, Filebeat, NXLog, QRadar
WinCollect …): append the stream as JSON Lines to a file the forwarder tails. Same
schedule and guarantees as §8.3 (a page is written before its cursor is saved, so a crash can repeat a page but never skip one).

```sh
#!/usr/bin/env bash
# callman-audit-to-file.sh — needs curl.  CALLMAN=…  CALLMAN_TOKEN=cm_int_…
set -euo pipefail
OUT=${OUT:-/var/log/callman/audit.jsonl}
STATE=${STATE:-/var/lib/callman-audit/cursor-file}
mkdir -p "$(dirname "$OUT")" "$(dirname "$STATE")"
CURSOR=$(cat "$STATE" 2>/dev/null || true)
while :; do
  head=$(mktemp); body=$(mktemp)
  curl -fsS -D "$head" -o "$body" -H "Authorization: Bearer $CALLMAN_TOKEN" \
    "$CALLMAN/api/public/v1/audit/events?format=jsonl&limit=1000${CURSOR:+&cursor=$CURSOR}"
  cat "$body" >> "$OUT"
  CURSOR=$(awk 'tolower($1)=="x-next-cursor:" {print $2}' "$head" | tr -d '\r')
  more=$(awk 'tolower($1)=="x-has-more:" {print $2}' "$head" | tr -d '\r')
  rm -f "$head" "$body"
  printf '%s' "$CURSOR" > "$STATE"
  [ "$more" = "true" ] || break
done
```

### 8.5 SIEM — Filebeat httpjson (Elastic, QRadar via Logstash)

Filebeat's `httpjson` input keeps the cursor in its registry:

```yaml
filebeat.inputs:
  - type: httpjson
    id: callman-audit
    interval: 1m
    request.url: https://callman.bank.local/api/public/v1/audit/events?limit=1000
    request.transforms:
      - set:
          target: header.Authorization
          value: 'Bearer ${CALLMAN_TOKEN}'
      - set:
          target: url.params.cursor
          value: '[[.cursor.next]]'
          default: ''
    response.split:
      target: body.data.rows
    response.pagination:
      - set:
          target: url.params.cursor
          value: '[[if .last_response.body.meta.hasMore]][[.last_response.body.meta.nextCursor]][[end]]'
          fail_on_template_error: true
    cursor:
      next:
        value: '[[.last_response.body.meta.nextCursor]]'
    processors:
      - decode_json_fields: { fields: [message], target: callman }
```

The first run reads the last 24 hours; add `&from=2026-01-01T00:00:00Z` to
`request.url` once to backfill further.

### 8.6 Jira / Xray status sync

Pull what changed since the last run, then match by test key:

```sh
# first run: everything with a Jira key; keep meta.syncCursor for the next run
curl -s "$CALLMAN/api/public/v1/tests?hasTestKey=true&limit=5000" -H "Authorization: Bearer $TOKEN" | jq '{cursor: .meta.syncCursor, tests: [.data.rows[] | {testKey, lastRunStatus, lastRunAt}]}'
# later runs: only the tests changed since then
curl -s "$CALLMAN/api/public/v1/tests?hasTestKey=true&updatedSince=2026-11-09T00:00:00Z&limit=5000" -H "Authorization: Bearer $TOKEN"
```

### 8.7 BI / Excel

Every list endpoint takes `format=csv`; Power BI / Excel *From Web* with the
`Authorization` header, or a scheduled `curl … -o file.csv`:

```sh
curl -s "$CALLMAN/api/public/v1/kpi/results?periodType=quarter&format=csv" -H "Authorization: Bearer $TOKEN" -o kpi-quarters.csv
```

## 9. Network and Helm

The Public API is part of the backend: wherever `/api` reaches the backend (the
backend ingress / route, path `/`), `/api/public/v1` works — nothing to switch on
and no new environment variable, except `PUBLIC_API_PROXY_HOPS` when **two**
proxies (e.g. an F5 in front of the ingress) add to `X-Forwarded-For` (§4).
(`PUBLIC_API_BASE_URL` in [ENVIRONMENT.md](ENVIRONMENT.md) is unrelated: it is the
address the desktops use.)

To publish it on a host of its own — an integrations hostname your monitoring
network can reach while the main host stays internal — the Helm chart has an
optional ingress (or OpenShift route) that exposes **only** `/api/public`:

```yaml
publicApi:
  ingress:
    enabled: true
    className: nginx                 # "" = backend.ingress.className
    host: callman-api.bank.local
    annotations:
      nginx.ingress.kubernetes.io/whitelist-source-range: "10.20.0.0/16"   # e.g. the Grafana / SIEM network
    tls:
      - hosts: [callman-api.bank.local]
        secretName: callman-api-tls
  # OpenShift instead:
  # route: { enabled: true, host: callman-api.apps.ocp.bank.local }
```

Behind your own reverse proxy (Docker Compose), route `/api/public/` to the backend
like the rest of `/api/` and set `X-Forwarded-For` (nginx: `proxy_set_header
X-Forwarded-For $proxy_add_x_forwarded_for;` or `$remote_addr`) — the token IP
allowlist reads the entry your proxy added, and only from a private / loopback
proxy.

## 10. Security notes

- An integration token works **only** on `/api/public/v1`; every other Callman API
  refuses it (401). A user's login or personal access token does not work on the
  Public API.
- Tokens are stored as SHA-256 hashes; the secret is shown once. Callman logs never
  contain it (`cm_int_…` is masked).
- Sensitive reads (`kpi:users:read`, `audit:read`) are recorded and visible in the
  audit stream; the token's page counts every call per endpoint for 120 days.
- `details` in the audit stream never carries secrets or content: secret-named keys
  are masked, content keys (prompt, answer, body, script, values …) are dropped and
  free text is scrubbed of bearer tokens, keys and card numbers.
- Prefer one token per consuming system, the narrowest scopes and boundary, an IP
  allowlist, and the shortest expiry you can rotate on.

## 11. OpenAPI

`GET /api/public/v1/openapi.json` — OpenAPI 3.1, no token needed. Import it into
Swagger UI / Postman / an API gateway, or generate a client. Each operation names
its scope in `x-callman-scope`. It is built from the same code that serves the
routes, and a test fails the build when a route and the document disagree.

```sh
curl -s "$CALLMAN/api/public/v1/openapi.json" -o callman-public-api.json
```
