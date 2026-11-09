# Team KPIs (on-prem)

Callman computes test-automation KPIs for every tribe and squad from the tests it
holds — scenarios, UI tests and pipeline collections — and shows them in the
admin panel (**QA / KPI**) and to every user in the desktop app (**KPI**). This
page explains what is counted, how each of your current Grafana panels maps to a
Callman KPI, and where the numbers can differ.

Personal scorecards (the weighted per-person KPIs that existed before) are still
there, under **QA / KPI → Personal scorecards**.

## 1. Groups

| Your term | In Callman |
|---|---|
| Tribe | A top-level on-prem group |
| Squad | A subgroup |
| Project → squad mapping (`project_squad` in your SQL) | Not needed. Every scenario, UI test and pipeline collection already belongs to a squad (its group). |
| "Technology and Architecture Excellence" (the whole bank) | The **Organization** row |
| Tribes `Unknown`, `Archive` | **KPI settings → Rollups** |

## 2. KPI fields on a test

Every scenario, UI test and pipeline collection has four KPI fields. They are set
in the desktop app (the item's settings, **KPI** section) or in bulk in
**QA / KPI → Test inventory**. Changing them never changes the test's content,
version or approval, and every change is logged in the workspace history
(`KPI fields changed`).

| Field | Values | Default |
|---|---|---|
| Regression scope | yes / no | no (UI tests: yes when their test type is *Regression*) |
| Automation | *Automatic*, *Will be automated*, *Can't be automated*, *No need to automate* | *Automatic*: an approved test counts as automated; a test that was never approved counts as *Will be automated* |
| Test key | free text, e.g. a Jira key | empty (for traceability only) |
| Leave out of KPIs | yes / no | no |

A scenario folder can also be left out of KPIs: every scenario in it is then
excluded (your `healthcheck` projects).

By default anyone who can edit the test can change its KPI fields, plus the
approvers of its group. **KPI settings → Who may change the KPI fields of a test → Only the group's
approvers** narrows this to approvers.

## 3. Validity rule

A regression test is **valid** when all of these hold:

1. it is not left out of KPIs;
2. it counts as automated (approved, and not marked otherwise);
3. its latest decided run inside the **validity window** (default 14 days,
   **KPI settings → Validity window**) passed.

"Decided" means passed or failed. Stopped, queued and running runs never count,
and neither do Load Testing Lab runs. Desktop runs (a user's own machine) count
unless **KPI settings → Count desktop runs** is off.

Every test carries the reason it is or isn't valid: *Valid*, *Last run failed*,
*No recent run*, *Not approved yet*, *Will be automated*, *Can't / no need to
automate*, *Excluded from KPIs*, *Not in regression*. The admin panel and the
desktop list the tests that pull a squad's coverage down, with that reason.

## 4. Measures

A KPI is a formula over these measures. Inventory measures are a snapshot at the
moment of the refresh; run measures use each test's **latest** decided run inside
the period, so reruns never inflate them.

| Measure | Meaning |
|---|---|
| Tests | every test of the group that is not excluded |
| Regression tests | tests in the regression scope |
| Automated tests / Automated regression tests | tests that count as automated |
| Valid regression tests | see §3 |
| Will be automated / Regression tests to automate | the automation backlog |
| Regression tests that can't be automated | marked *Can't be automated* |
| Regression tests with no need to automate | marked *No need to automate* |
| Excluded tests | left out of KPIs (information only) |
| Executed tests / Executed regression tests | tests with at least one decided run in the period |
| Passed tests / Passed regression tests | executed tests whose latest run in the period passed |
| Failed tests | executed tests whose latest run in the period failed |
| Runs | every decided run in the period, reruns included |

## 5. Your Grafana panels in Callman

Create each one in **QA / KPI → KPI catalog → New team KPI**, starting from its template.

| Your panel | Callman template | Formula | Period |
|---|---|---|---|
| Test Automation Scenario counts (squad), Tribe Base Test Automation Scenario (tribe) | Regression automation coverage | Valid regression tests ÷ (Regression tests − can't be automated − no need to automate) | Quarter, from the last snapshot of the quarter |
| Weekly Automation Run Ratio | Automation run pass ratio | Passed tests ÷ Executed tests | Week (Monday–Sunday) |
| Weekly Automation Run Ratio — executed vs selected | Regression execution coverage | Executed regression tests ÷ Regression tests | Week |
| Will Be Automated count | Automation backlog | Will be automated (a count) | Week |
| Regression / Total Scenario | Regression share | Regression tests ÷ Tests | Quarter |
| Running tests today | **QA / KPI → Live runs** and the desktop's *Running now* | runs queued or running now, by group | Live |

Field by field:

| Your field | Callman |
|---|---|
| `tbl_test_result.level` SUCCESS / FAILURE / ERROR | run status passed / failed (stopped is not decided) |
| `ROW_NUMBER() … ORDER BY startDate DESC` per test and week | the latest decided run of each test in the period |
| `test_scenario_id` / `test_key` (test identity) | the scenario, UI test or pipeline collection itself |
| `included_in_regression_count` | Regression tests |
| `kpi_valid_for_regression_success_count` | Valid regression tests (§3) |
| `cant_automated_count_in_regression_scope` | Regression tests that can't be automated |
| `no_need_to_automate_count_in_regression_scope` | Regression tests with no need to automate |
| `total_scenario_count` | Tests |
| `automation_status = 'Will Be Automated'` | Will be automated |
| `MAX(DATE(create_date))` in the quarter (latest daily report) | the last snapshot taken in the quarter |
| `tbl_qastudio_kpi.target_min` / `target` | **QA / KPI → Targets** (§7) |
| `LIKE '%healthcheck%'` | *Leave out of KPIs* on the test or its folder |

## 6. Tribe and organization values

Each KPI says how a tribe (and the organization) is computed — its **rollup** in
the KPI catalog:

- **Pooled** — add up the numbers of every squad, then divide. This is your
  *Tribe Base Test Automation Scenario* panel.
- **Average** — the average of the squads' own values; the organization is the
  average of the tribes. This is your tribe ranking panel (and your
  "Technology and Architecture Excellence = average of the other tribes").

Your two tribe panels use different methods, so they show different values for
the same tribe. In Callman a KPI has one method, written next to its value. If
you need both, create the KPI twice with different rollups.

## 7. Targets

**QA / KPI → Targets** holds a minimum and a target per KPI, quarter and group,
in percent for percentage KPIs (0–100). A squad without its own row uses its
tribe's, then the organization default. A weekly KPI uses the target of the
quarter the week belongs to. Status:

| Status | Rule |
|---|---|
| On target | value ≥ target |
| Above minimum | minimum ≤ value < target |
| Below minimum | value < minimum |
| No target set / No data | no target row / nothing to compute |

For a "lower is better" KPI (the backlog) the comparisons are reversed.

## 8. Time

- Weeks run Monday 00:00 to Sunday 24:00 and quarters are calendar quarters, both
  in the KPI timezone (**KPI settings → Timezone**, default Asia/Baku).
- The engine refreshes every 30 minutes by default (**KPI settings → Refresh**),
  a minute or two after a KPI field changes, and on **Refresh now**. It runs in
  the admin panel (env `KPI_ENGINE_ENABLED`, see [ENVIRONMENT.md](ENVIRONMENT.md)).
- The current week and quarter are shown as *in progress*. When a week or
  quarter ends it is frozen: its runs are recounted and its inventory is the last
  snapshot taken inside it. Frozen values do not change afterwards. Personal
  scorecards of an ended quarter are frozen at the same time.
- **KPI settings → Backfill past weeks** rebuilds run-based numbers (run pass ratio,
  executed tests) for up to 26 past weeks from the run history Callman still
  keeps. Inventory numbers (coverage, backlog) only exist from the day the engine
  first ran, because Callman does not keep a history of the KPI fields.

## 9. Who sees what

| Where | What |
|---|---|
| Admin panel, **QA / KPI** | `kpi:read` (analyst and up) sees the KPIs; `kpi:manage` (admin and up) edits KPIs, targets, KPI fields and settings. A scoped admin sees only their groups, never the organization row. |
| Desktop, **KPI** | Every on-prem user sees their own squads and tribes in full, their tribe's squad ranking (values only), the organization, and their own personal scorecard — never anyone else's. Each part has a switch in **KPI settings → Desktop**. |

## 10. Grafana

Grafana reads the KPIs through the **Public API** with an organization-owned
integration token that an admin creates in **Integration → Public API** — no service
account, no personal token. [GRAFANA.md](GRAFANA.md) has the data source, the ready
dashboard (`grafana/callman-kpi.json`, with the panels of §5) and the field list;
[PUBLIC_API.md](PUBLIC_API.md) the API reference. The endpoints:

| Endpoint | What |
|---|---|
| `/api/public/v1/kpi/results` | KPI values of the organization, tribes and squads per week / quarter |
| `/api/public/v1/kpi/measures` | the raw measures behind them (§4), for your own formulas |
| `/api/public/v1/kpi/users` | the same KPIs per person, from the tests they own (*KPIs per person* scope) |
| `/api/public/v1/kpi/live` | runs queued / running now, and today's finished runs |
| `/api/public/v1/metrics/kpi` | the current values in Prometheus format |

**KPI settings → KPIs per person** (on by default) makes the engine compute the
per-person numbers; they are only ever read through the Public API.

The older `GET /api/kpi/feed` (a personal access token with `scenarios:read`, the
token owner's groups only) still works for existing dashboards but is deprecated —
move them to `/api/public/v1/kpi/results`, which has the same fields plus `level`,
`groupPath`, `tribe`, `templateKey`, paging and CSV.

## 11. Where numbers differ from your current dashboards

- **Manual test cases in Jira are not counted.** Callman counts only the tests it
  holds. A test that lives only in Jira is in neither the numerator nor the
  denominator, so coverage is usually higher than in your Jira-based reports.
  Record such tests in Callman (for example a placeholder scenario marked *Will
  be automated*) to bring them into the scope.
- Inventory history starts on the first engine run (§8).
- Values are percentages with one decimal everywhere; the targets use the same
  scale.

## 12. To confirm with you

These start with the defaults below and are all settings:

| Question | Default |
|---|---|
| How old may the last passing run of a valid regression test be? | 14 days |
| Do runs from a user's own desktop count? | yes |
| Tribe coverage: pooled or average of squads? | pooled |
| "Will Be Automated": backlog size (snapshot) or tests added that week? | backlog size |
