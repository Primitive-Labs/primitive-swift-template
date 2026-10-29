import JsBaoClient
import PrimitiveAppTesting

/// Signs the tests in as the test account, with no email, browser or simulator.
///
/// The account is `PRIMITIVE_TEST_EMAIL`, a `+primitivetest` address whose base
/// the app lists in `testAccountBaseEmails` and admits (an invitation, or a
/// public app). The server accepts the fixed code `000000` for it. `./test.sh`
/// exports the app's identity as `VITE_APP_ID`, `VITE_API_URL` and
/// `VITE_WS_URL` from the selected environment; a missing value fails with an
/// error naming the variable, and a refused sign-in with one naming the
/// address and the likely cause.
enum TestSignIn {
    /// A connected client signed in as the test account.
    static func client() async throws -> JsBaoClient {
        let config = try PrimitiveTestConfig.fromEnvironment()
        return try await PrimitiveTestAuth.bootstrapClient(config: config)
    }

    /// Disconnects the client and drops its local state.
    static func tearDown(_ client: JsBaoClient) async {
        await client.destroy()
    }
}
