import SwiftUI
import PrimitiveApp
import JsBaoClient

struct ContentView: View {
    @EnvironmentObject var appState: TemplateAppState

    var body: some View {
        AuthGateView(appState: appState, appName: "Primitive Template", authManager: appState.authManager) {
            AppTabView()
        }
        .task {
            await appState.initialize()
        }
        // `errorMessage` is the FATAL channel — full-screen alert, user
        // must dismiss before continuing. Use for connection / config /
        // open-doc failures where the app genuinely can't proceed.
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        // `transientError` is the PER-MUTATION channel — bottom-anchored
        // toast that auto-dismisses. Use for `try todos.create(...)`
        // throws and other recoverable failures the user doesn't need
        // to block on. See `TemplateAppState.setTransientError(...)`.
        .overlay(alignment: .bottom) {
            TransientErrorToast(message: appState.transientError) {
                appState.transientError = nil
            }
        }
        // Incoming links (deep links / universal links / notification-tap
        // URLs). Primitive's own link shapes get default handling via the
        // library — document share links open, invitation links are
        // accepted, magic links sign in. Web links are trusted only after
        // you set `appState.client?.links.appBaseURL` or `trustedLinkHosts`;
        // custom-scheme links are OS-scoped and work without that.
        // `.notAPlatformLink` is where your app's own routes go.
        //
        // To actually RECEIVE links you still need at least one transport:
        // a custom URL scheme (CFBundleURLTypes in Info.plist) and/or
        // universal links (`applinks:` associated domain + your web domain
        // serving apple-app-site-association). The demo app's Deep Links
        // page walks through both.
        .onOpenURL { url in
            Task {
                do {
                    let outcome = try await appState.routePlatformLink(url)
                    if case .notAPlatformLink(let unhandled) = outcome {
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
}

struct AppTabView: View {
    @EnvironmentObject var appState: TemplateAppState

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                PrimitiveProfileView(appState: appState, authManager: appState.authManager)
            }
            .tabItem { Label("Profile", systemImage: "person.circle") }
        }
    }
}

// MARK: - Home — replace this with your app's main view.
//
// `appState` is the `TemplateAppState` subclass of `PrimitiveAppState`.
// Once you've added a model to `Models/models.toml` and bound it in
// `TemplateAppState.onDocumentOpened`, you read from it here — e.g.:
//
//   @StateObject private var loader = BaoDataLoader<[ItemRecord]>()
//   ...
//   .task {
//       loader.bind(client: appState.client, subscribeTo: [.onModel(subscribe: ItemRecord.subscribe)]) { _ in
//           try ItemRecord.findAll().sorted { $0.createdAt > $1.createdAt }
//       }
//   }
//
// See the agent guide (`primitive guides get documents --language swift`)
// for the full pattern including writes, queries, and reactivity.

struct HomeView: View {
    @EnvironmentObject var appState: TemplateAppState

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
            Text("Edit `Views/ContentView.swift` to replace this view, then add models to `Models/models.toml` and bind them in `TemplateAppState.onDocumentOpened`.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Home")
        // Stable identifier for the post-login smoke test: the idb
        // `ui_signin` scenario (`scripts/smoke-test.sh`) asserts this
        // element renders after sign-in. If you replace this view, either
        // keep the identifier or point the scenario at your own screen via
        // PRIMITIVE_SMOKE_SUCCESS_ID. See the DevTools agent guide.
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
