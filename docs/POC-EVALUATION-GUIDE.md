# Evaluating Callman in a field PoC: what to run, what to capture, what to expect

For teams that score each capability only after running it themselves. For every area:
how to exercise it, the evidence worth keeping, and the limits we know about — so a
"Partial" is written down with its caveat, not discovered later. Setup first:
[PILOT-QUICKSTART.md](PILOT-QUICKSTART.md); network and egress: [NETWORK.md](NETWORK.md).

Versions this guide describes: Callman on-prem 1.0.6 — backend, admin panel and UI-test runner
1.0.6, desktop 2.0.14, `callme-cli` 1.13.1, `callman-mcp` 0.12.1. Older
builds differ where noted.

## Admin panel (users, groups, roles, tokens, workspaces)
- **Run:** create a group, add users, flag an approver; log into the panel as `analyst`, `admin`
  and `super_admin` (three roles) and as an admin **scoped to one group** (Admin Users → Group access).
  Create a CI token (desktop: Workspace settings → CI Tokens) and a personal token (Settings → AI tools)
  with only `collections:read`.
- **Capture:** a denied action as an API response, not a hidden button. Examples:
  `POST /api/collections` with the read-only personal token → `403 PAT_SCOPE_MISSING` with
  `details.required`; a CI token on a non-pipeline route → `403 PAT_ROUTE_FORBIDDEN`; an `analyst`
  calling a panel write → `403 INSUFFICIENT_PERMISSION`.
- **Know:** the panel is read-only over Callman data by default (`CALLMAN_DB_WRITE_ENABLED=false`): revoking a
  token or ending a session answers *write disabled* until you enable it. A CI token acts with its creator's
  access, not only inside one workspace. The panel has no MFA/SSO. Revocation takes effect within ~30 s.

## Collections and requests
- **Run:** HTTP methods GET…OPTIONS; auth none / bearer / basic / API key / OAuth 2.0 (client credentials,
  password, refresh token); raw (JSON, XML, text), form-data (with files), urlencoded bodies; environments
  and variables; import an existing collection (Postman, OpenAPI/Swagger, Insomnia, Bruno, cURL, `.http`).
- **Capture:** the collection exported as JSON; the **import report** shown after the import (what did not
  come across).
- **Know:** no OAuth 2.0 authorization-code/PKCE, digest, NTLM/Kerberos or AWS SigV4; no GraphQL editor (a
  GraphQL body is imported as a JSON body) and no binary body mode.

## Assertions and contracts
- **Run:** one **request** with a DB assertion, a Redis assertion, a contract rule and a JSON Schema check in
  a post-response script (`pm.response.to.have.jsonSchema(...)`). **Kafka event matching is a scenario node**,
  not a request tab: build one scenario (Request → Database → Redis → Kafka → Assertion) and run it.
- **Capture:** the run report of that scenario (all four checks in one report) and the request's results in
  the Test results tab. The same request through `callme run` gives the same DB/Redis verdict (CLI
  1.9.1 and later).
- **Know:** a single request cannot carry a Kafka check. Contracts are path rules (type, range, enum, format,
  …); a full JSON Schema is a script call or the scenario request node's Schema tab.

## Scenarios
- **Run:** graph editor with the node types (Request, Database, Redis, Kafka, WebSocket, AI, Notification,
  Condition, Assertion, Wait, Poll, For each, End, Script, Set variables, Aggregator, Sub-scenario, Scenario
  reference, Temporal); a reusable sub-scenario group; a data-driven run from the Data tab; a node with
  retry/continue policy; export the scenario (`callman.scenario`).
- **Capture:** the saved and exported flow; the report of the data-driven run.
- **Know:** a server run executes at most 500 dataset rows (`SCENARIO_DATASET_MAX_ROWS`), sequentially; the
  report and `callme scenario run` say how many ran. Reuse by scenario reference is a pinned snapshot, not a
  live link.

## Schedules
- **Run:** approve a scenario (a second person), create a schedule, set your time zone, leave it to fire; start
  a long run so the next firing overlaps.
- **Capture:** the run history of the schedule; the schedule's `skippedOverlapCount` / `lastSkippedAt`.
- **Know:** an unapproved scenario is skipped. A run that outlasts the schedule interval delays the next firing
  (the next tick is planned when the run ends; ticks inside the run are not queued — tested with a
  1-minute cron and a 100-second run). A tick that does arrive during an active run is skipped (default) and
  counted, no report is created. A run due while the worker is restarting is not caught up. Failure notifications go
  through a Slack notification connection only.

## CLI and CI/CD
- **Run:** `callme run` (collection) and `callme scenario run` (server-side) in a real pipeline; a deliberate
  failure; `--fail-threshold`; `--folder-id` (one folder of a collection, or a scenario folder).
- **Capture:** pipeline definition, console output, exit codes. Exit `0` passed · `1` failed, or skipped
  (nothing tested) · `2` could not run (token refused, server unreachable, timeout, empty run).
- **Know:** the default `--fail-threshold critical` fails the job only for critical-priority scenarios; use
  `--fail-threshold low` to fail on any red scenario. An empty collection exits `2` (`--min-requests 0` allows
  it). `CALLME_API_URL` (or `--api-url`) is required — the CLI stops without it. `callme run` runs a collection depth-first in the
  desktop runner's order, and a request that got no response says why on its status line
  (`--verbose` adds the code and the causes).

