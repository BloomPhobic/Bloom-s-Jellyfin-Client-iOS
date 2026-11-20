import PhotosUI
import SwiftUI
import UIKit

/// The signed-in user's profile picture and password. The server decides what is allowed, so a
/// refusal shows its answer instead of the app guessing from the user's permissions.
struct ProfileView: View {
    @Environment(SessionStore.self) private var store

    @State private var pickedPhoto: PhotosPickerItem?
    @State private var pictureMessage: (text: String, isError: Bool)?
    @State private var isWorkingOnPicture = false

    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var passwordMessage: (text: String, isError: Bool)?
    @State private var isChangingPassword = false

    private var canSubmitPassword: Bool {
        !new.isEmpty && new == confirm && !isChangingPassword
    }

    var body: some View {
        List {
            Section {
                AccountAvatar(
                    name: store.session?.userName ?? "?",
                    imageURL: store.session.flatMap { store.userImageURL(userID: $0.userID, tag: $0.imageTag) },
                    size: 104
                )
                .frame(maxWidth: .infinity)
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
        }
        .themedBackground()
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedPhoto) {
            guard let item = pickedPhoto else { return }
            Task {
                defer { pickedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let jpeg = Self.squareJPEG(from: data) else {
                    pictureMessage = ("That picture couldn't be read.", true)
                    return
                }
                await update(jpeg)
            }
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

    /// The picture cropped to a centred square, at most 512 px, as JPEG.
    private static func squareJPEG(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        let target = min(side, 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
        let scale = target / side
        return renderer.jpegData(withCompressionQuality: 0.85) { _ in
            image.draw(in: CGRect(
                x: -(image.size.width - side) / 2 * scale,
                y: -(image.size.height - side) / 2 * scale,
                width: image.size.width * scale,
                height: image.size.height * scale
            ))
        }
    }
}
