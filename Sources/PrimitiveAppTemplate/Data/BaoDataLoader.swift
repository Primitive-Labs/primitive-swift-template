import Foundation
import SwiftUI
import JsBaoClient

// MARK: - LoaderTrigger

/// What makes a `BaoDataLoader` reload (debounced).
///
/// The default, `[.onDb3Events]`, reloads when a db3 this client holds
/// becomes ready, goes away, or is evicted. Add `.onModel(subscribe:)` for a
/// generated model's record changes:
///
/// ```swift
/// loader.bind(client: appState.client,
///             subscribeTo: [.onDb3Events, .onModel(subscribe: Contact.subscribe)]) { _ in
///     try Contact.findAll()
/// }
/// ```
enum LoaderTrigger {
    /// Reload on `db3:ready` (a subscription reached `live`), `db3:gone` (the
    /// room stopped syncing it with this user) and `db3:evicted` (its records
    /// left this device), for any db3.
    case onDb3Events

    /// Reload when the connection comes back. For REST-backed loaders.
    case onConnect

    /// Reload when a generated model's records change, in any db3: pass the
    /// generated `Model.subscribe` static. The callback is `@Sendable`; it
    /// fires on whichever thread committed the change.
    case onModel(subscribe: (@escaping @Sendable () -> Void) -> @Sendable () -> Void)

    /// Install your own subscription: receive the client and a reload
    /// callback, return the subscription (the loader cancels it on `unbind`)
    /// or nil.
    case custom((JsBaoClient, @escaping () -> Void) -> EventSubscription?)

    /// The events `.onDb3Events` subscribes to, in order.
    static let db3EventTypes: [any JsBaoEventPayload.Type] = [
        Db3ReadyEvent.self,
        Db3GoneEvent.self,
        Db3EvictedEvent.self,
    ]
}

// MARK: - LoaderPhase

/// View-facing trinary load state. Returned by `BaoDataLoader.phase`.
///
/// The `loader.data ?? []` pattern is a common foot-gun: it collapses
/// "first load hasn't completed yet" and "first load completed, no
/// results" into the same view branch, so empty-state placeholders
/// flash for ~50ms (or longer if a parent view does async setup
/// before binding) on every fresh detail-view appearance.
///
/// `LoaderPhase` distinguishes the two without making callers
/// remember to inspect `initialDataLoaded`:
///
/// ```swift
/// switch loader.phase {
/// case .loading:        ProgressView()
/// case .empty:          EmptyState()
/// case .loaded(let d):  List(d) { row in … }
/// }
/// ```
enum LoaderPhase<Data> {
    case loading
    case empty
    case loaded(Data)
}

/// Protocol the loader uses to decide whether loaded data is empty
/// (and therefore should surface as `.empty` rather than `.loaded`).
///
/// `[T]` and `String` get conformances out of the box. Custom `Data`
/// types (tuples, structs of aggregated values, etc.) that want to
/// participate in `.empty` should adopt this protocol. Types that
/// don't conform are always treated as non-empty when present —
/// callers will only see `.loading` and `.loaded(data)`.
protocol LoaderEmptiness {
    var isLoaderEmpty: Bool { get }
}

extension Array: LoaderEmptiness {
    var isLoaderEmpty: Bool { isEmpty }
}

extension String: LoaderEmptiness {
    var isLoaderEmpty: Bool { isEmpty }
}

extension Optional: LoaderEmptiness where Wrapped: LoaderEmptiness {
    var isLoaderEmpty: Bool {
        switch self {
        case .none: return true
        case .some(let w): return w.isLoaderEmpty
        }
    }
}

// MARK: - BaoDataLoader

