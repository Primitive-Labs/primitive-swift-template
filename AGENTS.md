# Primitive Swift App Template

A SwiftUI starter app built on the `PrimitiveApp` library and `JsBaoClient`.

> **For a tour of the app — source layout, the `TemplateAppState` pattern, the login flow, and where to add models and views — read [docs/README.md](docs/README.md) first.**

## Using the Primitive Platform

- The Primitive CLI (`primitive-admin` on npm) is required for working with the Primitive platform. Install it globally with `pnpm add -g primitive-admin` (or `npm install -g primitive-admin` if you use npm — pick one manager, not both), then authenticate with `primitive login`.
- This project uses **project mode**: the nearest ancestor `.primitive/config.json` — found by walking up from this directory the way git finds `.git` — defines named Primitive environments (e.g. `dev`, `prod`), each binding an `apiUrl` and `appId`. It is the SINGLE place those are typed. Per-environment tokens live in `.primitive/credentials.json` and this machine's selection in `.primitive/local.json` (both gitignored). `primitive init` scaffolds a `dev` environment. It may sit in this directory or, when this client is one of several sharing one Primitive app, at the repo root above it — either way there is exactly ONE, and every `primitive` command run from anywhere inside the tree resolves it, so no command needs a path flag. If no config exists in this directory or any parent, create one with `primitive env add dev --api-url <url> --app-id <appId>`.
- Select the Primitive environment with `primitive env use <name>` (writes the gitignored local selection — no tracked file changes), or per command with `--env <name>` / `PRIMITIVE_ENV`. Resolution order: `--env` → `PRIMITIVE_ENV` → `.primitive/local.json` → the committed `defaultEnvironment` → the sole environment.
- The app reads `primitive.json` (`appId`, `serverUrl`) at runtime, but that file is a **build product** — NEVER edit it and never commit it. `scripts/resolve-primitive-config.sh` regenerates it from the selected environment, and every build path runs it: `./run.sh`, `./build.sh`, `./run-ios.sh`, `./archive.sh`, and an always-run Xcode pre-build phase. Build against a different backend for one run with `./run.sh --primitive-env <name>` (same flag on `run-ios.sh` and `archive.sh`), or `PRIMITIVE_ENV=<name> bundle exec fastlane …`. Each build logs the environment it resolved.
- Before running other CLI commands, run `primitive whoami` to confirm the resolved environment, authenticated user, app ID, and server endpoint match this project.
- ALWAYS fetch the relevant guides before writing code that uses `PrimitiveApp` or `JsBaoClient` — the guides are the source of truth for how the platform works and are updated more often than this file. Run `primitive guides list` to see available topics and `primitive guides get <topic> --language swift` to retrieve one (always pass `--language swift` for the Swift variant).
- If using Claude Code, the `primitive-platform` skill automates the guides workflow and validates your code against them. Install it with `primitive skill install`, and make sure it's loaded into your context before starting work in this project.

## Build

This app is SPM-based, so **adding a new `.swift` file is just creating it on disk** — both the SPM build and the Xcode project pick it up automatically; no `project.pbxproj` edits.

```sh
swift build          # fastest check that it compiles
./run.sh             # run on macOS (terminal logs)
./run-ios.sh         # run on the iOS Simulator
```

