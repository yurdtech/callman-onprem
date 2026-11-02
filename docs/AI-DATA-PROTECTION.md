# AI data protection

What Callman does with your data before it reaches an AI model, and what an
administrator controls. Settings are under **Admin panel → AI Settings → AI
data protection**; which AI source each feature may use is in
[AI-POLICY.md](AI-POLICY.md).

## Masking

Every AI call passes a privacy shield first. It replaces sensitive values with
tokens, and puts the real values back in the model's answer where the answer is
used. The same value always gets the same token, so the model can still compare
values and write them by their token.

| Where | Applies to |
|---|---|
| Callman server, in front of every hosted model call | Request AI, the workspace, scenario and diagram assistants, the scenario AI node, AI Testing steps and scenario writing on a company key, an AI connection or a personal key. Applied whatever the desktop sent, so an old or modified desktop can't send values around it. |
| The desktop app, before a call leaves the computer | The same features on a subscription, an AI command-line tool or a model server (Ollama), and AI Testing on every source (screens, element lists, test data). |

Users cannot turn masking off. A model on the tester's own computer, or a
model server an administrator listed as trusted, gets the text unmasked (see
[Trusted model servers](#trusted-model-servers)).

### What is found

| Kind | Token | How it is recognised |
|---|---|---|
| Card number | `[CARD-1 ••5158]` | 13–19 digits as cards are printed, Luhn check |
| Bank account | `[ACCOUNT-1 ••1944]` | 16+ digits, or the usual account groupings |
| IBAN | `[IBAN-1 ••1944]` | Country length and mod-97 check |
| FIN, ID card | `[FIN-1]`, `[ID-1]` | Labelled FIN, or 7 mixed capitals and digits; `AZE` / `AA` serials |
| Phone number | `[PHONE-1 ••67]` | Azerbaijani formats; other countries written with `+` |
| Email | `[EMAIL-1]` | Address shape |
| JWT | `[JWT-1]` | Header `eyJ…` and its dot, also when cut short |
| API key, token | `[SECRET-1]` | Issuer prefixes (`sk-`, `sk_live_`, `AIza`, `AKIA`, `ghp_`, `github_pat_`, `glpat-`, `xox?-`, `npm_`); the value after `Bearer`, `Basic` or `Token` |
| Password, secret | `[SECRET-2]` | The value after a label: `password: …`, `"api_key": "…"`, `token=…`, `client_secret`, `şifrə`, `parol`… — a value with a digit, or 12+ characters of mixed case |
| CVV, expiry, PIN / OTP, VÖEN, BIC | `[CVV-1]`, `[EXPIRY-1]`, `[CODE-1]`, `[TAXID-1]`, `[BIC-1]` | The value after its label (`CVV: 123`, `exp 09/26`, `OTP 551234`, `VÖEN 1234567890`, `SWIFT PASHAZ22`); an expiry printed right after a card; a BIC with a digit in its location code |
| Test data (AI Testing) | `{{key}}` | A key or a value that says it is personal: password, pin, otp, card, iban, phone, email, name, address, birth date, jwt, bearer, session, cookie… |
| Your own formats | `[CUSTOMER_NUMBER-1]` | Regular expressions an administrator adds |

Amounts, dates and unlabelled short codes stay visible: tests need them.

**Under secret names.** A value under a secret field, header or query name is
hidden whatever it looks like: in test data, request headers (`Authorization`,
`Cookie`, `X-Api-Key`, `X-Auth-Token`…), JSON bodies and query parameters that
an assistant reads, and the environment values of a scenario the scenario
assistant edits (sent as `••••`, the real values kept). The same name list is
used by request history, token (PAT) reads and the MCP server.

**Last digits.** By default a card's or an account's last 4 digits and a
phone's last 2 stay in the token, so the model can tell values apart. Turn
**Show the last digits** off to hide every digit.

### What is not found

Detection is pattern-based: no named-entity recognition, machine learning or
OCR.

- A person's name, an address or a birth date in free text. Field names and
  test data keys cover them (`customerName`, `address`, `birthDate`), and you
  can add your own names.
- A secret with no label and no known prefix, or a password of plain words
  ("correcthorse").
- Text inside a screenshot that the screen's element list doesn't carry
  (images, canvas, an app without accessibility labels). See AI Testing below.

A value the shield misses goes to the model as it is. Callman does not block
the call (see [No block mode](#no-block-mode)).

### False positives (measured)

Run over 707 files without real personal data — the desktop app's feature
code and docs, the backend's test fixtures, these on-prem docs and the mock
servers, 6.97 million characters — on 2 November 2026:

| Kind | Hits | What they were |
|---|---|---|
| Secret | 8 | TypeScript type annotations (`secret: Uint8Array`) and one doc placeholder (`--token=<x>`) |
| FIN | 2 | A 7-character piece of a base64 integrity hash, one product code |
| Account | 1 | A 16-digit millisecond timestamp |
| Email, phone, card | 64, 12, 1 | Example values in docs and tests: real-shaped, so hidden as intended |

Before the labelled-secret check required a digit or a long mixed-case value,
code ternaries and assignments (`hidden ? "password" : "text"`,
`token: tokenValue`) produced 81 secret hits; that rule is why a plain-word
secret is missed. A false positive only means the model sees a token instead of
the value; the answer gets the real value back.

## Your own formats and names

**Your own formats.** Add a name and a regular expression for each kind of
value your systems use that Callman doesn't know (a customer number, a
contract code). Matches become `[<NAME>-1]`. Flags `i`, `m`, `s` and `u` are
allowed. A pattern that matches empty text, is longer than 500 characters, or
repeats a group that itself repeats (`(a+)+`) is refused. **Try your formats**
shows what a sample text becomes.

**Field names that are always secret.** One per line. A value written under
one of these names is hidden whatever it looks like: in test data, JSON
(`"contractRef": "…"`), `contractRef=…`, and response schemas
(`contractRef: string e.g. …`).

The server and the desktops pick up a change within a minute. Every change is
in **Audit Log** as `ai-data-controls.update`, with each changed setting's
value before and after.

## Trusted model servers

A model the tester runs on their own computer (Ollama on `localhost`) sees
data unmasked: nothing leaves the computer. Any other model server is masked
unless an administrator lists it under **Trusted model servers** — one host or
`host:port` per line (`llm.bank.internal:11434`, `10.20.0.15`). This applies
to Ollama and OpenAI-compatible servers on the desktop, and to an
OpenAI-compatible AI connection or company key on the Callman server. A cloud
provider (OpenAI, Anthropic, Google, DeepSeek) and an Ollama `-cloud` model are
never trusted.

**Changed in this release.** Earlier versions treated every private address
(`10.x`, `192.168.x`, `172.16–31.x`), `.local`, `.lan`, `.internal` and
bare hostnames as local and turned masking off for them. Such a server can
forward requests to a cloud service, so they are now masked until listed. If
your testers use a company model server, add it to the list to keep the old
behaviour. On the Callman server even `localhost` is not trusted by default:
a model server next to the backend is often a proxy to a cloud provider.

## Providers

**Allowed AI providers** limits AI to the providers you have a contract with.
It covers the Callman server's AI (company key, AI connections, personal keys,
the scenario AI node) and what the desktop app calls from the computer (Claude,
ChatGPT and Gemini sign-ins and command-line tools, Cursor, Ollama). The server
refuses a provider off the list (`AI_PROVIDER_NOT_ALLOWED`) and the app hides
it. With every provider ticked there is no allowlist.

**Personal AI keys may use their own server address** is off by default: a key
a user saves for themselves always goes to its provider's public API. The
server refuses a key with its own base URL (`AI_BASE_URL_NOT_ALLOWED`) before
it contacts that address, also when the key is checked. Turn it on only if
users must reach a server of their own.

**Changed in this release.** A personal key saved earlier with its own base URL
stops working until the setting is turned on.

## AI audit

**Admin panel → AI audit** lists every AI model call, one row each:

| Field | |
|---|---|
| When, user | Who made the call |
| Feature | Request AI, an assistant, the scenario AI node, AI Testing (runs and scenario writing), AI assistant tests |
| AI | The AI source (AI connection, company key, personal key, account or CLI on the computer, self-run model), provider and model |
| Sent from | **Callman server** (the server called the provider) or **Desktop app** (a subscription, CLI or Ollama on the tester's computer) |
| Result | OK, or the error code |
| Masking | How many values were hidden, by kind; or **Not masked** for a model on the tester's computer or a trusted server |
| Tokens, screenshot | Tokens the provider reported; whether a screenshot went |
| AI Knowledge | The Knowledge sources whose parts went into the prompt |

Prompts, answers, screenshots and keys are never recorded. Filter by user,
feature, source, where the call was sent from, result, masking and date, and
export the filtered rows as **CSV** or **JSON Lines** for a SIEM (up to 50,000
rows per export; each export is itself in Audit Log as `ai-audit.export`).

A desktop that can't reach the server keeps its events in its data folder
(`ai-audit-queue.json`) and sends them when it can, with their original time.
A desktop older than this release does not report its on-computer calls.

**Retention.** AI data protection → **Keep AI audit records for** (7–3650
days, default 365). The worker deletes older rows once a day.

### Masking counts and unmasked calls

Each AI audit row says how many values were hidden, by kind (`card 1, email 2,
secret 1`), never the values. A call whose model got the data unmasked — on the
tester's computer or on a trusted server — is marked **Not masked**; the
**Masking: none** filter lists only those, and the totals above the table count
them. In the desktop app, an AI Testing run on such a model shows **Not masked**
in its History.

### No block mode

Callman does not offer a mode that blocks a call when masking finds or misses
something. Whatever detection finds is already hidden, so blocking on it would
only stop calls that are safe; what detection misses, a block rule cannot see
either. To keep data in:

- allow only the company key and AI connections under AI policy, so every call
  goes through the Callman server and its masking;
- list only the model servers you run yourself as trusted;
- add your own formats and secret field names;
- review **Not masked** calls in AI audit.


## AI conversations: how long they stay, and deleting them

What people ask the AI and what it answers is stored in the Callman database:
Request AI and assistant chats, scenario assistant proposals, and the prompt and
answer of an AI node in a scenario run report.

- **Keep AI conversations for** (AI data protection, 0–3650 days, default 0 =
  until a user or an admin deletes them). Once a day the worker deletes older
  messages and the conversations left empty, and clears the AI node prompt and
  answer in older run reports (the report itself stays).
- **Delete AI conversations** (AI Settings): one user's, everyone's before a
  date, or both. Irreversible; in Audit Log as `ai-content.purge` with the
  counts.
- **Deleting a Callman user** deletes their AI conversations and their personal
  AI keys too (counts in the `callman.user.cascade_delete` audit entry). Their
  AI audit records stay until the audit retention removes them: they hold no
  content.
- A scenario assistant proposal never stores environment values; proposals
  saved by older versions get them hidden by the first daily run.

Backups taken before a deletion still hold the data; see [BACKUP.md](BACKUP.md).
