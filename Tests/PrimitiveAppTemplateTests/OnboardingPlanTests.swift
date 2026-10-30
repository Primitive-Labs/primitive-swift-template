import XCTest
@testable import PrimitiveAppTemplate

/// Which onboarding steps a sign-in gets (the web template's rule).
final class OnboardingPlanTests: XCTestCase {
    private func plan(
        isNewUser: Bool? = true,
        cause: String = "otpVerify",
        promptAddPasskey: Bool? = nil,
        passkeysAvailable: Bool = true,
        accountHasPasskeys: Bool = false,
        declinedOnDevice: Bool = false
    ) -> [OnboardingStep] {
        OnboardingPlan.make(
            isNewUser: isNewUser,
            cause: cause,
            promptAddPasskey: promptAddPasskey,
            passkeysAvailable: passkeysAvailable,
            accountHasPasskeys: accountHasPasskeys,
            declinedOnDevice: declinedOnDevice
        )
    }

    func testANewUserFromEveryInteractiveSignInGetsTheNameStepFirst() {
        for cause in ["otpVerify", "magicLinkVerify", "oauthCallback", "apple"] {
            XCTAssertEqual(plan(cause: cause), [.name, .passkey], cause)
            XCTAssertEqual(plan(cause: cause, passkeysAvailable: false), [.name], cause)
        }
    }

    func testAReturningUserGetsNothing() {
        XCTAssertEqual(plan(isNewUser: false), [])
        XCTAssertEqual(plan(isNewUser: false, promptAddPasskey: true), [])
    }

    func testAnUnknownNewUserFlagPlansNothing() {
        XCTAssertEqual(plan(isNewUser: nil), [])
    }

    func testAPasskeySignInGetsNothing() {
        XCTAssertEqual(plan(cause: "passkeyAuth"), [])
    }

    func testThePasskeyStepNeedsPasskeysOnTheAppAndNoDeclineOnTheDevice() {
        XCTAssertEqual(plan(passkeysAvailable: false), [.name])
        XCTAssertEqual(plan(declinedOnDevice: true), [.name])
        XCTAssertEqual(plan(promptAddPasskey: true, declinedOnDevice: true), [.name])
    }

    func testThePasskeyStepNeedsTheServersPromptOrAnAccountWithNone() {
        XCTAssertEqual(plan(promptAddPasskey: true, accountHasPasskeys: true), [.name, .passkey])
        XCTAssertEqual(plan(promptAddPasskey: false, accountHasPasskeys: true), [.name])
        XCTAssertEqual(plan(promptAddPasskey: false, accountHasPasskeys: false), [.name, .passkey])
        // No word from the server: the account's own passkeys decide.
        XCTAssertEqual(plan(promptAddPasskey: nil, accountHasPasskeys: true), [.name])
        XCTAssertEqual(plan(promptAddPasskey: nil, accountHasPasskeys: false), [.name, .passkey])
    }
}
