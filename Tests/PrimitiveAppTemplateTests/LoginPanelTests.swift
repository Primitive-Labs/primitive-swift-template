import XCTest
@testable import PrimitiveAppTemplate

/// Which login panel each sign-in state shows.
@MainActor
final class LoginPanelTests: XCTestCase {
    func testEachStateShowsItsPanel() {
        XCTAssertEqual(LoginView.panel(for: .initial), .signIn)
        XCTAssertEqual(LoginView.panel(for: .error("x")), .signIn)
        XCTAssertEqual(LoginView.panel(for: .sendingEmail), .sendingEmail)
        XCTAssertEqual(LoginView.panel(for: .emailSent(email: "a@example.com")), .checkEmail(email: "a@example.com"))
        XCTAssertEqual(LoginView.panel(for: .verifyingOtp), .signingIn)
        XCTAssertEqual(LoginView.panel(for: .authenticating), .signingIn)
        XCTAssertEqual(LoginView.panel(for: .waitlisted(email: "a@example.com")), .waitlisted)
        XCTAssertEqual(LoginView.panel(for: .waitlisted(email: nil)), .waitlisted)
    }

    func testOnlyTheWaitlistPanelHidesTheErrorLine() {
        XCTAssertFalse(LoginView.showsErrorMessage(in: .waitlisted))
        for panel: LoginView.Panel in [.signIn, .sendingEmail, .checkEmail(email: "a@example.com"), .signingIn] {
            XCTAssertTrue(LoginView.showsErrorMessage(in: panel), "\(panel)")
        }
    }
}
