import JellyfinAPI
import SwiftUI

/// Sign in to the saved server: pick a user from the server's public list, use Quick Connect,
/// or type a username and password.
struct LoginView: View {
    @Environment(SessionStore.self) private var store

    @State private var users: [UserDto] = []
    @State private var quickConnectEnabled = false
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var showQuickConnect = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        Form {
            if let route = store.route {
                Section {
                    LabeledContent(store.server?.name ?? "Server") {
                        Label(route.kind.label, systemImage: route.kind.systemImage)
                    }
                }
            }

            if !users.isEmpty {
                Section("Users") {
                    ForEach(users, id: \.id) { user in
                        Button {
                            select(user)
                        } label: {
                            UserRow(name: user.name ?? "?", isSelected: username == user.name)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .onSubmit { Task { await signIn() } }
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in")
                        if isSigningIn {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSigningIn || username.isEmpty)
            } header: {
                Text(users.isEmpty ? "Account" : "Or sign in manually")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if quickConnectEnabled {
                Section {
                    Button {
                        showQuickConnect = true
                    } label: {
                        Label("Use Quick Connect", systemImage: "qrcode")
                    }
                } footer: {
                    Text("Approve this device from another device where you're already signed in to Jellyfin.")
                }
            }
        }
        .themedBackground()
        .navigationTitle("Sign in")
        .task(id: store.route?.address) {
            await loadOptions()
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView()
        }
    }

    private func select(_ user: UserDto) {
        username = user.name ?? ""
        password = ""
        errorMessage = nil
        if user.hasPassword == false {
            Task { await signIn() }
        } else {
            passwordFocused = true
        }
    }

    private func loadOptions() async {
        async let usersRequest = store.publicUsers()
        async let quickConnectRequest = store.isQuickConnectEnabled()
        do {
            users = try await usersRequest
        } catch {
            users = []
            AppLog.shared.log("Couldn't load the user list: \(error.localizedDescription)", level: .warning)
        }
        quickConnectEnabled = await quickConnectRequest
        AppLog.shared.log("Login options: \(users.count) public user(s), Quick Connect \(quickConnectEnabled ? "on" : "off")")
    }

    private func signIn() async {
        guard !isSigningIn, !username.isEmpty else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            try await store.signIn(username: username, password: password)
            password = ""
        } catch {
            errorMessage = Self.message(for: error)
            AppLog.shared.log("Sign-in failed: \(error.localizedDescription)", level: .error)
        }
    }

    private static func message(for error: Error) -> String {
        let text = String(describing: error)
        if text.contains("401") {
            return "Wrong username or password."
        }
        return error.localizedDescription
    }
}

private struct UserRow: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased())
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor))
            Text(name)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// Shows a Quick Connect code and waits until it is approved on another device.
struct QuickConnectView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let code {
                    Text("On a device where you're signed in to Jellyfin, open your user menu, choose Quick Connect, and enter this code:")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(verbatim: code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    ProgressView(isSigningIn ? "Signing in…" : "Waiting for approval…")
                } else {
                    ProgressView("Getting a code…")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await run() }
    }

    private func run() async {
        do {
            let client = try store.loginClient()
            for try await event in client.quickConnect.connect() {
                switch event {
                case .polling(let newCode):
                    code = newCode
                    AppLog.shared.log("Quick Connect: code shown, waiting for approval")
                case .authenticated(let secret):
                    AppLog.shared.addSecret(secret)
                    isSigningIn = true
                    try await store.signIn(quickConnectSecret: secret, client: client)
                    dismiss()
                }
            }
        } catch is CancellationError {
            AppLog.shared.log("Quick Connect cancelled")
        } catch {
            errorMessage = "Quick Connect failed: \(error.localizedDescription)"
            AppLog.shared.log("Quick Connect failed: \(error.localizedDescription)", level: .error)
        }
    }
}
