# AI policy: which AI each feature may use

Callman's AI features can reach a model in several ways. The **AI policy**
decides, per feature, which of them are allowed. It answers "which provider
does our data go to, and who decides": the administrator, in one table.

Admin panel → **AI Settings** → **AI policy**.

## Sources

| Source | What it is | Where requests go from |
|---|---|---|
| **AI connections** | A connection you share with groups under **Managed connections** (provider, key and model you choose) | The Callman server |
| **Company key** | The provider and key at the top of **AI Settings**: OpenAI, Anthropic, Google (Gemini), DeepSeek, or an OpenAI-compatible server you run (base URL and model required) | The Callman server |
| **Personal keys** | API keys a user saves for themselves in the desktop app (**Settings → AI**), one per provider — the same providers as the company key; stored encrypted on the server | The Callman server |
| **Accounts on the computer** | A provider the user signs in to on their own computer: a Claude, ChatGPT or Gemini subscription signed in from the app, or a CLI (Claude, Codex, Gemini, Cursor) | The user's computer, straight to the provider |
| **Self-run models** | A model the user or your company runs itself, such as Ollama | The user's computer, to that model |

## Features

| Feature | Sources it can use |
|---|---|
| Request AI | AI connections, company key, personal keys, accounts on the computer |
| Scenario assistant | the same |
| Workspace assistant | the same |
| Diagram assistant | the same |
| AI Testing (writing scenarios and runs) | All five: AI connections, company key, personal keys, accounts on the computer, self-run models |

A box you untick takes that source away from that feature for everyone:

- **On the server.** A request from Request AI, an assistant or an AI Testing
  step through a source the feature may not use is refused (`403
  AI_SOURCE_NOT_ALLOWED`, with the sources that are allowed). On older desktops,
  which don't name the source, a personal key that isn't allowed is skipped and
  the company key answers instead if it is allowed.
- **In the desktop app (2.0.14+).** Sources that aren't allowed disappear from the
  feature's model list. AI Testing also lists only models that can read
  screenshots. If the source someone used last is no longer allowed, the app
  switches to one that is. The app checks the policy before every request on the
  computer. It picks up a change within about a minute.

AI Testing sends a screenshot and the page structure with each step. With a
server source (AI connection, company key, personal key) those go from the
Callman server to the provider; with an account on the computer or a self-run
model they go from the user's computer.

"Accounts on the computer" and "self-run models" never touch the server, so
the server can't block them. The desktop app enforces them. Older desktops
(before 2.0.14) don't read the policy. To keep data off unapproved providers,
make sure everyone updates ([DESKTOP-APP.md](DESKTOP-APP.md)), and block the
provider hosts at your proxy as well ([NETWORK.md](NETWORK.md)).

## Defaults and related settings

- **Nothing is restricted until you save the policy.** Every source is allowed,
  exactly as before.
- **A policy saved before AI Testing could use the server sources** keeps what
  you chose for "accounts on the computer" and "self-run models"; AI
  connections, the company key and personal keys are allowed for AI Testing
  until you untick them and save. The first save writes every feature's choice
  out explicitly, so nothing else changes.
- A feature with no box ticked doesn't work for anyone. The page warns about
  this. To switch a feature off for *some* people only, use **Features** (the
  `ai`, `ai_scenario`, `ai_assistant`, `ai_diagram` and `ai_testing` flags).
- Who can see the policy: `ai-settings:read`. Who can change it:
  `ai-settings:manage`. Every change is in the audit log as `ai-policy.update`,
  with each feature's sources before and after.
- The scenario **AI node** (a step in a scenario run on the server) uses the AI
  connection the step names. The policy doesn't cover it.
