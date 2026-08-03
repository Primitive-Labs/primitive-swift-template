# Primitive Swift App Template

A SwiftUI starter app built on the `PrimitiveApp` library and `JsBaoClient`.

> **For a tour of the app — source layout, the `TemplateAppState` pattern, the login flow, and where to add models and views — read [docs/README.md](docs/README.md) first.**

## Build

This app is SPM-based, so **adding a new `.swift` file is just creating it on disk** — both the SPM build and the Xcode project pick it up automatically; no `project.pbxproj` edits.

```sh
swift build          # fastest check that it compiles
./run.sh             # run on macOS (terminal logs)
./run-ios.sh         # run on the iOS Simulator
```

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

For the idb install steps (including the Python 3.12 requirement for `fb-idb`), the `+primitivetest` prerequisite, and the full command reference, read the DevTools guide:

```sh
primitive guides get devtools --language swift
```

## Data-side patterns

When adding models, queries, writes, or auth flows, fetch the matching guide first — e.g. `primitive guides get documents --language swift`. The guides are written against this same library.
