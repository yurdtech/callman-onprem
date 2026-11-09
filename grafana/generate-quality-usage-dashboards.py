# Generates two more ready Grafana dashboards for the Callman Public API (Infinity data source):
#   grafana/callman-quality.json — test runs, failing and flaky tests, the test inventory (runs:read, tests:read)
#   grafana/callman-usage.json   — licence, active people, desktop versions, feature adoption (usage:read)
# Run: python3 grafana/generate-quality-usage-dashboards.py grafana
import json, os, sys

DS = {"type": "yesoreyeram-infinity-datasource", "uid": "${datasource}"}
TRIBE = ("groupId", "${tribe:csv}")
RANGE = [("from", "${__from}"), ("to", "${__to}")]


def q(ref, url, params, columns, root="data.rows"):
    return {
        "refId": ref, "datasource": DS, "type": "json", "source": "url", "parser": "backend",
        "format": "table", "url": url,
        "url_options": {"method": "GET", "data": "", "params": [{"key": k, "value": v} for k, v in params]},
        "root_selector": root,
        "columns": [{"selector": s, "text": txt, "type": typ} for s, txt, typ in columns],
        "filters": [], "computed_columns": [],
    }


def order(*names):
    """Infinity returns columns alphabetically; keep the declared order."""
    return {"id": "organize", "options": {"indexByName": {n: i for i, n in enumerate(names)}}}


class Board:
    def __init__(self):
        self.panels, self.pid = [], 0

    def panel(self, kind, title, grid, targets, description="", **extra):
        self.pid += 1
        p = {"id": self.pid, "type": kind, "title": title, "description": description, "gridPos": grid,
             "datasource": DS, "targets": targets}
        p.update(extra)
        self.panels.append(p)

    def row(self, title, y):
        self.pid += 1
        self.panels.append({"id": self.pid, "type": "row", "title": title, "collapsed": False,
                            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []})


pct = {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "orange", "value": 70}, {"color": "green", "value": 90}]}
series = lambda unit=None, **custom: {"defaults": {**({"unit": unit} if unit else {}), "custom": {"drawStyle": "line", "lineWidth": 2, "pointSize": 5, "showPoints": "auto", "spanNulls": True, **custom}}, "overrides": []}
legend = {"legend": {"displayMode": "table", "placement": "right", "calcs": ["lastNotNull", "mean"]}, "tooltip": {"mode": "multi"}}
by_series = lambda field: [{"id": "partitionByValues", "options": {"fields": [field], "keepFields": False}}]
stat_opts = lambda calc, fields="": {"reduceOptions": {"values": False, "calcs": [calc], "fields": fields}, "colorMode": "value", "graphMode": "none", "textMode": "value"}

