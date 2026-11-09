# Generates grafana/callman-kpi.json — the ready Grafana dashboard for the Callman
# Public API (Infinity data source). Run: python3 grafana/generate-kpi-dashboard.py grafana/callman-kpi.json
import json, sys

DS = {"type": "yesoreyeram-infinity-datasource", "uid": "${datasource}"}

def q(ref, url, params, columns, root="data.rows", computed=None, filter_expr=None):
    t = {
        "refId": ref, "datasource": DS, "type": "json", "source": "url", "parser": "backend",
        "format": "table", "url": url,
        "url_options": {"method": "GET", "data": "", "params": [{"key": k, "value": v} for k, v in params]},
        "root_selector": root,
        "columns": [{"selector": s, "text": txt, "type": typ} for s, txt, typ in columns],
        "filters": [], "computed_columns": computed or [],
    }
    if filter_expr:
        t["filterExpression"] = filter_expr
    return t

panels = []

def order(*names):
    """Infinity returns columns alphabetically; keep the declared order."""
    return {"id": "organize", "options": {"indexByName": {n: i for i, n in enumerate(names)}}}
pid = [0]
def panel(kind, title, grid, targets, description="", **extra):
    pid[0] += 1
    p = {"id": pid[0], "type": kind, "title": title, "description": description, "gridPos": grid,
         "datasource": DS, "targets": targets}
    p.update(extra)
    panels.append(p)

def row(title, y):
    pid[0] += 1
    panels.append({"id": pid[0], "type": "row", "title": title, "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})

pct_thresholds = {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "orange", "value": 60}, {"color": "green", "value": 80}]}
GROUP = ("groupId", "${squad:csv}")