/// Reactive data-loading helper, the Swift twin of the web template's
/// `useJsBaoDataLoader`. Owns one piece of fetched data and the event
/// subscriptions that should cause it to refresh.
///
/// Generic over `Data` so callers pick the return shape — a single record,
/// `[T]`, a tuple/struct of derived values, anything. The `load` closure is
/// arbitrary, so the same loader works for model records, raw REST
/// resources, or multi-source aggregations.
///
/// Differences from JS:
/// - Drops the second `Q` (queryParams) generic. Filter state lives in the
///   View as `@State`; trigger reloads from `.onChange(of:)`.
/// - `subscribeTo` takes a `[LoaderTrigger]` enum array instead of model
///   classes (the Swift model facade's per-class pub/sub is `Model.subscribe`; the
///   equivalent reactivity is `JsBaoClient.stream(for:)` /
///   `observeOnMainActor(_:handler:)`).
/// - Settable `ready` / `isPaused` / `debounceInterval` properties so
///   you can flip them mid-flight without rebinding.
/// - `error` is `@Published` (in addition to the optional `onError` callback).
///
/// Usage, with a `Contact` model generated from a db3 type:
/// ```swift
/// @StateObject private var loader = BaoDataLoader<[Contact]>()
///
/// var body: some View {
///     List(loader.data ?? []) { /* ... */ }
///         .task {
///             loader.bind(client: appState.client,
///                         subscribeTo: [.onDb3Events, .onModel(subscribe: Contact.subscribe)]) { _ in
///                 try Contact.findAll()
///             }
///         }
/// }
/// ```
///
/// Cleanup happens automatically: `BaoDataLoader.deinit` cancels event
/// subscriptions and the pending reload Task, and `@StateObject` deinits the
/// loader when the view is destroyed. **Don't** wire `.onDisappear { loader.unbind() }`
/// — inside a `NavigationSplitView` detail slot, SwiftUI routes a stale
/// disappearance event through `_AppearanceActionModifier` on the *new* view
/// instance milliseconds after `.task` runs, which would cancel the
/// just-scheduled reload Task and leave the view permanently empty on
/// re-open. If you genuinely need to release subscriptions before the view
/// is destroyed (e.g. a loader owned by a long-lived view model), call
/// `unbind()` from a non-lifecycle hook.
@MainActor
final class BaoDataLoader<Data>: ObservableObject {

    // MARK: - Published State

    /// Latest successfully loaded data, or `nil` before the first load completes.
    @Published private(set) var data: Data?

    /// `true` after the first successful load (resets when `ready` becomes `false`).
    /// Distinguishes "still loading" from "loaded but empty" so views can show the
    /// right placeholder.
    @Published private(set) var initialDataLoaded = false

    /// `true` while a load is currently in flight.
    @Published private(set) var isLoading = false

    /// Last error from `load` (cleared on the next successful load). Surface this
    /// in your view if you want users to see failures instead of silently empty
    /// lists.
    @Published private(set) var error: Error?

    /// Anti-flash loading flag. Gate your skeleton/placeholder UI on this
    /// instead of `phase == .loading` (or `isLoading`) when you want to avoid
    /// a skeleton flashing on fast warm reloads. Mirrors the JS
    /// `useJsBaoDataLoader`'s `showSkeleton`:
    ///
    ///  - `true` immediately while the data is not ready to read (`ready` is
    ///    `false`, say until a db3's `ready()` returns) — no load runs yet.
    ///  - once `ready` is `true` and a load is in flight but the first
    ///    load hasn't completed, `true` only after the load has run longer than
    ///    ``skeletonDelay`` — so a warm reload that resolves from local state
    ///    in a few milliseconds never flashes a skeleton.
    ///  - `false` once the first load completes (`initialDataLoaded`), and
    ///    stays `false` across reactive reloads.
    ///
    /// ```swift
    /// if loader.showSkeleton {
    ///     SkeletonList()
    /// } else {
    ///     switch loader.phase { … }
    /// }
    /// ```
    @Published private(set) var showSkeleton: Bool = false

    /// View-facing trinary phase. The canonical `List(loader.data ?? [])`
    /// shape collapses "still loading" and "loaded but empty" into the
    /// same render — so views that show an empty-state placeholder
    /// flash that placeholder for the duration of the first load. Prefer
    /// this property:
    ///
    /// ```swift
    /// switch loader.phase {
    /// case .loading:       ProgressView()
    /// case .empty:         EmptyState()
    /// case .loaded(let d): List(d) { … }
    /// }
    /// ```
    ///
    /// The phase is derived from `initialDataLoaded` + `data`; it
    /// always returns `.loading` until the first successful load lands.
    /// `.empty` requires the loaded `Data` to satisfy `LoaderEmptiness`
    /// — `[T]` and `String` get conformances out of the box; custom
    /// `Data` types must adopt `LoaderEmptiness` to participate.
    var phase: LoaderPhase<Data> {
        guard initialDataLoaded, let data else { return .loading }
        if let empty = data as? LoaderEmptiness, empty.isLoaderEmpty {
            return .empty
        }
        return .loaded(data)
    }

