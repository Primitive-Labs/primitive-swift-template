import Foundation
import SwiftUI
import PrimitiveApp
import JsBaoClient

/// App-specific state. Subclasses `PrimitiveAppState` to extend the
/// post-connect flow with a per-user singleton document. Bind your
/// `TypedModel<T>` instances inside `onDocumentOpened(doc:documentId:)`
/// once you've defined a model in `Models/schema.toml`.
///
/// This template demonstrates the **canonical** Primitive shape for a
/// "one document per user" app:
///
/// 1. After the websocket connects, resolve-or-create one user-scoped
///    document via an atomic alias upsert (`getOrCreateWithAlias`).
/// 2. Open that doc through the base class's `selectDocumentAwaiting`
///    so sync/remoteUpdate event routing and the debug inspector stay
///    consistent.
/// 3. Bind your `TypedModel<T>` instances inside the
///    `onDocumentOpened(doc:documentId:)` hook — you get the live
///    `YDocument` handle, no re-open needed.
///
/// Replace the `app_root` alias key with something descriptive of your
/// app's per-user state shape.
@MainActor
final class TemplateAppState: PrimitiveAppState {

    // ----------------------------------------------------------------
    // Define your TypedModel<T> bindings here once you've added models
    // to `Models/schema.toml` and codegen has emitted the types. The
    // shape below is the canonical one — un-comment and adapt.
    //
    //   @Published private(set) var items: TypedModel<ItemRecord>?
    //
    // Then bind in `onDocumentOpened` (override defined below).
    // ----------------------------------------------------------------

    // MARK: - Error channels
    //
    // Two separate channels for two different shapes of failure:
    //
    //  • `errorMessage` (inherited from `PrimitiveAppState`) — used by
    //    the framework for fatal/blocking errors (connection failure,
    //    config missing, document open failed). Rendered as a full-screen
    //    alert via `.alert(...)` in `ContentView`. The user has to
    //    dismiss it before continuing — appropriate for "the app can't
    //    proceed."
    //
    //  • `transientError` (below) — for per-mutation, retryable failures
    //    like a `try todos.create(...)` that threw on schema validation,
    //    or a `client.documents.update` that hit a network blip. These
    //    don't block the app and shouldn't interrupt the user; render as
    //    a bottom-anchored toast that auto-dismisses. See
    //    `TransientErrorToast` in `Views/`.
    //
    // Call `setTransientError(...)` rather than assigning directly so
    // the auto-dismiss timer fires.
    @Published var transientError: String?

    private var transientErrorDismissTask: Task<Void, Never>?

    /// Show `message` in the transient-error toast and clear it after
    /// `seconds`. Subsequent calls cancel the prior auto-dismiss so the
    /// latest message owns the full timeout window — without this, two
    /// errors in quick succession would let the first message's timer
    /// clear the second one early.
    func setTransientError(_ message: String, dismissAfter seconds: Double = 4.0) {
        transientError = message
        transientErrorDismissTask?.cancel()
        transientErrorDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.transientError = nil }
        }
    }

    /// Extend the base connect flow: after super.connectClient() brings
    /// up the websocket and fetches the doc list, kick off our
    /// app-specific singleton-doc setup. `connectClient` is `open` on
    /// the base class precisely so subclasses can do this without
    /// having to thread their own Combine sink on `$isConnected`.
    public override func connectClient() async {
        await super.connectClient()
        await openSingletonDoc()
    }

    /// Resolve-or-create the user's singleton doc via a server-side
    /// atomic alias upsert.
    ///
    /// **Why `getOrCreateWithAlias` and not `aliases.resolve` +
    /// `createWithAlias`?** The two-step has a TOCTOU window where two
    /// clients onboarding at the same moment both fall into the
    /// "create" branch. The single-call helper is race-free; the
    /// server reconciles.
    private func openSingletonDoc() async {
        guard let client else { return }
        do {
            // TODO: replace "app_root" / "App Root" with a key + title
            // describing your app's per-user state (e.g. "todos" /
            // "Todos", "library" / "Library"). The aliasKey is the wire
            // identity of this user's singleton doc — pick once, then
            // don't rename without a migration plan.
            // `DocumentAlias` / `AliasedDocument` are PrimitiveApp's typed
            // forms — prefer them over a raw `[String: Any]` alias dict and
            // `result["documentId"] as? String`.
            let result = try await client.documents.getOrCreateWithAlias(
                alias: DocumentAlias(scope: .user, aliasKey: "app_root"),
                title: "App Root"
            )
            let docId = result.documentId

            // `selectDocumentAwaiting` is the base class's full open
            // flow: it closes any prior doc, opens this one, routes
            // the base class's sync / remoteUpdate hooks at this doc
            // id, and finally calls `onDocumentOpened(doc:documentId:)`
            // below with the live YDocument. Prefer this over a raw
            // `client.openDocument(...)` so the base bookkeeping —
            // selectedDocId, isSynced, debug inspector event routing —
            // stays consistent.
            await selectDocumentAwaiting(docId)
        } catch {
            errorMessage = "Failed to set up doc: \(error.localizedDescription)"
        }
    }

    /// Called by the base class once the singleton doc is open. The
    /// `YDocument` handle comes through so you can immediately bind
    /// `TypedModel<T>` instances without re-opening the doc.
    ///
    /// Prefer `makeTypedModel(doc:documentId:)` over direct
    /// `TypedModel<T>(doc:)` construction — it ALSO registers the
    /// model with the in-app debug inspector tab.
    ///
    /// Example, after adding an `ItemRecord` model to schema.toml:
    ///
    ///   public override func onDocumentOpened(doc: YDocument, documentId: String) async {
    ///       items = makeTypedModel(doc: doc, documentId: documentId)
    ///   }
    public override func onDocumentOpened(
        doc: YDocument,
        documentId: String
    ) async {
        // Bind your TypedModel<T> instances here once you've defined
        // models in schema.toml. See the example in the docstring above.
    }
}
