import Foundation
import JsBaoClient
import XCTest

/// An example to start from: sign in, make one real call, tear down.
final class ExampleTests: XCTestCase {
    func testSignsInAndReadsTheProfile() async throws {
        let client = try await TestSignIn.client()
        do {
            XCTAssertNotNil(client.userId, "the client is signed in")
            let profile = try await client.me.get()
            let expected = ProcessInfo.processInfo.environment["PRIMITIVE_TEST_EMAIL"] ?? ""
            XCTAssertEqual(profile?.email.lowercased(), expected.lowercased())
        } catch {
            await TestSignIn.tearDown(client)
            throw error
        }
        await TestSignIn.tearDown(client)
    }
}
