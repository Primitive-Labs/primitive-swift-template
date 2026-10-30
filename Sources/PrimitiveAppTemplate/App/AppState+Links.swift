import Foundation
import JsBaoClient

/// What `AppState.routePlatformLink(_:)` did with a URL.
enum PlatformLinkOutcome: Sendable, Equatable {
    /// An invitation link: the invitation was accepted.
    case acceptedInvitation(documents: Int, groups: Int)
    /// An emailed sign-in link: the client verified it and signed in.
    case signedIn
    /// Not a link the template routes. Your app's own routes go here.
    case notAPlatformLink(URL)
}

extension AppState {
    /// Route a link from `.onOpenURL` or a universal link:
    ///
    /// - an invitation (`…?inviteToken=…`) is accepted;
    /// - an emailed sign-in link goes to `client.auth.handleSignInCallback`,
    ///   which decides whether the URL is one it accepts; a refusal is
    ///   published on `auth` and thrown;
    /// - anything else returns `.notAPlatformLink` for the app's own routes.
    ///
    /// A custom-scheme link is trusted without configuration (only this app
    /// receives its scheme); a web link only from the origin `webUrl` names.
    func routePlatformLink(_ url: URL) async throws -> PlatformLinkOutcome {
        guard let client = await waitForClient() else {
            throw JsBaoError(code: .unavailable, message: "The link arrived before the client was ready")
        }
        switch try await client.links.resolve(url: url) {
        case .invitation(let token):
            let result = try await client.invitations.accept(inviteToken: token)
            return .acceptedInvitation(
                documents: result.grantsResolved.documents,
                groups: result.grantsResolved.groups
            )
        case .magicLink:
            try await auth.handleSignInCallback(url)
            return .signedIn
        case .document, .unknown:
            return .notAPlatformLink(url)
        }
    }

    /// The client, waiting briefly for `initialize()` when a link arrives at
    /// launch.
    private func waitForClient(timeout: TimeInterval = 5) async -> JsBaoClient? {
        let deadline = Date().addingTimeInterval(timeout)
        while client == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return client
    }
}
