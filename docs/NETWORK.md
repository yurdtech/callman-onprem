# Network requirements

What has to reach what, and which optional features go to the internet. Use it for
the firewall request and for the security review. Everything not listed can stay
closed.

## Inbound (to the Callman host)

| Port | Service | Who connects | Notes |
| --- | --- | --- | --- |
| `8080` (`CALLMAN_PORT`) | Backend API | Desktops, the `callme` CLI, `callman-mcp`, CI agents | Put it behind your TLS proxy (443). Plain HTTP is published on all interfaces by default; bind or firewall it. |
| `5100` (`CALLMAN_ADMIN_PORT`) | Admin panel | Admin workstations | Restrict to an admin segment or VPN. The Swagger page (`/admin/docs`) is off in production unless `ADMIN_API_DOCS_ENABLED=true`. |
| `8081` (`CALLMAN_STORAGE_PORT`) | Storage gateway | Desktops | Only with the `storage` profile. |
| `8082` (`CALLMAN_MOCK_PORT`) | Mock server (`/mock/*`) | Applications under test, CI, load generators — anything that calls a user's mock API | Public by design: mocks are called anonymously. Put it behind your proxy as its own domain or as `/mock/` on the API host ([MOCK-SERVER.md](MOCK-SERVER.md)). |

Keep these paths **off the user-facing proxy**: `/ops/*` and `/metrics` (no
authentication; `/ops/license` returns the licensee's name and seat counts) and
`/api/internal/*` (service to service). Let monitoring reach them on the internal
address. Example (nginx):

```nginx
location ~ ^/(ops|metrics|api/internal)(/|$) { return 404; }   # user-facing server block
```

Behind a proxy, raise the body-size and timeout limits for desktop installer uploads
and set `PUBLIC_API_BASE_URL` to the public address ([DESKTOP-APP.md](DESKTOP-APP.md)).

## Outbound from the Callman host

| Destination | Why | Required? |
| --- | --- | --- |
| Your MongoDB, Redis (if external) | Data, queue | Yes |
| Your LDAP / AD on `636` | Sign-in | If LDAP is used |
| The systems under test, Kafka brokers, Redis | Scenario and schedule runs execute **on the host** | Yes: this is the job. There is no allow-list in the product, restrict at the firewall |
| The databases your tests query (Oracle, PostgreSQL, MySQL, SQL Server, MongoDB) | Server runs, schedules and UI-test database steps connect from the worker and the UI-test runner; the server side of every connection test from the backend | When teams test databases. Ports and every test message: [DATABASE-CONNECTIONS.md](DATABASE-CONNECTIONS.md) |
| Your object storage (S3 / MinIO / FileNet) | Large files | Only with the `storage` profile |
| `ghcr.io` (or your registry) | Pulling images | Install and upgrade only; none with an air-gap bundle ([INSTALL.md](INSTALL.md)) |
| `api.telegram.org` | Error forwarding | Only if `TELEGRAM_ENABLED` is on; leave it empty |
| The AI provider set in **AI Settings** | AI assistant / AI node | Only if configured; switch the `ai*` flags off otherwise |
| Slack webhook | Notification connections | Only if someone creates one |
| `download.oracle.com` | Oracle Instant Client for Oracle 11g | Only when an admin clicks **Download from Oracle**; uploading the package instead needs no internet |

## Outbound from a user's workstation (desktop app)

| Destination | Why |
| --- | --- |
| Your Callman backend | API, request history, crash reports, the hourly update check |
| The systems under test | Requests run on the workstation |
| The databases users test | Requests' database steps, the scenario builder's **Run**, UI tests run in the app, schema import and the desktop side of connection tests connect from the workstation ([DATABASE-CONNECTIONS.md](DATABASE-CONNECTIONS.md)) |
| `download.oracle.com` | The Oracle client for Oracle 11g, once per machine when a user installs it — only if your server has no package for that platform under **Database drivers** |
| Model providers (`api.anthropic.com`, `api.openai.com`, `generativelanguage.googleapis.com`) | **AI Testing** only, with the user's own key; screenshots and page structure go with each step |
| `github.com`, `api.github.com`, `pypi.org`, the Playwright CDN | **AI Testing** and **Android UI testing**, once per machine: the AI engine, browsers, the Callman Agent APK and the Android UI-test driver |
| `api.figma.com` | Figma import / visual compare, only with a Figma token |

The first-use downloads in the `github.com` / `pypi.org` row come from the internet: a
packaged desktop has no setting that points them at an internal mirror. Two can be pre-staged on a workstation to skip
their download — the Callman Agent APK at `~/.callman/portal/callman-agent.apk` and
the Android UI-test driver at `~/.callman/modules/callmanui.jar`. To keep AI Testing
off, switch the **AI Testing** feature flag off in the admin panel (Feature Flags); it
hides the studio in desktop 2.0.14 and later.

The desktop sends each run's resolved request and response to your backend as
request history. Switch the `history` feature flag off if that is not acceptable, and
keep production secrets in environment values and managed connections.

## From CI agents and engineers' laptops

| Tool | Reaches |
| --- | --- |
| `callme` | The Callman API address you set (`CALLME_API_URL`) and, for `callme run` / `perf run`, the systems under test — for `callme run`, also the databases its DB steps query |
| `callman-mcp` | The Callman API address (`CALLMAN_API_URL`); tool output, including response-body previews, goes to the language model of the AI tool in use |

`callme` falls back to the public cloud address when `CALLME_API_URL` is missing (it
says so on stderr): set it. `callman-mcp` 0.10.0 does not start without `CALLMAN_API_URL`.
The CLI has no proxy or CA flags; use Node.js's (`NODE_EXTRA_CA_CERTS=/path/ca.pem`
for a private CA).

## Air-gapped installs

Compose: `scripts/compose-airgap-bundle.sh` on an internet-connected host builds one
tarball (images plus deployment files); `scripts/compose-airgap-load.sh` loads it on
the isolated host. Helm: `scripts/helm-airgap-bundle.sh` / `helm-airgap-load.sh`
([HELM-INSTALL.md](HELM-INSTALL.md)). The `callme-cli` and `callman-mcp` packages can
be carried the same way with `npm pack`.
