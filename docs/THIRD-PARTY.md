# Third-party components of the desktop's AI testing

This page names the open-source components the Callman desktop's **AI Testing**
runs on, the versions each release pins, and what they send where. It describes
desktop **2.0.14** (on-prem 1.0.6).

## The AI engine

| Component | Version | License | Supplier |
| --- | --- | --- | --- |
| **Mobilerun** (formerly DroidRun) — the agent that drives Android and iOS devices; Python package `mobilerun` | **0.6.11** (pinned) | MIT | Mobilerun / DroidRun project, `github.com/droidrun/mobilerun` |
| `mobilerun-core-local` — its device driver | 0.6.0 (a dependency of the pinned engine) | MIT | same project |
| **truststore** — makes the engine verify TLS against the operating system's certificate store | 0.10.4 (pinned) | MIT | `github.com/sethmlarson/truststore` |
| **uv** — creates the engine's Python environment and installs its packages | 0.12.0 (pinned, sha256-checked) | MIT or Apache-2.0 | Astral, `github.com/astral-sh/uv` |
| **CPython** | 3.12 | PSF License | python.org (the standalone build uv installs) |

The engine runs on the tester's computer, in its own Python environment under
`~/.callman/ai-engine`. Every desktop release pins the engine version; a release
that moves it says so in its notes. The engine's on-device companion is the
**Callman Agent** app (Android package id `com.mobilerun.portal`), Callman's
build of the engine's companion app; Callman installs it and grants it only the
notification permission ([POC-EVALUATION-GUIDE.md](POC-EVALUATION-GUIDE.md)).

## What the engine sends, and where

- **To the AI provider the tester picked**, on every step: the scenario text
  with its test data filled in, the screen's element list and, when *Vision*
  is on, a screenshot. With a local model (Ollama) nothing leaves the computer.
- **To nobody else.** The engine ships anonymous usage analytics switched on by
  default (task text, visited screens, model settings — sent to a third-party
  analytics service). Callman switches it off for every engine process it
  starts, in two independent ways: the engine's own opt-out variables are set
  on every spawn, and Callman's patch inside the engine makes its analytics
  module inert, so nothing is sent and no persistent analytics id is written
  (an id left by an older build in `~/.droidrun/user_id` is deleted). The
  engine's update and companion-app downloads from its upstream project are
  closed the same way: it never contacts the project's servers.
- **First-use downloads.** Installing the engine fetches uv, Python and the
  packages above from GitHub and PyPI — unless your server has an **AI engine
  bundle** for the platform, in which case everything comes from your server
  and nothing from the internet ([NETWORK.md](NETWORK.md#outbound-from-a-users-workstation-desktop-app)).

## The UI-test flow engine

Recorded UI tests (web and mobile flows, branded **M** in the product) run on
Callman's own runner and on-device driver (**Callman Driver**); they do not use
the AI engine or any model provider.
