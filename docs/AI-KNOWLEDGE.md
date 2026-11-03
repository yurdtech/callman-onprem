# AI Knowledge: give Callman's AI your organization's knowledge

Out of the box, Callman's AI sees only what the user has open: the request,
the scenario, the diagram. It does not know your API catalog, your naming
rules or the defects your teams keep finding, so it guesses.

**AI Knowledge** fixes that. In the admin panel you add your organization's
reference material once. Callman indexes it, and every AI feature it is
assigned to receives the relevant parts with each question. The material is
scoped to on-prem groups, so a squad's AI sees that squad's APIs and nobody
else's.

- **No vector database and no embedding model.** Everything is stored and
  searched in the Callman MongoDB you already run, so it works air-gapped.
- **Nothing leaves your network** except the selected snippets. They go to the
  model provider the user's AI request already goes to.
- **It can't break the AI.** With nothing added, nothing matching, the feature
  switched off or Mongo slow, the AI answers exactly as before.

## Requirements

- On-prem **1.0.6** or newer (backend, worker and admin panel). The worker runs
  the daily refresh.
- Desktop **2.0.14** or newer for the AI features that run on the user's own
  model (see [Where it is used](#where-it-is-used)). Older desktops still get
  knowledge on the company's hosted model, because the server adds it there.
- For AI tools (Claude Code, Cursor and others): **callman-mcp 0.10.1** or newer with the
  `search_knowledge` tool.

## Adding knowledge

Admin panel → **AI Knowledge** → **Add source**. Each source has a **kind**:

| Kind | What you give it | How it is split |
|---|---|---|
| OpenAPI definition | Paste it, upload a `.json` / `.yaml` file, or give a URL | One part per operation (method + path, parameters, request body, responses), plus one overview |
| Collections | Pick Callman collections (up to 50) | One part per request (its tests and contract rules included), plus the collection and folder docs |
| Conventions | Markdown, typed or uploaded | One part per heading |
| Known defects | Markdown or CSV (for example a Jira export) | One part per heading, or per CSV row |
| Document | Any other markdown or text | One part per heading |

For each source you also choose:

- **Who it is for.** *Everyone*, or chosen tribes and squads. A tribe's source
  reaches all of its squads.
- **Which AI features use it.** See below. Leave a feature unticked when the
  material would only distract it.
- **Always include.** For short, binding material such as naming conventions.
  It is sent with every question of those features, up to 40% of the space,
  whether or not the question's words match.
- **Refresh.** *Manual*, or *Daily* for an OpenAPI URL or collections that keep
  changing. Daily sources are re-read about once every 24 hours by the worker.
  Saving a source always re-indexes it straight away.

The list shows each source's state (*Indexing*, *Ready* with its number of
parts, or *Error* with the reason) and when it was last indexed. **Reindex**
re-reads a source on demand. Turning a source off removes it from every answer
without deleting it.

### What happens while a source is re-indexed

- **No gap.** The new parts are written next to the old ones; the AI switches
  to them only when all of them are in, and the old ones are deleted after.
  A question asked during a re-index gets the previous parts, never none and
  never both.
- **A failed re-index keeps the last good parts.** The source shows *Error*
  with the reason, and the AI keeps using the parts from its last good index
  (the list says how many) until a re-index succeeds. Turn the source off if
  that old material must not be used.
- **Who it is for, which features use it, and on/off apply at once.** They are
  checked against the source itself on every question, so narrowing a source
  to one squad takes effect immediately, without waiting for the re-index that
  saving starts.
- **One re-index at a time per source**, across every backend instance. A
  re-index asked for while one runs (an edit, the daily refresh) runs again
  once it is done, so a change made meanwhile is not lost.
- **Deleted collections.** When a collection is deleted in Callman, its parts
  stop being used the same moment, and every collections source that included
  it is re-indexed without it.
- **Long parts are cut.** A request, a CSV row or an OpenAPI overview longer
  than 1,800 characters keeps only its start; the status says how many parts
  were cut. Headings and operations are split instead, nothing is lost there.

**Preview** (below the list) shows what the AI would receive — the same parts,
selected and masked the same way — for the feature, groups and question you
give. Pick a
feature and the asker's groups, type what they ask, and optionally the endpoint
(`POST https://…/payments/123/refunds`). You see the parts and the text block
that would be added to the prompt. Use it to check a new source before people
rely on it.

Limits: 5 million characters per source, 5,000 parts per source (the status
says so when a source is cut), 8 MB per upload.

### Secrets and personal data in a source

Every part is checked while it is indexed, with the same detection as AI
calls ([AI data protection](AI-DATA-PROTECTION.md)): card and account numbers,
IBANs, FINs, phones, emails, JWTs, API keys, bearer tokens, labelled
passwords, CVV / PIN / codes, and your own formats and secret field names.
A collection's test scripts, a defect CSV or a runbook can hold real ones.

Each source has a **Secrets and personal data** setting:

| Choice | What happens |
|---|---|
| **Keep them as written** (default, as before the check existed) | The parts are stored and sent to the AI as they are; the list says what was found, so you can clean the source or choose one of the others |
| **Hide them** | The value is replaced in the stored part: `Test card [hidden card number], key [hidden secret]`. The value itself is never stored in the index, and no AI feature or AI tool receives it |
| **Don't index the source** | Nothing new is indexed while the source holds any. The source shows *Blocked: secrets or personal data* with what was found, and keeps serving its last good parts (already hidden). Remove the values and **Reindex** |

The list says what was found, by kind and count — never the values: *Holds
secrets or personal data: 1 card number, 1 JWT. They are hidden in its parts.*
(or *The AI gets them as written* while the source keeps them).
The re-index toast says it too, and the Audit Log entry of a re-index
(`ai-knowledge.source.reindex`) carries the counts (`sensitiveFound`).

A *Hide them* source's parts are checked again whenever they are read
(Preview, every AI feature, `search_knowledge` in AI tools), so parts indexed
before this check existed, and formats you add later, are hidden without a
re-index. A **Reindex** makes
it permanent in the stored parts.

Only the value is replaced, not the text around it, so the AI still learns
"a test card is used here". The original source text (what you pasted or
uploaded) is kept unchanged so you can edit it; only admins see it.

## Where it is used

| AI feature | Knowledge it gets |
|---|---|
| Request AI (requests, tests, contract rules) | The parts for the request's own endpoint (its method and URL) first, then the rest |
| Scenario assistant | Matching the user's instruction |
| Workspace assistant | Matching the user's question |
| Diagram assistant | Matching the user's instruction |
| AI Testing: writing scenarios from a ticket | Matching the ticket's text. The sources used appear as **Grounded in** under the result |
| AI Testing: runs | Matching the scenario, within the same 6,000 characters. Shown as **Grounded in** under the Run button |
| AI tools (MCP) | The `search_knowledge` tool. The tool asks for what it needs |

How the parts are picked, in this order, within about 6,000 characters per
question:

1. **The endpoint the user is working on.** An OpenAPI operation or collection
   request whose path matches the request's method and URL. Base paths, host
   names and ids are ignored, so `https://pay.bank.local/v2/payments/8f1e/refunds`
   matches `POST /payments/{paymentId}/refunds`.
2. **Always-include sources**, up to 40% of the space.
3. **The best text matches** for the question's words. This is word matching, not
   meaning: "pays 0 AZN" does not find a part titled "Zero amount". Write the
   words people use into your conventions and defect titles. The words are the
   question's own (punctuation removed, common words like "test", "create",
   "screen" left out) and the request's path words; the host, query values and
   ids are not used. A match is sent only if all three hold:
   - it scores at least the **search strictness** share of the best match
     (below);
   - it shares **at least two** of the question's words when the question has
     three words or more. One shared word is never enough then: a part that is
     the only, and so the best, match for one word ("merchant") is not sent;
   - its source has not used up **half of the space** (3,000 of 6,000
     characters) already, so one large source can't push the others out.

