import XCTest

/// The template's flows driven through the real UI against the real backend:
/// code sign-in and onboarding, a profile name edit, invitation accept,
/// sign-out. The avatar is not driven here: the system Photos picker runs out
/// of process, where XCUITest cannot reach its photos; the template's own
/// `ProfileTests` (`./test.sh`) cover the avatar upload. Run by
/// `./ui-test.sh`, which starts every run with the app uninstalled.
///
/// The tests run in name order and build on each other: the first signs in,
/// and the session it leaves in the simulator's keychain is what the next
/// ones relaunch into. Sign in as an address that has never signed in to this
/// app, so the onboarding screens appear.
///
/// The runner's environment (from `TEST_RUNNER_*` in xcodebuild's):
/// - `PRIMITIVE_TEST_EMAIL`: the `+primitivetest` address to sign in as.
/// - `PRIMITIVE_TEST_INVITE_URL`: a pending invitation's link in this app's
///   URL scheme; the invite test is skipped without it.
@MainActor
final class TemplateFlowUITests: XCTestCase {
    /// What onboarding saves as the name, and what the profile edit changes
    /// it to. The scaffold suite reads both back from the server.
    static let onboardingName = "Scaffold UI"
    static let editedName = "Scaffold UI Edited"

    /// The test account's one-time code (the server's `+primitivetest` bypass).
    static let testCode = "000000"

    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        // A screenshot of where a failed test stopped, kept in the result
        // bundle `./ui-test.sh` writes under build/ui/.
        if let run = testRun, run.totalFailureCount > 0 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(name) — failure"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    // MARK: - Flows

    func test1_signInWithCodeAndOnboard() throws {
        let email = try environment("PRIMITIVE_TEST_EMAIL")
        app.launch()

        let emailField = app.textFields["primitive.login.emailField"]
        require(emailField, "the login screen's email field (the app should start signed out)")
        emailField.tap()
        emailField.typeText(email)
        app.buttons["primitive.login.emailSubmit"].tap()

        let otpField = app.textFields["primitive.login.otpField"]
        require(otpField, "the code field after requesting a sign-in email")
        otpField.tap()
        otpField.typeText(Self.testCode)
        app.buttons["primitive.login.otpVerify"].tap()

        // A first sign-in plans the name step; the passkey step follows only
        // when the app offers passkeys.
        let nameField = app.textFields["primitive.onboarding.nameField"]
        require(nameField, "onboarding's name step after a first sign-in")
        nameField.tap()
        nameField.typeText(Self.onboardingName)
        app.buttons["primitive.onboarding.continue"].tap()

        let notNow = app.buttons["primitive.passkey.notNow"]
        if notNow.waitForExistence(timeout: 10) {
            notNow.tap()
        }
        require(home, "the home screen after onboarding")
    }

    func test2_editProfileName() throws {
        app.launch()
        openProfileTab()

        app.buttons["primitive.profile.edit"].tap()
        let nameField = app.textFields["primitive.profile.nameField"]
        require(nameField, "the profile editor's name field")
        replaceText(in: nameField, with: Self.editedName)

        app.buttons["primitive.profile.save"].tap()
        // The sheet closes on a successful save and the profile shows the name.
        let shownName = app.staticTexts.matching(
            NSPredicate(format: "identifier == 'primitive.profile.name' AND label == %@", Self.editedName)
        ).firstMatch
        require(shownName, "the profile showing the edited name after save", timeout: 30)
    }

    func test3_acceptInvitationFromLink() throws {
        guard let link = ProcessInfo.processInfo.environment["PRIMITIVE_TEST_INVITE_URL"], !link.isEmpty,
              let url = URL(string: link)
        else {
            throw XCTSkip("PRIMITIVE_TEST_INVITE_URL is not set: no invitation to accept")
        }
        app.launch()
        require(home, "the home screen, signed in")

        XCUIDevice.shared.system.open(url)
        // iOS asks before a custom-scheme link opens an app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }

        let accepted = app.buttons.matching(identifier: "primitive.invite.accepted").firstMatch
        require(accepted, "the invitation-accepted alert", timeout: 30)
        accepted.tap()
    }

    func test4_signOut() throws {
        app.launch()
        openProfileTab()

        let signOut = app.buttons["primitive.profile.signOut"]
        if !signOut.waitForExistence(timeout: 5) { app.swipeUp() }
        require(signOut, "the profile's Sign Out button")
        signOut.tap()
        require(app.textFields["primitive.login.emailField"], "the login screen after signing out")

        // Signed out stays signed out.
        app.terminate()
        app.launch()
        require(app.textFields["primitive.login.emailField"], "the login screen after a relaunch")
    }

    // MARK: - Helpers

    /// The home view. SwiftUI hands the identifier to the view's children (its
    /// image and texts), so any element carrying it is the home screen.
    private var home: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "primitive.template.home").firstMatch
    }

    private func environment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            XCTFail("\(name) is not set in the test runner's environment (TEST_RUNNER_\(name) in xcodebuild's)")
            throw XCTSkip("\(name) is not set")
        }
        return value
    }

    /// Fail naming what never appeared, with the app's element tree.
    private func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("Never saw \(what) within \(Int(timeout)) s.\n\(app.debugDescription)", file: file, line: line)
        }
    }

    private func openProfileTab() {
        let tab = app.tabBars.buttons["Profile"]
        require(tab, "the Profile tab (the app should already be signed in)")
        tab.tap()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        if !current.isEmpty && current != placeholder {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
}
