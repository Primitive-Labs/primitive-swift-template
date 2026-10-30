import Foundation
import XCTest
@testable import PrimitiveAppTemplate

/// The configuration rules, with no backend: where the web origin, the
/// passkey relying party and the scheme-link opt-in come from.
final class AppConfigTests: XCTestCase {
    func testABareHttpsOriginIsTheLinksBase() {
        XCTAssertEqual(AppConfig.linksBaseURL(webUrl: "https://notes.example.com")?.absoluteString, "https://notes.example.com")
        XCTAssertEqual(AppConfig.linksBaseURL(webUrl: " https://Notes.Example.com/ ")?.absoluteString, "https://notes.example.com")
        XCTAssertEqual(AppConfig.linksBaseURL(webUrl: "https://notes.example.com:443")?.absoluteString, "https://notes.example.com")
        XCTAssertEqual(AppConfig.linksBaseURL(webUrl: "https://notes.example.com:8443")?.absoluteString, "https://notes.example.com:8443")
        XCTAssertEqual(AppConfig.linksBaseURL(webUrl: "http://localhost:5173")?.absoluteString, "http://localhost:5173")
    }

    func testAnythingThatIsNotABareWebOriginHasNoLinksBase() {
        for value in [
            nil, "", "   ", "notes.example.com", "http://notes.example.com", "ftp://notes.example.com",
            "https://notes.example.com/app", "https://notes.example.com/?x=1", "https://notes.example.com/#top",
            "https://user:pw@notes.example.com", "myapp://oauth/callback",
        ] {
            XCTAssertNil(AppConfig.linksBaseURL(webUrl: value), String(describing: value))
            XCTAssertNil(AppConfig.defaultPasskeyRpId(webUrl: value), String(describing: value))
        }
    }

    func testThePasskeyRelyingPartyIsTheWebOriginsHost() {
        XCTAssertEqual(AppConfig.defaultPasskeyRpId(webUrl: "https://notes.example.com"), "notes.example.com")
        XCTAssertEqual(AppConfig.defaultPasskeyRpId(webUrl: "http://localhost:5173"), "localhost")
    }

    func testAnIpLiteralHostDerivesNoRelyingParty() {
        XCTAssertNil(AppConfig.defaultPasskeyRpId(webUrl: "http://127.0.0.1:5173"))
        XCTAssertNil(AppConfig.defaultPasskeyRpId(webUrl: "https://[::1]"))
        XCTAssertNotNil(AppConfig.linksBaseURL(webUrl: "http://127.0.0.1:5173"))
    }

    func testTheSchemeLinkOptInIsReadFromTheInfoDictionary() {
        XCTAssertEqual(
            AppConfig.oauthRedirectUri(infoDictionary: ["PrimitiveOAuthRedirectURI": "tmplapp://oauth/callback"]),
            "tmplapp://oauth/callback"
        )
        XCTAssertNil(AppConfig.oauthRedirectUri(infoDictionary: nil))
        XCTAssertNil(AppConfig.oauthRedirectUri(infoDictionary: [:]))
        XCTAssertNil(AppConfig.oauthRedirectUri(infoDictionary: ["PrimitiveOAuthRedirectURI": ""]))
        XCTAssertNil(AppConfig.oauthRedirectUri(infoDictionary: ["PrimitiveOAuthRedirectURI": "  "]))
        XCTAssertNil(AppConfig.oauthRedirectUri(infoDictionary: ["PrimitiveOAuthRedirectURI": 42]))
    }

    func testLoadReadsPrimitiveJsonAndTheInfoKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("primitive.json")
        try Data(#"{"appId":"01APP","appName":"Notes","serverUrl":"http://127.0.0.1:8787","webUrl":"https://notes.example.com"}"#.utf8)
            .write(to: file)

        let loaded = try AppConfig.load(
            searchPaths: [file],
            infoDictionary: ["PrimitiveOAuthRedirectURI": "notes://oauth/callback"]
        ).get()
        XCTAssertEqual(loaded, AppConfig(
            appId: "01APP",
            appName: "Notes",
            serverUrl: "http://127.0.0.1:8787",
            webUrl: "https://notes.example.com",
            oauthRedirectUri: "notes://oauth/callback"
        ))
        XCTAssertEqual(loaded.wsUrl, "ws://127.0.0.1:8787")
        XCTAssertNil(try AppConfig.load(searchPaths: [file], infoDictionary: [:]).get().oauthRedirectUri)
    }

    func testAMissingPrimitiveJsonNamesTheResolver() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/primitive.json")
        guard case .failure(let error) = AppConfig.load(searchPaths: [missing], infoDictionary: nil) else {
            return XCTFail("a missing primitive.json loaded")
        }
        XCTAssertEqual(error, .noAppConfig)
        XCTAssertTrue(error.description.contains("scripts/resolve-primitive-config.sh"), error.description)
    }
}
