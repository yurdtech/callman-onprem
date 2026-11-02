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
the call.

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