    // MARK: - Configuration

    /// Gate for the loader: while `false`, no loads run and `initialDataLoaded`
    /// resets to `false`. Flip to `true` once the data is readable (a db3's
    /// `ready()` returned) and the loader runs an immediate load.
    var ready: Bool = true {
        didSet {
            guard oldValue != ready else { return }
            handleReadyChange()
        }
    }

    /// Pause flag. While `true`, no loads (manual or scheduled) run.
    var isPaused: Bool = false

    /// Debounce interval for scheduled reloads. Default 50ms.
    var debounceInterval: TimeInterval = 0.05

    /// Delay before ``showSkeleton`` flips to `true` while a first load is in
    /// flight (with `ready == true`). If the load completes before
    /// this delay, the skeleton never shows. Default 100ms. The Swift analogue
    /// of the JS loader's `skeletonDelayMs` option (seconds here, matching
    /// ``debounceInterval``'s units).
    var skeletonDelay: TimeInterval = 0.1

    // MARK: - Private state

    private weak var client: JsBaoClient?
    private var loadClosure: (@MainActor (JsBaoClient) async throws -> Data)?
    private var onErrorCallback: ((Error) -> Void)?
    private var subscriptions: [EventSubscription] = []
    private var reloadTask: Task<Void, Never>?
    private var loadGeneration: Int = 0

    /// Timer that flips `skeletonDelayElapsed` once `skeletonDelay` passes while
    /// a first load is in flight. `nil` when not armed.
    private var skeletonTimerTask: Task<Void, Never>?

    /// `true` once the skeleton-delay timer has fired during an in-flight first
    /// load. Feeds `showSkeleton` while `ready` and not yet loaded.
    private var skeletonDelayElapsed: Bool = false

    init() {}

    deinit {
        // We can't touch MainActor state from deinit, but cancelling
        // EventSubscriptions and Tasks is safe from any thread.
        for sub in subscriptions { sub.cancel() }
        reloadTask?.cancel()
        skeletonTimerTask?.cancel()
    }

    // MARK: - Bind / unbind

    /// Wire the loader up to a client and a load closure, install any event
    /// subscriptions in `subscribeTo`, and (if `ready`) trigger an
    /// initial load.
    ///
    /// Safe to call from `.task` / `.onAppear`. Calling `bind` again replaces
    /// the previous binding (subscriptions are cancelled, then reinstalled).
    ///
    /// - Parameters:
    ///   - client: The connected `JsBaoClient`. Pass `nil` to no-op.
    ///   - subscribeTo: Event triggers that should schedule a reload. Default
    ///     is `[.onDb3Events]`. Pass `[]` to disable automatic reloads (you'll
    ///     have to call `.reload()` yourself after every mutation).
    ///   - load: The load closure. Receives the client; returns the data.
    ///     Errors thrown here are caught, stored on `error`, and forwarded to
    ///     `onError`. The closure is `@MainActor`-isolated (it runs on the
    ///     main actor, like the rest of this loader), so you can read
    ///     `@MainActor` state — e.g. a model read like
    ///     `try Contact.findAll()` — directly, without wrapping it in
    ///     `await MainActor.run { … }`. (`find`/`findAll` are synchronous
    ///     throwing reads: a stored row that fails typed decode throws
    ///     `PrimitiveDecodeError`, which this loader surfaces on
    ///     `error`/`onError` instead of silently dropping the row. The closure
    ///     itself is `async` so it can also do async work like REST reads.)
    ///   - onError: Optional error callback (called in addition to setting
    ///     `error`).
    func bind(
        client: JsBaoClient?,
        subscribeTo: [LoaderTrigger] = [.onDb3Events],
        load: @escaping @MainActor (JsBaoClient) async throws -> Data,
        onError: ((Error) -> Void)? = nil
    ) {
        // Tear down any prior binding before installing the new one.
        unbind()

        guard let client else { return }

        self.client = client
        self.loadClosure = load
        self.onErrorCallback = onError

        installSubscriptions(client: client, triggers: subscribeTo)

        if ready && !isPaused {
            scheduleReload()
        }
    }

