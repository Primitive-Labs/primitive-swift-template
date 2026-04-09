# Primitive App Template

The smallest possible app built on the [`PrimitiveApp`](../../swift-primitive-app/docs/README.md) library. **Two source files**, ~120 lines total. This is what you copy to start a new app.

If you've never used the library, read [PrimitiveApp library docs](../../swift-primitive-app/docs/README.md) first — this template assumes you understand `PrimitiveAppState`, `AuthGateView`, and the environment-object pattern.

## What you get out of the box

Build and run the template (`./run.sh` for macOS, `./run-ios.sh` for iOS) and you immediately have:

- A real Primitive app with email login (magic link + OTP) and optional Google OAuth
- A WebSocket-connected `JsBaoClient` available everywhere via `@EnvironmentObject`
- A reactive document list (auto-updates as new docs are created)
- A profile screen with logout
- Three tabs: Home, Documents, Profile

You haven't written any of that. You wrote zero auth code, zero connection-handling code, zero document-listing code. The library does all of it.

## Source layout

```
primitive-app-template/
├── Package.swift                       ← SPM manifest, depends on ../swift-primitive-app
├── primitive.json                      ← App config: appId, appName, serverUrl
├── Assets.xcassets/                    ← App icon
├── PrimitiveAppTemplate.xcodeproj      ← Xcode project (parallel to SPM, both build the same code)
├── run.sh / run-ios.sh / build.sh      ← Build helpers
└── Sources/PrimitiveAppTemplate/
    ├── PrimitiveAppTemplateApp.swift   ← @main entry: creates appState, sets up scene
    └── Views/
        └── ContentView.swift           ← Auth gate + tab view + Home/Documents/Profile screens
```

That's it. The whole template is two Swift files.

## Walking through the code

### `PrimitiveAppTemplateApp.swift` — the @main entry

```swift
@main
struct PrimitiveAppTemplateApp: App {
    @StateObject private var appState = PrimitiveAppState()

    var body: some Scene {
        WindowGroup("Primitive") {
            ContentView()
                .environmentObject(appState)
        }
    }
}
```

Three things happening:

1. **`@StateObject private var appState = PrimitiveAppState()`** — creates the session object. `@StateObject` means SwiftUI owns its lifetime; it's created once when the app launches and survives view rebuilds.
2. **`.environmentObject(appState)`** — injects it into the view tree so any descendant can do `@EnvironmentObject var appState: PrimitiveAppState` and grab it.
3. **macOS quirks** in `init()` — `setActivationPolicy(.regular)` makes the window appear when launched from `swift run` (otherwise the executable runs without a window).

### `ContentView.swift` — auth gate + tabs

The top-level view:

```swift
struct ContentView: View {
    @EnvironmentObject var appState: PrimitiveAppState

    var body: some View {
        AuthGateView(appName: "Primitive Template", authManager: appState.authManager) {
            AppTabView()
        }
        .task {
            await appState.initialize()
        }
        .alert("Error", isPresented: ...) { ... }
    }
}
```

The whole auth/connect/load state machine is `AuthGateView`. You give it an `authManager` and a content closure; it shows the right screen for each state (initializing → login → connecting → connected → error). When connected, it renders your content closure — `AppTabView()`.

The `.task { await appState.initialize() }` kicks off:
1. Loading `primitive.json`
2. Creating the `JsBaoClient` (without a token yet)
3. Attaching the auth manager to the client

After that, `AuthGateView` takes over and shows the login UI. When the user authenticates, `AuthGateView` automatically calls `connectClient()` for you.

### The three tabs

```swift
struct AppTabView: View {
    var body: some View {
        TabView {
            HomeView()         .tabItem { Label("Home", systemImage: "house") }
            DocumentsView()    .tabItem { Label("Documents", systemImage: "doc.text") }
            PrimitiveProfileView(authManager: appState.authManager)
                               .tabItem { Label("Profile", systemImage: "person.circle") }
        }
    }
}
```