# ── Quality: runs + inventory ───────────────────────────────────────────────
qb = Board()
qb.row("Runs", 0)
qb.panel("stat", "Runs in range", {"h": 4, "w": 6, "x": 0, "y": 1},
         [q("A", "/api/public/v1/runs/stats", [("interval", "day"), ("by", "org"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("runs", "Runs", "number")])],
         "Scenario, UI test and pipeline runs started in the dashboard's time range (load tests and desktop runs not counted).",
         options=stat_opts("sum", "/^Runs$/"), fieldConfig={"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []})
qb.panel("stat", "Pass rate — latest week", {"h": 4, "w": 6, "x": 6, "y": 1},
         [q("A", "/api/public/v1/runs/stats", [("interval", "week"), ("by", "org"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("passRate", "Pass rate", "number")])],
         "passed ÷ (passed + failed) of the most recent week in range.",
         options=stat_opts("lastNotNull", "/^Pass rate$/"), fieldConfig={"defaults": {"unit": "percent", "decimals": 1, "thresholds": pct, "color": {"mode": "thresholds"}}, "overrides": []})
qb.panel("stat", "Failed runs in range", {"h": 4, "w": 6, "x": 12, "y": 1},
         [q("A", "/api/public/v1/runs/stats", [("interval", "day"), ("by", "org"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("failed", "Failed", "number")])],
         "", options=stat_opts("sum", "/^Failed$/"), fieldConfig={"defaults": {"color": {"mode": "fixed", "fixedColor": "red"}}, "overrides": []})
qb.panel("stat", "p95 run duration — latest week", {"h": 4, "w": 6, "x": 18, "y": 1},
         [q("A", "/api/public/v1/runs/stats", [("interval", "week"), ("by", "org"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("p95DurationMs", "p95", "number")])],
         "", options=stat_opts("lastNotNull", "/^p95$/"), fieldConfig={"defaults": {"unit": "ms", "color": {"mode": "fixed", "fixedColor": "purple"}}, "overrides": []})
qb.panel("timeseries", "Runs per day by kind", {"h": 8, "w": 12, "x": 0, "y": 5},
         [q("A", "/api/public/v1/runs/stats", [("interval", "day"), ("by", "kind"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("kind", "Kind", "string"), ("runs", "Runs", "number")])],
         "Scenario / UI test / pipeline runs per day.", transformations=by_series("Kind"),
         fieldConfig={**series(drawStyle="bars", fillOpacity=60, stacking={"mode": "normal"}), "defaults": {**series(drawStyle="bars", fillOpacity=60, stacking={"mode": "normal"})["defaults"], "min": 0}}, options=legend)
qb.panel("timeseries", "Pass rate per week by tribe", {"h": 8, "w": 12, "x": 12, "y": 5},
         [q("A", "/api/public/v1/runs/stats", [("interval", "week"), ("by", "tribe"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("groupPath", "Tribe", "string"), ("passRate", "Pass rate", "number")])],
         "passed ÷ (passed + failed) per tribe and week.", transformations=by_series("Tribe"),
         fieldConfig={**series("percent"), "defaults": {**series("percent")["defaults"], "min": 0, "max": 100, "decimals": 1}}, options=legend)
qb.row("Failing and flaky", 13)
qb.panel("table", "Most failing tests", {"h": 9, "w": 12, "x": 0, "y": 14},
         [q("A", "/api/public/v1/runs/failures", [("top", "20"), TRIBE, *RANGE],
            [("item", "Test", "string"), ("groupPath", "Group", "string"), ("failed", "Failed", "number"), ("runs", "Runs", "number"), ("failRate", "Fail rate %", "number"), ("failedNode", "Failing step", "string"), ("lastError", "Last error", "string"), ("lastFailedAt", "Last failed", "timestamp")])],
         "The tests that failed most in the range, with the last error (credentials scrubbed).",
         transformations=[order("Test", "Group", "Failed", "Runs", "Fail rate %", "Failing step", "Last error", "Last failed")],
         fieldConfig={"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "Fail rate %"}, "properties": [{"id": "decimals", "value": 1}, {"id": "custom.cellOptions", "value": {"type": "color-background"}}, {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 10}, {"color": "red", "value": 30}]}}]}]})
qb.panel("table", "Flaky tests", {"h": 9, "w": 12, "x": 12, "y": 14},
         [q("A", "/api/public/v1/runs/flaky", [("minFlips", "2"), ("top", "20"), TRIBE, *RANGE],
            [("item", "Test", "string"), ("groupPath", "Group", "string"), ("flips", "Flips", "number"), ("runs", "Runs", "number"), ("flakinessScore", "Flakiness", "number"), ("lastStatus", "Last", "string"), ("lastRunAt", "Last run", "timestamp")])],
         "Tests whose result keeps flipping pass ↔ fail — at least two flips in the range.",
         transformations=[order("Test", "Group", "Flips", "Runs", "Flakiness", "Last", "Last run")])
qb.panel("table", "Latest failed runs", {"h": 9, "w": 24, "x": 0, "y": 23},
         [q("A", "/api/public/v1/runs", [("status", "failed"), ("limit", "50"), TRIBE, *RANGE],
            [("time", "Started", "timestamp"), ("kind", "Kind", "string"), ("item", "Test", "string"), ("groupPath", "Group", "string"), ("triggerType", "Trigger", "string"), ("userName", "Started by", "string"), ("failedNode", "Failing step", "string"), ("ciBranch", "CI branch", "string"), ("durationMs", "Duration", "number")])],
         "The 50 newest failed runs in the range.",
         transformations=[order("Started", "Kind", "Test", "Group", "Trigger", "Started by", "Failing step", "CI branch", "Duration")],
         fieldConfig={"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "Duration"}, "properties": [{"id": "unit", "value": "ms"}]}]})
qb.row("Test inventory", 32)
qb.panel("barchart", "Tests per group", {"h": 9, "w": 12, "x": 0, "y": 33},
         [q("A", "/api/public/v1/tests", [("limit", "5000"), TRIBE], [("groupPath", "Group", "string"), ("id", "id", "string")])],
         "Scenarios, UI tests and pipeline collections per tribe / squad.",
         transformations=[{"id": "groupBy", "options": {"fields": {"Group": {"aggregations": [], "operation": "groupby"}, "id": {"aggregations": ["count"], "operation": "aggregate"}}}},
                          {"id": "organize", "options": {"renameByName": {"id (count)": "Tests"}}}],
         options={"xField": "Group", "orientation": "horizontal", "showValue": "always", "legend": {"showLegend": False}},
         fieldConfig={"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}, "min": 0}, "overrides": []})
qb.panel("table", "Tests without a Jira key", {"h": 9, "w": 12, "x": 12, "y": 33},
         [q("A", "/api/public/v1/tests", [("hasTestKey", "false"), ("limit", "500"), TRIBE],
            [("name", "Test", "string"), ("kind", "Kind", "string"), ("groupPath", "Group", "string"), ("ownerName", "Owner", "string"), ("state", "State", "string"), ("lastRunStatus", "Last run", "string")])],
         "Tests not linked to a Jira test key yet — what a Jira / Xray sync cannot match.",
         transformations=[order("Test", "Kind", "Group", "Owner", "State", "Last run")])

# ── Usage: licence, active people, versions, adoption ───────────────────────
ub = Board()
ub.row("Licence", 0)
lic = lambda field, title: q("A", "/api/public/v1/usage/licence", [], [(field, title, "number" if field != "health" else "string")], root="data")
ub.panel("stat", "Seats used", {"h": 4, "w": 6, "x": 0, "y": 1}, [lic("seatsUsed", "Seats used")],
         "Callman accounts — one account is one seat. Needs an organization-wide token.",
         options=stat_opts("lastNotNull"), fieldConfig={"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []})
ub.panel("gauge", "Seats used %", {"h": 4, "w": 6, "x": 6, "y": 1}, [lic("seatsUsedPct", "Seats used %")], "",
         options={"reduceOptions": {"values": False, "calcs": ["lastNotNull"], "fields": ""}},
         fieldConfig={"defaults": {"unit": "percent", "min": 0, "max": 100, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 85}, {"color": "red", "value": 100}]}}, "overrides": []})
ub.panel("stat", "Licence days left", {"h": 4, "w": 6, "x": 12, "y": 1}, [lic("daysLeft", "Days left")], "",
         options=stat_opts("lastNotNull"), fieldConfig={"defaults": {"thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "orange", "value": 15}, {"color": "green", "value": 30}]}, "color": {"mode": "thresholds"}}, "overrides": []})
ub.panel("stat", "Licence health", {"h": 4, "w": 6, "x": 18, "y": 1}, [lic("health", "Health")],
         "valid / expiring / over_seats / expired / unlicensed.",
         options={**stat_opts("lastNotNull", "/^Health$/"), "textMode": "value"},
         fieldConfig={"defaults": {"mappings": [{"type": "value", "options": {"valid": {"color": "green", "index": 0}, "expiring": {"color": "orange", "index": 1}, "over_seats": {"color": "red", "index": 2}, "expired": {"color": "red", "index": 3}, "unlicensed": {"color": "red", "index": 4}}}], "color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []})
ub.row("Active people", 5)
ub.panel("timeseries", "Active people per day", {"h": 8, "w": 12, "x": 0, "y": 6},
         [q("A", "/api/public/v1/usage/active-users", [("interval", "day"), ("by", "org"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("activeUsers", "Active", "number"), ("totalUsers", "Accounts", "number")])],
         "Sent a request, started a run by hand or changed something that day (scheduled / CI runs do not count). Range up to 366 days.",
         fieldConfig=series(), options=legend)
ub.panel("table", "DAU / WAU / MAU per tribe", {"h": 8, "w": 12, "x": 12, "y": 6},
         [q("A", "/api/public/v1/usage/active-users", [("shape", "summary"), ("by", "tribe"), TRIBE],
            [("groupPath", "Tribe", "string"), ("dau", "DAU", "number"), ("wau", "WAU", "number"), ("mau", "MAU", "number"), ("totalUsers", "People", "number"), ("activePct", "Active %", "number"), ("stickinessPct", "Stickiness %", "number")])],
         "Active in the last 1 / 7 / 30 days; stickiness = DAU ÷ MAU.",
         transformations=[order("Tribe", "DAU", "WAU", "MAU", "People", "Active %", "Stickiness %")],
         fieldConfig={"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "Active %"}, "properties": [{"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "basic"}}, {"id": "max", "value": 100}, {"id": "min", "value": 0}]}]})
ub.panel("timeseries", "Weekly active people by tribe", {"h": 8, "w": 24, "x": 0, "y": 14},
         [q("A", "/api/public/v1/usage/active-users", [("interval", "week"), ("by", "tribe"), TRIBE, *RANGE], [("time", "Time", "timestamp"), ("groupPath", "Tribe", "string"), ("activeUsers", "Active", "number")])],
         "", transformations=by_series("Tribe"), fieldConfig=series(), options=legend)
ub.row("Desktop and adoption", 22)
ub.panel("barchart", "Desktop versions in use", {"h": 9, "w": 8, "x": 0, "y": 23},
         [q("A", "/api/public/v1/usage/desktop-versions", [("seenWithinDays", "30"), TRIBE], [("version", "Version", "string"), ("users", "People", "number")])],
         "People per desktop version, desktops seen in the last 30 days.",
         options={"xField": "Version", "orientation": "horizontal", "showValue": "always", "legend": {"showLegend": False}},
         fieldConfig={"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}, "min": 0}, "overrides": []})
ub.panel("table", "Feature adoption per squad (range)", {"h": 9, "w": 16, "x": 8, "y": 23},
         [q("A", "/api/public/v1/usage/adoption", [("by", "squad"), TRIBE, *RANGE],
            [("groupPath", "Group", "string"), ("members", "People", "number"), ("activeUsers", "Active", "number"), ("requestsSent", "Requests sent", "number"), ("scenarios", "Scenarios", "number"), ("uiTests", "UI tests", "number"), ("pipelineCollections", "Pipelines", "number"), ("scenarioRuns", "Scenario runs", "number"), ("uiTestRuns", "UI test runs", "number"), ("pipelineRuns", "Pipeline runs", "number"), ("mocks", "Mocks", "number"), ("approvals", "Approvals", "number")])],
         "What each squad has and did in the range. Totals (scenarios, UI tests, mocks) are what exists now.",
         transformations=[order("Group", "People", "Active", "Requests sent", "Scenarios", "UI tests", "Pipelines", "Scenario runs", "UI test runs", "Pipeline runs", "Mocks", "Approvals")])


def var_tribe():
    return {
        "name": "tribe", "label": "Tribe", "type": "query", "datasource": DS,
        "query": {"queryType": "infinity", "refId": "variable", "infinityQuery": q("variable", "/api/public/v1/org/groups", [("level", "tribe")], [("__text", "__text", "string"), ("__value", "__value", "string")])},
        "refresh": 1, "multi": True, "includeAll": True, "allValue": "$__all",
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "sort": 1,
    }


def dashboard(uid, title, description, tags, board, time_from):
    return {
        "__inputs": [{"name": "DS_CALLMAN", "label": "Callman Public API", "type": "datasource", "pluginId": "yesoreyeram-infinity-datasource", "pluginName": "Infinity"}],
        "__requires": [{"type": "datasource", "id": "yesoreyeram-infinity-datasource", "name": "Infinity", "version": "2.0.0"}],
        "uid": uid, "title": title, "description": description, "tags": tags,
        "timezone": "browser", "editable": True, "schemaVersion": 39, "version": 1, "refresh": "5m",
        "time": {"from": time_from, "to": "now"},
        "templating": {"list": [
            {"name": "datasource", "label": "Data source", "type": "datasource", "query": "yesoreyeram-infinity-datasource", "current": {}, "hide": 0, "refresh": 1},
            var_tribe(),
        ]},
        "panels": board.panels,
    }


out = sys.argv[1] if len(sys.argv) > 1 else "grafana"
for name, d in [
    ("callman-quality.json", dashboard("callman-quality", "Callman — test runs and inventory",
                                       "Runs, pass rate, failing and flaky tests, the test inventory — Callman Public API (runs:read, tests:read). See callman-onprem docs/GRAFANA.md.",
                                       ["callman", "qa", "runs"], qb, "now-30d")),
    ("callman-usage.json", dashboard("callman-usage", "Callman — usage and licence",
                                     "Licence seats and expiry, active people, desktop versions, feature adoption — Callman Public API (usage:read, organization-wide token for the licence). See callman-onprem docs/GRAFANA.md.",
                                     ["callman", "usage"], ub, "now-90d")),
]:
    with open(os.path.join(out, name), "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("wrote", os.path.join(out, name), len(d["panels"]), "panels")
