# Server migration: copy Callman to another server

The admin panel copies a whole Callman server to another one: every user,
test, setting, secret and file, proven identical by hash. Nothing is deleted on
the old server and it keeps working. It can be repeated: each migration deletes
what the new server holds and writes it again from scratch.

Not the same thing as the schema migrations the `migrate` service runs on an
upgrade.

## Requirements

| | |
|---|---|
| Version | The same Callman version (backend and admin panel) on both servers |
| MongoDB | The same major version on both. Standalone is fine |
| Network | The old **backend** reaches the new server's Callman API address (`/api/migration-peer`). Nothing has to reach the old server |
| Who | A super admin on each server |
| Space, old server | About the database's size in the backend's temporary directory, or in `MIGRATION_SPOOL_DIR`. It holds the whole database for the length of the run and is removed after it |
| Space, new server | About 2.2 times the database, plus the largest file, free in its MongoDB during the copy |
| Storage | If the old server has files: an active storage on the new one, with **its own** bucket, prefix or volume. A shared one is refused |
| License | An active one on both servers. Activate the same certificate on the new server first (it is not bound to a host); a migration replaces it with the old server's copy |
| Secrets | Each server keeps its **own** `.env` secrets. Nothing from `.env` is copied |

The same build matters: a tag rebuilt from another commit is refused too.

## Steps

1. Install the new server ([INSTALL.md](INSTALL.md) or
   [HELM-INSTALL.md](HELM-INSTALL.md)), sign in with its bootstrap admin,
   activate the license and connect its storage.
2. New server, **Migration > Receive on this server**: **Create token**.
3. Old server, **Migration > Copy from this server**: enter the new server's
   API address and that token, **Save token**. It shows its own token.
4. New server: paste that token, **Save token**. Tokens are valid for 30 minutes.
5. Both admins compare the code outside the channel the tokens went through and
   press **The codes match**.
6. New server: **Allow replace** (type `REPLACE` and your password). It lasts
   24 hours and covers one completed migration.
7. Old server: **Run check**, fix what it lists, **Start migration**.
8. When it completes, the new server has restarted and everybody is signed out
   there. Sign in with an admin account of the **old** server and check it.
9. Point the desktops' DNS name at the new server when you are ready.

To migrate again, repeat 6 and 7. The pairing stays.

## What users notice

| When | Old server | New server |
|---|---|---|
| Copying files | Works as usual | Works as usual |
| Snapshot (a `mongodump` of the database, so it grows with its size) | Reading works. Changes wait; one waiting over 15 s gets `423` and can be retried | Works as usual |
| Sending, restoring, verifying | Works as usual | Works as usual |
| Replace | Works as usual | `423` until the data is swapped, then every process restarts |

Run it at a quiet hour. Do not upgrade or run schema migrations on either
server while one runs.

## After it: two servers are running

Callman does not switch anything off on either server.

- **Schedules** run on both. A scheduled payment test then makes two payments.
- **Reminders and notifications** go out from both.
- **API tokens and the license** are valid on both.
- **Changes are not synced.** The servers drift apart.
- **Migrating again deletes** the work done on the new server since.

Switch schedules and notification channels off on one side, or stop the old
server after the cutover, if that matters to you.

## What is copied

Everything in Callman's database and every stored file, except:

| | |
|---|---|
| Kept on the new server | Its storage connections, its pairing and migration history |
| Emptied on the new server | Sign-in sessions, single-use links, rate limits, locks, queues, cache |
| Never sent | `.env` secrets, `certs/`, DNS, Grafana and anything else outside Callman |

Saved passwords and keys are re-encrypted with the new server's
`CONNECTION_ENCRYPTION_KEY`. Files are written into the new server's active
storage under `callman/migrated/`; the old storage is only read (apart from a
small probe object, written and removed, that proves the storage is separate).

Copy `certs/` yourself if your storage, LDAP or tested systems use a private CA.

## If it stops

| What happened | Result |
|---|---|
| Failed or cancelled before **Replace** | The new server is unchanged. Start again |
| The old backend died during the snapshot | The old server opens by itself within 30 seconds. Start again |
| The new backend died during **Replace** | It answers `423` until a backend process is back, then finishes by itself. It never opens half replaced |
| The snapshot took over 30 minutes | It stops and the old server opens. Raise `MIGRATION_MAX_PAUSE_MS` |

Both servers list every run with its result under **Migration > History**.

## Proxy and firewall

- The old backend must be allowed out to the new server's API address.
- Data is sent in requests of 4 MB. If a proxy refuses that, they shrink down
  to 256 KB by themselves; below that raise the limit
  (nginx: `client_max_body_size 8m;`). The usual 60 s timeouts are enough.
- Traffic is sealed end to end between the two backends (AES-256-GCM, keys
  from the two tokens). Use HTTPS anyway.
- Keep `/api/internal/*` off the user-facing proxy as before.
  `/api/migration-peer/*` must pass; it answers 404 unless the servers are paired.

## Kubernetes

The snapshot goes to the backend pod's ephemeral disk. For a large database
mount a volume and set `MIGRATION_SPOOL_DIR` to it through `backend.extraEnv`.
A rollout during a migration stops one that has not reached the new server's
restore; start it again afterwards.
