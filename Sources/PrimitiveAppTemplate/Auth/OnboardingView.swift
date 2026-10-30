import PhotosUI
import SwiftUI
import JsBaoClient

// MARK: - The plan

/// One onboarding screen.
enum OnboardingStep: Equatable, Sendable {
    /// Name and an optional avatar.
    case name
    /// Offer to add a passkey.
    case passkey
}

/// Which onboarding steps a sign-in gets. The same rule as the web
/// template's onboarding:
///
/// - a returning user gets none;
/// - a new user gets the name step;
/// - then the passkey step, when the app offers passkeys, the sign-in was not
///   itself a passkey, this device has not declined, and the server suggested
///   one or the account has none.
enum OnboardingPlan {
    static func make(
        isNewUser: Bool?,
        cause: String,
        promptAddPasskey: Bool?,
        passkeysAvailable: Bool,
        accountHasPasskeys: Bool,
        declinedOnDevice: Bool
    ) -> [OnboardingStep] {
        guard cause != "passkeyAuth", isNewUser == true else { return [] }
        var steps: [OnboardingStep] = [.name]
        if passkeysAvailable,
           !declinedOnDevice,
           promptAddPasskey == true || !accountHasPasskeys {
            steps.append(.passkey)
        }
        return steps
    }
}

// MARK: - The flow

/// The onboarding sheet's state: which step shows, what it is doing, and what
/// went wrong. The work is injected, so the steps can be driven without a
/// sheet.
@MainActor
final class OnboardingFlow: ObservableObject {
    @Published private(set) var steps: [OnboardingStep]
    @Published private(set) var index = 0
    @Published var name = ""
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    private let saveProfile: @MainActor (String, AvatarImage?) async throws -> Void
    private let enrollPasskey: @MainActor () async -> AuthModel.EnrollOutcome
    private let declinePasskey: @MainActor () -> Void

    init(
        steps: [OnboardingStep],
        saveProfile: @escaping @MainActor (String, AvatarImage?) async throws -> Void,
        enrollPasskey: @escaping @MainActor () async -> AuthModel.EnrollOutcome,
        declinePasskey: @escaping @MainActor () -> Void
    ) {
        self.steps = steps
        self.saveProfile = saveProfile
        self.enrollPasskey = enrollPasskey
        self.declinePasskey = declinePasskey
    }

    /// The flow for a signed-in app: saves through `AppState`, enrolls and
    /// declines through `AuthModel`.
    convenience init(steps: [OnboardingStep], appState: AppState) {
        self.init(
            steps: steps,
            saveProfile: { [weak appState] name, avatar in try await appState?.saveProfile(name: name, avatar: avatar) },
            enrollPasskey: { [weak appState] in await appState?.auth.enrollPasskey() ?? .cancelled },
            declinePasskey: { [weak appState] in appState?.auth.declinePasskeyEnrollment() }
        )
    }

    var current: OnboardingStep? { index < steps.count ? steps[index] : nil }
    var isFinished: Bool { current == nil }

    /// Continue from the name step: upload the avatar, then save the name
    /// (a blank name is skipped, as on the web). A failure stays on the step.
    func continueFromName(avatar: AvatarImage?) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await saveProfile(name, avatar)
            advance()
        } catch {
            message = AppState.saveFailureMessage(error)
        }
    }

    /// Add a passkey. A cancelled system sheet leaves the step as it was; a
    /// failure shows its message and stays.
    func addPasskey() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        switch await enrollPasskey() {
        case .enrolled: advance()
        case .cancelled: break
        case .failed(let text): message = text
        }
    }

    /// "Not now": never prompt on this device again.
    func notNow() {
        declinePasskey()
        advance()
    }

    private func advance() {
        message = nil
        index += 1
    }
}

// MARK: - The sheet

/// The onboarding sheet `AuthGate` presents after a new user signs in.
struct OnboardingView: View {
    @ObservedObject var flow: OnboardingFlow
    let onFinish: () -> Void

    @State private var photo: PhotosPickerItem?
    @State private var avatar: AvatarImage?
    @State private var isLoadingPhoto = false
    @State private var avatarError: String?

    var body: some View {
        VStack(spacing: 20) {
            switch flow.current {
            case .name: nameStep
            case .passkey: passkeyStep
            case nil: ProgressView()
            }
            if let message = flow.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .onChange(of: flow.isFinished) { _, finished in
            if finished { onFinish() }
        }
        // A new selection cancels the load of the one it replaces.
        .task(id: photo) { await load(photo) }
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            Text("Welcome")
                .font(.title2)
                .fontWeight(.semibold)
            Text("What should we call you?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Your name", text: $flow.name)
                .textFieldStyle(.roundedBorder)
                .textContentType(.name)
                .accessibilityIdentifier("primitive.onboarding.nameField")
            let photoTitle = isLoadingPhoto ? "Loading photo…" : avatar == nil ? "Add a photo" : "Change photo"
            PhotosPicker(selection: $photo, matching: .images) {
                Label(photoTitle, systemImage: "person.crop.circle.badge.plus")
            }
            .accessibilityIdentifier("primitive.onboarding.choosePhoto")
            if let avatarError {
                Text(avatarError).font(.caption).foregroundStyle(.red)
            }
            Button {
                Task { await flow.continueFromName(avatar: avatar) }
            } label: {
                HStack {
                    if flow.isWorking { ProgressView() }
                    Text("Continue")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(flow.isWorking || isLoadingPhoto)
            .accessibilityIdentifier("primitive.onboarding.continue")
        }
    }

    private var passkeyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Sign in faster next time")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Add a passkey to sign in with Face ID or Touch ID — no email codes, nothing to remember.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await flow.addPasskey() }
            } label: {
                HStack {
                    if flow.isWorking { ProgressView() } else { Image(systemName: "faceid") }
                    Text("Add Passkey")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(flow.isWorking)
            Button("Not Now") { flow.notNow() }
                .font(.subheadline)
                .accessibilityIdentifier("primitive.passkey.notNow")
        }
    }

    /// Load the picked photo. Continue waits while it loads, so a slow
    /// (iCloud) photo is never left out; a load a newer selection replaced
    /// publishes nothing.
    private func load(_ item: PhotosPickerItem?) async {
        avatarError = nil
        avatar = nil
        guard let item else { isLoadingPhoto = false; return }
        isLoadingPhoto = true
        let data = try? await item.loadTransferable(type: Data.self)
        guard !Task.isCancelled else { return }
        isLoadingPhoto = false
        guard let data else {
            avatarError = AvatarImageError.notAnImage.localizedDescription
            return
        }
        switch AvatarImage.prepare(data) {
        case .success(let image): avatar = image
        case .failure(let error): avatarError = error.localizedDescription
        }
    }
}
