# Primitive Swift App Template

A SwiftUI starter app built on `JsBaoClient`. Everything above the client is this app's own code in `Sources/PrimitiveAppTemplate/`: `AppState` (the client and the signed-in account), `AuthModel` (sign-in state), the login, onboarding and profile screens, and `BaoDataLoader`. Change it like any other code.

> **For a tour of the app — source layout, `AppState`, the sign-in flow, and where to add data and views — read [docs/README.md](docs/README.md) first.**

## Using the Primitive Platform

- The Primitive CLI (`primitive-admin` on npm) is required for working with the Primitive platform. Install it globally with `pnpm add -g primitive-admin` (or `npm install -g primitive-admin` if you use npm — pick one manager, not both), then authenticate with `primitive login`.
- This project uses **project mode**: the nearest ancestor `primitive/config.json` — found by walking up from this directory the way git finds `.git` — defines named Primitive environments (e.g. `dev`, `prod`), each binding an `apiUrl` and `appId`. It is the SINGLE place those are typed. Per-environment tokens live in `.primitive/credentials.json` and this machine's selection in `.primitive/local.json` (both gitignored). `primitive init` scaffolds a `dev` environment. It may sit in this directory or, when this client is one of several sharing one Primitive app, at the repo root above it — either way there is exactly ONE, and every `primitive` command run from anywhere inside the tree resolves it, so no command needs a path flag. If no config exists in this directory or any parent, create one with `primitive env add dev --api-url <url> --app-id <appId>`.
- Select the Primitive environment with `primitive env use <name>` (writes the gitignored local selection — no tracked file changes), or per command with `--env <name>` / `PRIMITIVE_ENV`. Resolution order: `--env` → `PRIMITIVE_ENV` → `.primitive/local.json` → the committed `defaultEnvironment` → the sole environment.
- The app reads `primitive.json` (`appId`, `serverUrl`) at runtime, but that file is a **build product** — NEVER edit it and never commit it. `scripts/resolve-primitive-config.sh` regenerates it from the selected environment, and every build path runs it: `./run.sh`, `./build.sh`, `./run-ios.sh`, `./archive.sh`, and an always-run Xcode pre-build phase. Build against a different backend for one run with `./run.sh --primitive-env <name>` (same flag on `run-ios.sh` and `archive.sh`), or `PRIMITIVE_ENV=<name> bundle exec fastlane …`. Each build logs the environment it resolved.
- When another agent or worktree shares the Primitive environment, work on your own child app: `scripts/child-app.sh up <slug>` creates or resumes it, runs this app's `scripts/child-app-init` (seeding is the app's own code there), pushes the tree and selects it — rebuild afterwards so `primitive.json` names the child; `scripts/child-app.sh down <slug>` runs `scripts/child-app-teardown`, which must revoke anything the child created outside the platform, then deletes it (docs/README.md "Child apps for parallel work").
- Before running other CLI commands, run `primitive whoami` to confirm the resolved environment, authenticated user, app ID, and server endpoint match this project.
- ALWAYS fetch the relevant guides before writing code that uses `JsBaoClient` — the guides are the source of truth for how the platform works and are updated more often than this file. Run `primitive guides list` to see available topics and `primitive guides get <topic> --language swift` to retrieve one (always pass `--language swift` for the Swift variant).
- If using Claude Code, the `primitive-platform` skill automates the guides workflow and validates your code against them. Install it with `primitive skill install`, and make sure it's loaded into your context before starting work in this project.

## Build

This app is SPM-based, so **adding a new `.swift` file is just creating it on disk** — both the SPM build and the Xcode project pick it up automatically; no `project.pbxproj` edits.

```sh
swift build          # fastest check that it compiles
./run.sh             # run on macOS (terminal logs)
./run-ios.sh         # run on the iOS Simulator
./test.sh            # run the tests in Tests/ (swift test on the Mac)
./ui-test.sh         # run the XCUITest suite in UITests/ on a dedicated simulator
```

