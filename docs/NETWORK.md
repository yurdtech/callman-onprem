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
| The systems under test, Kafka brokers, Redis | Scenario and schedule runs execute **on the host** | Yes: this is the job. There is no allow-list in the product, restrict at the firewall. Newer backends refuse the cloud instance-metadata service (`169.254.169.254` & co., `OUTBOUND_DENY_CIDRS` in [ENVIRONMENT.md](ENVIRONMENT.md)) for HTTP calls; the UI runner's **browser** is not covered — on a cloud VM or managed Kubernetes, also deny `169.254.169.254` egress for the `callman-ui-runner` container / pod (firewall or NetworkPolicy) |
| The databases your tests query (Oracle, PostgreSQL, MySQL, SQL Server, MongoDB) | Server runs, schedules and UI-test database steps connect from the worker and the UI-test runner; the server side of every connection test from the backend | When teams test databases. Ports and every test message: [DATABASE-CONNECTIONS.md](DATABASE-CONNECTIONS.md) |
| Your object storage (S3 / MinIO / FileNet) | Large files | Only with the `storage` profile |
| `ghcr.io` (or your registry) | Pulling images | Install and upgrade only; none with an air-gap bundle ([INSTALL.md](INSTALL.md)) |
| `api.telegram.org` | Error forwarding | Only if `TELEGRAM_ENABLED` is on; leave it empty |
| The AI providers on the server: the one set in **AI Settings**, your AI connections (**Managed connections**) and the providers of users' personal keys — `api.openai.com`, `api.anthropic.com`, `generativelanguage.googleapis.com`, `api.deepseek.com`, or an OpenAI-compatible server someone names | AI assistants, the AI node, and AI Testing steps that run on one of these (a screenshot and the page structure go with each step) | Only if configured; turn sources off in the AI policy ([AI-POLICY.md](AI-POLICY.md)) or switch the `ai*` flags off |
| Slack webhook | Notification connections | Only if someone creates one |
| An OpenAPI URL in **AI Knowledge** | The backend and worker fetch the definition (and re-fetch it daily if set so) | Only if an admin adds a source by URL; uploading the file instead needs no network ([AI-KNOWLEDGE.md](AI-KNOWLEDGE.md)) |
| `download.oracle.com` | Oracle Instant Client for Oracle 11g | Only when an admin clicks **Download from Oracle**; uploading the package instead needs no internet |

## Outbound from a user's workstation (desktop app)

| Destination | Why |
| --- | --- |
| Your Callman backend | API, request history, crash reports, the hourly update check |
| The systems under test | Requests run on the workstation |
| The databases users test | Requests' database steps, the scenario builder's **Run**, UI tests run in the app, schema import and the desktop side of connection tests connect from the workstation ([DATABASE-CONNECTIONS.md](DATABASE-CONNECTIONS.md)) |
| `download.oracle.com` | The Oracle client for Oracle 11g, once per machine when a user installs it — only if your server has no package for that platform under **Database drivers** |
| Model providers, when a user picks an AI connection that runs on their computer: a subscription they signed in to in the app — Claude (`claude.ai`, `console.anthropic.com`, `api.anthropic.com`), ChatGPT (`auth.openai.com`, `chatgpt.com`), Gemini (`accounts.google.com`, `oauth2.googleapis.com`, `cloudcode-pa.googleapis.com`) — or an AI CLI's own hosts | AI features on that connection; for **AI Testing** a screenshot and the page structure go with each step. Connections on the Callman server (company key, AI connections, personal keys) go through the backend instead (row above). A model the user runs (Ollama) is reached at the address they set, `localhost:11434` by default |
| `github.com`, `api.github.com`, the Playwright CDN | Once per machine: the browser for web **AI Testing** and web UI tests (Playwright CDN), and the Android UI-test driver (GitHub) |
| `api.figma.com` | Figma import / visual compare, only with a Figma token |

AI Testing downloads nothing else: it runs in the desktop app's own code (no
Python runtime, no agent app). On an Android device it installs only a small
Callman keyboard to type with, which ships inside the desktop app. The Android
UI-test driver can be pre-staged on a workstation at
`~/.callman/modules/callmanui.jar` to skip its download.

**TLS inspection.** Behind a proxy that re-signs HTTPS with a company certificate,
the desktop's AI requests that fail the certificate check are retried through the
operating system's network stack, which verifies against the OS certificate store
and uses the system proxy (desktop 2.0.14 and later) — so a company root installed
there by IT is trusted with nothing else to configure. A certificate failure is
reported as one. To keep AI Testing
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

Both need the address set: `callme` (since 1.11.0) stops with a usage error without
`--api-url` / `CALLME_API_URL`, and `callman-mcp` (since 0.10.0) does not start without
`CALLMAN_API_URL` (older versions fell back to the public cloud address).
The CLI has no proxy or CA flags; use Node.js's (`NODE_EXTRA_CA_CERTS=/path/ca.pem`
for a private CA).

## Air-gapped installs

Compose: `scripts/compose-airgap-bundle.sh` on an internet-connected host builds one
tarball (images plus deployment files); `scripts/compose-airgap-load.sh` loads it on
the isolated host. Helm: `scripts/helm-airgap-bundle.sh` / `helm-airgap-load.sh`
([HELM-INSTALL.md](HELM-INSTALL.md)). The `callme-cli` and `callman-mcp` packages can
be carried the same way with `npm pack`.
