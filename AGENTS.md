# Primitive Swift App Template

A SwiftUI starter app built on the `PrimitiveApp` library and `JsBaoClient`.

> **For a tour of the app — source layout, the `TemplateAppState` pattern, the login flow, and where to add models and views — read [docs/README.md](docs/README.md) first.**

## Using the Primitive Platform

- The Primitive CLI (`primitive-admin` on npm) is required for working with the Primitive platform. Install it globally with `pnpm add -g primitive-admin` (or `npm install -g primitive-admin` if you use npm — pick one manager, not both), then authenticate with `primitive login`.
- This project uses **project mode**: a checked-in `.primitive/config.json` defines named environments (e.g. `dev`, `prod`), each binding an `apiUrl` and `appId`. Per-environment tokens live in `.primitive/credentials.json` (gitignored). `primitive init` scaffolds a `dev` environment; if the config file is missing, create it with `primitive env add dev --api-url <url> --app-id <appId>`. Select an environment with `--env <name>`, the `PRIMITIVE_ENV` env var, or `primitive env use <name>`.
- The app itself reads [`primitive.json`](primitive.json) (`appId`, `serverUrl`) at runtime. `primitive init` fills it in; keep it pointing at the same app as the active CLI environment.
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
- Models are defined in `Sources/PrimitiveAppTemplate/Models/models.toml`; `swift build` runs codegen automatically (the Xcode/iOS path runs it from `run-ios.sh`). NEVER edit files under `Models/Generated/` — they are regenerated on every build. See `primitive guides get models --language swift`.

## Validating a change in the running app

Two dev tools cover different halves of "does my change work," and they pair up:

1. **Debug Inspector** — a dev-only dashboard the app serves in DEBUG builds (open the `http://localhost:9999` URL it prints on launch). Use it to inspect client **state**: browse documents and records, run in-app tests, inspect blobs. It asserts data and logic, out-of-band.
2. **idb UI smoke test** — drives the app's **UI** headlessly (tap, type, read the accessibility tree), which the Inspector can't do. Run it with:

   ```sh
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

For the idb install steps (including the Python 3.12 requirement for `fb-idb`), the `+primitivetest` prerequisite, and the full command reference, read the DevTools guide:

```sh
primitive guides get devtools --language swift
```

## Data-side patterns

When adding models, queries, writes, or auth flows, fetch the matching guide first — e.g. `primitive guides get documents --language swift`. The guides are written against this same library.
