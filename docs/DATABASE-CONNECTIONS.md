# Database connections

What has to reach your test databases, from where, and what a failed connection test
means. Use it for the firewall request and when a test works on one side and fails on
the other. Users' own settings (engines, connection strings, TLS options) are covered in
the API-testing guide, §8.1.

Callman connects to **Oracle**, **PostgreSQL**, **MySQL**, **SQL Server** and
**MongoDB** (Redis and Kafka are connection types of their own). Connections are made by
users in the desktop app (Sidebar → Connections) or by an admin under **Managed
Connections** in the admin panel; managed ones are shared with groups and stay read-only
for users.

## Where a connection is opened

A query connects from the machine that runs it. A connection that works from a laptop
can fail from the cluster, and the other way round.

| What runs the query | Connects from |
| --- | --- |
| A request's database steps and DB assertions, `pm.db.query` — on Send and in the collection runner | The user's workstation (desktop app) |
| The scenario builder's **Run**, and running a single node | The user's workstation |
| UI tests run in the desktop app (their database steps) | The user's workstation |
| Schema import for database diagrams | The user's workstation |
| Scenario **Run on server**, schedules, `callme scenario run`, scenario runs started by AI tools | The **worker** |
| UI tests run on the server runner and UI-test schedules (their database steps) | The **UI-test runner** |
| **Test connection** in the desktop, **Test** in Managed Connections | The **backend** (the server side), and for the desktop test also the workstation — both results are shown |
| `callme run` with a collection from the server | The CI agent running `callme` |
| `run_request` / `run_collection` from AI tools | The machine running `callman-mcp` |

## What must be reachable

Open the database ports **from both sides** for every database your teams test:

- **From the workstations** to the database host and port — for everything users run in
  the desktop app.
- **From the backend, worker and UI-test runner** containers or pods to the same host and
  port — for server runs, schedules, UI-test schedules and the server side of every
  connection test.
- **From CI agents** that run `callme run` against databases.

| Engine | Port to open | Notes |
| --- | --- | --- |
| Oracle | The listener, `1521` by default; TCPS often `2484` | Users choose **Connect by** service name or SID. |
| PostgreSQL | `5432` | `pg_hba.conf` must allow the source addresses — the workstations' and the cluster's egress addresses are different. |
| MySQL | `3306` | |
| SQL Server | The instance's TCP port, `1433` for a default instance | A **named instance** is looked up through the SQL Server Browser on **UDP 1434**. If UDP 1434 stays closed, users enter the instance's fixed port and leave the instance name empty. |
| MongoDB | `27017`, every member of a replica set | `mongodb+srv://` needs DNS SRV lookups from the machine that connects. |

Use host names that resolve on both sides, or IP addresses. `localhost` in a connection
means the workstation on the desktop and the container itself on the server.

On Kubernetes, the chart's own `networkPolicy` restricts only who may reach the bundled
MongoDB and Redis; the app pods keep open egress. If your cluster restricts egress, allow
the backend, worker and ui-runner pods to the database ports. Callman has no allow-list
of its own for test targets — restrict them at your firewall.

## Oracle 11g: the Oracle client

Oracle **12.1 and newer** need nothing. **Oracle 11g (11.2)** needs the Oracle **Instant
Client** where the connection is opened; Oracle 10g and older are not supported.

