# Login methods (local and LDAP / Active Directory)

Callman supports two ways to sign in:

- **Email and password** — Callman's built-in accounts. On by default.
- **LDAP / Active Directory** — staff sign in with their existing corporate
  credentials.

Both are configured in the **admin panel**, not in `.env`. Open
`http://<this-host>:5100` (or your `CALLMAN_ADMIN_PORT`), log in, and go to
**On-Prem → Authentication**.

Changes apply within about 30 seconds. **No `.env` edit, no restart, and no
shell access to the server** — including for the CA certificate, which you
paste into the form.

> **The desktop application is the same binary for everyone.** You do not
> rebuild or reconfigure it. It asks the backend which methods are enabled
> and shows the right login screen automatically.

> Everything works **air-gapped** — Callman talks to *your* directory server,
> never to the internet.

> **The admin panel has its own separate login** (`ADMIN_BOOTSTRAP_EMAIL` /
> `ADMIN_BOOTSTRAP_PASSWORD`) and is **not** affected by anything on this
> screen. So even a completely broken directory configuration can always be
> fixed from the panel — you cannot lock yourself out of the fix.

---

## 1. Email and password

| Setting | What it does |
|---|---|
| **Allow email and password login** | Callman's built-in login. Keep it on unless every single user comes from your directory. |
| **Let people create their own account** | When off, the desktop hides **Register** *and* the server refuses new signups. Turn this off on a directory-backed deployment so accounts can only come from LDAP. |

> Turning registration off is enforced by the server, not just hidden in the
> app. That matters: with it on, anyone who can reach the API can create a
> local account that bypasses your directory.

---

## 2. LDAP / Active Directory

### Create a read-only service account

Callman binds to your directory with a dedicated **service account** to look
users up. It needs only **read** access to the user subtree — never admin
rights.

1. Create a normal user in your directory, e.g.
   `cn=callman-svc,ou=services,dc=acme,dc=local`, with a strong,
   non-expiring password.
2. Grant it read access to the attributes Callman reads: the uid attribute,
   `mail`, and the display-name attribute, for entries under your user base.

The service-account password is stored **encrypted** in the database and is
never shown again — the screen displays only its last four characters.

### Fill in the form

| Field | Example | Notes |
|---|---|---|
| **Server URL** | `ldaps://ldap.acme.local:636` | LDAPS recommended. For `ldap://…:389`, enable **Use StartTLS**. |
| **Service account DN** | `cn=callman-svc,ou=services,dc=acme,dc=local` | The account above. |
| **Service account password** | — | Leave empty when editing to keep the stored one. |
| **Base DN** | `ou=users,dc=acme,dc=local` | Where to search for users. |
| **User filter** | `(sAMAccountName={{username}})` | **Must contain `{{username}}`** — see below. |
| **Unique id attribute** | AD: `objectGUID` · OpenLDAP: `entryUUID` | A **stable** id, so the link survives a rename or an OU move. Do not use the DN. |
| **Email attribute** | `mail` | Becomes the Callman account email. |
| **Display name attribute** | AD: `displayName` · OpenLDAP: `cn` | — |

### The user filter

`{{username}}` is replaced with whatever the user typed, safely escaped —
LDAP injection is not possible.

| Directory | Filter | Users log in with |
|---|---|---|
| Active Directory | `(sAMAccountName={{username}})` | their AD username (`jdoe`) |
| AD, by email | `(userPrincipalName={{username}})` | their UPN / email |
| OpenLDAP | `(uid={{username}})` | their uid |
| Either, by email | `(mail={{username}})` | their email address |

The filter must match **exactly one** entry. If it matches zero or several,
the login is rejected — Callman never guesses. **Test connection** tells you
how many entries matched.

### TLS

LDAP carries passwords, so Callman requires an encrypted connection:

- **LDAPS (recommended)** — a `ldaps://host:636` URL.
- **StartTLS** — an `ldap://host:389` URL plus **Use StartTLS**.

If your directory uses a **private or internal CA** (common with Active
Directory), paste the CA certificate into the **CA certificate** box. Export
it as PEM and paste the whole thing, including the
`-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----` lines. Nothing
needs to be copied onto the server.

> **Escape hatch (discouraged):** *Allow an unencrypted connection* permits
> plain `ldap://` with no TLS. Passwords then cross the network in cleartext.
> Use only on an isolated lab network; the backend logs a loud warning.

### Test before you save

Press **Test connection**. It performs the same steps as a real login:

1. Connects and signs in as the service account.
2. If you supplied a **directory username**, searches with your actual filter
   and reports the entry it found — DN, email, display name, unique id.
3. If you also supplied **that user's password**, binds as them, which proves
   end-to-end that logins will work.

Nothing is saved by the test. **Enabling LDAP requires a passing test**, and
editing any field afterwards means you must test again — that guard is what
stops a mistyped setting from locking your users out.

---

## 3. Which method is tried first

With both methods on, choose the order. **Directory first** means corporate
users authenticate against LDAP while local admin or service accounts still
work as a fallback — useful if the directory becomes unreachable.

Keep at least one local account working as a break-glass login.

---

## 4. "Forgot password?" link

Point it at your internal or AD self-service reset page and the desktop login
screen shows a **Forgot password?** link. Leave it empty and the link is
hidden.

---

## 5. How an LDAP login works

1. User enters their username (or email) and password in the desktop app.
2. Callman binds as the service account and searches with your filter.
3. Callman re-binds as the found user with the supplied password — that bind
   **is** the credential check.
4. On success Callman issues its normal session. A first-time directory user
   is created automatically, with no local password. If a local account
   already exists with the same email, the directory identity links to it.

The end user's password is used for that one bind and is never stored or
logged.

> **Account linking is by email and is not verified.** If a local account
> `alice@acme.local` already exists, whoever controls the directory entry with
> that email inherits it. Review existing local accounts before enabling LDAP
> on a deployment that has been running for a while.

---

## 6. Troubleshooting

Most problems are reported directly by **Test connection**, with the fix in
the message. Beyond that:

| Symptom | Likely cause |
|---|---|
| Test: "server name could not be resolved" | Wrong host, or the container cannot reach your DNS. |
| Test: "refused the connection" | Wrong port, or a firewall between this server and the directory. |
| Test: "TLS certificate could not be verified" | Private CA — paste its certificate into the **CA certificate** box. |
| Test: "rejected the service account credentials" | Wrong service account DN or password. |
| Test: "matched N entries" | The filter is not specific enough. It must match exactly one entry. |
| Test: "has no `mail` value" | That user has no email in the directory; Callman uses it as the account email. |
| A specific user cannot log in | The filter does not match them. Test with their username. |
| All directory logins fail after a working setup | The directory is unreachable, or the service account password expired or changed. |
| Nobody can log in at all | Open the admin panel (its login is separate and unaffected) and re-enable email and password login. |

Saved settings not taking effect? Give it 30 seconds. A desktop app that is
already open may take up to 5 minutes to notice, or restart it.

---

## 7. Not available yet

- **SSO / OIDC** (e.g. Okta, GitLab) — a redirect-based provider is planned;
  the settings are stored as a provider list so it can be added without
  reworking this screen.
- **Directory group → Callman role mapping** — all directory users currently
  receive the standard role.