    /// Tear down: cancel subscriptions, cancel any pending reload task, clear
    /// the load closure, reset published state.
    func unbind() {
        for sub in subscriptions { sub.cancel() }
        subscriptions.removeAll()
        reloadTask?.cancel()
        reloadTask = nil
        loadGeneration &+= 1
        client = nil
        loadClosure = nil
        onErrorCallback = nil
        data = nil
        initialDataLoaded = false
        isLoading = false
        error = nil
        skeletonTimerTask?.cancel()
        skeletonTimerTask = nil
        skeletonDelayElapsed = false
        showSkeleton = false
    }

    // MARK: - Reload

    /// Schedule a debounced reload (debounced by `debounceInterval`). Coalesces
    /// rapid bursts; the load only runs `debounceInterval` after the most
    /// recent call.
    func reload() {
        scheduleReload()
    }

    /// Reload immediately, bypassing debounce. Use this when you've just
    /// completed a write and want the latest state right now.
    func reloadNow() {
        reloadTask?.cancel()
        Task { @MainActor in await performLoad() }
    }

    /// Drop the currently-loaded `data` (and any error) without tearing down
    /// the binding. Resets `initialDataLoaded` so the view falls back to its
    /// loading state.
    ///
    /// Use this when the *parameters* of what you're loading change — e.g.
    /// switching the selected db3 — and you want the UI to stop
    /// showing the previous result the instant the user switches, instead of
    /// hanging onto stale data until the next load lands.
    func clear() {
        // Bump the generation so any in-flight load drops its result on the
        // floor instead of resurrecting the cleared state.
        loadGeneration &+= 1
        reloadTask?.cancel()
        reloadTask = nil
        data = nil
        error = nil
        initialDataLoaded = false
        isLoading = false
        disarmSkeletonTimer()
    }

    /// Reload immediately and wait for completion. Use this from button
    /// actions when you want the caller to know when the load has finished
    /// (e.g. so a `DemoButton` can keep its spinner visible until the data
    /// actually arrives).
    func reloadNowAwaiting() async {
        reloadTask?.cancel()
        await performLoad()
    }

