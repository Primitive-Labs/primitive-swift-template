import Foundation
import SwiftUI
import os
import JsBaoClient

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveAppTemplate", category: "Auth")

/// The sign-in state the login, onboarding and profile screens render, and
/// the calls they make.
///
/// Every call goes straight to the client: `client.auth.emailSignInRequest`
/// chooses where an emailed link lands, and `client.auth.handleSignInCallback`
/// decides which callback URLs it accepts. This model keeps the screen state
/// (what to show, the last failure, the passkeys on the account) and the two
/// per-device passkey facts.
@MainActor
final class AuthModel: ObservableObject {

    /// Digits in the emailed code.
    static let otpLength = 6

    // MARK: - Published state

    @Published private(set) var isAuthenticated = false
    @Published private(set) var userId: String?
    @Published private(set) var authError: String?
    @Published private(set) var isAuthenticating = false

    /// The last failed sign-in, with its type intact, so a screen can branch
    /// on `authFailure?.code == .addedToWaitlist` rather than on text. Cleared
    /// with `authError`, always together.
    @Published private(set) var authFailure: AuthFailure?

    /// A failed sign-in as the client reported it.
    struct AuthFailure {
        /// The thrown error, unchanged; nil for a failure that arrived as an
        /// `AuthFailedEvent`, which carries a message only.
        let error: Error?
        /// The server's code, typed, when there was one.
        let code: AuthCode?
        /// The text published on `authError`.
        let message: String
    }

    /// True while the client restores a persisted session on a cold start.
    /// Gate any "signed out" screen on it, or the login screen flashes.
    @Published private(set) var isAuthRestoring = false

    @Published private(set) var loginState: LoginState = .initial

    enum LoginState: Equatable {
        case initial
        case sendingEmail
        /// One "check your email" state: the email carries the code and, when
        /// the client chose a link target, a link.
        case emailSent(email: String)
        case verifyingOtp
        case authenticating
        /// The app is invite-only and the address went on its waitlist. An
        /// outcome, not an error: there is nothing to retry.
        case waitlisted(email: String?)
        case error(String)
    }

    /// The sign-in methods the server offers this app (`getAuthConfig()`),
    /// loaded on `attach`. Nil while loading; the login screen shows email
    /// only until it resolves.
    struct AuthProviders: Equatable, Sendable {
        var google: Bool
        var apple: Bool
        var passkey: Bool
        var email: Bool

        /// The fallback when the config cannot be read.
        static let emailOnly = AuthProviders(google: false, apple: false, passkey: false, email: true)
    }

    @Published private(set) var availableProviders: AuthProviders?

    /// A passkey was registered or used on this device for this app: the
    /// login screen leads with passkey sign-in.
    @Published private(set) var hasLocalPasskeyHint = false

    /// The signed-in account's passkeys, for the Profile screen.
    @Published private(set) var passkeys: [PasskeyInfo] = []

    /// The interactive sign-in that just finished, read from the call's own
    /// result (an `AuthSuccessEvent` carries the cause only). Onboarding plans
    /// from it; `finishOnboarding()` clears it.
    @Published private(set) var lastSignIn: SignIn?

    struct SignIn: Equatable, Sendable {
        /// The client's cause: `otpVerify`, `magicLinkVerify`, `oauthCallback`,
        /// `apple` or `passkeyAuth`.
        let cause: String
        let isNewUser: Bool?
        let promptAddPasskey: Bool?
    }

    // MARK: - Dependencies

    private weak var client: JsBaoClient?
    private let defaults: UserDefaults
    private var subscriptions: [EventSubscription] = []

    /// Registers a passkey for the signed-in user. Defaults to
    /// `client.auth.registerPasskey`; a test replaces it to drive the
    /// enrollment states without the system sheet.
    var passkeyRegistration: (@MainActor (_ deviceName: String?) async throws -> Void)?

    /// - Parameter defaults: Where the per-device passkey facts live.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reading a failure

