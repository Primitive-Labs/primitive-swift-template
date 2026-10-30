import Foundation
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// `routePlatformLink`: the client decides which sign-in links it accepts,
/// invitations go to `invitations.accept`, and the rest are the app's own.
@MainActor
final class AppStateLinksTests: XCTestCase {
    private let callback = URL(string: "tmplapp://oauth/callback?magic_token=bogus")!

    func testASchemeCallbackTheAppDidNotOptIntoIsRefusedBeforeAnyRequest() async throws {
        let app = try await TestApp.initialized()
        do {
            _ = try await app.routePlatformLink(callback)
            XCTFail("the callback was accepted")
        } catch let error as AuthError {
            XCTAssertEqual(error.code, .invalidToken)
            XCTAssertTrue(error.message.hasPrefix("Sign-in callback refused:"), error.message)
        }
        XCTAssertEqual(app.auth.authFailure?.code, .invalidToken)
        guard case .error = app.auth.loginState else { return XCTFail("\(app.auth.loginState)") }
        XCTAssertFalse(app.auth.isAuthenticated)
        await TestApp.tearDown(app)
    }

    func testWithTheSchemeOptInTheCallbackReachesTheServerWhichRefusesABogusToken() async throws {
        let app = try await TestApp.initialized(config: TestApp.config(oauthRedirectUri: "tmplapp://oauth/callback"))
        do {
            _ = try await app.routePlatformLink(callback)
            XCTFail("a bogus token signed in")
        } catch let error as HttpError {
            XCTAssertTrue((400..<500).contains(error.status), "\(error)")
        }
        XCTAssertTrue(app.auth.authFailure?.error is HttpError)
        guard case .error(let message) = app.auth.loginState else { return XCTFail("\(app.auth.loginState)") }
        XCTAssertFalse(message.hasPrefix("Sign-in callback refused:"), message)
        await TestApp.tearDown(app)
    }

    func testAnInvitationLinkGoesToTheInvitationsApi() async throws {
        let app = try await TestApp.signedIn()
        do {
            _ = try await app.routePlatformLink(URL(string: "tmplapp://invite/accept?inviteToken=bogus")!)
            XCTFail("a bogus invitation was accepted")
        } catch let error as HttpError {
            // The server judged the token: the link reached `invitations.accept`.
            XCTAssertTrue((400..<500).contains(error.status), "\(error)")
        }
        await TestApp.tearDown(app)
    }

    func testAnyOtherLinkIsTheAppsOwn() async throws {
        let app = try await TestApp.initialized()
        for raw in ["tmplapp://settings", "https://elsewhere.example.com/notes/1"] {
            let url = URL(string: raw)!
            let outcome = try await app.routePlatformLink(url)
            XCTAssertEqual(outcome, .notAPlatformLink(url), raw)
        }
        await TestApp.tearDown(app)
    }
}
