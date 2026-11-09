# Grafana — Callman KPI dashboards

Callman's Public API serves the team KPIs as plain JSON (or CSV), so Grafana reads
them with the **Infinity** data source — no exporter, no database access. This page
connects Grafana to Callman, imports the ready dashboard and maps the bank's current
KPI panels to it. The full API reference is [PUBLIC_API.md](PUBLIC_API.md).

## 1. Create a token

In the admin panel: **Integration → Public API → New token**.

| Step | Choose |
|---|---|
| Name | `Grafana — QA KPI` |
| Access | start from **Grafana — KPI** (scopes `org:read`, `kpi:read`). Tick **KPIs per person** only if the dashboard shows people. |
| Data | **The whole organization** (super admin), or the tribes / squads this Grafana may show. |
| Limits | 180 days; the Grafana server's IP address; 120 requests per minute is enough for ~3 dashboards refreshing every minute. |

Copy the token (`cm_int_…`) — it is shown once. Before it expires, **Rotate** it: the
old token keeps working for 24 hours while you paste the new one into Grafana.

## 2. Add the data source

Install the plugin once: `grafana-cli plugins install yesoreyeram-infinity-datasource <version>`
(or `GF_INSTALL_PLUGINS="yesoreyeram-infinity-datasource <version>"` in a container). Pick
the version your Grafana supports — a newer Infinity on an older Grafana fails to load
(the browser console shows `react/jsx-runtime` 404 and every panel says *Datasource …
was not found*):

| Grafana | Infinity |
|---|---|
| 10.4.8 – 11.5 | 3.7.1 (tested with Grafana 11.2.2) |
| 11.6 and newer | 3.8+ / 4.x |

**Connections → Data sources → Add → Infinity**:

| Field | Value |
|---|---|
| Name | `Callman Public API` |
| URL (base URL) | `https://<your-callman-url>` — the address the desktop app uses |
| Authentication | **Bearer token** → paste the token |
| Allowed hosts | `https://<your-callman-url>` |

**Save & test**, then check a query: `GET /api/public/v1/me` answers the token's name,
scopes and groups.

Provisioned instead (`/etc/grafana/provisioning/datasources/callman.yaml`):

```yaml
apiVersion: 1
datasources:
  - name: Callman Public API
    uid: callman-public-api
    type: yesoreyeram-infinity-datasource
    url: https://callman.example.bank
    jsonData:
      auth_method: bearerToken
      allowedHosts: ["https://callman.example.bank"]
    secureJsonData:
      bearerToken: ${CALLMAN_TOKEN}   # from the environment, never committed
```

## 3. Import the dashboard

**Dashboards → New → Import → Upload** [`grafana/callman-kpi.json`](../grafana/callman-kpi.json)
and pick the data source. Or provision it:

```yaml
apiVersion: 1
providers:
  - name: callman
    folder: Callman
    type: file
    options:
      path: /var/lib/grafana/dashboards/callman
```

The dashboard selects KPIs by their **template key** (`regression_automation_coverage`,
`weekly_run_pass_ratio`, `regression_execution_coverage`, `automation_backlog`), so it
works on any Callman as long as the KPIs were created from those templates in
**QA / KPI → KPI catalog**. A KPI's `kpiId` may be its id, its template key or its name.

Infinity returns a query's columns in alphabetical order; the dashboard's tables put
them back in order with an *Organize fields* transformation — do the same in your own
tables.

Variables: **Tribe** (from `/org/groups?level=tribe`) and **Squad** (from
`/org/groups?level=squad&parentId=${tribe:csv}`); every panel passes
`groupId=${squad:csv}`. "All" sends `$__all`, which the API reads as no filter.

## 4. The bank's panels in the dashboard

