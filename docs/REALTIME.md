# Live updates — how desktops hear about changes

Since release **1.0.6** the desktop app no longer asks the backend "anything
new?" every few seconds. It keeps one long-lived HTTP request open —
`GET /api/realtime/stream`, a [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
stream — and the backend tells it when something changed: a notification, a
review request, a finished run, work for the desktop's AI-tools relay.

What it changes for you:

- **Far fewer requests.** An idle desktop used to make ~14 requests a minute
  (more with AI-tool relays on); with live updates it makes about 2. With
  1 000 users open all day that is the difference between ~240 and ~40
  requests per second on the backend.
- **No new service, image, port or secret.** It runs inside the backend you
  already have and uses the Redis you already have (a Redis Stream,
  `callman:rt:events`, capped at ~20 000 small entries — a few MB).
- **Nothing breaks without it.** If the stream cannot be used (an old desktop,
  a proxy that buffers it, `REALTIME_ENABLED=false`), desktops simply poll the
  way they did before 1.0.6.

---

## Upgrading to 1.0.6

**Docker Compose:** the usual `git pull`, `docker compose pull`,
`docker compose up -d`. Nothing to add to `.env`.

**Helm:** the usual `helm upgrade`. New value `backend.realtimeEnabled`
(default `true`); ingress-nginx and OpenShift Routes pass the stream through
as they are, and the chart's 1800 s / 1 h timeouts are far above what the
stream needs.

**Order does not matter.** A 1.0.6 backend serves older desktops exactly as
before (they keep polling), and a newer desktop talking to an older backend
sees no `realtime` entry in `/api/system-info` and keeps polling too.

Then run the check below once from the users' network.

---

## Behind your proxy

The stream is a normal HTTPS `GET` that stays open. Two things matter on every
hop between the desktops and the backend (your reverse proxy, a load
balancer, a WAF):

1. **It must not buffer the response.** The backend sends
   `X-Accel-Buffering: no`, which **nginx** honours on its own — no change
   needed. Other products need buffering off for `/api/realtime/` (F5 BIG-IP:
   no response buffering / "streaming" on that path; HAProxy and Traefik do
   not buffer by default).
2. **Its idle timeout must exceed 25 s.** The backend writes a heartbeat line
   every 25 s; nginx's default `proxy_read_timeout` (60 s) is fine, and the
   1800 s from [DESKTOP-APP.md](DESKTOP-APP.md) §2 is too.

If you write nginx config by hand and want to be explicit (optional — the
header already does it):

```nginx
location /api/realtime/ {
    proxy_pass http://callman-backend:8080;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 120s;
}
```

### Check it

From a workstation on the users' network, against the address the desktops
use:

```bash
./scripts/check-realtime.sh https://callman.yourcompany.local
```

| Result | Meaning |
|---|---|
| `✓ First event after … ms` | Live updates work on this path. |
| `✗ First event only after … ms` | A hop buffers responses. Desktops still work but keep polling — turn buffering off for `/api/realtime/` on that hop. |
| `! … answered 404` | The backend is older than 1.0.6, or `REALTIME_ENABLED=false`. |

The same by hand: `curl -N https://callman.yourcompany.local/api/realtime/probe`
must print `event: hello` at once, then two `: hb` lines one second apart, then
`event: bye`. If all of it appears at the same moment after 3 s, something
buffers.

### Which desktops fell back

A desktop that cannot use the stream (no first event within 10 s) reports it
once and keeps polling. `GET /ops/realtime` shows the count and when it last
happened (`fallbackReports.buffered`, `buffered:lastAt`), next to how many
streams this backend holds right now — see [MONITORING.md](MONITORING.md).

---

## Turning it off

```bash
# .env (Compose)
REALTIME_ENABLED=false
```

or `backend.realtimeEnabled: false` in your Helm values. Once the backend
restarts with it, desktops are refused when their stream reconnects and go
back to polling as before; nothing else changes.

## Tuning (rarely needed)

| Variable | Default | Meaning |
|---|---|---|
| `REALTIME_ENABLED` | `true` | Master switch (see above). |
| `REALTIME_HEARTBEAT_MS` | `25000` | Heartbeat interval. Keep it below the shortest idle timeout on the path. |
| `REALTIME_MAX_STREAM_MS` | `900000` | A stream is closed after about this long (±20 %) and the desktop reconnects at once — it re-checks the session and spreads desktops across backend replicas after a rolling update. |
| `REALTIME_STREAM_MAXLEN` | `20000` | Entries kept in the Redis Stream. A desktop that was away longer than that many events simply refreshes everything it shows. |
| `REALTIME_MAX_STREAMS_PER_USER` | `10` | Open streams per user per backend process; the oldest is closed beyond it. |

## How it behaves

- **Backend restarts / rolling updates.** Streams are closed cleanly first;
  desktops reconnect after a random 0.5–3 s (then with growing pauses), so a
  restart is not followed by every desktop at the same instant. Whatever
  happened in between is replayed from the stream (`Last-Event-ID`).
- **Several backend replicas** (Helm `backend.replicaCount > 1`): every replica
  reads every event, so no sticky sessions are needed.
- **What travels over the stream** is only "this changed" — an id and a status,
  never content. The desktop then loads the data through the normal API with
  the user's permissions, exactly as before.
- **Signing out** (or a session evicted by the per-user session limit) closes
  that session's streams immediately.
- **External Redis** must be 5.0 or newer (streams); the documented minimum
  already is.