The AI is told that conventions are binding, that known defects are things to
check for, and that it must not invent endpoints the knowledge doesn't contain.

The hosted paths (the company's model, an AI connection or a personal key) add
the knowledge on the server. When the user runs a feature on a model on their
own computer, the desktop asks the server for the same knowledge
(`POST /api/ai/grounding`) and adds it itself. AI Testing always works the
second way, whichever AI connection runs its steps. Either way the server
decides what a user may see.

Every AI call that used knowledge lists its sources in **AI audit** (admin
panel), whether the call went through the server or from the desktop.

## How strict the search is

A part found by the search is sent only if it scores at least a set share of the
best match for that question. Set it in the admin panel under **AI Knowledge →
Search strictness**: send every match, 25%, 50% (the default) or 75%. Endpoint
material and sources marked always included are not affected. A change reaches
every backend process within 30 seconds, and Preview on the same page shows the
result.

## Switching it on and off

- The feature flag **AI Knowledge** (`ai_knowledge`, admin panel → Features) is
  on by default. Turning it off for a user or group means their AI gets no
  knowledge. The sources are kept.
- Permissions: viewing the page and the preview needs `ai-knowledge:read`
  (analyst and above). Adding, changing and deleting sources needs
  `ai-knowledge:manage` (admin and super admin). Every change — sources,
  re-indexes and the search strictness — is in the audit log.
- Personal AI-tool tokens read knowledge with the `collections:read` scope.

## Network

- An OpenAPI **URL** is fetched by the Callman **backend and worker**, not by the
  admin's browser, so the URL must be reachable from those containers. Redirects
  are followed. Addresses in `OUTBOUND_DENY_CIDRS` (by default the cloud metadata
  service) are refused, redirects included. Fetches time out after 30 seconds.
- Uploads go through the admin panel's API. If your reverse proxy limits request
  bodies to less than 8 MB for the admin host, raise it or paste smaller files.

## Troubleshooting

| What you see | Why, and what to do |
|---|---|
| Source stays **Error: Could not reach …** | The backend can't reach the URL (DNS, firewall, proxy). Test from the backend container, or upload the file instead |
| **Error: … blocked: the address is in a denied range** | The URL points into `OUTBOUND_DENY_CIDRS`. Use another address or upload the file |
| **The source produced nothing to use** | Empty content, an OpenAPI file without `paths`, or collections without requests |
| **Only the first 5000 parts are used** | Split the source, for example one OpenAPI file per domain |
| **N parts were longer than 1,800 characters; only the start is used** | Rows, requests or an overview that are too long. Split them (one CSV row per defect, shorter test scripts), or move long text under its own heading in a document source |
| **Blocked: secrets or personal data** | The source is set to *Don't index the source* and holds secrets or personal data (listed in the message). Remove them, or switch the setting to *Hide them* |
| **Error**, but the AI still uses the source | The last re-index failed; the parts from the last good index stay in use until one succeeds. Fix the reason and **Reindex**, or turn the source off |
| Preview shows nothing for a group | The source isn't shared with that group (or its tribe), isn't assigned to that feature, or is turned off |
| The AI ignores a convention | Mark the conventions source **Always include**, or put the words people type into its headings |