    /// The `AuthCode` an error carries: an `AuthError`'s, or the code in an
    /// `HttpError`'s body. Nil for an outage, a cancelled sheet, or a code
    /// this client version does not know.
    static func authCode(of error: Error) -> AuthCode? {
        if let authError = error as? AuthError { return authError.code }
        if let http = error as? HttpError { return http.authCode }
        return nil
    }

    /// The server's own explanation of a failure, when it sent one.
    static func serverMessage(of error: Error) -> String? {
        if let http = error as? HttpError, let message = http.serverMessage, !message.isEmpty {
            return message
        }
        if let authError = error as? AuthError, !authError.message.isEmpty {
            return authError.message
        }
        return nil
    }

    /// The waitlist screen when the server queued the address, else `otherwise`.
    static func failureState(for error: Error, email: String?, otherwise: LoginState) -> LoginState {
        authCode(of: error) == .addedToWaitlist ? .waitlisted(email: email) : otherwise
    }

    /// What the user is told when the server rejected the code itself.
    static let invalidOtpMessage = "Invalid code. Please try again."

    /// What a failed `verifyOtp` says. A rejected code is the one rejection
    /// the server names no cause for: a 400/401 whose `code` is the status
    /// default (`INVALID_REQUEST`, `UNAUTHENTICATED`) or absent. Anything
    /// with its own code — a waitlist, too many attempts — says what it is.
    static func otpVerifyMessage(for error: Error) -> String {
        if let http = error as? HttpError,
           http.status == 400 || http.status == 401,
           http.serverCode == nil || statusDefaultCodes.contains(http.serverCode ?? "") {
            return invalidOtpMessage
        }
        return serverMessage(of: error) ?? error.localizedDescription
    }

    /// The codes the server stamps on a 400 and a 401 whose handler named none.
    private static let statusDefaultCodes: Set<String> = ["INVALID_REQUEST", "UNAUTHENTICATED"]

    private func publishFailure(_ error: Error, message: String, state: LoginState?) {
        authFailure = AuthFailure(error: error, code: Self.authCode(of: error), message: message)
        authError = message
        if let state { loginState = state }
    }

    private func publishFailure(message: String, state: LoginState? = nil) {
        authFailure = AuthFailure(error: nil, code: nil, message: message)
        authError = message
        if let state { loginState = state }
    }

    private func clearFailure() {
        authError = nil
        authFailure = nil
    }

    // MARK: - Attach

    /// Listen to the client's auth events and load the app's sign-in methods.
    func attach(to client: JsBaoClient) {
        self.client = client
        hasLocalPasskeyHint = defaults.bool(forKey: passkeyHintKey)

        Task { @MainActor [weak self] in
            do {
                let config = try await client.auth.getAuthConfig()
                self?.availableProviders = AuthProviders(
                    google: config.googleSignInAvailable,
                    apple: config.hasApple,
                    passkey: config.hasPasskey,
                    email: config.emailSignInEnabled
                )
            } catch {
                logger.warning("Auth config fetch failed; showing email sign-in only: \(error.localizedDescription)")
                self?.availableProviders = .emailOnly
            }
        }

        if client.authState.authenticated {
            isAuthenticated = true
            userId = client.userId
        } else {
            // `waitForStorageReady`, not `waitForAuthReady`: finishing with
            // nobody signed in is the ordinary answer on a fresh install.
            isAuthRestoring = true
            Task { @MainActor [weak self] in
                if !(await client.waitForStorageReady(timeout: 15)) {
                    logger.error("Session restore did not settle within 15s")
                }
                self?.isAuthRestoring = false
            }
        }

        subscriptions = [
            client.observeOnMainActor(AuthSuccessEvent.self) { [weak self] event in
                guard let self else { return }
                let newUserId = self.client?.userId
                if self.userId != nil && self.userId != newUserId { self.passkeys = [] }
                self.isAuthenticated = true
                self.userId = newUserId
                self.isAuthenticating = false
                self.isAuthRestoring = false
                self.loginState = .initial
                self.clearFailure()
                if event.cause == "passkeyAuth" { self.recordPasskeyOnDevice() }
            },
            client.observeOnMainActor(AuthFailedEvent.self) { [weak self] event in
                guard let self else { return }
                let message = event.message ?? "Authentication failed"
                self.publishFailure(message: message, state: .error(message))
                self.isAuthenticating = false
                self.isAuthRestoring = false
                self.passkeys = []
            },
        ]
    }

