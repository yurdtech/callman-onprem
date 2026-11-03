# Third-party components of the desktop's AI testing

This page names what the Callman desktop's **AI Testing** runs on and what it
sends where. It describes desktop **2.0.15**.

## Callman's own agent

AI Testing runs on Callman's own agent code inside the desktop app — for web,
Android and iOS runs and for writing test scenarios. It downloads and runs no
third-party agent, Python runtime or package manager. (Earlier preview builds
installed an upstream open-source Python agent with its own runtime and an
on-device companion app; that engine has been removed, and the app deletes the
files it left behind when it starts.)

| Component | Used for | Where it comes from |
| --- | --- | --- |
| **Playwright** (`playwright-core`, Apache-2.0) | Driving the browser in web runs | Part of the desktop app; the browser itself is downloaded once per machine from the Playwright CDN ([NETWORK.md](NETWORK.md#outbound-from-a-users-workstation-desktop-app)) |
| **Android platform tools** (`adb`) | Android devices and emulators | The tester's own Android SDK |
| **The flow-engine module** (`callmanui.jar`, see below) | On Android: the screen's element tree and screenshots through its on-device driver. On iOS: every gesture and keystroke through its XCUITest runner | Downloaded on first use, not part of the installer |
| **Xcode** (`xcrun simctl`) | iOS simulators: listing, launching apps, frames | The tester's Mac |
| **Callman keyboard** | Typing on Android devices | Callman; ships inside the desktop app and is installed on the device for the run |

## What a run sends, and where

- **To the AI connection the tester picked**, on every step: the scenario text
  with its test data filled in, the screen's element list and, when the step
  needs it, a screenshot. Which way it goes depends on the connection:
  - a **server connection** (the company key, an AI connection, or the user's
    personal key) — from the desktop to your Callman server, which calls the
    provider; the server never logs the step's text or screenshot;
  - a **subscription or CLI on the computer** — from the tester's computer
    straight to the provider;
  - a **model the tester runs** (Ollama) — to that model; with a local one
    nothing leaves the computer.

  The administrator decides which of these AI Testing may use
  ([AI-POLICY.md](AI-POLICY.md)).
- **To nobody else.** The agent sends no analytics and makes no update or
  download calls of its own.

## The UI-test flow engine

Recorded UI tests (mobile flows, branded **M** in the product) run on the
flow-engine module: Callman's packaging of an open-source mobile UI-testing
engine (Apache-2.0) — its runner (a Java program, run with the tester's Java
runtime), its Android on-device driver (shown as **Callman Driver**) and its
iOS XCUITest runner. Flows use no AI agent and no model provider; AI Testing
on Android and iOS uses the module's drivers as listed above.

- **Where it comes from.** The desktop downloads the module the first time a
  mobile flow or a mobile AI run needs it, into the user's profile
  (`~/.callman/modules/`). On-prem it comes only from your Callman server,
  where an admin uploaded it, with its SHA-256 checked
  ([DESKTOP-APP.md](DESKTOP-APP.md#10-desktop-modules)). It is not part of
  the installer.
- **Its licenses.** The module carries the engine's Apache-2.0 license and
  NOTICE, but it bundles many libraries (it is a single ~140 MB Java archive)
  and does **not** yet carry a complete attribution list for them. That list
  is produced with the module build; until it ships, ask us for it.

## Licenses and the SBOM

Every release ships the attribution of what it contains and a CycloneDX SBOM
(software bill of materials) of its production dependencies:

| Part | Third-party notices | SBOM |
| --- | --- | --- |
| Desktop app | `resources/licenses/THIRD-PARTY-NOTICES.txt` in the installed app | `resources/licenses/sbom.cdx.json` |
| Backend image | `/app/licenses/THIRD-PARTY-NOTICES.txt` | `/app/licenses/sbom.cdx.json` (npm packages); the whole image — OS packages included — as a BuildKit SBOM attestation on the image (`docker buildx imagetools inspect <image> --format "{{ json .SBOM }}"`) |
| Admin panel image | `/repo/licenses/THIRD-PARTY-NOTICES.txt` | `/repo/licenses/sbom.cdx.json`, and the image attestation as above |

Copy them out of an image with
`docker run --rm --entrypoint cat <image> /app/licenses/sbom.cdx.json > sbom.json`.

Each build checks every production dependency's license against an allowlist
(permissive licenses, plus MPL-2.0, EPL-2.0 and OFL-1.1 for fonts) and stops on
anything else. Packages that needed a decision:

| Package | License | Decision |
| --- | --- | --- |
| `dompurify` | MPL-2.0 or Apache-2.0 | Used under Apache-2.0, unmodified |
| `elkjs` (diagram layout) | EPL-2.0 or GPL-3.0 | Used under EPL-2.0, unmodified; Callman's own code is not EPL-covered |
| `bpmn-js` (BPMN diagrams) | MIT with the bpmn.io condition | The bpmn.io watermark stays visible on rendered diagrams |
| `domutils`, `css-select` | no SPDX id in the package | Their license files are BSD-2-Clause |
| `khroma` | no license field | Its license file is MIT |
| `tv4` | public domain | Treated as Unlicense |
| `oracledb` | Apache-2.0 or UPL-1.0 | Used under Apache-2.0 |