## Reporting and the report API
- **Run:** `callme run … --report json|html`; `callme scenario run … --report json`; read runs back with
  `GET /api/scenario-reports?from=&to=&status=&priority=&triggerType=&scenarioId=&page=&limit=` (CI token with
  `pipeline:read`, or a personal token).
- **Capture:** a report file; a raw API response.
- **Know:** `callme run` reports carry a `run` block (run id, timing, CLI version, environment, CI job and
  commit); scenario JSON reports carry a `cli` block. Scenario reports are kept until you set
  `SCENARIO_REPORT_RETENTION_DAYS`. Collection runs from the CLI are not uploaded to the server; scenario runs
  are. No duration percentiles per scenario; averages only.

## AI Testing (web, Android, iOS)
- **Run:** the same plain-English task twice; Android on an emulator, iOS on a simulator (Mac with Xcode),
  synthetic data only — once on a server connection (company key or a personal key) and once on a connection on
  the computer (a subscription sign-in or a CLI) if you allow both. Then **Save as UI test** on a passed
  Android/iOS run.
- **Capture:** the two runs' duration and step count (History shows both, plus a Repeatability card
  for scenarios run more than once); the exported UI test; the AI policy row for AI Testing.
- **Know:** runs are not deterministic. Web AI runs cannot be saved as a replayable UI test. Each step sends the
  test text and the screen's element list — and a screenshot when the step needs one — to the AI connection you
  picked: through your Callman server for the company key, an AI connection or a personal key; from the
  workstation for a subscription, a CLI or a local model (see UI testing docs §19.15 and
  [AI-POLICY.md](AI-POLICY.md)). Only models that can read screenshots are offered. AI Testing runs on Callman's
  own agent: nothing is downloaded for it except the browser for web runs; on Android it installs only a Callman
  keyboard to type with — still use test devices. An admin can hide AI Testing with the AI Testing feature flag
  and choose its AI sources in the AI policy.

## Migration of existing test assets
- **Run:** import one real suite (Postman, Insomnia, Bruno, OpenAPI) and read the import report; run it.
- **Capture:** the result either way, including the report.
- **Know:** SoapUI, Karate, HAR and WSDL are not importable. OAuth 1, digest, AWS and NTLM auth, binary
  bodies and Insomnia/Bruno scripts are reported as lost.

## Performance and load behaviour
- **Server side:** start several runs at once (schedules, *Run on server*, CI). One queue serves everyone in
  arrival order; per worker 50 jobs in parallel (`BULLMQ_WORKER_CONCURRENCY`), a run stops after 5 min. No
  per-user fairness. See [SCALING.md](SCALING.md).
- **Target side:** `callme perf run` (or the desktop's Load test) generates load against your API with a
  closed or open model and pass criteria; that measures your service, not Callman's queue.

## Security and access model
- **Run:** a least-privilege token against a forbidden action (see Admin panel); watch the network during a
  run (desktop, CLI, a server run) against [NETWORK.md](NETWORK.md).
- **Know:** desktop and CLI requests originate from the machine running them; schedules, CI-triggered runs and
  *Run on server* originate from the Callman host. Request history is uploaded with common secrets masked
  (Settings → Keep secrets out of request history); matching is by name.

## MCP server and IDE integration
- **Run:** a read-only personal token in an AI tool; `callman-mcp doctor`; ask for `whoami`.
- **Capture:** the tool list (a read-only token sees only the tools it can use), a session transcript, the
  token's permission list.
- **Know:** 120 tools (a token sees only those it can use); tool output, including response-body previews,
  goes to the language model of the AI tool. `CALLMAN_API_URL` is required — `callman-mcp` does not start
  without it (since 0.10.0).

## Database connections
- **Run:** a connection per engine you use (Oracle, PostgreSQL, MySQL, SQL Server, MongoDB) with **Test
  connection**; a request with a DB assertion run from the desktop, and a scenario with a DB node run on the
  server.
- **Capture:** the test result (one row for the server, one for the desktop) and, for a failure, the reading
  it shows.
- **Know:** the desktop and the server connect from different machines — open the database ports from the
  workstations and from the cluster ([DATABASE-CONNECTIONS.md](DATABASE-CONNECTIONS.md)). Oracle 11g needs
  the Oracle client: admin panel → Database drivers for the server, one click in the desktop.

## Diagrams and connections
- **Run:** create a diagram (by hand, from Mermaid/BPMN, or from a database schema); export PNG/SVG/PDF/JSON/Mermaid.
- **Know:** diagrams are not generated from, or kept in sync with, a collection; only a database-schema diagram
  has a manual *Refresh schema*. Connections are managed in the Connections menu and travel in scenario
  exports without secrets.

## KPI continuity
- **Run:** map your current run events to Callman's report output with the fields above.
- **Available per scenario run:** run id, scenario id/name/version, status, start/end, duration, priority,
  trigger type and token name, environment, node and test counts, failed node. **Missing:** git commit and
  pipeline id in server reports (the CLI's own JSON has them), duration percentiles, per-assertion detail in the
  list feed (it is in the full report).
