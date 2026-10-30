# Primitive App Template

A small SwiftUI starter app built on [`JsBaoClient`](https://github.com/Primitive-Labs/swift-client/blob/main/docs/README.md). This is what `primitive init --platform ios` scaffolds to start a new app. Everything above the client — app state, sign-in, onboarding, the profile screen, the data loader — is code in this app, so you read and change it like the rest of your app.

## What you get out of the box

Build and run the template (`./run.sh` for macOS, `./run-ios.sh` for iOS) and you immediately have:

- Sign-in with an emailed 6-digit code, plus passkeys, Google and Apple when the app is configured for them, and an emailed sign-in link once the app has a link target (see "Sign-in links" below)
- Onboarding for a new user: a name and an optional photo, then an offer to add a passkey where passkeys apply
- A Profile tab: avatar, name and email, Edit Profile (name and photo), passkey management, Sign Out
- A connected `JsBaoClient` on `AppState`, available everywhere via `@EnvironmentObject`
- `BaoDataLoader`, which reloads a view's data when a db3 becomes ready, goes away or is evicted, and when a model's records change
- Model codegen from a db3 type: name the type file in `bao-codegen.json` and the build emits typed Swift models
- Two error channels (fatal alert + transient toast) and link routing for invitations and sign-in links

## Source layout

```
primitive-swift-template/
├── Package.swift                       ← SPM manifest; depends on JsBaoClient
├── primitive.json                      ← GENERATED (gitignored) from primitive/config.json
├── project.yml / *.xcodeproj           ← Xcode project (parallel to SPM, both build the same code)
├── Info-Partial.plist                  ← The app's URL scheme and the scheme-link opt-in key
├── run.sh / run-ios.sh / build.sh      ← Build helpers
├── test.sh                             ← Runs the tests in Tests/ (see Running the tests below)
├── ui-test.sh                          ← Runs the XCUITest suite in UITests/ on a simulator
├── fastlane/                           ← TestFlight + App Store lanes (see Distribution below)
├── archive.sh                          ← Xcode-account archives (not the TestFlight path — see Distribution)
├── scripts/codegen.sh                  ← The one codegen entry point every build path runs
├── scripts/smoke-test.sh               ← Simulator smoke tests (launch + opt-in idb sign-in)
└── Sources/PrimitiveAppTemplate/
    ├── PrimitiveAppTemplateApp.swift   ← @main entry: creates AppState, injects it
    ├── bao-codegen.json                ← The db3 type file codegen reads (none yet)
    ├── App/                            ← AppConfig (primitive.json), AppState, link routing
    ├── Auth/                           ← AuthModel, LoginView, AuthGate, onboarding
    ├── Profile/                        ← ProfileView, EditProfileView, avatar and profile saving
    ├── Data/                           ← BaoDataLoader, ReadyGate
    ├── Models/Generated/               ← Codegen output — never edit by hand
    └── Views/
        ├── ContentView.swift           ← Auth gate + tab view + Home placeholder
        └── TransientErrorToast.swift   ← Toast for per-mutation, recoverable errors
└── Tests/PrimitiveAppTemplateTests/
    ├── ExampleTests.swift              ← One test that signs in and reads the profile
    ├── AppStateTests.swift, …          ← The template's own tests of its app code
    └── Support/SignIn.swift            ← TestSignIn: a client signed in as the test account
```

## How the pieces fit

### `AppState` — the app's state object

`PrimitiveAppTemplateApp` creates one `AppState` as a `@StateObject` and injects it with `.environmentObject(appState)`. `initialize()` reads `primitive.json` into an `AppConfig`, builds the client (a persisted session, the passkey relying party your web origin implies, the web origin as `links.appBaseURL`), registers the generated models and starts listening for sign-in. After a sign-in, `connectClient()` connects and loads `userName`, `userEmail` and `userAvatarUrl`.

It also owns the two error channels — `errorMessage` (a full-screen alert, for "the app cannot proceed") and `transientError` (a toast that dismisses itself; set it with `setTransientError(_:)`) — and the db3s the app subscribes to: `subscribe(db3:)` keeps the subscription until sign-out, which disposes it and evicts the db3 from the device.

### `AuthModel` and `AuthGate` — sign-in

`AuthModel` holds what the login screen shows (`loginState`, the last failure, the providers the server offers) and makes the calls: `requestEmailSignIn(email:)`, `verifyOtp`, `signInWithPasskey`, `signInWithGoogle`, `signInWithApple`, `handleSignInCallback(_:)`, `logout()`. The client decides where an emailed link lands and which callback URLs it accepts; `AuthModel` adds no rules of its own.

`AuthGate` shows the right screen for each state (initializing → login → connecting → your content), connects after a sign-in, and presents onboarding for a new user: the name step, then the passkey step when the app offers passkeys and this device has not said no.

### `ContentView.swift` — tabs and links

A `TabView` with `HomeView` (placeholder) and `ProfileView`. It wires the two error channels and link routing — `.onOpenURL` for the custom scheme and `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` for universal links, the only delivery on macOS. `appState.routePlatformLink(_:)` accepts invitations and hands sign-in links to the client; your own routes go in the `.notAPlatformLink` branch.

## Customizing it

### Replace HomeView with your real content

This is the main thing. `HomeView` is a placeholder; rip it out and put your app there. `@EnvironmentObject var appState: AppState` anywhere in the tree gets you:

- `appState.client` — the `JsBaoClient` for any direct calls
- `appState.subscribe(db3:)` — a db3 subscription that ends at sign-out
- `appState.userName` / `userEmail` / `userAvatarUrl`
- `appState.isConnected`, `appState.auth` (the sign-in state)

Heads-up: the idb smoke test asserts the `primitive.template.home` accessibility identifier after sign-in. If you replace the home screen, keep the identifier or point the test at your own screen via `PRIMITIVE_SMOKE_SUCCESS_ID`.

### Replace the app icon

`Assets.xcassets/AppIcon.appiconset` holds a placeholder cube. Drop your own
artwork in at the same sizes — and keep it **opaque**: App Store Connect
rejects an upload whose large icon carries an alpha channel, transparent
pixels or not ("Invalid large app icon … can't be transparent or contain an
alpha channel", 90717). Export flattened onto a background rather than
trusting a transparent PNG that merely looks solid.

### Add your data

Your data lives in db3s, and a db3 type declares its models. To add one:

1. Declare the type in `primitive/<env>/db3-types/<name>.toml` — a `[type]` table and one `[models.<name>]` table per model — and push it with `primitive config push`.
2. Point `Sources/PrimitiveAppTemplate/bao-codegen.json` at it, relative to that directory:

   ```json
   { "input": "../../primitive/dev/db3-types/contacts.toml" }
   ```

3. Build. `scripts/codegen.sh` emits a Swift type per model into `Models/Generated/` (never edit those files; hand-written companions like `Contact+Extensions.swift` go in `Models/`, outside `Generated/`), and `AppState` registers them at startup.
4. Subscribe to a db3 of that type and load it with a `BaoDataLoader`:

   ```swift
   @StateObject private var loader = BaoDataLoader<[Contact]>()

   .task {
       let subscription = try? appState.subscribe(db3: contactsId)
       try? await subscription?.ready()
       loader.bind(client: appState.client,
                   subscribeTo: [.onDb3Events, .onModel(subscribe: Contact.subscribe)]) { _ in
           try Contact.findAll()
       }
   }
   ```

The emitted files are **committed** — generated code is code, so a type change that changes the emission shows up as a diff you commit with the change. Every scripted build path and every Xcode build regenerates them first; a bare `swift build` compiles what is committed.

One thing the pre-build phase cannot do for you: a new model is a new *file*, and the Xcode project lists its sources explicitly, so `.xcodeproj` has to be regenerated before Xcode will compile it. `./run-ios.sh` does that for you (codegen, then `xcodegen`); building straight from Xcode after adding a model fails the build naming the file, rather than compiling an app quietly missing the type — run `bash scripts/regenerate-project.sh` and build again. Editing an EXISTING model needs none of this.

For the type file's syntax, queries, writes and reactivity, fetch the guide: `primitive guides get databases --language swift`.

### Point it at your app

`primitive init` configures everything: it scaffolds `primitive/config.json` with a `dev` Primitive environment bound to your app, then generates `primitive.json` from it. That config file is the one place the backend URL and app ID are typed — `primitive.json` is a build product, gitignored, regenerated by `scripts/resolve-primitive-config.sh` on every build.

If you cloned this template by hand instead, create the environment yourself and generate the file:

```sh
primitive apps create "My App" --json
primitive env add dev --api-url <url> --app-id <appId>
primitive login
bash scripts/resolve-primitive-config.sh
```

Switch which backend this machine builds against with `primitive env use <name>`, or for a single run with `./run.sh --primitive-env <name>`. Every build prints the environment it resolved.

## Child apps for parallel work

When several agents or git worktrees work on this app at once, give each line of work its own child app — a copy of the selected environment's app that shares its `primitive/<env>/` tree — so a `config push` from one branch never reaches the others. With the parent environment selected:

```sh
scripts/child-app.sh up feature-x
./run.sh                              # any build regenerates primitive.json for the child
# ... work, push, test ...
scripts/child-app.sh down feature-x
```

`up` creates the child (or attaches or resumes one that exists), checks that it is the environment it acts on, runs your `scripts/child-app-init`, pushes the tree into it and selects it. Rerun it to resume an interrupted run. `down` runs your `scripts/child-app-teardown`, then deletes the child and its local state.

The template ships neither hook: what a fresh child needs is your app's call. Add them as executable files:

- `scripts/child-app-init` — seed the child: test users, databases, its own config vars (`primitive config set vars KEY=value`). It runs before the first push and on every `up`, so make it safe to repeat.
- `scripts/child-app-teardown` — revoke or delete anything the child created outside the platform (third-party connections, webhooks). Deleting the child doesn't reach those, so this is your app's responsibility; `down --skip-teardown` skips the hook and leaves them behind.

Both run from the app root with `PRIMITIVE_ENV` (the child), `CHILD_APP_ID`, `CHILD_APP_SLUG` and `PARENT_ENV` set; address the child through `PRIMITIVE_ENV`, not the selected environment. A slug must not be the name of a committed environment. See `primitive guides get configuration` ("Child apps") for the rest of the workflow.

## SPM vs Xcode project

The template ships **both** a `Package.swift` and a `PrimitiveAppTemplate.xcodeproj`. They build the same source files. Use whichever you prefer:

| Method | What you run | When to use |
|---|---|---|
| `swift run` (via `./run.sh`) | SPM build, no `.app` bundle | Fastest iteration, terminal logs |
| `xcodebuild` (via `./build.sh`) | SPM-backed, real `.app` bundle | Proper Dock icon, app behavior |
| `xcodebuild` for iOS (via `./run-ios.sh`) | iOS Simulator build | Testing iOS-specific code |
| `open *.xcodeproj` | Xcode IDE | Full IDE, debugging, instruments |

Because this is SPM-based, **adding a new `.swift` file is just creating it on disk** — both the SPM build and the Xcode project pick it up automatically. (This is different from an app that uses an Xcode project as the source of truth, which requires `project.pbxproj` edits when you add files.)

## Running the tests

`./test.sh` runs the tests in `Tests/` with `swift test` on your Mac. They sign in as a test account and call your app's backend for real, with no simulator, browser or code email:

```bash
export PRIMITIVE_TEST_EMAIL="you+primitivetest-ios@yourdomain.com"
./test.sh
```

Each test gets a signed-in client from `TestSignIn.client()` and releases it with `TestSignIn.tearDown(_:)`; `ExampleTests.swift` is the one to copy.

`./test.sh --primitive-env <name>` runs against another environment, and any other argument goes to `swift test`, so `./test.sh --filter ExampleTests` runs one test class.

### One-time setup

The test account signs in with the fixed code `000000`, which the server accepts only for an address your app has whitelisted and admits. On a fresh scaffold do both:

1. **Whitelist a base address.** Add it to `[app]` in `primitive/<env>/app.toml` (run `primitive config pull --only app` first if the file isn't there), then push:

   ```toml
   [app]
   testAccountBaseEmails = ["you@yourdomain.com"]
   ```

   ```bash
   primitive config push --only app
   ```

   Any `you+primitivetest-<suffix>@yourdomain.com` address is then a test account. The base address itself never signs in this way. Keep one stable suffix, such as `+primitivetest-ios`, so every run reuses one test user.

2. **Admit the test address.** A scaffold is invite-only unless `primitive init` was told otherwise, and a test account joins the app like any other sign-up. Invite the exact address once (no email is sent):

   ```bash
   primitive users invite <app-id> you+primitivetest-ios@yourdomain.com
   ```

   Or, if the app should be open to everyone, set `mode = "public"` under `[app]` in `app.toml` before the push.

`./test.sh` exports your app's ID and server from the selected environment for the tests to read, the same way a build does.

**Gotchas**

- If step 2 is missing, sign-in fails with `OTP sign-in failed for <address>` and an underlying `INVITATION_REQUIRED`. Invite that exact address, or make the app public.
- `./test.sh` stops before building when `PRIMITIVE_TEST_EMAIL` is unset. Export it in your shell profile or CI environment.

### UI tests

`./ui-test.sh` builds the app for the iOS Simulator and runs the XCUITest suite in `UITests/` against it: it signs in with the code, completes onboarding, edits the profile name, accepts an invitation from its link, and signs out, all through the real screens and your app's backend. It needs Xcode with an iOS simulator runtime and xcodegen; on a machine missing either it changes nothing, prints `[ui-test] SKIP: <reason>` and exits 77, so a CI job can report the suite as skipped rather than failed.

```bash
export PRIMITIVE_TEST_EMAIL="you+primitivetest-ios-ui@example.com"
./ui-test.sh
```

Use an address that has never signed in to the app, set up the same way as above (whitelist the base address, invite this one), so its first sign-in shows onboarding. To run the invitation test, create a pending invitation for some other address and set `PRIMITIVE_TEST_INVITE_TOKEN` to its `inviteToken`; without it that test is skipped.

The run uses a simulator of its own, `UI — <bundle id>`, created on first use, and uninstalls the app before each run so it starts signed out. `PRIMITIVE_UI_SIM` and `PRIMITIVE_UI_SIM_BASE` override the device's name and the device type it is created from. Any other argument goes to `xcodebuild test`, so `./ui-test.sh -only-testing:PrimitiveAppTemplateUITests/TemplateFlowUITests/test4_signOut` runs one test. A failed test's screenshot is in the run's result bundle under `build/ui/`.

The run passes `-collect-test-diagnostics never`, because the simulator diagnostics xcodebuild otherwise collects after a failing test can stall it for up to 10 minutes; pass `-collect-test-diagnostics on-failure` to collect them anyway. If xcodebuild still has not exited 60 seconds after the run's verdict, `./ui-test.sh` stops it and exits with that verdict (0 passed, 65 failed); a run whose output stays silent for 5 minutes before any verdict, such as one where no test ever starts, is stopped with exit status 124. `PRIMITIVE_UI_EXIT_GRACE` and `PRIMITIVE_UI_STALL_TIMEOUT` set the two bounds in seconds. A stopped run's result bundle can be left unfinished.

## Sign-in links

The sign-in email carries a 6-digit code out of the box, with no app settings. It also carries a link once the app has somewhere for the link to land:

- **An https link (an app with a web client).** Add `"webUrl": "https://<your-web-domain>"` to the environment in `primitive/config.json`. The email then links to that origin's `/oauth/callback`, which opens this app where it is installed (a universal link, once the domain serves `apple-app-site-association` and the `applinks:` entitlement in `project.yml` names it) and signs in through the browser anywhere else.
- **A custom-scheme link (an iOS-only app).** Add the `PrimitiveOAuthRedirectURI` key to `Info-Partial.plist` with the value `<scheme>://oauth/callback`, where `<scheme>` is the one `primitive init` registered there:

  ```xml
  <key>PrimitiveOAuthRedirectURI</key>
  <string>myapp-01j8…://oauth/callback</string>
  ```

Either way, allow-list the URL: merge it into the existing `[auth].emailRedirectUris` array in `primitive/<env>/app.toml` (run `primitive config pull --only app` first if the file isn't there), then run `primitive config push --only app`.

**Gotchas**

- A link whose URL is not allow-listed makes every sign-in email request fail with 400 `Invalid redirect URI`. Allow-list first, then set the key.
- A custom-scheme link opens only on a device with the app installed: not in the Simulator, not on another device, and many webmail clients do not render it as a link. The code always works.

## Smoke-testing the UI

`scripts/smoke-test.sh` runs simulator smoke tests that catch runtime failures a plain build misses:

- `bash scripts/smoke-test.sh` — the zero-dependency default: launches the app and asserts it survives without crashing.
- `bash scripts/smoke-test.sh ui_signin` — an [idb](https://fbidb.io/)-driven test that signs in end-to-end and asserts the post-login screen renders. This one needs idb installed and a `+primitivetest` account. Install idb with `bash scripts/setup-idb.sh` — one idempotent command that sets up the Homebrew companion and the `fb-idb` client in a Python 3.12 venv, which the smoke test then finds on its own. Run `bash scripts/smoke-test.sh --list` to see both scenarios.

`ui_signin` is opt-in, so the default run never requires idb.

Both scenarios run on a simulator dedicated to this app — `Smoke — <bundle id>`, created on first use — rather than whichever device is booted, so two apps built from this template can smoke-test side by side on one machine. Set `PRIMITIVE_SMOKE_SIM` to pick the device by name yourself, or `PRIMITIVE_SMOKE_SIM_BASE` (default `iPhone 17 Pro`) to change the device type it is created from.

`./run-ios.sh` works the same way on a device of its own, `Run — <bundle id>` (`PRIMITIVE_RUN_SIM` and `PRIMITIVE_RUN_SIM_BASE` are the matching knobs), so a smoke run never reinstalls the app out from under the session you are driving by hand, and neither run adopts another app's booted simulator. `./run-ios.sh --sim <name-or-udid>` still targets whatever device you name for one run.

To inspect what the backend holds — users, db3s, logs — use the CLI: `primitive guides get inspecting-and-debugging`.

## Distribution

Simulator builds run unsigned. TestFlight, the App Store and device installs need an Apple Developer account ($99/year) and `DEVELOPMENT_TEAM` set in `project.yml` (your Team ID, from [developer.apple.com/account](https://developer.apple.com/account) → Membership Details; every build path regenerates the Xcode project from `project.yml`, so that edit is the whole step).

**TestFlight and the App Store: the fastlane lanes.** The template ships a `Gemfile` and `fastlane/` (`bundle install` once). The iOS lanes sign entirely from an App Store Connect API key — they authenticate the archive with it and fetch your Apple Distribution certificate and App Store provisioning profile through it — so they need **no Apple ID signed into Xcode and no certificate already in your keychain**:

```sh
cp fastlane/.env.example fastlane/.env   # then fill in ASC_KEY_ID / ASC_ISSUER_ID; save the .p8 as fastlane/api_key.p8
bundle exec fastlane bump type:patch     # new build number — App Store Connect rejects a repeat
bundle exec fastlane ios beta            # archive, export, upload to TestFlight
bundle exec fastlane ios release         # archive, export, upload the App Store build
```

`ios release` uploads the build to App Store Connect; it does not start review. Finish the version's metadata there and submit it for review by hand — the lane prints that reminder when it succeeds.

The key's role is App Manager (or Admin); `fastlane/.env.example` walks through creating it, and a lane run before it is set up prints the same steps and stops. `bundle exec fastlane lanes` lists the rest (`mac beta`, `mac dmg`, `status`). Never commit `fastlane/api_key.p8` or `fastlane/.env`.

**`./archive.sh {ios|mac|dmg}` is the Xcode-account path.** It archives with Xcode automatic signing, which authenticates through the Apple ID in Xcode → Settings → Accounts; it never reads `fastlane/.env`. On a machine with only the API key configured it fails with `No Accounts` — that is the machine state, not the project, and `bundle exec fastlane ios beta` is the command for it. `dmg` mode builds a Developer ID-signed `.app` for direct macOS distribution (`fastlane mac dmg` also notarizes and staples it).

The full walkthrough — team ID, the API key, registering the app on App Store Connect, CI — is the platform's Deploying guide: `primitive guides get deploying --language swift`.

## Where to look next

- **Platform guides:** `primitive guides list` and `primitive guides get <topic> --language swift` — the source of truth for databases, auth, invitations, blobs, and every other platform feature
- **The client:** [JsBaoClient docs](https://github.com/Primitive-Labs/swift-client/blob/main/docs/README.md) — every API the app code calls
