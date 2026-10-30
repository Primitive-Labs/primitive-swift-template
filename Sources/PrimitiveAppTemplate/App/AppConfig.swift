import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveAppTemplate", category: "Config")

/// The app's configuration: `primitive.json`, plus one optional Info.plist key.
///
/// `primitive.json` is a BUILD PRODUCT, not a tracked file: the app ID and
/// server URL are typed once in `primitive/config.json`, and
/// `scripts/resolve-primitive-config.sh` writes the selected environment's
/// values into it before every build. Never hand-edit it; change the
/// environment instead (`primitive env use <name>`).
struct AppConfig: Equatable, Sendable {
    var appId: String
    var appName: String
    var serverUrl: String

    /// The app's web counterpart, the origin its web client is served from
    /// (`https://notes.example.com`, or `http://localhost:5173` in dev), or nil
    /// for an app with no web client.
    ///
    /// One value with two jobs: the client points an emailed sign-in link at
    /// this origin's `/oauth/callback` (an https link iOS opens straight into
    /// this app when it is installed, and an ordinary web sign-in anywhere
    /// else), and it trusts an incoming universal link from the same origin.
    var webUrl: String?

    /// Where an emailed sign-in link should land instead, when the app wants a
    /// custom-scheme link (`<scheme>://oauth/callback`): the
    /// `PrimitiveOAuthRedirectURI` key in `Info-Partial.plist`. Nil, the
    /// default, leaves the choice to the client. Forwarded unchanged as the
    /// client's `options.auth.oauthRedirectUri`.
    var oauthRedirectUri: String?

    init(
        appId: String,
        appName: String,
        serverUrl: String = "https://primitiveapi.com",
        webUrl: String? = nil,
        oauthRedirectUri: String? = nil
    ) {
        self.appId = appId
        self.appName = appName
        self.serverUrl = serverUrl
        self.webUrl = webUrl
        self.oauthRedirectUri = oauthRedirectUri
    }

    /// The WebSocket URL derived from the server URL.
    var wsUrl: String {
        serverUrl
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }

    /// The Info.plist key that opts the app into custom-scheme sign-in links.
    static let oauthRedirectUriInfoKey = "PrimitiveOAuthRedirectURI"

    /// Load the first `primitive.json` among `searchPaths` — by default the
    /// working directory (`./run.sh`), then the app bundle (Xcode and the
    /// simulator) — and read the `PrimitiveOAuthRedirectURI` key from
    /// `infoDictionary`.
    static func load(
        searchPaths: [URL]? = nil,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Result<AppConfig, AppConfigError> {
        let fm = FileManager.default
        let candidates = searchPaths ?? [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("primitive.json"),
            Bundle.main.url(forResource: "primitive", withExtension: "json"),
        ].compactMap { $0 }
        guard let path = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            logger.error("primitive.json not found in any candidate path")
            return .failure(.noAppConfig)
        }
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appId = json["appId"] as? String else {
            return .failure(.noAppConfig)
        }
        logger.info("Loaded primitive.json from \(path.path, privacy: .public)")
        return .success(AppConfig(
            appId: appId,
            appName: json["appName"] as? String ?? appId,
            serverUrl: json["serverUrl"] as? String ?? "https://primitiveapi.com",
            // A non-string value is absent, not something to make a URL of.
            webUrl: json["webUrl"] as? String,
            oauthRedirectUri: oauthRedirectUri(infoDictionary: infoDictionary)
        ))
    }

    /// The `PrimitiveOAuthRedirectURI` value, or nil when the key is absent,
    /// empty, or not a string.
    static func oauthRedirectUri(infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?[oauthRedirectUriInfoKey] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The app's web origin as a URL, or nil when the environment names none.
    ///
    /// Anything that is not a bare web origin resolves to nil, which reads as
    /// "no web counterpart": https (http only on `localhost`/`127.0.0.1`), no
    /// path, query, fragment or credentials. `primitive env add --web-url`
    /// refuses those shapes already; this is the floor for a `primitive.json`
    /// written by hand.
    static func linksBaseURL(webUrl: String?) -> URL? {
        guard let trimmed = webUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else { return nil }
        if scheme == "http" && host != "localhost" && host != "127.0.0.1" { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = components.port, port != (scheme == "https" ? 443 : 80) {
            origin += ":\(port)"
        }
        return URL(string: origin)
    }

    /// The passkey relying party the environment implies: the host of its
    /// web origin, the RP a browser on that origin would use. Nil when there
    /// is no web origin, and for an IP-literal host, which is never a valid
    /// relying-party id.
    static func defaultPasskeyRpId(webUrl: String?) -> String? {
        guard let host = linksBaseURL(webUrl: webUrl)?.host,
              IPv4Address(host) == nil,
              IPv6Address(host) == nil else { return nil }
        return host
    }
}

/// Why the configuration could not be loaded.
enum AppConfigError: Error, CustomStringConvertible, Equatable {
    case noAppConfig

    var description: String {
        switch self {
        case .noAppConfig:
            return """
                No primitive.json found. It is generated from the Primitive \
                environment selected in primitive/config.json — run \
                `bash scripts/resolve-primitive-config.sh` (run.sh, run-ios.sh, \
                archive.sh and the Xcode pre-build phase all do this for you).
                """
        }
    }
}
