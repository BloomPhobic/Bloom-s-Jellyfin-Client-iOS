import PhotosUI
import SwiftUI
import UIKit

/// The signed-in user's profile picture and password. The server decides what is allowed, so a
/// refusal shows its answer instead of the app guessing from the user's permissions.
struct ProfileView: View {
    @Environment(SessionStore.self) private var store

    @State private var showAuthorize = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var pictureMessage: (text: String, isError: Bool)?
    @State private var isWorkingOnPicture = false
    @State private var cropping: PhotoToCrop?
    @State private var showPreview = false

    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var passwordMessage: (text: String, isError: Bool)?
    @State private var isChangingPassword = false

    private var avatarURL: URL? {
        store.session.flatMap { store.userImageURL(userID: $0.userID, tag: $0.imageTag) }
    }

    private var canSubmitPassword: Bool {
        !new.isEmpty && new == confirm && !isChangingPassword
    }

    var body: some View {
        List {
            Section {
                Button {
                    if avatarURL != nil {
                        showPreview = true
                    }
                } label: {
                    AccountAvatar(name: store.session?.userName ?? "?", imageURL: avatarURL, size: 104)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile picture")
                .accessibilityHint(avatarURL == nil ? "" : "Shows it full screen")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label(isWorkingOnPicture ? "Uploading…" : "Choose a new picture", systemImage: "photo")
                }
                .disabled(isWorkingOnPicture)
                if store.session?.imageTag != nil {
                    Button("Remove picture", role: .destructive) {
                        Task { await update(nil) }
                    }
                    .disabled(isWorkingOnPicture)
                }
            } footer: {
                if let pictureMessage {
                    Text(pictureMessage.text)
                        .foregroundStyle(pictureMessage.isError ? Color.red : Color.secondary)
                } else {
                    Text("Shown on the sign-in screen and next to your name, on every device that uses this server.")
                }
            }

            Section {
                SecureField("Current password", text: $current)
                    .textContentType(.password)
                SecureField("New password", text: $new)
                    .textContentType(.newPassword)
                SecureField("Repeat new password", text: $confirm)
                    .textContentType(.newPassword)
            } header: {
                Text("Password")
            } footer: {
                if !confirm.isEmpty && new != confirm {
                    Text("The new passwords don't match.")
                        .foregroundStyle(Color.red)
                } else {
                    Text("Leave the current password empty if the account has none. Other devices stay signed in.")
                }
            }

            Section {
                Button {
                    Task { await changePassword() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Change password")
                        if isChangingPassword {
                            ProgressView()
                                .tint(Theme.onAccent)
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 48))
                .opacity(canSubmitPassword ? 1 : 0.4)
                .disabled(!canSubmitPassword)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                if let passwordMessage {
                    Text(passwordMessage.text)
                        .foregroundStyle(passwordMessage.isError ? Color.red : Color.secondary)
                }
            }

            Section {
                Button {
                    showAuthorize = true
                } label: {
                    Label("Authorize Quick Connect", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Sign in a TV or another device by typing the code it shows.")
            }

            Section {
                Button("Sign out", role: .destructive) {
                    Task { await store.signOut() }
                }
            } footer: {
                Text("Signs out this account on this iPhone. Other accounts stay signed in.")
            }
        }
        .sheet(isPresented: $showAuthorize) {
            QuickConnectAuthorizeView()
                .environment(store)
        }
        .themedBackground()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            Task {
                defer { pickedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    pictureMessage = ("That picture couldn't be read.", true)
                    return
                }
                cropping = PhotoToCrop(image: image)
            }
        }
        .fullScreenCover(item: $cropping) { photo in
            PhotoCropView(image: photo.image) {
                cropping = nil
            } onDone: { square in
                cropping = nil
                guard let jpeg = square.jpegData(compressionQuality: 0.85) else { return }
                Task { await update(jpeg) }
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            AvatarPreview(url: avatarURL) { showPreview = false }
        }
    }

    private func update(_ jpeg: Data?) async {
        isWorkingOnPicture = true
        pictureMessage = nil
        defer { isWorkingOnPicture = false }
        do {
            try await store.setProfilePicture(jpeg)
            pictureMessage = (jpeg == nil ? "Picture removed." : "Picture changed.", false)
        } catch {
            AppLog.shared.log("Profile picture failed: \(error.localizedDescription)", level: .warning)
            pictureMessage = (Self.message(for: error, refused: "The server didn't allow this. An administrator may have turned off profile changes for this account."), true)
        }
    }

    private func changePassword() async {
        isChangingPassword = true
        passwordMessage = nil
        defer { isChangingPassword = false }
        do {
            try await store.changePassword(current: current, new: new)
            current = ""
            new = ""
            confirm = ""
            passwordMessage = ("Password changed.", false)
        } catch {
            AppLog.shared.log("Password change failed: \(error.localizedDescription)", level: .warning)
            passwordMessage = (Self.message(for: error, refused: "The current password is wrong, or an administrator doesn't let this account change its password."), true)
        }
    }

    private static func message(for error: Error, refused: String) -> String {
        let text = String(describing: error)
        if text.contains("(401)") || text.contains("(403)") {
            return refused
        }
        return error.localizedDescription
    }
}