- **`HomeView`** — placeholder. Uses `appState.userName` (populated by the library after connect). Replace with your actual app content.
- **`DocumentsView`** — reads `appState.documents` directly. The library populates this array as part of `connectClient()` and keeps it `@Published`, so the list shows up the moment connect succeeds. Selecting a row calls `appState.selectDocument(docId)` which opens the doc and starts syncing it.
- **`PrimitiveProfileView`** — provided by the library. Shows the user's info and a logout button. You just have to hand it the `authManager`.

## Customizing it

### Replace HomeView with your real content

This is the main thing. `HomeView` is a placeholder; rip it out and put your app there. You have access to `@EnvironmentObject var appState: PrimitiveAppState` anywhere in the tree, which gets you:

- `appState.client` — the `JsBaoClient` for any direct calls (`client.documents.create(...)`, `client.collections.list()`, etc.)
- `appState.documents` — reactive doc list
- `appState.userName` / `userEmail` / `userAvatarUrl`
- `appState.isConnected`, `appState.isSynced`

### Add typed BaoModels (TaskRecord, etc.)

The base `PrimitiveAppState` doesn't know about your record types. Subclass it:

```swift
@MainActor
final class MyAppState: PrimitiveAppState {
    @Published var taskModel: BaoModel<TaskRecord>?

    override func onDocumentOpened(documentId: String) {
        guard let client, let doc = client.getDoc(documentId) else { return }
        taskModel = BaoModel<TaskRecord>(doc: doc, client: client, documentId: documentId)
    }
}
```

Then update the `@main` to use your subclass and inject it twice (once as the base, once as the subclass — see [PrimitiveApp library docs §"Inject the subclass twice"](../../swift-primitive-app/docs/README.md#patterns-that-show-up-everywhere)):

```swift
@StateObject private var appState = MyAppState()

WindowGroup {
    ContentView()
        .environmentObject(appState as PrimitiveAppState)
        .environmentObject(appState)
}
```

The [demo app](../../primitive-app-demo) is exactly this pattern at scale — it has 4 `BaoModel` types and a sidebar of feature pages. Borrow as much from it as you want.

### Use a different `primitive.json`

The template ships with a placeholder `appId`. To point at a real Primitive app:

1. Run `primitive apps create "My App Name" --json` (requires the [Primitive CLI](https://docs.primitive.dev/cli))
2. Copy the returned `appId` into [`primitive.json`](../primitive.json)
3. Done — the next build picks it up

Auth tokens come from `~/.primitive/credentials.json` (set up by `primitive login`) — they're never committed.

## SPM vs Xcode project

The template ships **both** a `Package.swift` and a `PrimitiveAppTemplate.xcodeproj`. They build the same source files. Use whichever you prefer:

| Method | What you run | When to use |
|---|---|---|
| `swift run` (via `./run.sh`) | SPM build, no `.app` bundle | Fastest iteration, terminal logs |
| `xcodebuild` (via `./build.sh`) | SPM-backed, real `.app` bundle | Proper Dock icon, app behavior |
| `xcodebuild` for iOS (via `./run-ios.sh`) | iOS Simulator build | Testing iOS-specific code |
| `open *.xcodeproj` | Xcode IDE | Full IDE, debugging, instruments |

Because this is SPM-based, **adding a new `.swift` file is just creating it on disk** — both the SPM build and the Xcode project pick it up automatically. (This is different from [primitive-app-demo](../../primitive-app-demo), which uses an Xcode project as the source of truth and requires `project.pbxproj` edits when you add files.)

## Where to look next

- **Library reference:** [swift-primitive-app/docs/README.md](../../swift-primitive-app/docs/README.md) — what every public type does, and why
- **Real-world examples:** [primitive-app-demo/docs/README.md](../../primitive-app-demo/docs/README.md) — one demo page per JsBaoClient feature, all written against the same library
- **REST/CRDT primitives:** [JsBaoClient docs](../../../js-bao-wss-swift/swift-client/docs/README.md) — when you need to drop below the SwiftUI layer