- ALWAYS run `swift build` after making changes and fix any errors.
- Models are defined in `Sources/PrimitiveAppTemplate/Models/models.toml` — or, when this client shares one Primitive app with another (a web client in a sibling directory), in the file named by `Sources/PrimitiveAppTemplate/bao-codegen.json` (`{"input": "../../../models/models.toml"}`, resolved against the app's source directory). ONE schema per app either way: its TOML keys are the wire field names, so a second copy that drifts orphans the other one's records. `swift build` runs codegen automatically, and the Xcode targets run it from a pre-build phase, so every build path compiles the current schema. Adding a NEW model also needs the new file listed in the Xcode project before a build can see it — run `./run-ios.sh`, or the pair it runs (`bash scripts/codegen.sh && bash scripts/regenerate-project.sh`), since `xcodegen` can only list a file that already exists. Until then an Xcode build fails naming the file. NEVER edit files under `Models/Generated/` — they are regenerated on every build. See `primitive guides get models --language swift`.
- Workflow factories under `Sources/PrimitiveAppTemplate/Workflows/Generated/` and database types under `Sources/PrimitiveAppTemplate/Databases/Generated/` are generated from the synced workflow / database-type TOMLs (`<project root>/.primitive/sync/<env>/<appId>/`) and **committed**, so no build regenerates them on its own. `./run.sh`, `./run-ios.sh` and `scripts/smoke-test.sh` do, through `bash scripts/codegen.sh` — the one entry point that runs all three codegens (the model half is `scripts/generate-models.sh`, which the Xcode pre-build phase also runs). NEVER edit those files by hand. After changing a workflow or database-type schema, or upgrading the CLI, run `bash scripts/codegen.sh` and commit the result.
- `bash scripts/codegen.sh --check` is the drift guard: it fails if the committed factories or database types no longer match what the CLI emits, and writes nothing. It reads local TOML only — no network, no login, no toolchain — so wire it into a pre-commit hook or a CI job.
- `./archive.sh` runs that same `--check` before it archives and refuses to build a shippable artifact against stale committed sources. It does not regenerate for you: run `bash scripts/codegen.sh`, commit, then archive.

## Validating a change in the running app

Two dev tools cover different halves of "does my change work," and they pair up:

1. **Debug Inspector** — a dev-only dashboard the app serves in DEBUG builds (open the `http://localhost:9999` URL it prints on launch). Use it to inspect client **state**: browse documents and records, run in-app tests, inspect blobs. It asserts data and logic, out-of-band.
2. **idb UI smoke test** — drives the app's **UI** headlessly (tap, type, read the accessibility tree), which the Inspector can't do. Run it with:

   ```sh
   bash scripts/setup-idb.sh              # installs idb (one command, idempotent) — needed once per machine
   bash scripts/smoke-test.sh ui_signin   # idb-driven: signs in end-to-end, asserts the post-login screen
   bash scripts/smoke-test.sh --list      # launch_survive + ui_signin
   bash scripts/smoke-test.sh             # default run (no idb needed)
   ```

   `ui_signin` is opt-in and needs idb plus a `+primitivetest` test account; its preflight prints the exact setup if a prerequisite is missing. The framing: **idb drives the UI, the Inspector asserts the resulting state.**

**Driving the UI ad hoc** (a bug repro, or any tap/typing outside the canned scenario) — use idb for that too. Do NOT drive the app's UI with `osascript` / System Events / macOS accessibility clicking: it makes the user grant assistive access to the whole machine at a permission prompt, it can't see inside a SwiftUI surface, and it taps fixed screen coordinates that break on any layout change. Device-level operations all have real CLI equivalents — reach for `xcrun simctl` (`io booted screenshot`, `openurl`, `privacy`, `erase`) instead of automating the Simulator.app menu bar.

```sh
xcrun simctl list devices booted                   # the booted simulator's UDID
idb_companion --udid <UDID> --grpc-port 10882 &    # start a companion
idb --companion localhost:10882 ui describe-all    # AX tree; a SwiftUI .accessibilityIdentifier shows up as AXUniqueId
idb --companion localhost:10882 ui tap <X> <Y>     # tap the center of that element's frame, in integer points
idb --companion localhost:10882 ui text "hello"    # type into the focused field
idb --companion localhost:10882 ui key 40          # 40 = Return
xcrun simctl io booted screenshot /tmp/shot.png    # see what happened
```

These ad-hoc commands need `idb` on PATH, which `bash scripts/setup-idb.sh` arranges via `~/.local/bin` (the smoke test finds its client without any PATH change). If `idb` still isn't found after setup, either add the line the script prints — `export PATH="$HOME/.local/bin:$PATH"` — or call the venv binary directly at `~/.local/share/primitive/idb-venv/bin/idb`.

For what the installer does (including the Python 3.12 requirement for `fb-idb`), the `+primitivetest` prerequisite, and the full command reference, read the DevTools guide:

```sh
primitive guides get devtools --language swift
```

## Data-side patterns

When adding models, queries, writes, or auth flows, fetch the matching guide first — e.g. `primitive guides get documents --language swift`. The guides are written against this same library.

## Email sign-in links

Email sign-in works out of the box and needs no app settings: `PrimitiveAuthManager` sends no redirect target, so the server emails a 6-digit code alone. That code is the credential that always works — including in the Simulator, where a custom-scheme link cannot open anything.

To also send a LINK that opens this app, two things have to be true, and each missing piece fails differently:

1. **Allow-list the URI.** Merge `<scheme>://auth/magic-link` into the existing `[auth].emailRedirectUris` array in the app's `config/app.toml` (run `primitive config pull --only app` first if that file isn't there yet), then `primitive config push --only app` — never a bare replacement array; `app.toml` is the whole app-settings truth on push. Missing → EVERY email sign-in request fails 400 `Invalid redirect URI`.
2. **Set `authManager.sendsEmailSignInLink = true`** before requesting the email. Missing → the email is code-only (no error).

The other two pieces this template already ships: the scheme is registered in `Info-Partial.plist` under the `PrimitiveAuth` URL type (`primitive init` stamps an app-unique one there, and the manager reads its `callbackScheme` from that same entry — an unregistered scheme makes the emailed link a dead tap), and `ContentView`'s `.onOpenURL` → `routePlatformLink` routes the incoming URL (unrouted → the app opens and nobody signs in). That scheme also carries the OAuth callback, `<scheme>://oauth/callback`, when you use `startOAuth()`.

A custom-scheme link only opens on a device with the app installed, so it is dead cross-device and in the Simulator, and many webmail clients won't render a non-http(s) href as a link at all. Full checklist and symptoms: `primitive guides get authentication --language swift`.
