# Pilot quick start: from a running server to a first scheduled run

You have installed Callman ([INSTALL.md](INSTALL.md)) and activated the license. This
page is the shortest path to a team that can run its first scenario, put it on a
schedule and call it from a pipeline. About one working hour for two people.

The order matters: **a scenario can only be scheduled or called from CI after a
second person has approved it**, and nobody can approve their own work. Doing the
people and groups first saves a confusing afternoon.

## What you need before you start

- Two Callman users (the author and an approver), plus an admin-panel account.
- The address your users reach this server on (for example
  `https://callman.bank.local`) and a **desktop installer built for that address**.
  The address is baked into the installer at build time; a different hostname means a
  new build ([DESKTOP-APP.md](DESKTOP-APP.md)).
- Network paths: see [NETWORK.md](NETWORK.md).

## 1. Create the group and the people

In the **admin panel** (port `5100`, see [INSTALL.md](INSTALL.md) step 8):

1. **On-Prem → Groups**: create a top-level group for the pilot team.
2. Make sure both users exist. With local sign-up closed they are created from your
   directory on first login (LDAP, [AUTH_SETUP.md](AUTH_SETUP.md)); self-registration
   is **on by default** otherwise.
3. Open the group and **add both users as members**.
4. On the second user tick the **approver** flag. A scenario is reviewed by an
   approver of its own group (or of the top-level group above it). **Without one the
   author's *Submit for review* button is disabled**, schedules skip, and CI reports
   the scenario as skipped (`callme scenario run` exits `1`).

Group scenarios and flows are visible to members of the group in any workspace.

## 2. Install the desktop app and sign in

1. Install the installer you were delivered. It already points at your server.
2. Sign in with the pilot user. Pick or create a workspace; the group you belong to
   appears in the group picker.
3. Note: there is no second server to configure and no telemetry switch to find; the
   desktop talks to this backend only, plus the optional features listed in
   [NETWORK.md](NETWORK.md).

## 3. Build and approve a first scenario

1. **Author:** create a collection with one request, then a scenario (Request node →
   Assertion node). Run it from the builder.
2. **Author:** *Submit for review*.
3. **Approver:** open the bell → **Review**, open the item, read the diff, **Approve**.

The approved snapshot is what schedules and pipelines run. Editing anything material
afterwards sends the scenario back to *draft*; the approved snapshot keeps running
until the next approval.

## 4. Schedule it

Open the scenario's schedules and create one. The form defaults to your computer's
time zone (the API default is UTC); check it. The overlap policy defaults to *skip*: a
due run is skipped while the previous run of the same schedule is still going (counted on
the schedule as `skippedOverlapCount` / `lastSkippedAt`, no report is created). In
practice the next tick is planned when a run finishes, so a run that outlasts its
interval just delays the next firing to the next tick after it ends; ticks inside the
run are not queued. Failure notifications need a **Slack notification connection** chosen on
the schedule; without one a failed scheduled run is visible only in the scenario's run
history and the schedule monitor.

## 5. Call it from a pipeline

1. In the desktop: **Workspace settings → CI Tokens → New CI Token** with *Trigger*.
   Give it an expiry (30, 90 or 365 days; avoid *Never*). Keep the value in the
   pipeline's secret store.
2. In the pipeline (Node 18+ on the agent):

   ```bash
   npm install -g callme-cli
   export CALLME_API_URL=https://callman.bank.local   # required on-prem
   export CALLME_TOKEN=<the CI token>
   callme scenario run --scenario-id <id> --fail-threshold low
   ```

   `--fail-threshold low` makes every failed scenario fail the job (the default,
   `critical`, only fails for critical-priority scenarios). Exit `0` = passed,
   `1` = failed or skipped (nothing was tested), `2` = could not run (token refused,
   server unreachable, timeout). A folder of scenarios runs with `--folder-id`.
3. To read results back (a KPI feed): `GET /api/scenario-reports?from=…&to=…&status=…`
   with the same token.

## 6. Things worth knowing on day one

- **The admin panel is read-only by default** (`CALLMAN_DB_WRITE_ENABLED=false`):
  revoking a token, ending a session or disabling a schedule from the panel answers
  *write disabled* until you turn it on deliberately (docs: On-prem guide §5.11).
- **Feature flags**: every feature, including AI tools (MCP) and AI Testing, is on
  until an admin switches it off under *Feature Flags*.
- **CLI and MCP environment names differ**: `CALLME_API_URL` for `callme`,
  `CALLMAN_API_URL` for `callman-mcp`. Both are required: `callme` 1.11.0 and
  `callman-mcp` 0.10.0 stop and say what to set instead of falling back to the
  public cloud address.
- **Databases are reached from two sides**: the desktop's own queries from each
  workstation, server runs and schedules from the worker and UI-test runner — open
  the database ports for both ([DATABASE-CONNECTIONS.md](DATABASE-CONNECTIONS.md)).
- **One queue for everyone**: server-side runs are served in order of arrival
  ([SCALING.md](SCALING.md)).
- **Limits**: a scenario run stops after 5 minutes, a node after 60 s, an HTTP request
  after 30 s; a data-driven run executes at most 500 rows
  ([ENVIRONMENT.md](ENVIRONMENT.md)).
