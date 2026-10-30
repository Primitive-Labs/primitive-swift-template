import SwiftUI
import JsBaoClient

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var acceptedInvitation = false

    var body: some View {
        AuthGate(appState: appState, appName: "Primitive Template") {
            AppTabView()
        }
        .task {
            await appState.initialize()
        }
        // `errorMessage` is the FATAL channel: an alert the user dismisses.
        // For a missing configuration or a connection that never came up.
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert("Invitation accepted", isPresented: $acceptedInvitation) {
            Button("OK") {}
                // Stable identifier for UI automation: the XCUITest invite
                // flow (UITests/) waits for it after opening an invite link.
                .accessibilityIdentifier("primitive.invite.accepted")
        }
        // `transientError` is the PER-MUTATION channel: a toast that
        // dismisses itself. Set it with `appState.setTransientError(_:)`.
        .overlay(alignment: .bottom) {
            TransientErrorToast(message: appState.transientError) {
                appState.transientError = nil
            }
        }
        // Incoming links. Two transports deliver them: the app's custom URL
        // scheme (registered in Info-Partial.plist; `primitive init` stamps an
        // app-unique one) through `.onOpenURL`, and universal links (https on
        // the web origin `webUrl` names) as a browsing activity, which is the
        // only delivery on macOS. Both go to `routePlatformLink`: invitations
        // are accepted, emailed sign-in links sign in, and your own routes go
        // in the `.notAPlatformLink` branch.
        //
        // The sign-in email is code-only until the app has a link target: a
        // `webUrl` in primitive/config.json (an https link that opens this app
        // or signs in on the web), or the `PrimitiveOAuthRedirectURI`
        // Info.plist key for a custom-scheme link. docs/README.md
        // ("Sign-in links") has the setup.
        .onOpenURL { url in
            route(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            route(url)
        }
    }

    /// One routing path for every transport that can deliver a link.
    private func route(_ url: URL) {
        Task {
            do {
                switch try await appState.routePlatformLink(url) {
                case .acceptedInvitation:
                    acceptedInvitation = true
                case .signedIn:
                    break
                case .notAPlatformLink(let unhandled):
                    // TODO: your app-specific routes go here, e.g.
                    // `myapp://settings` → open the settings screen.
                    appState.setTransientError("No route for link: \(unhandled.absoluteString)")
                }
            } catch {
                appState.setTransientError("Couldn't open link: \(error.localizedDescription)")
            }
        }
    }
}

struct AppTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                ProfileView(appState: appState)
            }
            .tabItem { Label("Profile", systemImage: "person.circle") }
        }
    }
}

// MARK: - Home — replace this with your app's main view.
//
// Your data lives in db3s. Declare a type in
// `primitive/<env>/db3-types/<name>.toml`, name it in
// `Sources/PrimitiveAppTemplate/bao-codegen.json`, push the config, and the
// build generates its models. Then subscribe and load, e.g.:
//
//   @StateObject private var loader = BaoDataLoader<[Contact]>()
//   ...
//   .task {
//       let sub = try? appState.subscribe(db3: contactsId)
//       try? await sub?.ready()
//       loader.bind(client: appState.client,
//                   subscribeTo: [.onDb3Events, .onModel(subscribe: Contact.subscribe)]) { _ in
//           try Contact.findAll()
//       }
//   }
//
// The databases guide has the full pattern:
// `primitive guides get databases --language swift`.

struct HomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // `.symbolRenderingMode(.hierarchical)` makes SF Symbols
            // render in shaded layers off a single accent color, so
            // dimming naturally falls out of `.foregroundStyle`. For
            // icons that have an obvious disabled / active state — a
            // send button, a star, a checkmark — prefer this pattern
            // over manual color ternaries like
            // `Color(canSend ? .accentColor : .secondary)`. See the
            // worked example in the docstring of
            // `SymbolButtonExample` below.
            Image(systemName: "circle.dotted")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text("Your app here")
                .font(.title2)
                .fontWeight(.medium)
            Text("Edit `Views/ContentView.swift` to replace this view. Declare a db3 type and name it in `bao-codegen.json` to generate your models.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
        // Stable identifier for UI automation: the idb `ui_signin` scenario
        // (`scripts/smoke-test.sh`) asserts this element renders after
        // sign-in. If you replace this view, keep the identifier or point the
        // scenario at your own screen with PRIMITIVE_SMOKE_SUCCESS_ID.
        .accessibilityIdentifier("primitive.template.home")
    }
}

/// Worked example of the SF Symbol rendering-mode pattern for "send
/// button dims when the input is empty." Left here as documentation
/// rather than wired into the template — copy it into your own view
/// when you build a text-input + submit pair.
///
/// The naive pattern is a foreground-color ternary:
///
///     Image(systemName: "arrow.up.circle.fill")
///         .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
///
/// That works, but you're now in the business of picking palette
/// colors that look right in light, dark, and high-contrast. SF
/// Symbols 4+ has built-in rendering modes that handle this for free:
///
///     // Recommended: rely on `.disabled(...)` + `.hierarchical`.
///     // Hierarchical renders the glyph in shaded layers of one tint;
///     // `.disabled(true)` automatically applies a system-defined
///     // "disabled" opacity that respects the user's contrast settings.
///     Image(systemName: "arrow.up.circle.fill")
///         .symbolRenderingMode(.hierarchical)
///         .foregroundStyle(.tint)
///
///     Button { /* send */ } label: {
///         Image(systemName: "arrow.up.circle.fill")
///             .symbolRenderingMode(.hierarchical)
///             .font(.title)
///             .foregroundStyle(.tint)
///     }
///     .disabled(text.isEmpty)
///
/// `.palette` mode is the second tool in the kit: assign two or three
/// distinct colors to the symbol's layers and they composite as one
/// glyph. Useful for status icons (warning triangle yellow + black
/// stroke) — see `TransientErrorToast` for a live example.
struct SymbolButtonExample: View {
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("Type something", text: $text)
                .textFieldStyle(.roundedBorder)
            Button {
                text = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }
}

#Preview("SymbolButtonExample") {
    SymbolButtonExample()
}