    /// - Parameter reactive: `true` when a subscription event asked for this
    ///   reload. Those fire from the moment the loader binds, and a
    ///   large initial sync delivers one notification per record, so they pay
    ///   the debounce even before the first load has finished — taking the
    ///   first-load fast path there would cancel and restart a load per record
    ///   instead of coalescing the burst into one.
    private func scheduleReload(reactive: Bool = false) {
        guard ready, !isPaused, loadClosure != nil else { return }
        reloadTask?.cancel()
        // Retire the load in flight now rather than when the reload starts: a
        // reload has been decided on, so a load that resolves during the
        // debounce window must not publish its (usually empty) result and mark
        // the loader loaded.
        loadGeneration &+= 1
        // The debounce exists to coalesce bursts of *reactive* reloads (model
        // events). The FIRST load shouldn't pay it: delaying it 50ms is what
        // makes a `.loading` ProgressView flash before instantly-available
        // local data lands. Run load #0 immediately; debounce the rest.
        let delay = (initialDataLoaded || reactive) ? debounceInterval : 0
        reloadTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.performLoad()
        }
    }

    private func performLoad() async {
        guard ready, !isPaused else { return }
        guard let client, let load = loadClosure else { return }

        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        // Start the anti-flash timer only for the first load. If it completes
        // before `skeletonDelay`, `disarmSkeletonTimer()` below cancels the
        // timer and the skeleton never shows.
        if !initialDataLoaded { armSkeletonTimer() }

        do {
            let result = try await load(client)
            // If `unbind` (or another load) ran while we were awaiting, drop
            // this result on the floor — it's stale.
            guard generation == loadGeneration else { return }
            data = result
            error = nil
            if !initialDataLoaded {
                initialDataLoaded = true
            }
            disarmSkeletonTimer()
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error
            onErrorCallback?(error)
            // Stop the anti-flash timer on failure. If we left it armed (or
            // `skeletonDelayElapsed` already set), then — because a failed load
            // never sets `initialDataLoaded` — `showSkeleton` would compute to
            // `true` and stay stuck, hiding the error UI behind the skeleton.
            // Disarming clears the flag and refreshes `showSkeleton` to `false`
            // so the error surfaces. (This deliberately diverges from the JS
            // loader, which keeps the skeleton on error: Swift exposes a public
            // `error` flag, so the view should render the error, not a skeleton.)
            disarmSkeletonTimer()
        }

        isLoading = false
    }

    // MARK: - Ready transitions

    private func handleReadyChange() {
        if !ready {
            // Not ready again (another db3, say): the next ready runs the
            // initial load again.
            initialDataLoaded = false
            reloadTask?.cancel()
            reloadTask = nil
            // The skeleton timer runs independently of `reloadTask`, so cancel
            // it too and clear `skeletonDelayElapsed`. Otherwise a timer still
            // armed from the interrupted load could fire against the previous
            // load's start time, or a leftover elapsed flag could make the next
            // load's skeleton appear immediately instead of after `skeletonDelay`.
            // `disarmSkeletonTimer()` also calls `refreshShowSkeleton()`, which
            // flips the skeleton on immediately here — while the data is
            // (re)opening no load runs yet, so the delay timer wouldn't cover
            // this wait.
            disarmSkeletonTimer()
            return
        }

        refreshShowSkeleton()
        if !isPaused, loadClosure != nil {
            scheduleReload()
        }
    }

    // MARK: - Anti-flash skeleton gating

    /// Recompute `showSkeleton` from the current state. Mirrors the JS
    /// `showSkeleton` computed:
    ///  - loaded             → never show
    ///  - not ready          → show immediately (`ready == false`)
    ///  - ready, still loading → show only after `skeletonDelay` elapsed
    private func refreshShowSkeleton() {
        let next: Bool
        if initialDataLoaded {
            next = false
        } else if !ready {
            next = true
        } else {
            next = skeletonDelayElapsed
        }
        if showSkeleton != next {
            showSkeleton = next
        }
    }

    /// Arm the skeleton-delay timer for a first load in flight. No-op if a
    /// timer is already running or the first load has already completed.
    private func armSkeletonTimer() {
        guard skeletonTimerTask == nil, !initialDataLoaded else { return }
        let delay = skeletonDelay
        skeletonTimerTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            self.skeletonTimerTask = nil
            guard !self.initialDataLoaded else { return }
            self.skeletonDelayElapsed = true
            self.refreshShowSkeleton()
        }
    }

    /// Cancel the skeleton-delay timer and clear the elapsed flag, then refresh
    /// `showSkeleton`. Called when a load completes and when state resets.
    private func disarmSkeletonTimer() {
        skeletonTimerTask?.cancel()
        skeletonTimerTask = nil
        skeletonDelayElapsed = false
        refreshShowSkeleton()
    }

    // MARK: - Subscriptions

    private func installSubscriptions(client: JsBaoClient, triggers: [LoaderTrigger]) {
        // `@Sendable` so it can be handed to the model-subscription triggers,
        // whose callbacks fire off the main thread. The body only
        // hops to the main actor, so it captures nothing thread-bound.
        // deliberately NOT gated on the first load having finished.
        // The loader used to arm its subscriptions only once a load had
        // succeeded, to avoid double-fetching when an event arrived mid-load.
        // That is precisely the event worth keeping: the initial sync of a
        // db3 opened with an empty local replica lands while the first
        // load is still reading, so gating it left the view on the empty
        // result with nothing left to move it. The extra fetch is cheap, the
        // debounce coalesces bursts of them, and the generation counter in
        // `performLoad` makes sure the load that started last is the one whose
        // result lands.
        let scheduleReloadFromEvent: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.ready, !self.isPaused else { return }
                self.scheduleReload(reactive: true)
            }
        }

        for trigger in triggers {
            switch trigger {
            case .onDb3Events:
                for type in LoaderTrigger.db3EventTypes {
                    subscriptions.append(observe(type, on: client, then: scheduleReloadFromEvent))
                }

            case .onConnect:
                let sub = client.observeOnMainActor(StatusChangedEvent.self) { event in
                    if event.status == .connected {
                        scheduleReloadFromEvent()
                    }
                }
                subscriptions.append(sub)

            case .onModel(let subscribe):
                let unsubscribe = subscribe {
                    scheduleReloadFromEvent()
                }
                subscriptions.append(EventSubscription(cancel: unsubscribe))

            case .custom(let installer):
                if let sub = installer(client, scheduleReloadFromEvent) {
                    subscriptions.append(sub)
                }
            }
        }
    }

    /// One `observeOnMainActor` subscription for an event type named at run time.
    private func observe<E: JsBaoEventPayload>(
        _ type: E.Type,
        on client: JsBaoClient,
        then reload: @escaping @Sendable () -> Void
    ) -> EventSubscription {
        client.observeOnMainActor(type) { _ in reload() }
    }
}
