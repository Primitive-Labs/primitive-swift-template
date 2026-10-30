import XCTest

/// The test bootstrap's own refusals, with no backend.
final class TestBootstrapTests: XCTestCase {
    func testAMissingVariableFailsNamingIt() {
        let full = [
            "VITE_APP_ID": "01APP",
            "VITE_API_URL": "http://127.0.0.1:8787",
            "VITE_WS_URL": "ws://127.0.0.1:8787",
            "PRIMITIVE_TEST_EMAIL": "a+primitivetest@example.com",
        ]
        XCTAssertNoThrow(try TestEnvironment.fromEnvironment(full))
        for name in full.keys {
            var env = full
            env[name] = " "
            XCTAssertThrowsError(try TestEnvironment.fromEnvironment(env)) { error in
                XCTAssertTrue(String(describing: error).contains(name), "\(error)")
            }
        }
    }

    func testARefusedSignInNamesTheAddressAndTheLikelyCause() {
        let error = TestBootstrapError.signInFailed(email: "a+primitivetest@example.com", underlying: URLError(.badServerResponse))
        XCTAssertTrue(error.description.contains("a+primitivetest@example.com"))
        XCTAssertTrue(error.description.contains("testAccountBaseEmails"))
    }
}
