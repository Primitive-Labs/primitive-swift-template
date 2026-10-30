import SwiftUI

/// Shows the right screen for where sign-in is: initializing, restoring a
/// session, the login screen, connecting, or the app. After a new user signs
/// in it presents onboarding (the name step, then the passkey prompt where
/// passkeys apply).
struct AuthGate<Content: View>: View {
    @ObservedObject var appState: AppState
    @ObservedObject var auth: AuthModel
    let appName: String
    @ViewBuilder let content: () -> Content

    init(appState: AppState, appName: String, @ViewBuilder content: @escaping () -> Content) {
        self.appState = appState
        self.auth = appState.auth
        self.appName = appName
        self.content = content
    }

    /// Connected at least once this session: the app stays up offline.
    @State private var hasConnectedOnce = false
    @State private var onboarding: OnboardingFlow?

    var body: some View {
        ZStack {
            if !appState.isInitialized {
                LoadingView(message: appState.errorMessage ?? "Initializing...")
            } else if auth.isAuthRestoring && !auth.isAuthenticated {
                LoadingView(message: "Restoring session...")
            } else if !auth.isAuthenticated {
                LoginView(auth: auth, appName: appName)
            } else if appState.isConnected || hasConnectedOnce {
                content()
            } else if let error = appState.errorMessage {
                errorView(error)
            } else {
                LoadingView(message: "Connecting...")
            }
        }
        .onChange(of: auth.isAuthenticated) { _, authenticated in
            if !authenticated {
                hasConnectedOnce = false
                onboarding = nil
            }
            if authenticated && !appState.isConnected {
                Task { await appState.connectClient() }
            }
        }
        .onChange(of: appState.isConnected) { _, connected in
            if connected { hasConnectedOnce = true }
        }
        .onChange(of: auth.lastSignIn) { _, signIn in
            guard let signIn else { return }
            Task { await planOnboarding(for: signIn) }
        }
        .sheet(isPresented: Binding(
            get: { onboarding != nil },
            set: { if !$0 { finishOnboarding() } }
        )) {
            if let onboarding {
                OnboardingView(flow: onboarding, onFinish: finishOnboarding)
                    .interactiveDismissDisabled()
            }
        }
    }

    private func planOnboarding(for signIn: AuthModel.SignIn) async {
        let passkeysAvailable = auth.availableProviders?.passkey == true
        if passkeysAvailable, signIn.isNewUser == true, signIn.promptAddPasskey != true {
            await auth.refreshPasskeys()
        }
        let steps = OnboardingPlan.make(
            isNewUser: signIn.isNewUser,
            cause: signIn.cause,
            promptAddPasskey: signIn.promptAddPasskey,
            passkeysAvailable: passkeysAvailable,
            accountHasPasskeys: !auth.passkeys.isEmpty,
            declinedOnDevice: auth.declinedPasskeyOnDevice
        )
        if steps.isEmpty {
            auth.finishOnboarding()
        } else {
            onboarding = OnboardingFlow(steps: steps, appState: appState)
        }
    }

    private func finishOnboarding() {
        onboarding = nil
        auth.finishOnboarding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                appState.errorMessage = nil
                Task { await appState.connectClient() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A full-screen spinner with a status line.
struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
