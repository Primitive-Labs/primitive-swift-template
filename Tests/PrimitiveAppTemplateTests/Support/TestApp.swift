import Foundation
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// An `AppState` the way the app builds one, against the test backend.
@MainActor
enum TestApp {
    /// The test backend as the app's configuration.
    static func config(oauthRedirectUri: String? = nil, webUrl: String? = nil) throws -> AppConfig {
        let env = try TestEnvironment.fromEnvironment()
        return AppConfig(
            appId: env.appId,
            appName: "Template tests",
            serverUrl: env.apiUrl,
            webUrl: webUrl,
            oauthRedirectUri: oauthRedirectUri
        )
    }

    /// A fresh, signed-out app with its own defaults and its own on-disk
    /// store, as the app keeps one (a db3 opens only on disk).
    static func initialized(config: AppConfig? = nil) async throws -> AppState {
        let appState = AppState(auth: AuthModel(defaults: scratchDefaults()))
        await appState.initialize(config: try config ?? self.config(), storage: scratchStorage())
        XCTAssertTrue(appState.isInitialized)
        return appState
    }

    /// A fresh app signed in as the test account with the emailed-code flow,
    /// and connected.
    static func signedIn(config: AppConfig? = nil) async throws -> AppState {
        let appState = try await initialized(config: config)
        let email = try TestEnvironment.fromEnvironment().email
        await appState.auth.verifyOtp(email: email, code: TestEnvironment.otpCode)
        if let failure = appState.auth.authFailure {
            throw TestBootstrapError.signInFailed(email: email, underlying: failure.error ?? AuthError(message: failure.message))
        }
        try await eventually("signed in") { appState.auth.isAuthenticated }
        await appState.connectClient()
        XCTAssertTrue(appState.isConnected, appState.errorMessage ?? "not connected")
        return appState
    }

    /// Sign out and drop the client.
    static func tearDown(_ appState: AppState) async {
        if appState.auth.isAuthenticated { await appState.signOut() }
        await appState.client?.destroy()
    }

    /// A SQLite file of its own under the temporary directory.
    static func scratchStorage() -> StorageConfig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("template-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return .sqlite(directory: directory.appendingPathComponent("\(UUID().uuidString).sqlite").path)
    }

    /// A `UserDefaults` of its own, so per-device facts never leak between tests.
    static func scratchDefaults() -> UserDefaults {
        let name = "template-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

/// Wait until `condition` holds, failing with `what` after `timeout` seconds.
@MainActor
func eventually(
    _ what: String,
    timeout: TimeInterval = 15,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        guard Date() < deadline else {
            throw TimedOut(what: what)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

/// `eventually` gave up.
struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for: \(what)" }
}
