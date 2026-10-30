import Foundation
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// `AppState` against the test backend: how it builds the client, connects,
/// loads the profile, tracks db3s and signs out.
@MainActor
final class AppStateTests: XCTestCase {
    func testTheClientCarriesTheSessionThePasskeyRelyingPartyAndTheSchemeOptIn() {
        var config = AppConfig(appId: "01APP", appName: "Notes", serverUrl: "https://api.example.com", webUrl: "https://notes.example.com")
        let options = AppState.clientOptions(config: config, storage: .memory)
        XCTAssertEqual(options.apiUrl, "https://api.example.com")
        XCTAssertEqual(options.wsUrl, "wss://api.example.com")
        XCTAssertEqual(options.appId, "01APP")
        XCTAssertTrue(options.auth.persistJwtInStorage)
        XCTAssertEqual(options.auth.storageKeyPrefix, "01APP")
        XCTAssertEqual(options.auth.passkeyRpId, "notes.example.com")
        XCTAssertNil(options.auth.oauthRedirectUri)
        XCTAssertFalse(options.autoNetwork)

        config.oauthRedirectUri = "notes://oauth/callback"
        XCTAssertEqual(AppState.clientOptions(config: config, storage: .memory).auth.oauthRedirectUri, "notes://oauth/callback")
    }

    func testInitializeWiresTheWebOriginAndTheSchemeOptInIntoTheClient() async throws {
        let web = try await TestApp.initialized(config: TestApp.config(webUrl: "https://notes.example.com"))
        XCTAssertEqual(web.client?.links.appBaseURL?.absoluteString, "https://notes.example.com")
        XCTAssertEqual(web.client?.auth.emailSignInLinkTarget(), "https://notes.example.com/oauth/callback")

        let scheme = try await TestApp.initialized(config: TestApp.config(oauthRedirectUri: "tmplapp://oauth/callback"))
        XCTAssertNil(scheme.client?.links.appBaseURL)
        XCTAssertEqual(scheme.client?.auth.emailSignInLinkTarget(), "tmplapp://oauth/callback")

        let plain = try await TestApp.initialized()
        XCTAssertNil(plain.client?.auth.emailSignInLinkTarget(), "no web origin and no opt-in: a code-only email")

        // A webUrl that is not a bare origin is no web counterpart at all.
        let junk = try await TestApp.initialized(config: TestApp.config(webUrl: "https://notes.example.com/app?x=1"))
        XCTAssertNil(junk.client?.links.appBaseURL)
        XCTAssertNil(junk.client?.auth.emailSignInLinkTarget())
        XCTAssertNil(AppState.clientOptions(config: try TestApp.config(webUrl: "notes.example.com"), storage: .memory).auth.passkeyRpId)

        for app in [web, scheme, plain, junk] { await TestApp.tearDown(app) }
    }

    func testAMissingPrimitiveJsonSetsAnErrorNamingTheResolver() async {
        let appState = AppState(auth: AuthModel(defaults: TestApp.scratchDefaults()))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/primitive.json")
        await appState.initialize(storage: .memory, configSearchPaths: [missing])
        XCTAssertFalse(appState.isInitialized)
        XCTAssertNil(appState.client)
        XCTAssertTrue(appState.errorMessage?.contains("scripts/resolve-primitive-config.sh") == true, appState.errorMessage ?? "nil")
    }

    func testConnectingLoadsTheProfileAndRefreshReReadsIt() async throws {
        let app = try await TestApp.signedIn()
        let email = try TestEnvironment.fromEnvironment().email
        XCTAssertTrue(app.isConnected)
        XCTAssertEqual(app.connectionStatus, "Connected")
        XCTAssertEqual(app.userEmail.lowercased(), email.lowercased())
        XCTAssertFalse(app.userName.isEmpty)

        let name = "Refreshed \(UUID().uuidString.prefix(6))"
        _ = try await XCTUnwrap(app.client).me.update(params: UpdateMeParams(name: name))
        await app.refreshProfile()
        XCTAssertEqual(app.userName, name)
        await TestApp.tearDown(app)
    }

    func testAConnectThatTimesOutFinishesWhenTheConnectionArrives() async throws {
        let app = try await TestApp.initialized()
        await app.auth.verifyOtp(email: try TestEnvironment.fromEnvironment().email, code: TestEnvironment.otpCode)
        try await eventually("signed in") { app.auth.isAuthenticated }

        app.connectTimeout = 0
        await app.connectClient()
        XCTAssertEqual(app.errorMessage, AppState.connectionErrorMessage)
        XCTAssertEqual(app.connectionStatus, "Error")

        try await eventually("connected, and the profile loaded") { app.isConnected && !app.userEmail.isEmpty }
        XCTAssertNil(app.errorMessage)
        await TestApp.tearDown(app)
    }

    func testSignOutDisposesTrackedDb3sEvictsThemAndClearsTheAccount() async throws {
        let app = try await TestApp.signedIn()
        let client = try XCTUnwrap(app.client)
        let info = try await client.db3.create(title: "Template sign-out")
        let subscription = try app.subscribe(db3: info.id)
        try await subscription.ready()
        XCTAssertEqual(app.trackedDb3Ids, [info.id])
        let resident = try await client.db3.state(info.id).resident
        XCTAssertTrue(resident)

        let evicted = EventLog()
        let heard = client.observeOnMainActor(Db3EvictedEvent.self) { event in evicted.ids.append(event.id) }
        app.errorMessage = "left over"
        await app.signOut()

        try await eventually("the db3 evicted") { evicted.ids.contains(info.id) }
        XCTAssertEqual(app.trackedDb3Ids, [])
        XCTAssertFalse(app.auth.isAuthenticated)
        XCTAssertEqual(app.userName, "")
        XCTAssertEqual(app.userEmail, "")
        XCTAssertNil(app.userAvatarUrl)
        XCTAssertNil(app.errorMessage)
        if let state = try? await client.db3.state(info.id) {
            XCTAssertFalse(state.resident, "no local copy after sign-out")
        }
        heard.cancel()
        await client.destroy()
    }

    func testASignOutWhileConnectingPublishesNothingForTheOldAccount() async throws {
        let app = try await TestApp.initialized()
        await app.auth.verifyOtp(email: try TestEnvironment.fromEnvironment().email, code: TestEnvironment.otpCode)
        try await eventually("signed in") { app.auth.isAuthenticated }

        app.connectTimeout = 30
        let connecting = Task { await app.connectClient() }
        await app.signOut()
        await connecting.value
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(app.userEmail, "")
        XCTAssertEqual(app.userName, "")
        XCTAssertNil(app.errorMessage)
        await app.client?.destroy()
    }
}

/// Event ids a test heard, on the main actor.
@MainActor
final class EventLog {
    var ids: [String] = []
}