- **Servers.** Install it once in the admin panel under **On-Prem → Database drivers**:
  **Download from Oracle** (the server needs internet access) or upload the *Instant
  Client Basic Light* zip (Linux x86-64 or ARM64, version 19), then **Apply now**. The
  backend, workers and UI-test runner restart one by one (running jobs finish first) and
  the page shows each process in *thick* mode. Details and optional settings:
  [ENVIRONMENT.md › Connecting to old Oracle databases](ENVIRONMENT.md#connecting-to-old-oracle-databases).
- **Desktops.** The first time a test, query, scenario step or schema import meets an 11g
  database, the app offers **Install Oracle client** (about 40 MB, once per computer;
  later under **Settings → Database drivers**). It downloads the package from your
  Callman server when you uploaded the Windows and macOS (Intel) packages under Database
  drivers, otherwise from `download.oracle.com`. There is no client for Apple Silicon
  Macs or Windows on ARM; users there run such scenarios on the server, or use the Intel
  build of Callman on an Apple Silicon Mac.
- **CI agents.** Install the Instant Client on the agent and set `ORACLE_CLIENT_LIB_DIR`
  to its directory for `callme run`.

## TLS and company certificates

Per connection, users can turn on **Encrypt connection (TLS)** (SQL Server, MySQL,
MongoDB, Oracle over TCPS), **Trust server certificate** (SQL Server, MySQL, MongoDB —
accepts a self-signed or company-issued certificate without checking it), or choose a
PostgreSQL TLS mode (`require`, `verify-ca`, `verify-full`) with a CA certificate and an
optional client certificate.

To have certificates **verified** against your company CA instead of trusted blindly:

- **On the server:** put the CA bundle in `certs/` (Compose) or in `certs.files` /
  `certs.existingConfigMap` (Helm) — it is mounted at `/certs` in every container — and set
  `NODE_EXTRA_CA_CERTS=/certs/<bundle>.pem`. Compose: in `.env`. Helm: in
  `backend.extraEnv`, `worker.extraEnv` and `uiRunner.extraEnv`. One bundle can hold
  several CAs; restart the services after changing it.
- **On workstations:** the desktop's database connections do not take the CA from the OS
  trust store. Users paste the CA certificate into a PostgreSQL connection (`verify-ca` /
  `verify-full`), tick **Trust server certificate**, or the app is started with the
  `NODE_EXTRA_CA_CERTS` environment variable pointing at the CA bundle.
- **CI agents:** `NODE_EXTRA_CA_CERTS` for `callme` as well.

## When the test fails

**Test connection** shows one row for the Callman server and one for the workstation. The
connection counts as usable when either side reaches it; the failed row says which runs
will break — a failed *server* row breaks server runs and schedules, a failed *desktop*
row breaks what users run in the app. Each failed row leads with what the error means and
what to change, and keeps the driver's message underneath. Managed Connections → **Test**
shows the same reading for the server side.

| The test says | What it means | What to change |
| --- | --- | --- |
| **This Oracle version needs the Oracle Instant Client** (`NJS-138`, `DPI-1047`) | Oracle 11g, and no Oracle client is installed — or it cannot be loaded — where the query runs | Server: **Database drivers** → install, **Apply now**. Desktop: **Install Oracle client**. CI: `ORACLE_CLIENT_LIB_DIR` |
| **Oracle does not know this service name** (`ORA-12514`) | The listener answers, but has no service with this name | Check the service name, or switch **Connect by** to SID |
| **Oracle does not know this SID** (`ORA-12505`) | The listener answers, but has no instance with this SID | Check the SID, or switch to service name |
| **No Oracle listener at this address** (`ORA-12541`) | Nothing answers as an Oracle listener on this host and port | Check the host and the port (often 1521) |
| **Wrong user name or password** (`ORA-01017`) | Oracle rejected the credentials | Check them — passwords are case-sensitive from 11g on |
| **SQL Server instance not found** | The named instance could not be looked up | Start the SQL Server Browser and open UDP 1434, or use the instance's port and leave the instance name empty |
| **Wrong user name or password** (`ELOGIN`, `ER_ACCESS_DENIED_ERROR`, `28P01`, *Login failed for user*, *Authentication failed*) | The database rejected the credentials | Check them. MongoDB: set the **Auth database** when the user is defined in another database (often `admin`). SQL Server Windows account: a connection string with `User Id=DOMAIN\user` |
| **Database not found** (`ER_BAD_DB_ERROR`, `3D000`, *Cannot open database*) | The server answers and the login works, but the database does not exist or the user cannot open it | Check the database name |
| **PostgreSQL refused this client** (*no pg_hba.conf entry*) | No access rule for this address, user and database | If the rule requires SSL, turn on TLS; otherwise the DBA allows the address the query comes from — the workstation or the cluster |
| **The server does not accept encrypted connections** | TLS is on, the server does not offer it | Turn **Encrypt connection** off, or enable TLS on the database |
| **The server's certificate is not trusted** (`SELF_SIGNED_CERT_IN_CHAIN`, `UNABLE_TO_VERIFY_LEAF_SIGNATURE`, `CERT_HAS_EXPIRED`, `ERR_TLS_CERT_ALTNAME_INVALID`, …) | The link is encrypted, but the certificate does not verify on that side | Add the CA ([above](#tls-and-company-certificates)), or tick **Trust server certificate** (SQL Server, MySQL, MongoDB) |
| **Host name not found** (`ENOTFOUND`, `EAI_AGAIN`) | The name does not resolve on that side | Fix DNS on that side, or use the IP address |
| **Connection refused** (`ECONNREFUSED`) | Nothing accepts connections on this host and port from that side | Check the host and the port, and that the database listens for remote connections |
| **The server closed the connection** (`ECONNRESET`, *socket hang up*) | Often an encryption mismatch; a firewall that resets connections looks the same | Turn **Encrypt connection** on if the server requires it, off if it does not support it; check the firewall |
| **No answer from the database (timeout)** (`ETIMEDOUT`, `ORA-12170`, `ORA-12535`, *Server selection timed out*) | A firewall or network rule drops traffic from that side to the database port | Open the port from that side — workstations or the cluster |
| **The database network is unreachable** (`EHOSTUNREACH`, `ENETUNREACH`) | No route from that side to the address | Check VPN, routing and firewall rules |

When the cause is none of these, the row shows the driver's message as it is. Network
failures from the server side also carry the host and port the server tried, and a Redis
test reports the real socket error, for example *Connection refused (10.0.0.5:6379)*.

To check reachability from the server side by hand (the images have Node.js, not
`nc`):

```bash
# Compose — the worker; use ui-runner or backend for those services
docker compose exec -T worker node -e "const s=require('net').connect(1521,'db.example.com');s.setTimeout(5000,()=>{console.log('no answer (timeout)');process.exit(1)});s.on('connect',()=>{console.log('reachable');process.exit(0)});s.on('error',e=>{console.log(e.code);process.exit(1)})"
# Kubernetes
kubectl -n callman exec deploy/<release>-worker -- node -e "const s=require('net').connect(1521,'db.example.com');s.setTimeout(5000,()=>{console.log('no answer (timeout)');process.exit(1)});s.on('connect',()=>{console.log('reachable');process.exit(0)});s.on('error',e=>{console.log(e.code);process.exit(1)})"
```

`reachable` means the port answers from the cluster; `ECONNREFUSED`, `ENOTFOUND` or
`no answer (timeout)` match the rows above.
