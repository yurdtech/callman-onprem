# App builds — from CI to a tester's emulator in one click

Your Android and iOS teams already build their apps in CI (GitHub Actions,
GitLab CI, Jenkins, Bitrise, Azure DevOps…). **App builds** gets those builds
to QA without anyone passing files around:

1. The last step of the pipeline runs one line —
   `callme build publish app-debug.apk`.
2. The file goes into **your** storage (the provider you connected under
   **Storage** in the admin panel — see [STORAGE.md](STORAGE.md)). Nothing
   leaves your network.
3. In the Callman desktop app, testers open **Builds**, pick a build and press
   **Install on emulator** / **Install on simulator**. The desktop downloads it,
   verifies its checksum, boots the device if needed, installs and launches the
   app.

Builds are grouped in **folders**. By default the folder is the platform
(`android`, `ios`); a pipeline can choose its own, such as `android/release` or
`ios/feature-login`. Every build shows its version, build number, app id, size,
sha256, branch and commit, a link back to the pipeline run, release notes and
who published it.

## Requirements

- The **storage gateway is enabled** and an **active provider** is connected —
  follow [STORAGE.md](STORAGE.md) first. App builds are stored there and
  nowhere else. On a deployment without it, `/api/app-builds` answers `404`.
- `CALLMAN_STORAGE_PUBLIC_URL` is set (STORAGE.md, step 2b). It is the base of
  every build's download link.
- Your reverse proxy routes `/storage/` to the gateway **with the large-body
  settings** from STORAGE.md — builds are 50–300 MB.
- **callme-cli 1.8.0 or newer** on the CI runner (`npm i -g callme-cli`).
- The desktop app on testers' machines; the **Builds** page appears only on
  on-prem deployments. Installing on an emulator/simulator needs the Android
  SDK (Android) or Xcode (iOS, macOS only) on that machine.

No new `.env` settings are needed.

## Create a CI token

The pipeline authenticates with a **workspace CI token** that carries the
**`builds:publish`** scope. A workspace owner creates it once:

- In the desktop: **Workspace Settings → CI Tokens → New token**, tick
  **Publish app builds**.
- Or over the API with your own session:

  ```bash
  curl -X POST https://callman.yourbank.local/api/api-tokens \
    -H "Authorization: Bearer <your access token>" \
    -H "x-workspace-id: <workspace id>" \
    -H "Content-Type: application/json" \
    -d '{"name":"mobile-ci","scopes":["builds:publish"],"expiresInDays":365}'
  ```

The token is shown **once** — store it as a secret in your CI system
(`CALLME_TOKEN`). It is bound to that one workspace. With `builds:publish` it
can upload app builds, publish, list and delete them; it **cannot** upload any
other kind of file, read other files, or touch the rest of the workspace. A
token that should only list builds (a dashboard, a release script) needs just
`builds:read`.

Every pipeline needs four variables:

| Variable | Value |
|---|---|
| `CALLME_API_URL` | `https://callman.yourbank.local` — the address users reach Callman on |
| `CALLME_STORAGE_URL` | Only if the gateway is **not** behind the same hostname on `/storage/` (e.g. `http://callman-host:8081`). Otherwise leave it unset. |
| `CALLME_TOKEN` | The CI token (secret) |
| `CALLME_WORKSPACE_ID` | The workspace id |

## Pipeline examples

`callme build publish` reads the app id, version, build number and SDK
levels from the file itself, and picks up branch, commit and the pipeline link
from the CI's own environment variables. Flags (`--app-id`, `--version`,
`--build-number`, `--folder`, `--notes`, `--notes-file`) override anything it
detects. Add `--json` to get the published build as JSON on stdout.

### GitHub Actions — Android

```yaml
jobs:
  android:
    runs-on: ubuntu-latest
    env:
      CALLME_API_URL: https://callman.yourbank.local
      CALLME_TOKEN: ${{ secrets.CALLME_TOKEN }}
      CALLME_WORKSPACE_ID: ${{ vars.CALLME_WORKSPACE_ID }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: "17" }
      - run: ./gradlew assembleDebug
      - run: npm i -g callme-cli
      - run: callme build publish app/build/outputs/apk/debug/app-debug.apk --notes "${{ github.event.head_commit.message }}"
```

### GitHub Actions — iOS simulator

Only a build made **for the simulator** (`-sdk iphonesimulator`) can be
installed on a simulator. Publish the `.app` folder; the CLI zips it for you.

```yaml
jobs:
  ios:
    runs-on: macos-14
    env:
      CALLME_API_URL: https://callman.yourbank.local
      CALLME_TOKEN: ${{ secrets.CALLME_TOKEN }}
      CALLME_WORKSPACE_ID: ${{ vars.CALLME_WORKSPACE_ID }}
    steps:
      - uses: actions/checkout@v4
      - run: |
          xcodebuild -scheme MyApp -sdk iphonesimulator -configuration Debug \
            -derivedDataPath build build
      - run: npm i -g callme-cli
      - run: callme build publish build/Build/Products/Debug-iphonesimulator/MyApp.app --folder ios/${GITHUB_REF_NAME//\//-}
```

