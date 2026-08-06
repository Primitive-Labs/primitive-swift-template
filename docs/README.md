# Primitive App Template

A small SwiftUI starter app built on the [`PrimitiveApp`](https://github.com/Primitive-Labs/swift-primitive-app/blob/main/docs/README.md) library. This is what `primitive init --platform ios` scaffolds to start a new app.

If you've never used the library, read the [PrimitiveApp library docs](https://github.com/Primitive-Labs/swift-primitive-app/blob/main/docs/README.md) first — this template assumes you understand `PrimitiveAppState`, `AuthGateView`, and the environment-object pattern.

## What you get out of the box

Build and run the template (`./run.sh` for macOS, `./run-ios.sh` for iOS) and you immediately have:

- A real Primitive app with email login (magic link + OTP) and optional Google OAuth
- A WebSocket-connected `JsBaoClient` available everywhere via `@EnvironmentObject`
- A per-user singleton document, resolved-or-created on connect (the `TemplateAppState` pattern)
- Model codegen wired up: define models in `Models/models.toml` and `swift build` emits typed Swift records
- Two tabs (Home, Profile), two error channels (fatal alert + transient toast), and deep-link routing hooks

You wrote zero auth, connection, or document plumbing. The library does all of it.

## Source layout

```
primitive-swift-template/
├── Package.swift                       ← SPM manifest; depends on PrimitiveApp + JsBaoClient (codegen plugin)
├── primitive.json                      ← App config: appId, appName, serverUrl
├── project.yml / *.xcodeproj           ← Xcode project (parallel to SPM, both build the same code)
├── run.sh / run-ios.sh / build.sh      ← Build helpers
├── scripts/smoke-test.sh               ← Simulator smoke tests (launch + opt-in idb sign-in)
└── Sources/PrimitiveAppTemplate/
    ├── PrimitiveAppTemplateApp.swift   ← @main entry: creates TemplateAppState, injects it
    ├── TemplateAppState.swift          ← PrimitiveAppState subclass: singleton doc + error channels
    ├── Models/
    │   ├── models.toml                 ← Your model schemas (ships with a commented example)
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

`AuthGateView` runs the whole auth/connect state machine — it shows the right screen for each state (initializing → login → connecting → connected → error) and renders your content when connected: a `TabView` with `HomeView` (placeholder) and the library's `PrimitiveProfileView`. The view also wires the two error channels and `.onOpenURL` deep-link routing (Primitive's own link shapes get default handling; your app's routes go in the `.notAPlatformLink` branch).

## Customizing it

### Replace HomeView with your real content

This is the main thing. `HomeView` is a placeholder; rip it out and put your app there. `@EnvironmentObject var appState: TemplateAppState` anywhere in the tree gets you:

- `appState.client` — the `JsBaoClient` for any direct calls
- `appState.documents` — reactive doc list
- `appState.userName` / `userEmail` / `userAvatarUrl`
- `appState.isConnected`, `appState.isSynced`

Heads-up: the idb smoke test asserts the `primitive.template.home` accessibility identifier after sign-in. If you replace the home screen, keep the identifier or point the test at your own screen via `PRIMITIVE_SMOKE_SUCCESS_ID`.

### Add typed records

Codegen is already wired: the `JsBaoCodegenPlugin` runs on `swift build`, and the Xcode/iOS path runs it from `run-ios.sh`. To add a model:

1. Define it in `Sources/PrimitiveAppTemplate/Models/models.toml` — the file ships with a commented example showing the full shape (id field, typed scalars, the `required` constraint, class-name override).
2. Run `swift build` — a typed record struct is emitted into `Models/Generated/` (never edit those files; hand-written companions like `ItemRecord+Extensions.swift` go in `Models/`, outside `Generated/`).
3. Load it in `TemplateAppState.onDocumentOpened` (e.g. `items = ItemRecord.query()`) and write with `try ItemRecord(...).save(in: documentId)`.

For the schema vocabulary, query options, and reactivity patterns, fetch the guides: `primitive guides get models --language swift` and `primitive guides get documents --language swift`.

### Point it at your app

`primitive init` configures everything: it writes your `appId` into `primitive.json` and scaffolds `.primitive/config.json` with a `dev` environment for the CLI. If you cloned this template by hand instead, the checked-in `primitive.json` ships a placeholder `appId` — replace it with your own (`primitive apps create "My App" --json`) and set up the CLI environment with `primitive env add dev --api-url <url> --app-id <appId>`, then `primitive login`. The app won't get past the login screen until a real `appId` is in place.

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
- `bash scripts/smoke-test.sh ui_signin` — an [idb](https://fbidb.io/)-driven test that signs in end-to-end and asserts the post-login screen renders. This one needs idb installed and a `+primitivetest` account; run `bash scripts/smoke-test.sh --list` to see both, and see the DevTools agent guide (`primitive guides get devtools --language swift`) for the idb setup and how it complements the Debug Inspector.

`ui_signin` is opt-in, so the default run never requires idb.

## Where to look next

- **Platform guides:** `primitive guides list` and `primitive guides get <topic> --language swift` — the source of truth for models, documents, auth, blobs, and every other platform feature, written against this same library
- **Library reference:** [swift-primitive-app/docs/README.md](https://github.com/Primitive-Labs/swift-primitive-app/blob/main/docs/README.md) — what every public type does, and why
- **REST/CRDT primitives:** [JsBaoClient docs](https://github.com/Primitive-Labs/swift-client/blob/main/docs/README.md) — when you need to drop below the SwiftUI layer