- ALWAYS run `swift build` after making changes and fix any errors.
- `./test.sh` runs the app's tests with `swift test`. They sign in through the OTP test bypass as `PRIMITIVE_TEST_EMAIL` and call the real backend, with no simulator. The tests reach the app's own types with `@testable import PrimitiveAppTemplate`. That address must be whitelisted (`[app].testAccountBaseEmails` in `app.toml`) and admitted (`primitive users invite <app-id> <address>`, or a public app); setup in `docs/README.md` ("Running the tests"). Get a signed-in client in a test with `TestSignIn.client()` (`Tests/PrimitiveAppTemplateTests/Support/SignIn.swift`); `--filter <TestClass>` and other `swift test` arguments pass through.
- `./ui-test.sh` drives the real screens with XCUITest (`UITests/`, an Xcode-only target SwiftPM never sees): code sign-in, onboarding, a profile name edit, invitation accept, sign-out (the avatar is `./test.sh`'s: the Photos picker runs out of process, where XCUITest cannot reach it). It signs in as `PRIMITIVE_TEST_EMAIL`, which must be an address that has never signed in to the app; the invitation test needs `PRIMITIVE_TEST_INVITE_TOKEN` and is skipped without it. Setup in `docs/README.md` ("UI tests").
- Data lives in db3s. The template ships no data model: declare a db3 type in `primitive/<env>/db3-types/<name>.toml`, name it in `Sources/PrimitiveAppTemplate/bao-codegen.json` (`{ "input": "../../primitive/dev/db3-types/<name>.toml" }`, relative to that directory; the shipped `{ "input": null }` means no model yet), and push it with `primitive config push`. The next build emits the type's models into `Sources/PrimitiveAppTemplate/Models/Generated/`. A NEW model is a new file the Xcode project has to list, so run `./run-ios.sh` or `bash scripts/regenerate-project.sh` once; an Xcode build fails naming the file until then. Subscribe with `appState.subscribe(db3:)` and bind a `BaoDataLoader` with `.onModel(subscribe: Model.subscribe)` beside its default db3 triggers. See `primitive guides get databases --language swift`.
- **Generated code is code.** Model types under `Sources/PrimitiveAppTemplate/Models/Generated/` and server-function invokers under `Sources/PrimitiveAppTemplate/Functions/Generated/` are **committed** and reviewed like any other source, and **every scripted and Xcode build path regenerates them**: `./build.sh`, `./run.sh`, `./run-ios.sh`, `./test.sh`, `./ui-test.sh`, `scripts/smoke-test.sh`, `./archive.sh`, the fastlane lanes, and every Xcode entry point (Run, Profile, Archive, a bare `xcodebuild`). They all run `bash scripts/codegen.sh` directly or through `scripts/regenerate-project.sh`; a bare `swift build` compiles what is committed. NEVER edit those files by hand. Change a type, build, and the regenerated output is a working-tree diff you commit **with** the change.
- The function half reads the synced TOMLs (`<project root>/primitive/<env>/functions/`) for the environment the CLI itself would resolve, so an app that has synced none needs no CLI to build.

## Shipping

- **TestFlight and the App Store go through the fastlane lanes, NEVER through `./archive.sh`.** `bundle exec fastlane ios beta` archives, exports and uploads a TestFlight build; `bundle exec fastlane ios release` uploads an App Store build — it does NOT start review, so tell the user to complete the version's metadata in App Store Connect and submit it for review by hand; `bundle exec fastlane bump type:patch` gets the new build number Apple requires for each upload. Run `bundle install` once first. The iOS lanes sign entirely from an App Store Connect API key in `fastlane/.env` — they authenticate the archive with it and fetch the distribution certificate and provisioning profile through it — so they need no Apple ID signed into Xcode and no certificate in the keychain (#3008).
- `./archive.sh {ios|mac|dmg}` is the **Xcode-account** path, not the TestFlight path: it signs through the Apple ID in Xcode → Settings → Accounts and never sees the API key, so on a machine set up as `fastlane/.env.example` prescribes it fails with `error: No Accounts: Add a new account in Accounts settings.` (#3416). That is the machine state, not the project — reach for the beta lane instead. Its `dmg` mode (Developer ID `.app` for direct macOS distribution) has no lane-based equivalent worth avoiding, and `fastlane mac beta` signs through Xcode's account too, so macOS TestFlight does need that Apple ID.
- Distribution setup — Team ID in `project.yml`, creating the API key, registering the app on App Store Connect — is in `docs/README.md` ("Distribution") and, in full, `primitive guides get deploying --language swift`. NEVER commit `fastlane/api_key.p8` or `fastlane/.env`.

## Validating a change in the running app

- `./test.sh` is the first check: the app's own tests drive `AppState`, `AuthModel` and the data loader against the real backend.
- Inspect the backend side — users, db3s, logs, function runs — with the CLI: `primitive guides get inspecting-and-debugging`.
- **Drive the UI with idb.** `scripts/smoke-test.sh` runs simulator smoke tests:

  ```sh
  bash scripts/setup-idb.sh              # installs idb (one command, idempotent) — needed once per machine
  bash scripts/smoke-test.sh ui_signin   # idb-driven: signs in end-to-end, asserts the post-login screen
  bash scripts/smoke-test.sh --list      # launch_survive + ui_signin
  bash scripts/smoke-test.sh             # default run (no idb needed)
  ```

  `ui_signin` is opt-in and needs idb plus a `+primitivetest` test account; its preflight prints the exact setup if a prerequisite is missing.

**Driving the UI ad hoc** (a bug repro, or any tap/typing outside the canned scenario) — use idb for that too. Do NOT drive the app's UI with `osascript` / System Events / macOS accessibility clicking: it makes the user grant assistive access to the whole machine at a permission prompt, it can't see inside a SwiftUI surface, and it taps fixed screen coordinates that break on any layout change. Device-level operations all have real CLI equivalents — reach for `xcrun simctl` (`io booted screenshot`, `openurl`, `privacy`, `erase`) instead of automating the Simulator.app menu bar.

```sh
xcrun simctl list devices booted                   # the booted simulator's UDID
DEVELOPER_DIR="$(bash scripts/idb-developer-dir.sh)" idb_companion --udid <UDID> --grpc-port 10882 &   # start a companion
idb --companion localhost:10882 ui describe-all    # AX tree; a SwiftUI .accessibilityIdentifier shows up as AXUniqueId
idb --companion localhost:10882 ui tap <X> <Y>     # tap the center of that element's frame, in integer points
idb --companion localhost:10882 ui text "hello"    # type into the focused field
idb --companion localhost:10882 ui key 40          # 40 = Return
xcrun simctl io booted screenshot /tmp/shot.png    # see what happened
```

These ad-hoc commands need `idb` on PATH, which `bash scripts/setup-idb.sh` arranges via `~/.local/bin` (the smoke test finds its client without any PATH change). If `idb` still isn't found after setup, either add the line the script prints — `export PATH="$HOME/.local/bin:$PATH"` — or call the venv binary directly at `~/.local/share/primitive/idb-venv/bin/idb`.

**Start the companion through `scripts/idb-developer-dir.sh`, as above.** `idb_companion` loads SimulatorKit — the framework behind every HID call (`ui tap`, `ui text`, `ui key`) — from `$DEVELOPER_DIR/Library/PrivateFrameworks`, and Xcode 27 moved it to `Xcode.app/Contents/SharedFrameworks`. Start the companion plainly on that Xcode and `describe-all` still works while every tap fails with `SimulatorKit is required for HID interactions: … but it does not exist`. That script prints a `DEVELOPER_DIR` where the framework is — a symlink mirror of the Xcode bundle, built on first use, nothing written inside `Xcode.app` and no root — and on an older Xcode it prints the active developer directory unchanged. `scripts/smoke-test.sh ui_signin` calls it itself, so the scenario needs no setup beyond `scripts/setup-idb.sh`.

The stable accessibility identifiers are `primitive.login.emailField`, `primitive.login.emailSubmit`, `primitive.login.otpField`, `primitive.login.otpVerify`, `primitive.onboarding.nameField`, `primitive.onboarding.continue`, `primitive.passkey.notNow`, `primitive.template.home` and the `primitive.profile.*` controls. Keep them when you restyle a screen.

## Data-side patterns

When adding data, queries, writes, or auth flows, fetch the matching guide first — `primitive guides get databases --language swift`, `primitive guides get authentication --language swift`. The guides are written against this same client.

## Email sign-in links

Email sign-in works out of the box and needs no app settings: with no web origin configured, the client sends no link target, so the server emails a 6-digit code alone. That code is the credential that always works — including in the Simulator, where a custom-scheme link cannot open anything.

**If this app has a web counterpart, the link should be an https URL.** Add `"webUrl": "https://<your-web-domain>"` to the environment in `primitive/config.json` (`primitive env add` takes `--web-url` when it CREATES an environment; it cannot edit one that already exists). It must be a bare origin — https, or http on `localhost`/`127.0.0.1`. `AppState` sets it as the client's `links.appBaseURL`, and the client then asks for `https://<your-web-domain>/oauth/callback` as the email's link with no code change. Tapped on a device with this app installed it opens the app (a universal link); anywhere else it is an ordinary web sign-in. Allow-list that https URL as below, serve `apple-app-site-association` from the web domain (the web template ships the file and the checklist under `public/.well-known/`), and enable the `applinks:` entitlement in `project.yml` last — the commented block there says why that order matters. `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` in `ContentView` receives such a link on macOS and on hand-off.

To send a custom-scheme LINK instead (an app with no web client), two things have to be true, and each missing piece fails differently:

1. **Allow-list the URI.** Merge `<scheme>://oauth/callback` into the existing `[auth].emailRedirectUris` array in the app's `primitive/<env>/app.toml` (run `primitive config pull --only app` first if that file isn't there yet), then `primitive config push --only app` — never a bare replacement array; `app.toml` is the whole app-settings truth on push. Missing → EVERY email sign-in request fails 400 `Invalid redirect URI`.
2. **Set the `PrimitiveOAuthRedirectURI` key** in `Info-Partial.plist` to that same `<scheme>://oauth/callback`. `AppState` passes it to the client as its `oauthRedirectUri`, which points the link there and accepts the callback when it opens the app. Missing → the email is code-only (no error).

The scheme itself is already registered in `Info-Partial.plist` (`primitive init` stamps an app-unique one there; an unregistered scheme makes the link a dead tap), and `ContentView`'s `.onOpenURL` → `routePlatformLink` hands the URL to the client (unrouted → the app opens and nobody signs in).

A custom-scheme link only opens on a device with the app installed, so it is dead cross-device and in the Simulator, and many webmail clients won't render a non-http(s) href as a link at all. Full checklist and symptoms: `primitive guides get authentication --language swift`.