### GitLab CI

```yaml
publish-android:
  stage: deploy
  image: node:20
  variables:
    CALLME_API_URL: https://callman.yourbank.local
    # CALLME_TOKEN and CALLME_WORKSPACE_ID: masked CI/CD variables
  script:
    - npm i -g callme-cli
    - callme build publish app/build/outputs/apk/debug/app-debug.apk --folder android/$CI_COMMIT_REF_SLUG
  needs: [assemble-debug]
```

### Jenkins

```groovy
stage('Publish build') {
  environment {
    CALLME_API_URL      = 'https://callman.yourbank.local'
    CALLME_TOKEN        = credentials('callme-ci-token')
    CALLME_WORKSPACE_ID = '<workspace id>'
  }
  steps {
    sh 'npm i -g callme-cli'
    sh 'callme build publish app/build/outputs/apk/release/app-release.apk --folder android/release'
  }
}
```

Publishing is **idempotent**: re-running a job with the same file into the same
folder returns the existing build (`duplicate: true`) instead of creating a
second one, so CI retries are safe.

## Folders

- Default: the platform — `android` or `ios`.
- Up to **3 levels** separated by `/`, at most **120 characters**.
- Each level uses only `a-z`, `0-9`, `.`, `_` and `-`. Upper case is lowered
  for you (`Android/Release` → `android/release`); `..`, empty levels and
  spaces are refused.
- Builds in a folder are numbered `#1, #2, #3…` in publish order. Numbers are
  never reused; a number can occasionally be skipped.

## What can be installed

| File | Stored and listed | One-click install |
|---|---|---|
| `.apk` | yes | Android emulator |
| `.app` built with `-sdk iphonesimulator` (published as a zip) | yes | iOS simulator (macOS) |
| `.aab` (App Bundle) | yes | **no** — publish an `.apk` (e.g. `assembleDebug`) for testers |
| `.ipa` (device build) | yes | **no** — a device build cannot run on a simulator |

On Apple Silicon Macs the Android emulator is `arm64-v8a`; an APK that only
contains `x86_64` native libraries will not install there. The desktop's error
message lists the ABIs the build contains.

## Size limit

Uploads are capped by `STORAGE_MAX_UPLOAD_BYTES` (default **500 MB**), checked
before a byte is transferred. iOS builds can be bigger; if you raise the limit,
raise your reverse proxy's / ingress's body limit as well (STORAGE.md →
[Route it through your reverse proxy](STORAGE.md#route-it-through-your-reverse-proxy);
on Kubernetes `nginx.ingress.kubernetes.io/proxy-body-size`).

## If something's off

| Symptom | Cause / fix |
|---|---|
| `404` from `/api/app-builds`, or the CLI says "App builds are available only on Callman on-prem" | The backend is not running as on-prem, or it is a version without app builds. Check `CALLMAN_EDITION=onprem` and `CALLMAN_VERSION`. |
| `No storage provider is active…` | The storage gateway is on but no provider is set as active. Admin panel → **Storage**. |
| `403 PAT_SCOPE_MISSING` | The CI token lacks `builds:publish` (or `builds:read` for listing). Scopes are fixed at creation — create a new token. |
| `403 PAT_ROUTE_FORBIDDEN` on `/storage/files` | A CI token tried something other than uploading a build (listing or downloading files). That is not allowed for CI tokens. |
| `403 STORAGE_KIND_FORBIDDEN_FOR_TOKEN` | A CI token tried to upload a file that is not an app build. Use `callme build publish`. |
| `403 WORKSPACE_ACCESS_DENIED` | `CALLME_WORKSPACE_ID` is not the workspace the token was created in. |
| `413` / upload fails at exactly 1 MB | Your reverse proxy's body limit, or the file is bigger than `STORAGE_MAX_UPLOAD_BYTES`. |
| `409 APP_BUILD_FILE_NOT_READY` | The upload did not finish before the build was published. Re-run the job — uploads restart from the beginning. |
| `422 STORAGE_CHECKSUM_MISMATCH` ("bytes do not match the declared sha256") | The file changed or was corrupted in transit. Nothing was stored; the CLI retries once by itself. |
| `422 APP_BUILD_FILE_KIND_MISMATCH` | The file's extension does not match its type (e.g. an `.aab` published as an APK). Check the path you pass. |
| `400 APP_BUILD_INVALID_FOLDER` | The `--folder` breaks the rules above. |
| The job "succeeds" but no new build appears | It was the same file into the same folder — the response says `duplicate: true` and points at the existing build. |
| **Install** is greyed out | The build is an `.aab`, a device `.ipa` or a device `.app`; the tooltip says which. iOS installs also need macOS. |

More general issues: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