# ── Freshness + organization ──────────────────────────────────────────────
row("Organization", 0)
panel("stat", "KPI data refreshed", {"h": 4, "w": 6, "x": 0, "y": 1},
      [q("A", "/api/public/v1/kpi/status", [], [("lastRefreshAt", "Last refresh", "timestamp"), ("stale", "Stale", "boolean")], root="data")],
      "When the Callman KPI engine last refreshed. Stale = older than twice the refresh interval.",
      options={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": "/Last refresh/"}, "colorMode": "none", "graphMode": "none", "textMode": "value"},
      fieldConfig={"defaults": {"unit": "dateTimeFromNow"}, "overrides": []})
panel("stat", "Organization — this week", {"h": 4, "w": 18, "x": 6, "y": 1},
      [q("A", "/api/public/v1/kpi/results", [("periodType", "week"), ("level", "org"), ("frozen", "false")],
         [("kpi", "KPI", "string"), ("value", "Value", "number")])],
      "Every team KPI for the whole organization, current week. Needs an organization-wide token.",
      options={"reduceOptions": {"values": True, "calcs": [], "fields": ""}, "colorMode": "none", "graphMode": "none", "textMode": "value_and_name", "orientation": "vertical", "justifyMode": "center"},
      fieldConfig={"defaults": {"decimals": 1, "displayName": "${__data.fields.KPI}"}, "overrides": []})

# ── Bank panel 1: regression automation coverage (squad + tribe) ──────────
row("Regression automation coverage (quarter)", 5)
cov_cols = [("groupPath", "Group", "string"), ("value", "Coverage %", "number"), ("targetMin", "Minimum", "number"), ("target", "Target", "number"), ("status", "Status", "string")]
table_cov = {"defaults": {"custom": {"align": "auto"}}, "overrides": [
    {"matcher": {"id": "byName", "options": "Coverage %"}, "properties": [{"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "lcd"}}, {"id": "max", "value": 100}, {"id": "min", "value": 0}, {"id": "thresholds", "value": pct_thresholds}, {"id": "decimals", "value": 1}]}]}
panel("table", "Squads — Test Automation Scenario counts", {"h": 8, "w": 12, "x": 0, "y": 6},
      [q("A", "/api/public/v1/kpi/results", [("periodType", "quarter"), ("kpiId", "regression_automation_coverage"), ("level", "squad"), ("frozen", "false"), GROUP], cov_cols)],
      "Valid regression tests ÷ (regression − can't automate − no need to automate), this quarter, per squad.",
      transformations=[order("Group", "Coverage %", "Minimum", "Target", "Status")], fieldConfig=table_cov)
panel("table", "Tribes — Tribe Base Test Automation Scenario", {"h": 8, "w": 12, "x": 12, "y": 6},
      [q("A", "/api/public/v1/kpi/results", [("periodType", "quarter"), ("kpiId", "regression_automation_coverage"), ("level", "tribe"), ("frozen", "false"), ("groupId", "${tribe:csv}")], cov_cols)],
      "The same KPI per tribe (pooled over its squads), this quarter.",
      transformations=[order("Group", "Coverage %", "Minimum", "Target", "Status")], fieldConfig=table_cov)

# ── Bank panels 2 + 3: weekly run ratios ─────────────────────────────────
row("Weekly runs", 14)
ts_cols = [("time", "Time", "timestamp"), ("groupPath", "Group", "string"), ("value", "Value", "number")]
ts_common = dict(transformations=[{"id": "partitionByValues", "options": {"fields": ["Group"], "keepFields": False}}],
                 fieldConfig={"defaults": {"unit": "percent", "min": 0, "max": 100, "decimals": 1, "custom": {"drawStyle": "line", "lineWidth": 2, "pointSize": 6, "showPoints": "always", "spanNulls": True}}, "overrides": []},
                 options={"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "mean"]}, "tooltip": {"mode": "multi"}})
panel("timeseries", "Weekly Automation Run Ratio — passed ÷ executed", {"h": 9, "w": 12, "x": 0, "y": 15},
      [q("A", "/api/public/v1/kpi/results", [("periodType", "week"), ("kpiId", "weekly_run_pass_ratio"), ("level", "squad"), GROUP, ("from", "${__from}"), ("to", "${__to}")], ts_cols)],
      "Latest decided run of each test in the week: passed ÷ executed, per squad.", **ts_common)
panel("timeseries", "Weekly Automation Run Ratio — executed vs selected", {"h": 9, "w": 12, "x": 12, "y": 15},
      [q("A", "/api/public/v1/kpi/results", [("periodType", "week"), ("kpiId", "regression_execution_coverage"), ("level", "squad"), GROUP, ("from", "${__from}"), ("to", "${__to}")], ts_cols)],
      "Executed regression tests ÷ regression tests, per squad and week.", **ts_common)

# ── Bank panels 4 + 5: backlog and regression share ─────────────────────
row("Scope", 24)
panel("barchart", "Will Be Automated count (this week)", {"h": 8, "w": 12, "x": 0, "y": 25},
      [q("A", "/api/public/v1/kpi/results", [("periodType", "week"), ("kpiId", "automation_backlog"), ("level", "squad"), ("frozen", "false"), GROUP],
         [("groupPath", "Group", "string"), ("value", "Will be automated", "number")])],
      "Tests marked “Will be automated” or not approved yet — lower is better.",
      options={"xField": "Group", "orientation": "horizontal", "showValue": "always", "legend": {"showLegend": False}},
      fieldConfig={"defaults": {"color": {"mode": "fixed", "fixedColor": "orange"}, "min": 0, "custom": {"axisSoftMax": 5}}, "overrides": []})
panel("table", "Regression / Total Scenario (this quarter)", {"h": 8, "w": 12, "x": 12, "y": 25},
      [q("A", "/api/public/v1/kpi/measures", [("periodType", "quarter"), ("level", "squad"), ("measure", "items_regression,items_total"), GROUP],
         [("groupPath", "group", "string"), ("periodKey", "quarter", "string"), ("items_regression", "regression", "number"), ("items_total", "tests", "number")],
         # Infinity evaluates computed columns on the column names, so they stay plain
         # here and the organize transformation gives the headings.
         computed=[{"selector": "regression / tests * 100", "text": "share", "type": "number"}])],
      "Built from the raw measures: regression tests ÷ all tests. Works without creating a KPI for it.",
      transformations=[{"id": "organize", "options": {"indexByName": {"group": 0, "quarter": 1, "regression": 2, "tests": 3, "share": 4}, "renameByName": {"group": "Group", "quarter": "Quarter", "regression": "Regression tests", "tests": "Tests", "share": "Regression share %"}}}],
      fieldConfig={"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "share"}, "properties": [{"id": "decimals", "value": 1}, {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}}, {"id": "max", "value": 100}, {"id": "min", "value": 0}, {"id": "color", "value": {"mode": "fixed", "fixedColor": "blue"}}]}]})

# ── Running today + people ───────────────────────────────────────────────
row("Today", 33)
panel("table", "Running tests today", {"h": 8, "w": 12, "x": 0, "y": 34},
      [q("A", "/api/public/v1/kpi/live", [("shape", "summary"), GROUP],
         [("groupPath", "Group", "string"), ("queued", "Queued", "number"), ("running", "Running", "number"), ("finishedToday", "Finished today", "number"), ("passRateToday", "Pass rate today %", "number")])],
      "Runs queued and running now, and the runs that finished today (KPI timezone).",
      transformations=[order("Group", "Queued", "Running", "Finished today", "Pass rate today %")],
      fieldConfig={"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "Pass rate today %"}, "properties": [{"id": "thresholds", "value": pct_thresholds}, {"id": "custom.cellOptions", "value": {"type": "color-text"}}]}]})
panel("table", "People — this week", {"h": 8, "w": 12, "x": 12, "y": 34},
      [q("A", "/api/public/v1/kpi/users", [("periodType", "week"), ("frozen", "false"), GROUP],
         [("userName", "Person", "string"), ("groups", "Groups", "string"), ("kpi", "KPI", "string"), ("value", "Value", "number")])],
      "Each person's KPIs from the tests they own. Needs a token with the “KPIs per person” scope; otherwise this panel shows an error.",
      transformations=[{"id": "groupingToMatrix", "options": {"columnField": "KPI", "rowField": "Person", "valueField": "Value"}}],
      fieldConfig={"defaults": {"decimals": 1}, "overrides": []})

def var_groups(name, label, params, depends=None):
    return {
        "name": name, "label": label, "type": "query", "datasource": DS,
        "query": {"queryType": "infinity", "refId": "variable", "infinityQuery": q("variable", "/api/public/v1/org/groups", params, [("__text", "__text", "string"), ("__value", "__value", "string")])},
        "refresh": 1, "multi": True, "includeAll": True, "allValue": "$__all",
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "sort": 1,
    }

dashboard = {
    "__inputs": [{"name": "DS_CALLMAN", "label": "Callman Public API", "type": "datasource", "pluginId": "yesoreyeram-infinity-datasource", "pluginName": "Infinity"}],
    "__requires": [{"type": "datasource", "id": "yesoreyeram-infinity-datasource", "name": "Infinity", "version": "2.0.0"}],
    "uid": "callman-kpi",
    "title": "Callman — QA KPIs",
    "description": "Team KPIs from the Callman Public API: the bank's five Grafana panels, running tests today, people. See callman-onprem docs/GRAFANA.md.",
    "tags": ["callman", "kpi", "qa"],
    "timezone": "browser",
    "editable": True,
    "schemaVersion": 39,
    "version": 1,
    "refresh": "5m",
    "time": {"from": "now-90d", "to": "now"},
    "templating": {"list": [
        {"name": "datasource", "label": "Data source", "type": "datasource", "query": "yesoreyeram-infinity-datasource", "current": {}, "hide": 0, "refresh": 1},
        var_groups("tribe", "Tribe", [("level", "tribe")]),
        var_groups("squad", "Squad", [("level", "squad"), ("parentId", "${tribe:csv}")]),
    ]},
    "panels": panels,
}
json.dump(dashboard, open(sys.argv[1], "w"), indent=2)
print(f"{len([p for p in panels if p['type'] != 'row'])} panels")
