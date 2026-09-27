# Desktop app: delivering and updating it

Your users run the Callman desktop app. This page covers how a new version
reaches them — which, from this release on, is something you do once in the admin
panel instead of sending files to every person.

Nothing leaves your network. We hand you the installers; you upload them into
your own deployment; the desktops download from your own storage.

---

## 1. What you get from us

A folder per version, named after your company and that version, containing:

| File | What it is |
|---|---|
| `Callman-<company>-<version>-x64.exe`, `…-arm64.exe` | the Windows installers |
| `Callman-<company>-<version>.exe` | one Windows installer covering both architectures — handy to hand to a person, but the panel does not upload it (the per-architecture ones are what updates use) |
| `Callman-<company>-<version>-arm64.dmg`, `…-x64.dmg` | the macOS installers a person runs |
| `Callman-<company>-<version>-arm64.zip`, `…-x64.zip` | what the automatic update installs on macOS — **not** for installing by hand |
| `latest.yml`, `latest-mac.yml` | describe the release: which file, how big, and its checksum |
| `build-manifest.json` | which company, version and server address this build was made for |
| `README-DELIVERY.txt` | the short version of this page |

**Upload all of it.** The `.yml` files are not optional extras — they are how the
panel knows what to expect and how each desktop verifies what it downloaded. A
release uploaded without them cannot be published.

The build is signed (macOS Developer ID + notarization). An unsigned build is
clearly marked as such in the delivered folder and in the panel; macOS cannot
auto-update from one, so it is only ever for our own testing.

---

## 2. Before the first upload

Three settings, all in `.env`, all checked by `scripts/preflight.sh`:

```bash
# The address your users' desktops reach the backend on. This is what they are
# told to fetch updates from — a wrong value sends every desktop to the wrong
# host. Include the scheme, no trailing slash.
PUBLIC_API_BASE_URL=https://callman.yourcompany.local

# Your company slug, exactly as it appears in the delivered build-manifest.json.
# This is what refuses another customer's build.
ONPREM_COMPANY_SLUG=yourcompany

# An installer upload is a single HTTP request of up to 2 GB. The 2-minute
# default cuts it off part-way.
HTTP_REQUEST_TIMEOUT_MS=1800000
```

**And your reverse proxy.** This is the most common reason a first upload fails.
The admin panel's vhost now carries the installer bytes, so it needs:

```nginx
location / {
    client_max_body_size 0;          # nginx's 1 MB default rejects an installer
    proxy_request_buffering off;     # stream it through; do not spool 2 GB to disk
    proxy_read_timeout 1800s;
    proxy_send_timeout 1800s;
    proxy_pass http://callman-admin:5100;
}
```

The backend vhost needs the same, because that is where the desktops download
from. On Kubernetes the equivalent annotations are commented in
`helm/callman/values.yaml` under both `admin.ingress` and `storage.ingress`.

**Storage must be connected** (admin panel → **Storage**). The installers go
wherever your other large files go — your S3/MinIO, FileNet, or the local volume.
A 200-seat deployment serving a 200 MB update means roughly 40 GB leaving that
store within the polling hour, so prefer a local volume or MinIO over CMIS, which
cannot resume a partial download at all.

---

## 3. Publishing a release

Admin panel → **Desktop Releases** → **Upload a build**.

1. **Drop the folder.** The panel reads the three small text files and lists
   every installer it now expects, with sizes.
2. **Upload.** One file at a time, with progress. Leave the tab open; if you do
   close it, drop the same folder again and it carries on — files already
   uploaded are not re-sent.
3. **Publish.** The button stays disabled, with the reason shown, until at least
   one platform can actually be served.

Within the hour every desktop notices, downloads in the background, and shows its
user a **Restart** button. Nobody has to be told anything.

### If the panel refuses

| What it says | What it means |
|---|---|
| built for a different deployment | The `build-manifest.json` names another company or another server address. **Do not override it.** A build carries the server address baked in, so publishing it would point every desktop here at someone else's Callman. Come back to us. |
| does not match the checksum | That file is damaged or came from a different build. Copy it out of the delivered folder again. |
| not the size the update file declares | Same cause: the folder has been mixed with another build's files. |
| is not part of this release | You are uploading a file no update file mentions — probably a leftover from an older folder. |
| not newer than the published version | Callman would then show no update at all to anyone. To undo a bad release, publish a **higher** version, never a lower one. |
| the request timeout is too short | `HTTP_REQUEST_TIMEOUT_MS` — see §2. |
| no storage is connected | Connect one under **Storage** first. |

### Requiring an update

The **Require this update** checkbox makes the app block users on older versions
until they take it. Leave it off unless you mean it — confirm the release is
healthy in the wild for a day first, and remember you can turn it off again from
the release list at any time.

