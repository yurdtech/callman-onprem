# Storage — where Callman keeps large files

Most of what Callman stores is small: scenarios, requests, run reports, users.
Those live in MongoDB and need nothing from you. **Large** files are different —
a mobile build artifact is 50–300 MB, a screen recording can be larger — and
putting those in MongoDB is the wrong place for both of us.

So Callman keeps them in **storage you own**. You connect your existing S3,
MinIO or IBM FileNet in the admin panel under **Storage**, and an optional
service — the **storage gateway** — streams files to it. Callman never holds a
copy: the bytes go straight to your provider, inside your own backup and
retention policy.

The gateway is **opt-in**. Until you enable it, nothing about your deployment
changes; features that need large files simply report that storage is not
configured.

> **Desktop installers live here too.** Since desktop auto-update arrived, the
> installers your administrator uploads are kept in this same storage and served
> from it to every desktop in the deployment — see
> [`DESKTOP-APP.md`](./DESKTOP-APP.md). They are the largest and most
> frequently-read thing Callman will store, and they are the reason the sizing
> and provider-choice notes below matter more than they used to.

## Requirements

- Callman backend **1.1.0 or newer** (`CALLMAN_VERSION`).
- Somewhere to put the files — one of:
  - an **S3 bucket** (AWS, or any S3-compatible appliance: MinIO, Ceph RGW,
    NetApp StorageGRID, Dell ECS), with an access key that can read, write and
    delete in it;
  - an **IBM FileNet** repository *(from a later version — see
    [Which providers are available](#which-providers-are-available))*;
  - or nothing at all, in which case the gateway can use a **local volume** on
    this host. That works, but it makes this container stateful and takes the
    files out of your own backup regime, so treat it as a starting point rather
    than the destination.
- **No new image to pull.** The gateway runs from the same image as the backend.
- ~100 MB RAM. It streams, so a 300 MB upload does not cost 300 MB of memory.

## Enable it (one-time)

All steps happen in your `callman-onprem` folder.

```bash
# 1. Refresh the deployment files (brings the storage service definition)
git pull

# 2. Edit .env
#    a) add "storage" to the profiles line, keeping what is already there:
#         bundled databases:  COMPOSE_PROFILES=bundled-mongo,bundled-redis,storage
#         your own databases: COMPOSE_PROFILES=storage
#    b) tell Callman the address your users reach the gateway on — this is what
#       goes into every download link, and it is why your bucket's own URL and
#       credentials never reach a client:
#         CALLMAN_STORAGE_PUBLIC_URL=https://callman.yourbank.local
#       (no trailing slash, and no /storage path — Callman adds that)

# 3. Sanity-check the configuration
./scripts/preflight.sh

# 4. Start it
docker compose pull
docker compose up -d

# 5. Verify
docker compose ps                        # callman-storage should become "healthy"
docker compose logs storage | tail -5    # look for "Storage gateway listening"
```

### Route it through your reverse proxy

The gateway publishes port `8081` (`CALLMAN_STORAGE_PORT`). Put it behind the
same hostname as the API, on the `/storage/` path:

```nginx
location /storage/ {
    proxy_pass http://127.0.0.1:8081;

    # Large uploads. Without these two lines nginx buffers the whole body to
    # disk and rejects anything over 1 MB — a 200 MB build would fail with 413
    # before it ever reached Callman.
    client_max_body_size 0;
    proxy_request_buffering off;

    # Transfers take minutes on a slow link.
    proxy_read_timeout  3600s;
    proxy_send_timeout  3600s;

    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
}
```

On Kubernetes the equivalent is
`nginx.ingress.kubernetes.io/proxy-body-size: "0"` plus
`proxy-read-timeout`/`proxy-send-timeout` annotations — see
[HELM-INSTALL.md](HELM-INSTALL.md).

## Connect your storage

In the admin panel → **Storage** → **New provider**.

### S3 or MinIO

| Field | What to enter |
|---|---|
| Endpoint | Leave empty for AWS S3. For MinIO or an appliance, its URL, e.g. `https://minio.yourbank.local:9000` |
| Region | `us-east-1` if your appliance does not care — it is still required by the protocol |
| Bucket | An existing bucket. Callman does not create it. |
| Prefix | Optional, e.g. `callman/` — lets Callman share a bucket with other systems |
| Path-style addressing | **On** for MinIO and most on-prem appliances; off for AWS S3 |
| Access key / Secret key | A key that can **read, write and delete** in that bucket. Delete matters: without it Callman cannot apply retention. |

Press **Test connection**. Callman checks the bucket is reachable, writes a tiny
probe object and deletes it again — so a read-only key is caught here rather
than at the first real upload. Then press **Set as active**.

If your endpoint uses a privately-signed certificate, put the CA bundle in
`certs/` and add `NODE_EXTRA_CA_CERTS=/certs/<bundle>.pem` to `.env`.

### Local volume

Only Endpoint-free: you give a path inside the container, and the compose file
already mounts a Docker volume at `/var/lib/callman/files` for it. Use this to
try things out, or if you genuinely have no object store. Remember that these
files are then **not** covered by your MongoDB backup — see
[BACKUP.md](BACKUP.md).

### Which providers are available

| Provider | Status |
|---|---|
| S3 / MinIO / S3-compatible | Available |
| Local volume | Available (fallback, not recommended for production) |
| IBM FileNet | Config is in place; the connector ships in a later version. Selecting it now reports "FileNet storage is not available in this build yet". If you need it, tell us your binding details (CMIS endpoint, repository id, target folder, authentication) and we will finish it against your system. |

## Switching provider later

You can move from one provider to another — MinIO to FileNet, one bucket to
another — **without your users noticing and without breaking a single existing
file**. Two things make that safe:

1. **Every file remembers where it lives.** Switching changes where *new* files
   go; old files keep pointing at the provider that holds them.
2. **The previous provider becomes read-only, not disconnected.** It keeps
   serving downloads. The panel does this for you when you press **Set as
   active** on the new one.

So the procedure is simply: add the new provider → **Test connection** → **Set
as active**. Nothing else. Within a minute new uploads land on the new provider.

Keep the old provider connected (read-only) as long as files still reference it.
Callman refuses to delete a provider that is still in use, and tells you so —
**including the desktop installers**, which are counted in that usage figure. Do
not disconnect a provider that still holds a published release: a desktop
part-way through downloading it would fail, and so would anyone installing by
hand.
Copying the historical files across is a separate, optional step that a later
version automates.

## Day-2 operations

- **Scale:** the gateway holds no state, so `docker compose up -d --scale
  storage=2` is safe — the one exception being the *Local volume* provider,
  where all replicas must see the same volume.
- **Restarts and upgrades:** in-flight transfers are given `SHUTDOWN_TIMEOUT_MS`
  to finish before the process exits. A normal version update
  (`CALLMAN_VERSION=…` → `pull` → `up -d`) covers the gateway automatically,
  because it is the same image as the backend.
- **Size limits:** `STORAGE_MAX_UPLOAD_BYTES` (default 500 MB) is refused from
  the request headers, so an oversized upload costs one round trip rather than a
  half-transferred file. If you raise it, raise the proxy's body limit too.
  Desktop installers have their own, larger ceiling
  (`DESKTOP_RELEASE_MAX_ARTIFACT_BYTES`, 2 GiB) because a signed macOS disk image
  is legitimately far bigger than anything else here.
- **Sizing for desktop updates:** publishing a release means roughly
  `seats × installer size` leaving this storage within the polling hour — 200
  seats and a 200 MB build is about 40 GB. Windows updates are full downloads,
  not incremental. Prefer **MinIO or S3** for this: CMIS/FileNet cannot serve a
  byte range at all, so a download interrupted at 90% restarts from zero.
- **The *Local volume* provider and desktop releases:** it works, but the files
  are touched by more than the gateway now — the API process writes them (the
  panel uploads through it) and serves them (the desktops' update feed reads
  through it). So **every app container must see the same directory**. Compose
  does that for you: the volume is mounted into all of them. On Kubernetes the
  claim is mounted by the API Deployment as well as the gateway, which means
  `storage.localVolume.accessModes` **must include `ReadWriteMany`** — the chart
  refuses to render otherwise and tells you to use S3/MinIO if RWX is not
  available to you.
- **Retention:** Callman deletes what it no longer needs through the provider's
  delete API. Your own bucket lifecycle rules still apply on top — if you set
  one, make sure it is not shorter than what your teams expect to keep.
- **Disable again:** remove `storage` from `COMPOSE_PROFILES`, then
  `docker compose up -d --remove-orphans`. The provider settings and all file
  records stay in the database; nothing is deleted from your bucket.

## If something's off

| Symptom | Cause / fix |
|---|---|
| "No storage provider is active. Connect one in the admin panel under Storage." | Exactly that: either nothing is connected, or the provider you connected was never set as active. |
| "The active storage provider … is not usable. Stored credentials could not be decrypted…" | The admin panel and the backend have **different** `CONNECTION_ENCRYPTION_KEY` values. They must be identical; fix `.env` and restart both, then re-enter the storage credentials. |
| "The active storage provider … is not usable. Invalid configuration: …" | A required field is missing — most often an S3 provider saved without a bucket. Re-open it in the panel; the message names the field. |
| **Test connection** says "Connected, but cannot write to …" | The bucket is reachable but the key is read-only. Callman needs read, write and delete. |
| Uploads fail at exactly 1 MB, or with `413` | Your reverse proxy's body limit, not Callman. See [Route it through your reverse proxy](#route-it-through-your-reverse-proxy). |
| Uploads stop partway on a slow link | The proxy's read/send timeout. Raise `proxy_read_timeout` / `proxy_send_timeout`. |
| "Another upload of this file is already in progress" | A previous attempt was interrupted and still holds the slot. It is released automatically after `STORAGE_UPLOAD_CLAIM_STALE_MS` (30 min), or immediately once the running transfer finishes. |
| "The uploaded bytes do not match the declared sha256" | The file changed or was corrupted in transit. Nothing was stored — the upload can simply be retried. |
| A changed setting in the panel does not take effect at once | Provider settings are re-read every `STORAGE_PROVIDER_CACHE_TTL_SECONDS` (60 s). Wait a minute; it is safe, because files already written keep pointing at the provider that holds them. |
| `callman-storage` is `unhealthy` | Check `docker compose logs storage`. On-prem-only service: it exits on purpose if `CALLMAN_EDITION` is not `onprem`. |

More general issues: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
