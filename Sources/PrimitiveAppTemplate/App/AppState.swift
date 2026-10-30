import Combine
import Foundation
import SwiftUI
import os
import JsBaoClient

private let logger = Logger(subsystem: "com.primitivelabs.PrimitiveAppTemplate", category: "AppState")

/// The app's state: the client, its connection, the signed-in profile, the
/// db3s the app reads, and the two error channels.
///
/// `initialize()` builds the client from `primitive.json`; `AuthGate` calls
/// `connectClient()` once a user signs in. Add your own per-account state
/// here and clear it in `onSignedOut()`.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Connection and profile

    @Published private(set) var isInitialized = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectionStatus = "Disconnected"

    @Published private(set) var userName = ""
    @Published private(set) var userEmail = ""
    @Published private(set) var userAvatarUrl: String?

    // MARK: - Error channels
    //
    // `errorMessage` is the fatal channel: no configuration, no connection.
    // ContentView renders it as an alert the user dismisses.
    //
    // `transientError` is for a retryable failure (a write that threw, a link
    // with no route): a toast that dismisses itself. Set it through
    // `setTransientError(_:)` so the timer runs.
    @Published var errorMessage: String?
    @Published var transientError: String?

    private var transientErrorDismissTask: Task<Void, Never>?

    /// Show `message` in the toast and clear it after `seconds`. A newer
    /// message cancels the older one's timer.
    func setTransientError(_ message: String, dismissAfter seconds: Double = 4.0) {
        transientError = message
        transientErrorDismissTask?.cancel()
        transientErrorDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.transientError = nil
        }
    }

    // MARK: - Client

    let auth: AuthModel
    private(set) var client: JsBaoClient?
    private(set) var config: AppConfig?

    /// How long `connectClient()` waits for the socket before it reports
    /// "could not connect". The client keeps retrying behind it.
    var connectTimeout: TimeInterval = 10

    private var statusSubscription: EventSubscription?
    private var signOutSubscription: AnyCancellable?

    /// Bumped at every sign-out, so a `connectClient()` still running for
    /// the previous account publishes nothing.
    private var sessionGeneration = 0

    /// Set when `connectClient()` gave up waiting, so a later `.connected`
    /// finishes it.
    private var resumesConnectOnConnected = false

    init(auth: AuthModel = AuthModel()) {
        self.auth = auth
    }

    /// Build the client and start listening for sign-in. Loads
    /// `primitive.json` (from `configSearchPaths` when given) unless `config`
    /// is; `storage` is where the client keeps its local data.
    func initialize(
        config: AppConfig? = nil,
        storage: StorageConfig = .sqlite(),
        configSearchPaths: [URL]? = nil
    ) async {
        guard client == nil else { return }
        let resolved: AppConfig
        if let config {
            resolved = config
        } else {
            switch AppConfig.load(searchPaths: configSearchPaths) {
            case .failure(let error):
                logger.error("Config error: \(error.description, privacy: .public)")
                errorMessage = error.description
                return
            case .success(let loaded):
                resolved = loaded
            }
        }
        self.config = resolved

        let client = JsBaoClient(options: Self.clientOptions(config: resolved, storage: storage))
        // The app's web origin: incoming universal links are trusted from it,
        // and the client points an emailed link at its `/oauth/callback`.
        client.links.appBaseURL = AppConfig.linksBaseURL(webUrl: resolved.webUrl)
        // The default client the generated model facades read
        // (`Contact.findAll()`, `record.save(in:)`, `Contact.subscribe`).
        JsBaoClient.configureDefault(client)
        // Register every generated model, so a db3's records reach the
        // facades the moment it opens. Empty until bao-codegen.json names a
        // db3 type.
        GeneratedModels.register(on: client)
        self.client = client

        statusSubscription = client.observeOnMainActor(StatusChangedEvent.self) { [weak self] event in
            guard let self else { return }
            switch event.status {
            case .connected:
                self.isConnected = true
                self.connectionStatus = "Connected"
                if self.resumesConnectOnConnected {
                    self.resumesConnectOnConnected = false
                    Task { await self.connectClient() }
                }
            case .connecting:
                self.connectionStatus = "Connecting..."
            case .disconnected:
                self.isConnected = false
                self.connectionStatus = "Disconnected"
            }
        }
        auth.attach(to: client)
        signOutSubscription = auth.$isAuthenticated
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.resetSignedInState() }
            }
        isInitialized = true
    }

    /// The client options `initialize` builds the client with: a persisted
    /// session, the passkey relying party `webUrl` implies, and the app's
    /// `oauthRedirectUri` forwarded unchanged (nil unless the
    /// `PrimitiveOAuthRedirectURI` Info.plist key is set).
    static func clientOptions(config: AppConfig, storage: StorageConfig) -> JsBaoClientOptions {
        JsBaoClientOptions(
            apiUrl: config.serverUrl,
            wsUrl: config.wsUrl,
            appId: config.appId,
            token: nil,
            offline: false,
            globalAdminAppId: "global-admin-app",
            logLevel: .info,
            storageConfig: storage,
            auth: AuthConfig(
                persistJwtInStorage: true,
                storageKeyPrefix: config.appId,
                passkeyRpId: AppConfig.defaultPasskeyRpId(webUrl: config.webUrl),
                oauthRedirectUri: config.oauthRedirectUri
            ),
            autoNetwork: false
        )
    }

    // MARK: - Connect

    /// Connect the signed-in client and load the profile.
    ///
    /// Waits up to `connectTimeout`. When the socket is still down it sets
    /// `errorMessage` and returns; the client keeps retrying, and the
    /// connection arriving later runs this again, clears the error and loads
    /// the profile.
    func connectClient() async {
        guard let client else { return }
        let generation = sessionGeneration
        let deadline = Date().addingTimeInterval(connectTimeout)
        connectionStatus = "Connecting..."

        // Not awaited: a stalled handshake can outlast the window, which the
        // wait below bounds. `setShouldConnect(true)` rather than `connect()`,
        // so a sign-in after a sign-out reconnects.
        Task { await client.setShouldConnect(true) }
        let connected = await waitUntilConnected(client, generation: generation, deadline: deadline)
        guard generation == sessionGeneration else { return }
        guard connected else {
            errorMessage = Self.connectionErrorMessage
            connectionStatus = "Error"
            resumesConnectOnConnected = true
            return
        }
        resumesConnectOnConnected = false
        if errorMessage == Self.connectionErrorMessage { errorMessage = nil }
        isConnected = true
        connectionStatus = "Connected"
        await refreshProfile()
    }

    static let connectionErrorMessage = "Connection error: could not connect"

    private func waitUntilConnected(_ client: JsBaoClient, generation: Int, deadline: Date) async -> Bool {
        while !client.isConnected {
            guard generation == sessionGeneration, Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Re-read the signed-in user's profile into `userName`, `userEmail` and
    /// `userAvatarUrl`.
    func refreshProfile() async {
        guard let client else { return }
        let generation = sessionGeneration
        guard let me = try? await client.me.get(), generation == sessionGeneration else { return }
        userEmail = me.email
        userName = (me.name ?? "").isEmpty ? me.email : me.name ?? ""
        userAvatarUrl = me.avatarUrl
    }

    // MARK: - db3s

    private var db3Subscriptions: [Db3Subscription] = []

    /// The db3s this account has subscribed to through `subscribe(db3:)`.
    var trackedDb3Ids: [String] { Array(Set(db3Subscriptions.map(\.id))).sorted() }

    /// Subscribe to a db3 and keep the subscription until sign-out, which
    /// disposes it and evicts the db3 from this device.
    ///
    /// ```swift
    /// let notes = try appState.subscribe(db3: notesId)
    /// try await notes.ready()
    /// ```
    func subscribe(db3 id: String, options: Db3SubscribeOptions = Db3SubscribeOptions()) throws -> Db3Subscription {
        guard let client else { throw JsBaoError(code: .unavailable, message: "The client is not initialized") }
        let subscription = try client.db3.subscribe(id, options: options)
        db3Subscriptions.append(subscription)
        return subscription
    }

    // MARK: - Sign-out

    /// Sign out: dispose every tracked db3 subscription, evict those db3s
    /// from this device, then sign the client out.
    func signOut() async {
        let ids = trackedDb3Ids
        disposeDb3Subscriptions()
        if let client {
            for id in ids {
                do {
                    try await client.db3.evict(id, options: Db3EvictOptions(force: true))
                } catch {
                    logger.error("Evicting \(id, privacy: .public) at sign-out: \(error.localizedDescription)")
                }
            }
        }
        await auth.logout()
    }

    private func disposeDb3Subscriptions() {
        db3Subscriptions.forEach { $0.dispose() }
        db3Subscriptions = []
    }

    /// Runs whenever `auth` reports signed out, whichever path got there.
    private func resetSignedInState() {
        sessionGeneration += 1
        resumesConnectOnConnected = false
        disposeDb3Subscriptions()
        userName = ""
        userEmail = ""
        userAvatarUrl = nil
        errorMessage = nil
        transientErrorDismissTask?.cancel()
        transientError = nil
        onSignedOut()
    }

    /// Clear your own per-account state here, so the next account to sign in
    /// starts empty.
    private func onSignedOut() {}
}
