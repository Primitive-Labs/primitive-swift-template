import Foundation
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// `AuthModel` against the test backend: the emailed-code flow, the failure
/// it shows for a wrong code, and sign-out.
@MainActor
final class AuthModelTests: XCTestCase {
    func testTheProvidersLoadAndAnEmailRequestMovesToCheckEmail() async throws {
        let app = try await TestApp.initialized()
        let email = try TestEnvironment.fromEnvironment().email
        try await eventually("the auth config") { app.auth.availableProviders != nil }
        XCTAssertEqual(app.auth.availableProviders?.email, true)

        await app.auth.requestEmailSignIn(email: email)
        XCTAssertEqual(app.auth.loginState, .emailSent(email: email), app.auth.authError ?? "")
        XCTAssertNil(app.auth.authFailure)
        await TestApp.tearDown(app)
    }

    func testAWrongCodeStaysOnCheckEmailWithTheInvalidCodeMessage() async throws {
        let app = try await TestApp.initialized()
        let email = try TestEnvironment.fromEnvironment().email
        await app.auth.verifyOtp(email: email, code: "123456")
        XCTAssertEqual(app.auth.loginState, .emailSent(email: email))
        XCTAssertEqual(app.auth.authError, AuthModel.invalidOtpMessage)
        XCTAssertFalse(app.auth.isAuthenticated)
        XCTAssertFalse(app.auth.isAuthenticating)
        await TestApp.tearDown(app)
    }

    func testTheCodeSignsInAndLogoutSignsOut() async throws {
        let app = try await TestApp.initialized()
        await app.auth.verifyOtp(email: try TestEnvironment.fromEnvironment().email, code: TestEnvironment.otpCode)
        try await eventually("signed in") { app.auth.isAuthenticated }
        XCTAssertNotNil(app.auth.userId)
        XCTAssertEqual(app.auth.loginState, .initial)
        XCTAssertNil(app.auth.authFailure)
        XCTAssertEqual(app.auth.lastSignIn?.cause, "otpVerify")
        XCTAssertNotNil(app.auth.lastSignIn?.isNewUser)

        await app.auth.logout()
        XCTAssertFalse(app.auth.isAuthenticated)
        XCTAssertNil(app.auth.userId)
        XCTAssertNil(app.auth.authFailure)
        XCTAssertNil(app.auth.lastSignIn)
        await app.client?.destroy()
    }

    func testOnlyACodeTheServerRejectsReadsAsAnInvalidCode() {
        XCTAssertEqual(AuthModel.otpVerifyMessage(for: HttpError(status: 401, message: "x", serverMessage: "Invalid or expired code")), AuthModel.invalidOtpMessage)
        XCTAssertEqual(
            AuthModel.otpVerifyMessage(for: HttpError(status: 401, message: "x", serverCode: "UNAUTHENTICATED", serverMessage: "Invalid or expired code")),
            AuthModel.invalidOtpMessage
        )
        XCTAssertEqual(
            AuthModel.otpVerifyMessage(for: HttpError(status: 400, message: "x", serverCode: "INVALID_REQUEST", serverMessage: "Invalid code format")),
            AuthModel.invalidOtpMessage
        )
        XCTAssertEqual(
            AuthModel.otpVerifyMessage(for: HttpError(status: 403, message: "x", serverCode: "ADDED_TO_WAITLIST", serverMessage: "You're on the waitlist")),
            "You're on the waitlist"
        )
        XCTAssertEqual(
            AuthModel.otpVerifyMessage(for: HttpError(status: 401, message: "x", serverCode: "OTP_MAX_ATTEMPTS", serverMessage: "Too many attempts")),
            "Too many attempts"
        )
    }

    func testAWaitlistedAddressGetsTheWaitlistScreen() {
        let waitlisted = HttpError(status: 403, message: "x", serverCode: "ADDED_TO_WAITLIST", serverMessage: "queued")
        XCTAssertEqual(AuthModel.failureState(for: waitlisted, email: "a@example.com", otherwise: .initial), .waitlisted(email: "a@example.com"))
        XCTAssertEqual(AuthModel.failureState(for: URLError(.notConnectedToInternet), email: "a@example.com", otherwise: .initial), .initial)
    }
}
