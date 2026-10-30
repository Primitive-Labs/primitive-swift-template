import Foundation
import JsBaoClient

/// The backend and test account the tests use: the environment `./test.sh`
/// exports from the selected Primitive environment, plus
/// `PRIMITIVE_TEST_EMAIL`.
struct TestEnvironment: Sendable {
    let appId: String
    let apiUrl: String
    let wsUrl: String
    let email: String

    /// The code the server accepts for a whitelisted `+primitivetest` address.
    static let otpCode = "000000"

    /// Read from `environment`; a missing or blank value throws naming it.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TestEnvironment {
        func required(_ name: String) throws -> String {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw TestBootstrapError.missingEnvironment(name)
            }
            return value
        }
        return TestEnvironment(
            appId: try required("VITE_APP_ID"),
            apiUrl: try required("VITE_API_URL"),
            wsUrl: try required("VITE_WS_URL"),
            email: try required("PRIMITIVE_TEST_EMAIL")
        )
    }
}

/// Why a test could not get a signed-in client.
enum TestBootstrapError: Error, CustomStringConvertible {
    case missingEnvironment(String)
    case signInFailed(email: String, underlying: Error)
    case storageNotReady(TimeInterval)
    case connectFailed(underlying: Error)

    var description: String {
        switch self {
        case .missingEnvironment(let name):
            return "\(name) is not set. ./test.sh exports VITE_APP_ID, VITE_API_URL and VITE_WS_URL from the "
                + "selected environment; set PRIMITIVE_TEST_EMAIL yourself (docs/README.md, \"Running the tests\")."
        case let .signInFailed(email, underlying):
            return "OTP sign-in failed for \(email). The app must list its base address in testAccountBaseEmails "
                + "and admit it (an invitation, or a public app). Underlying error: \(underlying)"
        case .storageNotReady(let timeout):
            return "The client's storage did not settle within \(timeout)s, so the test did not sign in."
        case .connectFailed(let underlying):
            return "Signed in, but the client did not connect. Underlying error: \(underlying)"
        }
    }
}

/// A client signed in as the test account through the OTP bypass.
enum TestBootstrap {
    static let timeout: TimeInterval = 15

    /// Build an in-memory client, sign it in with the fixed code, connect it.
    ///
    /// The order matters: the client is built without auto-connecting, its
    /// storage is allowed to settle (so a restored session cannot overwrite
    /// the new token), any local state is purged, the code is verified, the
    /// user-scoped storage is rebound to the signed-in user, and only then
    /// does the socket connect.
    static func client(_ env: TestEnvironment) async throws -> JsBaoClient {
        let client = JsBaoClient(options: JsBaoClientOptions(
            apiUrl: env.apiUrl,
            wsUrl: env.wsUrl,
            appId: env.appId,
            offline: false,
            globalAdminAppId: "global-admin-app",
            logLevel: .warn,
            storageConfig: .memory,
            autoNetwork: false
        ))
        guard await client.waitForStorageReady(timeout: timeout) else {
            await client.destroy()
            throw TestBootstrapError.storageNotReady(timeout)
        }
        try? await client.logout(wipeLocal: true)
        do {
            _ = try await client.auth.otpVerify(email: env.email, code: TestEnvironment.otpCode)
        } catch {
            await client.destroy()
            throw TestBootstrapError.signInFailed(email: env.email, underlying: error)
        }
        await client.rebindUserScopedStorage()
        await client.setShouldConnect(true)
        guard client.isConnected else {
            await client.destroy()
            throw TestBootstrapError.connectFailed(
                underlying: JsBaoError(code: .unavailable, message: "WebSocket did not connect")
            )
        }
        do {
            _ = try await client.waitForAuthReady(timeout: timeout)
        } catch {
            await client.destroy()
            throw TestBootstrapError.connectFailed(underlying: error)
        }
        return client
    }
}