| Your panel (KPI.md §5) | Dashboard panel | Endpoint |
|---|---|---|
| Test Automation Scenario counts (squad) | Squads — Test Automation Scenario counts | `/kpi/results?periodType=quarter&kpiId=regression_automation_coverage&level=squad&frozen=false` |
| Tribe Base Test Automation Scenario | Tribes — Tribe Base Test Automation Scenario | same, `level=tribe` |
| Weekly Automation Run Ratio | Weekly Automation Run Ratio — passed ÷ executed | `/kpi/results?periodType=week&kpiId=weekly_run_pass_ratio&from=${__from}&to=${__to}` |
| Weekly Automation Run Ratio — executed vs selected | Weekly Automation Run Ratio — executed vs selected | `kpiId=regression_execution_coverage` |
| Will Be Automated count | Will Be Automated count (this week) | `kpiId=automation_backlog&frozen=false` |
| Regression / Total Scenario | Regression / Total Scenario (this quarter) | `/kpi/measures?periodType=quarter&measure=items_regression,items_total` + a computed column — no KPI needed |
| Running tests today | Running tests today | `/kpi/live?shape=summary` |

Also on the dashboard: the organization's KPIs this week (an organization-wide token
only), the KPI engine's last refresh (`/kpi/status`), and **People — this week**
(`/kpi/users`, needs the *KPIs per person* scope).

## 5. Build your own panel

Infinity query: **Type** JSON, **Parser** Backend, **Source** URL, **Format** Table.

| Setting | Value |
|---|---|
| URL | `/api/public/v1/kpi/results` |
| Query params | `periodType=week`, `kpiId=weekly_run_pass_ratio`, `level=squad`, `groupId=${squad:csv}`, `from=${__from}`, `to=${__to}` |
| Rows / root | `data.rows` |
| Columns | `time` (Timestamp), `groupPath` (String), `value` (Number) |
| Transformation | *Partition by values* on `groupPath` — one line per squad |

Useful fields on every KPI row: `time`, `periodKey`, `kpi`, `templateKey`, `level`
(`org` / `tribe` / `squad`), `group`, `groupPath`, `tribe`, `value`, `numerator`,
`denominator`, `target`, `targetMin`, `status`, `partial`, `frozen`.

- Target lines: add the `target` and `targetMin` columns to the same query.
- Your own formula: query `/kpi/measures` (`shape=wide`) and add a computed column,
  e.g. `passed_items / executed_items * 100`.
- Several squads in one table: `/kpi/results?…&level=squad` without `from`/`to`
  and `frozen=false` gives this week's (or quarter's) value per squad.

## 6. Prometheus instead

If alerts live in Prometheus, scrape the same numbers:

```yaml
scrape_configs:
  - job_name: callman-kpi
    metrics_path: /api/public/v1/metrics/kpi
    scheme: https
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/callman-token
    static_configs:
      - targets: ['callman.example.bank']
```

Series: `callman_kpi_value`, `callman_kpi_target`, `callman_kpi_target_min`,
`callman_kpi_numerator`, `callman_kpi_denominator`, `callman_kpi_status{status=…}`,
`callman_kpi_last_refresh_timestamp_seconds`, `callman_runs_queued`,
`callman_runs_running`. People are never exported to Prometheus.

## 7. When a panel is empty or red

| Grafana shows | Cause |
|---|---|
| 401 `INT_TOKEN_INVALID` | Token expired, revoked or mistyped — see the token's status in the admin panel. |
| 403 `INT_SCOPE_MISSING` | The token lacks the scope (People panel → *KPIs per person*). |
| 403 `INT_IP_FORBIDDEN` | The Grafana server's address is not in the token's allowed IPs. |
| 404 `INT_GROUP_NOT_FOUND` | A squad outside the token's groups is selected. |
| 429 `INT_RATE_LIMITED` | Too many panels / too short a refresh for the token's limit — raise it on the token. |
| No data, no error | The KPI was not created from its template, KPIs per person is off, or the engine has not run (`/kpi/status` → `stale`). |

The admin panel's token page shows every call of the last 30 days with its last error.