    func detach() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }

    // MARK: - Email sign-in

    /// Request one sign-in email. The client picks the link target (the
    /// app's `oauthRedirectUri`, else its web origin's callback, else a
    /// code-only email); nothing here chooses one.
    func requestEmailSignIn(email: String) async {
        guard let client else { return }
        loginState = .sendingEmail
        clearFailure()
        do {
            _ = try await client.auth.emailSignInRequest(email: email)
            loginState = .emailSent(email: email)
        } catch {
            logger.error("Email sign-in request failed: \(error.localizedDescription)")
            let message = Self.serverMessage(of: error)
                ?? "Failed to send sign-in email: \(error.localizedDescription)"
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: email, otherwise: .error(message))
            )
        }
    }

    /// Finish with the emailed code.
    func verifyOtp(email: String, code: String) async {
        guard let client else { return }
        loginState = .verifyingOtp
        isAuthenticating = true
        do {
            let result = try await client.auth.otpVerify(email: email, code: code)
            lastSignIn = SignIn(cause: "otpVerify", isNewUser: result.isNewUser, promptAddPasskey: nil)
        } catch {
            publishFailure(
                error,
                message: Self.otpVerifyMessage(for: error),
                state: Self.failureState(for: error, email: email, otherwise: .emailSent(email: email))
            )
            isAuthenticating = false
        }
    }

    /// Finish a sign-in from the URL an emailed link opened. The client
    /// decides which URLs it accepts; a refusal (`AuthError` `.invalidToken`,
    /// "Sign-in callback refused: …") or a failed verify is published as
    /// `authFailure` and rethrown.
    @discardableResult
    func handleSignInCallback(_ url: URL) async throws -> SignInCallbackResult {
        guard let client else { throw JsBaoError(code: .unavailable, message: "The client is not initialized") }
        isAuthenticating = true
        loginState = .authenticating
        clearFailure()
        do {
            let result = try await client.auth.handleSignInCallback(url)
            lastSignIn = SignIn(
                cause: result.method == .oauth ? "oauthCallback" : "magicLinkVerify",
                isNewUser: result.isNewUser,
                promptAddPasskey: result.promptAddPasskey
            )
            return result
        } catch {
            let message = Self.serverMessage(of: error) ?? "That sign-in link is expired or invalid"
            publishFailure(
                error,
                message: message,
                state: Self.failureState(for: error, email: nil, otherwise: .error(message))
            )
            isAuthenticating = false
            throw error
        }
    }

    // MARK: - Google and Apple

    /// Native Google sign-in: the system sheet, then the server's exchange.
    /// The redirect comes from a bundled `GoogleService-Info.plist`.
    func signInWithGoogle() async {
        guard let client else { return publishFailure(message: "The client is not initialized") }
        isAuthenticating = true
        loginState = .authenticating
        clearFailure()
        do {
            let result = try await client.signInWithGoogle()
            lastSignIn = SignIn(cause: "oauthCallback", isNewUser: result.isNewUser, promptAddPasskey: nil)
        } catch OAuthSignInError.cancelled {
            isAuthenticating = false
            loginState = .initial
        } catch {
            providerFailed(error)
        }
    }

    /// Sign in with Apple: the system Apple ID sheet, then the server's exchange.
    func signInWithApple() async {
        guard let client else { return publishFailure(message: "The client is not initialized") }
        isAuthenticating = true
        loginState = .authenticating
        clearFailure()
        do {
            let result = try await client.signInWithApple()
            lastSignIn = SignIn(cause: "apple", isNewUser: result.isNewUser, promptAddPasskey: nil)
        } catch AppleSignInError.cancelled {
            isAuthenticating = false
            loginState = .initial
        } catch {
            providerFailed(error)
        }
    }

    private func providerFailed(_ error: Error) {
        let message = Self.serverMessage(of: error) ?? error.localizedDescription
        publishFailure(error, message: message, state: Self.failureState(for: error, email: nil, otherwise: .error(message)))
        isAuthenticating = false
    }

    // MARK: - Passkeys

    /// Sign in with a passkey through the system sheet. The relying party is
    /// the client's `passkeyRpId`, which `AppState` derives from `webUrl`.
    func signInWithPasskey() async {
        guard let client else { return publishFailure(message: "The client is not initialized") }
        isAuthenticating = true
        loginState = .authenticating
        clearFailure()
        do {
            _ = try await client.auth.signInWithPasskey()
            recordPasskeyOnDevice()
            lastSignIn = SignIn(cause: "passkeyAuth", isNewUser: false, promptAddPasskey: nil)
        } catch PasskeyError.canceled {
            isAuthenticating = false
            loginState = .initial
        } catch {
            providerFailed(error)
        }
    }

    /// What adding a passkey came to.
    enum EnrollOutcome: Equatable {
        case enrolled
        /// The user dismissed the system sheet: nothing to report.
        case cancelled
        /// It failed; the message is on `authError` too.
        case failed(String)
    }

    /// Register a passkey for the signed-in user (onboarding's passkey step
    /// and the Profile screen).
    @discardableResult
    func enrollPasskey(deviceName: String? = nil) async -> EnrollOutcome {
        let register = passkeyRegistration ?? { [weak self] deviceName in
            guard let client = self?.client else {
                throw JsBaoError(code: .unavailable, message: "The client is not initialized")
            }
            _ = try await client.auth.registerPasskey(deviceName: deviceName)
        }
        do {
            try await register(deviceName)
            recordPasskeyOnDevice()
            await refreshPasskeys()
            return .enrolled
        } catch PasskeyError.canceled {
            return .cancelled
        } catch {
            let message = Self.serverMessage(of: error) ?? error.localizedDescription
            publishFailure(error, message: message, state: nil)
            return .failed(message)
        }
    }

    /// Whether this device declined the onboarding passkey prompt.
    var declinedPasskeyOnDevice: Bool { defaults.bool(forKey: passkeyDeclinedKey) }

    /// "Not now" on the passkey prompt: never prompt again on this device.
    func declinePasskeyEnrollment() {
        defaults.set(true, forKey: passkeyDeclinedKey)
    }

    /// Load the account's passkeys into `passkeys`. A failure leaves the list
    /// as it was: the usual one is "passkeys not configured", which reads as
    /// none.
    func refreshPasskeys() async {
        guard let client else { return }
        do {
            passkeys = try await client.auth.passkeyList().passkeys
        } catch {
            logger.info("refreshPasskeys: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func deletePasskey(passkeyId: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.auth.passkeyDelete(passkeyId: passkeyId)
            await refreshPasskeys()
            return true
        } catch {
            publishFailure(error, message: Self.serverMessage(of: error) ?? error.localizedDescription, state: nil)
            return false
        }
    }

    private var passkeyHintKey: String { "primitive.passkey.onDevice.\(client?.appId ?? "default")" }
    private var passkeyDeclinedKey: String { "primitive.passkey.promptDeclined.\(client?.appId ?? "default")" }

    /// A passkey was used or registered here: lead with it next time.
    func recordPasskeyOnDevice() {
        hasLocalPasskeyHint = true
        defaults.set(true, forKey: passkeyHintKey)
    }

    // MARK: - Onboarding and sign-out

    /// Onboarding is done with `lastSignIn`.
    func finishOnboarding() {
        lastSignIn = nil
    }

    /// Back to the sign-in panel, clearing any failure.
    func reset() {
        loginState = .initial
        clearFailure()
    }

    /// Sign out and drop this device's copy of the account's data.
    func logout() async {
        if let client {
            do {
                try await client.logout(wipeLocal: true)
            } catch {
                logger.error("Logout error: \(error.localizedDescription)")
            }
        }
        passkeys = []
        lastSignIn = nil
        isAuthenticated = false
        isAuthenticating = false
        userId = nil
        clearFailure()
        loginState = .initial
    }
}
