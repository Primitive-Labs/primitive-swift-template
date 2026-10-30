import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The sign-in screen: the providers the server offers this app (passkey,
/// Apple, Google, email), then the emailed code.
struct LoginView: View {
    @ObservedObject var auth: AuthModel
    let appName: String

    @State private var email = ""
    @State private var otpCode = ""

    /// The screens this view can show. One panel per outcome, so the mapping
    /// from `AuthModel.LoginState` is a value a test can assert: a SwiftUI
    /// `body` is not inspectable.
    enum Panel: Equatable {
        case signIn
        case sendingEmail
        case checkEmail(email: String)
        case signingIn
        /// The waitlist screen: this address is queued for an invite-only app,
        /// so there is nothing to retry. Matches the Vue template's
        /// `waitlisted` state.
        case waitlisted
    }

    /// Which panel a login state shows.
    ///
    /// `.error` shows the sign-in panel (with the message underneath) because
    /// every error state here is retryable from the form; the waitlist is the
    /// one failure that is not, and gets a screen of its own.
    static func panel(for state: AuthModel.LoginState) -> Panel {
        switch state {
        case .initial, .error: return .signIn
        case .sendingEmail: return .sendingEmail
        case .emailSent(let email): return .checkEmail(email: email)
        case .verifyingOtp, .authenticating: return .signingIn
        case .waitlisted: return .waitlisted
        }
    }

    /// Whether the shared red error line belongs under a panel.
    ///
    /// It doesn't under the waitlist panel: that panel already tells the whole
    /// story, and the server's "this app is invite-only" text repeated in red
    /// underneath reads as a second, contradicting outcome. The Vue template
    /// shows no error there either.
    static func showsErrorMessage(in panel: Panel) -> Bool {
        panel != .waitlisted
    }

    /// The waitlist screen's heading, the web template's words.
    static let waitlistTitle = "You're on the waitlist"

    /// The waitlist screen's body copy, the web template's words.
    static func waitlistDetail(appName: String) -> String {
        "We've added you to the waitlist for \(appName). "
            + "We'll send you an email when your access is approved."
    }

    /// Which buttons to render: the server's auth config, loaded by
    /// `AuthModel.attach`. Email only until it resolves.
    private var providers: AuthModel.AuthProviders {
        auth.availableProviders ?? .emailOnly
    }

    /// Passkey-first on return visits: a passkey was registered or used on
    /// this device before, so lead with it (the standard iOS pattern).
    private var leadWithPasskey: Bool {
        providers.passkey && auth.hasLocalPasskeyHint
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text(appName)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Sign in to continue")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Auth content based on state
                VStack(spacing: 16) {
                    switch Self.panel(for: auth.loginState) {
                    case .signIn:
                        initialLoginView
                    case .sendingEmail:
                        ProgressView("Sending sign-in email...")
                    case .checkEmail(let sentEmail):
                        emailSentView(email: sentEmail)
                    case .signingIn:
                        ProgressView("Signing in...")
                    case .waitlisted:
                        waitlistedView
                    }
                }
                .frame(maxWidth: 320)

                // Error message
                if let error = auth.authError,
                   Self.showsErrorMessage(in: Self.panel(for: auth.loginState)) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tap anywhere outside the text fields to clear focus.
        // `.contentShape` makes the Spacer regions hit-testable; without it
        // taps in the empty space above/below the form do nothing.
        .contentShape(Rectangle())
        .onTapGesture {
            dismissKeyboard()
        }
        // ESC key on macOS clears focus from the active text field. The
        // modifier is *unavailable* on iOS (not just inert), so guard it.
        #if os(macOS)
        .onExitCommand { dismissKeyboard() }
        #endif
    }

    /// Resigns first responder on whichever platform we're running on.
    /// iOS: route resignFirstResponder through UIApplication so it walks the
    /// responder chain. macOS: tell the key window to drop its first
    /// responder, which clears focus from any NSTextField hosted by SwiftUI.
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }

    // MARK: - Initial Login

    /// Standard iOS sign-in layout, driven by the server's auth config:
    ///
    /// - Return visit (a passkey lives on this device): passkey first,
    ///   prominent, with the other providers below the divider.
    /// - First visit: Apple, then Google, then email — with a small
    ///   passkey link at the bottom for users who registered one on
    ///   another device.
    private var initialLoginView: some View {
        VStack(spacing: 16) {
            if leadWithPasskey {
                Button {
                    Task { await auth.signInWithPasskey() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                        Text("Sign in with Passkey")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                dividerWithText("or")
            }

            if providers.apple {
                Button {
                    Task { await auth.signInWithApple() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "applelogo")
                        Text("Sign in with Apple")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            if providers.google {
                // The system sheet, with the redirect from a bundled
                // GoogleService-Info.plist.
                Button {
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            if providers.email {
                if providers.apple || providers.google {
                    dividerWithText("or")
                }

                TextField("Email address", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                    // Stable identifier for UI automation: the idb smoke
                    // scenario (`scripts/smoke-test.sh ui_signin`) finds the
                    // field by it, not by placeholder text.
                    .accessibilityIdentifier("primitive.login.emailField")
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    #endif

                // One email button: the email carries the code, and a link
                // when the client has a target for one.
                emailProminence(
                    Button {
                        Task { await auth.requestEmailSignIn(email: email) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope")
                            Text("Sign in with Email")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .disabled(email.isEmpty)
                    .accessibilityIdentifier("primitive.login.emailSubmit")
                )
            }

            // Passkey exists server-side but (as far as this device knows)
            // not locally: keep it reachable without leading with it —
            // e.g. a passkey registered on the user's other device.
            if providers.passkey && !leadWithPasskey {
                Button("Sign in with a Passkey") {
                    Task { await auth.signInWithPasskey() }
                }
                .font(.caption)
            }
        }
    }

    /// `.bordered` vs `.borderedProminent` are distinct opaque types, so a
    /// ternary can't pick between them — branch in a ViewBuilder instead.
    @ViewBuilder
    private func emailProminence<V: View>(_ button: V) -> some View {
        if leadWithPasskey {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Email sent (the code, plus a link when the client sent one)

    private func emailSentView(email sentEmail: String) -> some View {
        let otpLength = AuthModel.otpLength
        return VStack(spacing: 12) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            Text("Check your email")
                .font(.headline)
            Text("We sent a sign-in email to **\(sentEmail)**")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Code first, link conditionally: link issuance is fail-closed on
            // the server (no allow-listed redirect target, no link), and the
            // request's `{ success: true }` does not say which email went out.
            // Promising a link the app cannot guarantee makes the supported
            // code-only fallback look broken.
            Text("Enter the \(otpLength)-digit code. If that email also has a sign-in link, opening it works too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField(String(repeating: "0", count: otpLength), text: $otpCode)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.system(.title2, design: .monospaced))
                .accessibilityIdentifier("primitive.login.otpField")
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            Button("Verify") {
                Task { await auth.verifyOtp(email: email, code: otpCode) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(otpCode.count < otpLength)
            .accessibilityIdentifier("primitive.login.otpVerify")

            Button("Back to login") {
                auth.reset()
                otpCode = ""
            }
            .font(.caption)
        }
    }

    // MARK: - Waitlisted

    /// The invite-only app queued this address. Nothing to retry, so the
    /// screen says what happened and offers the way back — the same shape as
    /// the Vue template's `waitlisted` state.
    private var waitlistedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .accessibilityIdentifier("primitive.login.waitlisted")
            Text(Self.waitlistTitle)
                .font(.headline)
            Text(Self.waitlistDetail(appName: appName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Back to sign in") {
                auth.reset()
                otpCode = ""
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    private func dividerWithText(_ text: String) -> some View {
        HStack {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
    }
}
