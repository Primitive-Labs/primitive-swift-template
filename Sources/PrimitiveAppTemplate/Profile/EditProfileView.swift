import PhotosUI
import SwiftUI

/// Edit the name and avatar. Save uploads the avatar first, then the name,
/// as the web template's editor does; a failure keeps the sheet open with the
/// server's message and leaves the previous avatar in place.
struct EditProfileView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var photo: PhotosPickerItem?
    @State private var avatar: AvatarImage?
    @State private var isLoadingPhoto = false
    @State private var message: String?
    @State private var isSaving = false

    init(appState: AppState) {
        self.appState = appState
        let current = appState.userName == appState.userEmail ? "" : appState.userName
        _name = State(initialValue: current)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        AvatarView(name: name.isEmpty ? appState.userName : name, url: appState.userAvatarUrl)
                            .frame(width: 80, height: 80)
                        Spacer()
                    }
                    let photoTitle = isLoadingPhoto ? "Loading Photo…" : avatar == nil ? "Choose Photo" : "Photo Chosen"
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label(photoTitle, systemImage: "photo")
                    }
                    .accessibilityIdentifier("primitive.profile.choosePhoto")
                }
                Section("Name") {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .accessibilityIdentifier("primitive.profile.nameField")
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || isLoadingPhoto)
                        .accessibilityIdentifier("primitive.profile.save")
                }
            }
            // A new selection cancels the load of the one it replaces.
            .task(id: photo) { await load(photo) }
        }
    }

    /// Load the picked photo. Save waits while it loads, so a slow (iCloud)
    /// photo is never left out; a load a newer selection replaced publishes
    /// nothing.
    private func load(_ item: PhotosPickerItem?) async {
        message = nil
        avatar = nil
        guard let item else { isLoadingPhoto = false; return }
        isLoadingPhoto = true
        let data = try? await item.loadTransferable(type: Data.self)
        guard !Task.isCancelled else { return }
        isLoadingPhoto = false
        guard let data else {
            message = AvatarImageError.notAnImage.localizedDescription
            return
        }
        switch AvatarImage.prepare(data) {
        case .success(let image): avatar = image
        case .failure(let error): message = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        message = nil
        defer { isSaving = false }
        do {
            try await appState.saveProfile(name: name, avatar: avatar)
            dismiss()
        } catch {
            message = AppState.saveFailureMessage(error)
        }
    }
}
