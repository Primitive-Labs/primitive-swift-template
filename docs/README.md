# Primitive App Template

A small SwiftUI starter app built on the [`PrimitiveApp`](https://github.com/Primitive-Labs/swift-primitive-app/blob/main/docs/README.md) library. This is what `primitive init --platform ios` scaffolds to start a new app.

If you've never used the library, read the [PrimitiveApp library docs](https://github.com/Primitive-Labs/swift-primitive-app/blob/main/docs/README.md) first — this template assumes you understand `PrimitiveAppState`, `AuthGateView`, and the environment-object pattern.

## What you get out of the box

Build and run the template (`./run.sh` for macOS, `./run-ios.sh` for iOS) and you immediately have:

- A real Primitive app with email login (a 6-digit code out of the box; the emailed sign-in link is the environment's `webUrl` https callback when this app has a web client, else a two-line scheme opt-in — see AGENTS.md, "Email sign-in links") and optional Google OAuth
- A WebSocket-connected `JsBaoClient` available everywhere via `@EnvironmentObject`
- A per-user singleton document, resolved-or-created on connect (the `TemplateAppState` pattern)
- Model codegen wired up: define models in the app's `models.toml` and `swift build` emits typed Swift records
- Two tabs (Home, Profile), two error channels (fatal alert + transient toast), and deep-link routing hooks

You wrote zero auth, connection, or document plumbing. The library does all of it.

## Source layout

```
primitive-swift-template/
├── Package.swift                       ← SPM manifest; depends on PrimitiveApp + JsBaoClient (codegen plugin)
├── primitive.json                      ← GENERATED (gitignored) from .primitive/config.json
├── project.yml / *.xcodeproj           ← Xcode project (parallel to SPM, both build the same code)
├── run.sh / run-ios.sh / build.sh      ← Build helpers
├── scripts/smoke-test.sh               ← Simulator smoke tests (launch + opt-in idb sign-in)
└── Sources/PrimitiveAppTemplate/
    ├── PrimitiveAppTemplateApp.swift   ← @main entry: creates TemplateAppState, injects it
    ├── TemplateAppState.swift          ← PrimitiveAppState subclass: singleton doc + error channels
    ├── Models/
    │   ├── models.toml                 ← Your model schemas (ships with a commented example; absent when the app's schema is shared — see `bao-codegen.json`)
    │   └── Generated/                  ← Codegen output — never edit by hand
    └── Views/
        ├── ContentView.swift           ← Auth gate + tab view + Home placeholder
        └── TransientErrorToast.swift   ← Toast for per-mutation, recoverable errors
```

## How the pieces fit

### `PrimitiveAppTemplateApp.swift` — the @main entry

Creates `TemplateAppState` (a `PrimitiveAppState` subclass) as a `@StateObject` — SwiftUI owns its lifetime, so it's created once at launch and survives view rebuilds — and injects it with `.environmentObject(appState)` so any descendant view can grab it.

### `TemplateAppState.swift` — the app's state object

Demonstrates the canonical Primitive shape for a "one document per user" app:

1. After the websocket connects (`connectClient()`), it registers every codegen'd model (`GeneratedModels.register(on: client)`) and resolves-or-creates the user's singleton document via an atomic alias upsert (`getOrCreateWithAlias` — race-free, unlike a resolve-then-create two-step).
2. It opens that doc through `selectDocumentAwaiting`, which keeps the base class's sync-state bookkeeping consistent and then calls `onDocumentOpened` — the place to load your models.
3. It adds a `transientError` channel (auto-dismissing toast, for retryable per-mutation failures) alongside the inherited `errorMessage` channel (full-screen alert, for fatal failures).

The file's doc comments walk through each step. Replace the `app_root` alias key with something descriptive of your app's per-user state.

### `ContentView.swift` — auth gate + tabs

`AuthGateView` runs the whole auth/connect state machine — it shows the right screen for each state (initializing → login → connecting → connected → error) and renders your content when connected: a `TabView` with `HomeView` (placeholder) and the library's `PrimitiveProfileView`. The view also wires the two error channels and deep-link routing — `.onOpenURL` for custom-scheme URLs and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` for universal links, which is the only delivery on macOS (Primitive's own link shapes get default handling; your app's routes go in the `.notAPlatformLink` branch).

## Customizing it

### Replace HomeView with your real content

This is the main thing. `HomeView` is a placeholder; rip it out and put your app there. `@EnvironmentObject var appState: TemplateAppState` anywhere in the tree gets you:

- `appState.client` — the `JsBaoClient` for any direct calls
- `appState.documents` — reactive doc list
- `appState.userName` / `userEmail` / `userAvatarUrl`
- `appState.isConnected`, `appState.isSynced`

Heads-up: the idb smoke test asserts the `primitive.template.home` accessibility identifier after sign-in. If you replace the home screen, keep the identifier or point the test at your own screen via `PRIMITIVE_SMOKE_SUCCESS_ID`.

### Replace the app icon

`Assets.xcassets/AppIcon.appiconset` holds a placeholder cube. Drop your own
artwork in at the same sizes — and keep it **opaque**: App Store Connect
rejects an upload whose large icon carries an alpha channel, transparent
pixels or not ("Invalid large app icon … can't be transparent or contain an
alpha channel", 90717). Export flattened onto a background rather than
trusting a transparent PNG that merely looks solid.

### Add typed records

Codegen is already wired on every build path: the `JsBaoCodegenPlugin` runs on `swift build`, and the Xcode targets run `scripts/generate-models.sh` from a pre-build phase, so Xcode's Run button and a bare `xcodebuild` regenerate too. `models.toml` is that phase's declared input, so builds that don't touch the schema skip it. To add a model:

1. Define it in the app's schema — `Sources/PrimitiveAppTemplate/Models/models.toml` here, or the file `Sources/PrimitiveAppTemplate/bao-codegen.json` names (`{"input": "../../../models/models.toml"}`) when this client shares one Primitive app with another. One schema per app, never a copy: its TOML keys are the wire field names. The shipped file carries a commented example showing the full shape (id field, typed scalars, the `required` constraint, class-name override).
2. Run `swift build` — a typed record struct is emitted into `Models/Generated/` (never edit those files; hand-written companions like `ItemRecord+Extensions.swift` go in `Models/`, outside `Generated/`).
3. Load it in `TemplateAppState.onDocumentOpened` (e.g. `items = ItemRecord.query()`) and write with `try ItemRecord(...).save(in: documentId)`.

One thing the pre-build phase cannot do for you: a new model is a new *file*, and the Xcode project lists its sources explicitly, so `.xcodeproj` has to be regenerated before Xcode will compile it. `./run-ios.sh` does that for you (codegen, then `xcodegen`); building straight from Xcode after adding a model fails the build naming the file, rather than compiling an app quietly missing the type — run `bash scripts/regenerate-project.sh` and build again. That script emits the models before it runs `xcodegen`, so it also covers the fresh clone where `Models/Generated/` — gitignored build products — does not exist yet, and `./archive.sh` and the fastlane lanes get the same ordering for free. Editing an EXISTING model needs none of this.

For the schema vocabulary, query options, and reactivity patterns, fetch the guides: `primitive guides get models --language swift` and `primitive guides get documents --language swift`.

### Point it at your app

`primitive init` configures everything: it scaffolds `.primitive/config.json` with a `dev` Primitive environment bound to your app, then generates `primitive.json` from it. That config file is the one place the backend URL and app ID are typed — `primitive.json` is a build product, gitignored, regenerated by `scripts/resolve-primitive-config.sh` on every build.

If you cloned this template by hand instead, create the environment yourself and generate the file:

```sh
primitive apps create "My App" --json
primitive env add dev --api-url <url> --app-id <appId>
primitive login
bash scripts/resolve-primitive-config.sh
```

Switch which backend this machine builds against with `primitive env use <name>`, or for a single run with `./run.sh --primitive-env <name>`. Every build prints the environment it resolved.

## SPM vs Xcode project

The template ships **both** a `Package.swift` and a `PrimitiveAppTemplate.xcodeproj`. They build the same source files. Use whichever you prefer:

| Method | What you run | When to use |
|---|---|---|
| `swift run` (via `./run.sh`) | SPM build, no `.app` bundle | Fastest iteration, terminal logs |
| `xcodebuild` (via `./build.sh`) | SPM-backed, real `.app` bundle | Proper Dock icon, app behavior |
| `xcodebuild` for iOS (via `./run-ios.sh`) | iOS Simulator build | Testing iOS-specific code |
| `open *.xcodeproj` | Xcode IDE | Full IDE, debugging, instruments |

Because this is SPM-based, **adding a new `.swift` file is just creating it on disk** — both the SPM build and the Xcode project pick it up automatically. (This is different from an app that uses an Xcode project as the source of truth, which requires `project.pbxproj` edits when you add files.)

## Smoke-testing the UI

`scripts/smoke-test.sh` runs simulator smoke tests that catch runtime failures a plain build misses:

- `bash scripts/smoke-test.sh` — the zero-dependency default: launches the app and asserts it survives without crashing.
- `bash scripts/smoke-test.sh ui_signin` — an [idb](https://fbidb.io/)-driven test that signs in end-to-end and asserts the post-login screen renders. This one needs idb installed and a `+primitivetest` account. Install idb with `bash scripts/setup-idb.sh` — one idempotent command that sets up the Homebrew companion and the `fb-idb` client in a Python 3.12 venv, which the smoke test then finds on its own. Run `bash scripts/smoke-test.sh --list` to see both scenarios, and see the DevTools agent guide (`primitive guides get devtools --language swift`) for what the setup does and how idb complements the Debug Inspector.

`ui_signin` is opt-in, so the default run never requires idb.

Both scenarios run on a simulator dedicated to this app — `Smoke — <bundle id>`, created on first use — rather than whichever device is booted, so two apps built from this template can smoke-test side by side on one machine. Set `PRIMITIVE_SMOKE_SIM` to pick the device by name yourself, or `PRIMITIVE_SMOKE_SIM_BASE` (default `iPhone 17 Pro`) to change the device type it is created from.

`./run-ios.sh` works the same way on a device of its own, `Run — <bundle id>` (`PRIMITIVE_RUN_SIM` and `PRIMITIVE_RUN_SIM_BASE` are the matching knobs), so a smoke run never reinstalls the app out from under the session you are driving by hand, and neither run adopts another app's booted simulator. `./run-ios.sh --sim <name-or-udid>` still targets whatever device you name for one run.

## Where to look next

- **Platform guides:** `primitive guides list` and `primitive guides get <topic> --language swift` — the source of truth for models, documents, auth, blobs, and every other platform feature, written against this same library
- **Library reference:** [swift-primitive-app/docs/README.md](https://github.com/Primitive-Labs/swift-primitive-app/blob/main/docs/README.md) — what every public type does, and why
- **REST/CRDT primitives:** [JsBaoClient docs](https://github.com/Primitive-Labs/swift-client/blob/main/docs/README.md) — when you need to drop below the SwiftUI layer
