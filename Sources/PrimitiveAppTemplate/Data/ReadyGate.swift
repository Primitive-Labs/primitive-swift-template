import SwiftUI

/// Renders its content only once an awaited value is available, showing a
/// placeholder until then.
///
/// The things a screen reads — a db3 id the app resolved after sign-in, a
/// subscription that has to reach `ready()` — are `nil` for the first beat
/// after launch. A screen that reads them in `.task` sees `nil`, and the
/// naive
///
/// ```swift
/// .task {
///     guard let notesId = appState.notesId else { return }   // bails on first appear
///     loader.bind(client: appState.client) { … }
/// }
/// ```
///
/// silently never binds: the `.task` runs once, before the value arrives.
/// `ReadyGate` mounts the content only **after** the value is non-`nil`, so
/// the content can read it unconditionally:
///
/// ```swift
/// ReadyGate(appState.notesId) { notesId in
///     NotesScreen(notesId: notesId)
/// }
/// ```
///
/// Gate **once, as high as makes sense** (e.g. wrapping a tab's root)
/// and every screen below it can be written assuming its data is ready.
/// Because `value` is read in `body`, the gate re-evaluates whenever the
/// owning `ObservableObject` publishes — so the content appears the
/// instant the value flips from `nil` to non-`nil`.
///
/// The default placeholder is a centered `ProgressView`; supply your own
/// with the two-closure initializer.
struct ReadyGate<Value, Content: View, Placeholder: View>: View {
    private let value: Value?
    private let content: (Value) -> Content
    private let placeholder: () -> Placeholder

    /// - Parameters:
    ///   - value: The awaited optional. While `nil`, `placeholder` shows;
    ///     once non-`nil`, `content` is mounted with the unwrapped value.
    ///   - content: Builds the ready UI from the unwrapped value.
    ///   - placeholder: Shown while `value` is `nil`.
    init(
        _ value: Value?,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.value = value
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        if let value {
            content(value)
        } else {
            placeholder()
        }
    }
}

extension ReadyGate where Placeholder == ReadyGateProgress {
    /// Convenience using the default centered `ProgressView` placeholder.
    init(_ value: Value?, @ViewBuilder content: @escaping (Value) -> Content) {
        self.init(value, content: content, placeholder: { ReadyGateProgress() })
    }
}

/// The default `ReadyGate` placeholder: a `ProgressView` centered in the
/// available space.
struct ReadyGateProgress: View {
    init() {}
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
