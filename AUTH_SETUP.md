# Callman authentication setup (on-prem)

Callman supports pluggable login providers. Out of the box only **local**
(email + password) is enabled. On-prem customers can additionally enable
their **corporate LDAP / Active Directory** so staff sign in with their
existing directory credentials.

> **The desktop application is the same binary for everyone.** You do
> **not** rebuild or reconfigure the desktop. It asks the backend which
> providers are enabled (`GET /api/auth/providers`) and shows the right
> login UI automatically. Only the backend `.env` changes.

Everything works **air-gapped** — Callman talks to *your* LDAP server,
never to the internet.

---

## 1. Quick reference

All settings go in your backend `.env` (see `.env.example`). After editing,
restart the backend container.

```dotenv
CALLMAN_EDITION=onprem
AUTH_PROVIDERS=local,ldap
PASSWORD_PROVIDER_ORDER=ldap,local

LDAP_URL=ldaps://ldap.acme.local:636
LDAP_BIND_DN=cn=callman-svc,ou=services,dc=acme,dc=local
LDAP_BIND_PASSWORD=<service account password>
LDAP_BASE_DN=ou=users,dc=acme,dc=local
LDAP_USER_FILTER=(sAMAccountName={{username}})
LDAP_ATTR_EMAIL=mail
LDAP_ATTR_NAME=displayName
LDAP_ATTR_UID=entryUUID
```

- `AUTH_PROVIDERS=local,ldap` enables both. Keep `local` so your break-glass
  admin account still works if LDAP is unreachable.
- `PASSWORD_PROVIDER_ORDER=ldap,local` means a login is checked against LDAP
  first, then local. Directory users authenticate via LDAP; local-only
  admin/service accounts still work as a fallback.
- `ldap` only takes effect when `CALLMAN_EDITION=onprem`. The backend
  **refuses to start** (with a clear message) if `ldap` is enabled but
  required settings are missing or TLS is not configured — so a
  misconfiguration is caught at boot, not at first login.

**Forgot-password link (optional).** Set `AUTH_PASSWORD_RESET_URL` to your
internal / AD self-service password-reset page and the desktop login screen
shows a **Forgot password?** link that opens it in the browser. Leave it
unset and the link is hidden. Users sign in with their directory username
**or** email — the login field accepts both.

---

## 2. Create a read-only service account

Callman binds to LDAP with a dedicated **service account** to look up users.
It needs only **read** access to the user subtree — never admin rights.

1. Create a normal user in your directory, e.g.
   `cn=callman-svc,ou=services,dc=acme,dc=local`, with a strong,
   non-expiring password.
2. Grant it read access to the attributes Callman reads: the uid attribute,
   `mail`, and the display-name attribute, for entries under your user base.
3. Put its DN in `LDAP_BIND_DN` and password in `LDAP_BIND_PASSWORD`.

The service-account password lives only in `.env`. End users' passwords are
used for a single verify-bind and are never stored or logged.

---

## 3. TLS (required)

LDAP carries passwords, so Callman **requires an encrypted connection**.
Choose one:

- **LDAPS (recommended):** `LDAP_URL=ldaps://your-ldap-host:636`.
- **StartTLS:** `LDAP_URL=ldap://your-ldap-host:389` **and**
  `LDAP_STARTTLS=true`.

If your directory uses a **private / internal CA** (common for AD), export
its CA certificate as PEM and point Callman at it so the certificate
validates:

```dotenv
LDAP_TLS_CA_FILE=/run/secrets/ldap-ca.pem
```

(Mount that file into the backend container.)

> **Escape hatch (discouraged):** `LDAP_ALLOW_INSECURE=true` permits a plain
> `ldap://` connection with no TLS. Passwords then cross the network in
> cleartext. Use only on an isolated lab network; the backend logs a loud
> warning at startup when it is on.

---

## 4. The user filter

`LDAP_USER_FILTER` resolves the login value to exactly one directory entry.
`{{username}}` is replaced with what the user typed (safely escaped — LDAP
injection is not possible).

| Directory | Typical filter | Users log in with |
|---|---|---|
| Active Directory | `(sAMAccountName={{username}})` | their AD username (`jdoe`) |
| AD (by email) | `(userPrincipalName={{username}})` | their UPN / email |
| OpenLDAP | `(uid={{username}})` | their uid |
| Either, by email | `(mail={{username}})` | their email address |

The filter must match **exactly one** entry. If it matches zero or several,
the login is rejected.

### Attribute mapping

| Setting | Meaning | AD value | OpenLDAP value |
|---|---|---|---|
| `LDAP_ATTR_EMAIL` | becomes the Callman account email | `mail` | `mail` |
| `LDAP_ATTR_NAME` | display name | `displayName` | `cn` |
| `LDAP_ATTR_UID` | **stable** id linking the directory user to the Callman account | `objectGUID` | `entryUUID` |

Use a **stable** `LDAP_ATTR_UID` (not the DN) so the link survives a user
being renamed or moved between OUs.

---

## 5. How a login works

1. User enters username + password in the desktop app.
2. Backend binds as the service account and searches with `LDAP_USER_FILTER`.
3. Backend re-binds as the found user with the supplied password — that bind
   is the credential check.
4. On success Callman issues its normal session. A first-time LDAP user is
   created automatically (just-in-time), with no local password. If a local
   account already exists with the same email, the LDAP identity links to it.
5. New users get the standard role. (Mapping LDAP groups → Callman roles is
   not yet supported — see "Future".)

---

## 6. Test it

Use the test directory under
`p_man_backend/deploy/ldap-dev/` for a local dry run, or against your real
server:

```bash
# Valid credentials -> 200 + a session.
curl -sS -X POST http://<callman-host>:<port>/api/auth/login \
  -H 'content-type: application/json' \
  -d '{"email":"jdoe","password":"<their-password>"}'

# Check what the desktop will see:
curl -sS http://<callman-host>:<port>/api/auth/providers
```

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Backend won't start, complains about `LDAP_*` | `ldap` enabled but a required var is missing, or no TLS configured. Read the boot error — it names the problem. |
| Backend won't start, "federated providers are on-prem only" | `AUTH_PROVIDERS` has `ldap` but `CALLMAN_EDITION` is not `onprem`. |
| All LDAP logins fail with "invalid credentials" | Wrong `LDAP_BIND_DN`/`LDAP_BIND_PASSWORD`, wrong `LDAP_BASE_DN`, or the server is unreachable. Check the backend logs — operational LDAP errors are logged there (credentials never are). |
| Specific user can't log in | The `LDAP_USER_FILTER` doesn't match them (or matches more than one entry). Test the filter with `ldapsearch`. |
| TLS / certificate errors in logs | Private CA not trusted — set `LDAP_TLS_CA_FILE` to your CA's PEM. |
| Local admin still needed during an LDAP outage | Keep `local` in `AUTH_PROVIDERS` and a local admin account; with `PASSWORD_PROVIDER_ORDER=ldap,local` it keeps working. |

---

## 8. Future (not available yet)

- **SSO / OIDC** (e.g. GitLab, Okta) — a redirect-based provider is planned;
  the desktop provider-discovery and one-time-code handoff are already in
  place to support it.
- **Admin-panel "Auth Settings" UI** — today these are `.env` settings; a
  future admin-panel screen will let admins edit them without redeploying.
- **LDAP/OIDC group → Callman role mapping** — all just-in-time users
  currently receive the standard role.
