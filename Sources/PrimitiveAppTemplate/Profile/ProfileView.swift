import SwiftUI
import JsBaoClient

/// The Profile tab: avatar, name and email, Edit Profile, the account's
/// passkeys when the app offers them, and Sign Out.
struct ProfileView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var auth: AuthModel

    @State private var isEditing = false
    @State private var isAddingPasskey = false

    init(appState: AppState) {
        self.appState = appState
        self.auth = appState.auth
    }

    /// The server reports passkeys on for this app.
    private var passkeysAvailable: Bool { auth.availableProviders?.passkey == true }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AvatarView(name: appState.userName, url: appState.userAvatarUrl)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.userName)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("primitive.profile.name")
                        if !appState.userEmail.isEmpty && appState.userEmail != appState.userName {
                            Text(appState.userEmail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
                Button("Edit Profile") { isEditing = true }
                    .accessibilityIdentifier("primitive.profile.edit")
            }

            if passkeysAvailable {
                passkeysSection
            }

            Section {
                Button(role: .destructive) {
                    Task { await appState.signOut() }
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out")
                        Spacer()
                    }
                }
                .accessibilityIdentifier("primitive.profile.signOut")
            }
        }
        .navigationTitle("Profile")
        .task {
            if passkeysAvailable { await auth.refreshPasskeys() }
        }
        .sheet(isPresented: $isEditing) {
            EditProfileView(appState: appState)
        }
    }

    private var passkeysSection: some View {
        Section("Passkeys") {
            ForEach(auth.passkeys, id: \.passkeyId) { passkey in
                VStack(alignment: .leading, spacing: 2) {
                    Text(passkey.deviceName.isEmpty ? "Passkey" : passkey.deviceName)
                    Text("Added \(passkey.createdAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await auth.deletePasskey(passkeyId: passkey.passkeyId) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button {
                Task {
                    isAddingPasskey = true
                    await auth.enrollPasskey()
                    isAddingPasskey = false
                }
            } label: {
                HStack {
                    Label("Add a Passkey", systemImage: "plus.circle")
                    Spacer()
                    if isAddingPasskey { ProgressView() }
                }
            }
            .disabled(isAddingPasskey)
        }
    }
}

/// A round avatar: the image at `url`, else the name's initials.
struct AvatarView: View {
    let name: String
    let url: String?

    var body: some View {
        if let url, let parsed = URL(string: url) {
            AsyncImage(url: parsed) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                initials
            }
            .clipShape(Circle())
            .accessibilityIdentifier("primitive.profile.avatarImage")
        } else {
            initials
        }
    }

    private var initials: some View {
        let parts = name.split(separator: " ")
        let text = parts.count >= 2
            ? String(parts[0].prefix(1) + parts[1].prefix(1))
            : String(name.prefix(2))
        return Circle()
            .fill(Color.accentColor.opacity(0.15))
            .overlay(
                Text(text.uppercased())
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            )
    }
}
