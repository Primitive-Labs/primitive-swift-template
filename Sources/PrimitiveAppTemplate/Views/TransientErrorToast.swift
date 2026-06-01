import SwiftUI

/// Bottom-anchored toast for per-mutation errors that shouldn't take
/// over the whole screen. Pairs with `TemplateAppState.transientError`
/// and `setTransientError(_:)` — see the docstring there for when to
/// use this vs. the full-screen alert backed by `errorMessage`.
///
/// Wire it into the root view with an overlay:
///
///   AppTabView()
///       .overlay(alignment: .bottom) {
///           TransientErrorToast(message: appState.transientError) {
///               appState.transientError = nil
///           }
///       }
///
/// The view is its own dismiss target — tapping the close icon clears
/// the binding immediately. The auto-dismiss timer is owned by
/// `setTransientError`; this view doesn't need to know about it.
struct TransientErrorToast: View {
    let message: String?
    let onDismiss: () -> Void

    var body: some View {
        // `.transition(.move + .opacity)` slides the toast up from
        // below and fades it in, then reverses on dismiss. The
        // `.animation(_, value:)` binding is on `message` (not a
        // separate `isPresented`) so an in-place message swap (one
        // error replaced by another before the first auto-dismissed)
        // crossfades rather than pops.
        Group {
            if let message {
                toastBody(message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    private func toastBody(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                // Hierarchical rendering makes the warning triangle's
                // foreground/midground/background layers share one tint
                // so we get a multi-tone glyph without picking individual
                // colors. Auto-handles disabled state and dynamic type.
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.subheadline)
                .lineLimit(3)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

#Preview("With message") {
    ZStack {
        Color(.sRGB, white: 0.95, opacity: 1).ignoresSafeArea()
        TransientErrorToast(
            message: "Couldn't save todo: schema validation failed",
            onDismiss: {}
        )
    }
}

#Preview("Empty") {
    TransientErrorToast(message: nil, onDismiss: {})
}
