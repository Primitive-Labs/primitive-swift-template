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

    func testTheCodeFieldKeepsTheFirstSixDigits() {
        XCTAssertEqual(AuthModel.otpLength, 6)
        XCTAssertEqual(LoginView.otpFieldText("0000000000"), "000000")
        XCTAssertEqual(LoginView.otpFieldText("1234567890"), "123456")
        XCTAssertEqual(LoginView.otpFieldText("12345"), "12345")
        XCTAssertEqual(LoginView.otpFieldText(""), "")
    }

    func testTheCodeFieldDropsAnythingButDigits() {
        XCTAssertEqual(LoginView.otpFieldText("123 456"), "123456")
        XCTAssertEqual(LoginView.otpFieldText("123-456-789"), "123456")
        XCTAssertEqual(LoginView.otpFieldText(" Your code: 654321\n"), "654321")
        XCTAssertEqual(LoginView.otpFieldText("abcdef"), "")
        // Only ASCII digits: the server's code is 0-9.
        XCTAssertEqual(LoginView.otpFieldText("١٢٣٤٥٦"), "")
        XCTAssertEqual(LoginView.otpFieldText("１２３456"), "456")
    }

    func testVerifyNeedsExactlySixDigits() {
        XCTAssertTrue(LoginView.canVerify(otpCode: "123456"))
        XCTAssertFalse(LoginView.canVerify(otpCode: ""))
        XCTAssertFalse(LoginView.canVerify(otpCode: "12345"))
        XCTAssertFalse(LoginView.canVerify(otpCode: "1234567"))
        XCTAssertFalse(LoginView.canVerify(otpCode: "0000000000"))
        XCTAssertFalse(LoginView.canVerify(otpCode: "12345a"))
        XCTAssertFalse(LoginView.canVerify(otpCode: "123 45"))
    }
}
