import Foundation
import XCTest
import JsBaoClient
@testable import PrimitiveAppTemplate

/// How many times a loader's `load` ran, on the main actor.
@MainActor
final class LoadCount {
    var value = 0
}

/// The reload callback a `.custom` trigger was handed.
@MainActor
final class ReloadHook {
    var reload: (() -> Void)?
}

/// A model-subscription callback a test fires by hand.
final class ModelChange: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private(set) var unsubscribed = false

    func subscribe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.withLock { self.callback = callback }
        return { [self] in lock.withLock { unsubscribed = true; self.callback = nil } }
    }

    func fire() {
        lock.withLock { callback }?()
    }
}

/// `BaoDataLoader`: its db3 triggers against the test backend, and the
/// loader rules that need no backend.
@MainActor
final class BaoDataLoaderTests: XCTestCase {
    private func counting(_ loader: BaoDataLoader<Int>, client: JsBaoClient?, triggers: [LoaderTrigger] = [.onDb3Events]) -> LoadCount {
        let count = LoadCount()
        loader.bind(client: client, subscribeTo: triggers) { _ in
            count.value += 1
            return count.value
        }
        return count
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    // MARK: - db3 events (live)

    func testADb3BecomingReadyAndBeingEvictedEachReloadOnce() async throws {
        let app = try await TestApp.signedIn()
        let client = try XCTUnwrap(app.client)
        let info = try await client.db3.create(title: "Loader")

        let loader = BaoDataLoader<Int>()
        let count = counting(loader, client: client)
        try await eventually("the first load") { loader.initialDataLoaded }
        XCTAssertEqual(count.value, 1)

        let subscription = try app.subscribe(db3: info.id)
        try await subscription.ready()
        try await eventually("a reload on db3:ready") { count.value == 2 }

        // Bound after the db3 is ready: no reload until the next event.
        let late = BaoDataLoader<Int>()
        let lateCount = counting(late, client: client)
        try await eventually("the late loader's first load") { late.initialDataLoaded }
        try await settle()
        XCTAssertEqual(count.value, 2, "one reload for one ready")
        XCTAssertEqual(lateCount.value, 1)

        try await client.db3.evict(info.id, options: Db3EvictOptions(force: true))
        try await eventually("a reload on db3:evicted") { count.value == 3 && lateCount.value == 2 }
        try await settle()
        XCTAssertEqual(count.value, 3)
        XCTAssertEqual(lateCount.value, 2)
        loader.unbind()
        late.unbind()
        await TestApp.tearDown(app)
    }

    func testOnConnectReloadsWhenTheConnectionComesBack() async throws {
        let app = try await TestApp.signedIn()
        let client = try XCTUnwrap(app.client)
        let loader = BaoDataLoader<Int>()
        let count = counting(loader, client: client, triggers: [.onConnect])
        try await eventually("the first load") { loader.initialDataLoaded }

        await client.setShouldConnect(false)
        try await eventually("disconnected") { !client.isConnected }
        await client.setShouldConnect(true)
        try await eventually("a reload on reconnect") { count.value >= 2 }
        loader.unbind()
        await TestApp.tearDown(app)
    }

    // MARK: - No backend

    /// A client that never connects: enough to bind to.
    private func offlineClient() -> JsBaoClient {
        JsBaoClient(options: JsBaoClientOptions(
            apiUrl: "http://127.0.0.1:9",
            wsUrl: "ws://127.0.0.1:9",
            appId: "loader-tests",
            offline: true,
            storageConfig: .memory,
            autoNetwork: false
        ))
    }

    func testTheDb3TriggerListensForReadyGoneAndEvicted() {
        XCTAssertEqual(
            LoaderTrigger.db3EventTypes.map { String(describing: $0) },
            ["Db3ReadyEvent", "Db3GoneEvent", "Db3EvictedEvent"]
        )
    }

    func testBindingANilClientDoesNothing() async throws {
        let loader = BaoDataLoader<Int>()
        let count = counting(loader, client: nil)
        try await settle()
        XCTAssertEqual(count.value, 0)
        XCTAssertNil(loader.data)
        XCTAssertFalse(loader.isLoading)
    }

    func testTheFirstLoadSkipsTheDebounceAndAModelChangeReloads() async throws {
        let client = offlineClient()
        let change = ModelChange()
        let loader = BaoDataLoader<Int>()
        loader.debounceInterval = 0.2
        let count = counting(loader, client: client, triggers: [.onModel(subscribe: change.subscribe)])
        try await eventually("the first load, at once", timeout: 0.15) { count.value == 1 }

        change.fire()
        change.fire()
        try await eventually("one debounced reload") { count.value == 2 }
        try await settle()
        XCTAssertEqual(count.value, 2, "a burst coalesces")

        loader.unbind()
        XCTAssertTrue(change.unsubscribed)
        await client.destroy()
    }

    func testBindingAgainReplacesTheSubscriptions() async throws {
        let client = offlineClient()
        let installs = LoadCount()
        let cancels = LoadCount()
        let hook = ReloadHook()
        let trigger = LoaderTrigger.custom { _, reload in
            installs.value += 1
            hook.reload = reload
            return EventSubscription { MainActor.assumeIsolated { cancels.value += 1 } }
        }
        let loader = BaoDataLoader<Int>()
        _ = counting(loader, client: client, triggers: [trigger])
        XCTAssertEqual(cancels.value, 0)
        let second = counting(loader, client: client, triggers: [trigger])
        XCTAssertEqual(cancels.value, 1, "the first binding's subscription is cancelled")
        XCTAssertEqual(installs.value, 2)
        try await eventually("the second binding loaded") { second.value == 1 }

        hook.reload?()
        try await eventually("a custom reload") { second.value == 2 }
        loader.unbind()
        XCTAssertEqual(cancels.value, 2)
        await client.destroy()
    }

    func testALoadThatResolvesAfterUnbindOrClearPublishesNothing() async throws {
        let client = offlineClient()
        for end in ["unbind", "clear"] {
            let loader = BaoDataLoader<Int>()
            loader.bind(client: client, subscribeTo: []) { _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return 7
            }
            try await eventually("loading") { loader.isLoading }
            if end == "unbind" { loader.unbind() } else { loader.clear() }
            try await settle()
            XCTAssertNil(loader.data, end)
            XCTAssertFalse(loader.initialDataLoaded, end)
        }
        await client.destroy()
    }
}
