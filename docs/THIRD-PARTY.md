# Third-party components of the desktop's AI testing

This page names what the Callman desktop's **AI Testing** runs on and what it
sends where. It describes desktop **2.0.14** (on-prem 1.0.6).

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
| **Xcode** (`xcrun simctl`) and Callman's XCUITest runner | iOS simulators | The tester's Mac; the runner is part of the desktop app |
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

Recorded UI tests (web and mobile flows, branded **M** in the product) run on
Callman's own runner and on-device driver (**Callman Driver**); they do not use
the AI agent or any model provider.