---

## 4. Getting an installer back

The panel keeps every build you upload, and **Desktop Releases → Uploaded
builds** lists them with their files. Expand a release and press Download on any
file to pull it back to your own machine.

That is the answer to "I need to install this on one more laptop and I no longer
have the folder you sent us". Nothing had to be kept on your side: the installers
have been in your own storage since you uploaded them, including for releases you
published months ago.

Two notes:

- The file comes through your browser tab, so a 200 MB installer occupies that
  much memory while it saves. The size is shown next to each button.
- A release uploaded before you switched storage provider still downloads — the
  old provider keeps serving reads (see [`STORAGE.md`](./STORAGE.md)). Do not
  disconnect it while anything still references it; the panel tells you when
  something does.

---

## 5. The first release is different — read this

Every desktop installed **before** this feature existed has no updater inside it.
No server-side change can reach those machines: the code that would do the
updating is not in them.

So the first auto-updating release has to be installed **by hand, once, on each
machine**. Two ways, either is fine:

- in the app: profile menu → **Update** → **Download**, then **Install & Quit**
  (the app tells the user this is a one-off);
- or run the installer from the delivered folder.

It installs over the existing app — same location, same settings, same data.

After that one install, every future release arrives on its own.

---

## 6. Checking it works

From a machine that can reach the backend, with any user's access token:

```bash
API=https://callman.yourcompany.local
TOKEN=<a signed-in user's access token>

# The update check. A 404 means nothing is published yet — that is normal.
curl -i -H "Authorization: Bearer $TOKEN" \
  "$API/api/desktop-releases/feed/win/x64/latest.yml"

# The installer, resumably. Expect 206 Partial Content.
curl -i -r 0-99 -o /dev/null -H "Authorization: Bearer $TOKEN" \
  "$API/api/desktop-releases/feed/win/x64/Callman-yourcompany-2.1.0-x64.exe"

# What the app itself asks, and what it decides from.
curl -s -H "Authorization: Bearer $TOKEN" \
  "$API/api/desktop-releases/latest?os=win&arch=x64&currentVersion=2.0.0" | jq
```

In that last response, `"updateMode": "auto"` with a `feedUrl` ending in `/` is
the signal the desktop uses. `"manual"` means that machine will keep using the
Download button — expected on an unsigned macOS build, and on any build from
before this feature.

In the app: profile menu shows **Check for updates** and, once an update is
downloaded, **Restart to update**.

---

## 7. When something is wrong

**Nobody sees the update.**
Check `PUBLIC_API_BASE_URL` first — it is what the desktops were told to poll.
Then confirm the release is published (not just uploaded) and that the platform
the user is on shows as ready. A user must be signed in; the feed is
authenticated, so a signed-out app does not poll.

**One user sees it, another does not.**
Resolution is per platform and architecture. A release published with only the
macOS build ready leaves Windows users on their previous version — deliberately,
so they keep a working download rather than being offered a file that was never
uploaded.

**macOS downloads it and then nothing happens.**
Squirrel refuses an update whose signature does not match the installed app. That
happens with an unsigned build, and it happens if our signing identity changed
between the installed version and the new one. In the second case you need one
manual install again; tell us and we will say which it is.

**"Update failed" in the app.**
Expected failures are shown as *Up to date*, not as errors — no release published
yet, VPN down, token being refreshed. A real error means something else:
a checksum mismatch (re-upload that file), or the backend answering the feed with
something unusable (send us the app's log from
`~/Library/Logs/Callman/` or `%APPDATA%\Callman\logs\`).

**Windows updates are large.**
Every update is a full download, about 150–250 MB per machine. There is no
incremental update on Windows in this build. Size the storage link accordingly:
200 seats ≈ 40 GB in the hour after you publish.

**An upload dies part-way.**
Almost always the reverse proxy (§2). `413` is the body limit; a timeout around
the 60-second or 5-minute mark is `proxy_read_timeout` or
`HTTP_REQUEST_TIMEOUT_MS`.

**A half-finished upload is taking up space.**
Drop the same folder again to finish it, or use **Discard draft**, which removes
its files from your storage. A published release cannot be deleted — a desktop
may be downloading it at that moment.

---

## 8. If you would rather not have automatic updates

Tell us, and we will build with the updater left out. Those builds behave exactly
as before: you distribute the installers, each user runs them. Nothing in the
deployment changes.

---

## See also

- [`STORAGE.md`](./STORAGE.md) — connecting the storage the installers live in
- [`ENVIRONMENT.md`](./ENVIRONMENT.md) — every setting mentioned here
- [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) — the rest of the deployment
