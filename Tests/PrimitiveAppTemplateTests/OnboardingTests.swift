import Foundation
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// The onboarding flow: the name step saves through the profile API, an
/// avatar goes up before the name, and the passkey step's outcomes.
@MainActor
final class OnboardingTests: XCTestCase {
    func testTheNameStepSavesTheNameThenNotNowDeclinesOnThisDevice() async throws {
        let app = try await TestApp.signedIn()
        let flow = OnboardingFlow(steps: [.name, .passkey], appState: app)
        let name = "Onboarded \(UUID().uuidString.prefix(6))"
        flow.name = name
        await flow.continueFromName(avatar: nil)
        XCTAssertNil(flow.message)
        XCTAssertEqual(flow.current, .passkey)
        XCTAssertEqual(app.userName, name)
        let saved = try await XCTUnwrap(app.client).me.get()
        XCTAssertEqual(saved?.name, name)

        XCTAssertFalse(app.auth.declinedPasskeyOnDevice)
        flow.notNow()
        XCTAssertTrue(flow.isFinished)
        XCTAssertTrue(app.auth.declinedPasskeyOnDevice)
        XCTAssertEqual(
            OnboardingPlan.make(
                isNewUser: true, cause: "otpVerify", promptAddPasskey: true, passkeysAvailable: true,
                accountHasPasskeys: false, declinedOnDevice: app.auth.declinedPasskeyOnDevice
            ),
            [.name],
            "the next sign-in plans no passkey step"
        )
        await TestApp.tearDown(app)
    }

    func testABlankNameContinuesWithoutAWrite() async throws {
        let app = try await TestApp.signedIn()
        let client = try XCTUnwrap(app.client)
        let kept = "Kept \(UUID().uuidString.prefix(6))"
        _ = try await client.me.update(params: UpdateMeParams(name: kept))

        let flow = OnboardingFlow(steps: [.name], appState: app)
        flow.name = "   "
        await flow.continueFromName(avatar: nil)
        XCTAssertNil(flow.message)
        XCTAssertTrue(flow.isFinished)
        let profile = try await client.me.get()
        XCTAssertEqual(profile?.name, kept)
        await TestApp.tearDown(app)
    }

    func testTheAvatarGoesUpBeforeTheName() async throws {
        let app = try await TestApp.signedIn()
        let client = try XCTUnwrap(app.client)
        let before = "Before \(UUID().uuidString.prefix(6))"
        _ = try await client.me.update(params: UpdateMeParams(name: before))

        // An avatar the server refuses stops the step before the name is saved.
        let flow = OnboardingFlow(steps: [.name], appState: app)
        flow.name = "After \(UUID().uuidString.prefix(6))"
        await flow.continueFromName(avatar: TestImages.oversized)
        XCTAssertNotNil(flow.message)
        XCTAssertEqual(flow.current, .name)
        let unchanged = try await client.me.get()
        XCTAssertEqual(unchanged?.name, before)

        await flow.continueFromName(avatar: TestImages.pixel)
        XCTAssertNil(flow.message)
        XCTAssertTrue(flow.isFinished)
        XCTAssertEqual(app.userName, flow.name)
        XCTAssertNotNil(app.userAvatarUrl)
        await TestApp.tearDown(app)
    }

    // MARK: - The passkey step, with the registration injected

    private func passkeyFlow(_ register: @escaping @MainActor (String?) async throws -> Void) -> (OnboardingFlow, AuthModel) {
        let auth = AuthModel(defaults: TestApp.scratchDefaults())
        auth.passkeyRegistration = register
        let flow = OnboardingFlow(
            steps: [.passkey],
            saveProfile: { _, _ in },
            enrollPasskey: { await auth.enrollPasskey() },
            declinePasskey: { auth.declinePasskeyEnrollment() }
        )
        return (flow, auth)
    }

    func testACancelledPasskeySheetLeavesTheStepWithNoFailure() async {
        let (flow, auth) = passkeyFlow { _ in throw PasskeyError.canceled }
        await flow.addPasskey()
        XCTAssertEqual(flow.current, .passkey)
        XCTAssertNil(flow.message)
        XCTAssertNil(auth.authFailure)
        XCTAssertFalse(auth.declinedPasskeyOnDevice)
    }

    func testAFailedRegistrationShowsItsMessageAndKeepsItsCode() async {
        let (flow, auth) = passkeyFlow { _ in
            throw AuthError(code: .passkeyRpNotConfigured, message: "Passkeys are not set up for this app")
        }
        await flow.addPasskey()
        XCTAssertEqual(flow.current, .passkey)
        XCTAssertEqual(flow.message, "Passkeys are not set up for this app")
        XCTAssertEqual(auth.authFailure?.code, .passkeyRpNotConfigured)
    }

    func testARegisteredPasskeyFinishesTheStepAndMarksTheDevice() async {
        let (flow, auth) = passkeyFlow { _ in }
        await flow.addPasskey()
        XCTAssertTrue(flow.isFinished)
        XCTAssertTrue(auth.hasLocalPasskeyHint)
        XCTAssertNil(auth.authFailure)
    }
}
