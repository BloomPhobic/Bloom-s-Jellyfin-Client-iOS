import JellyfinAPI
import SwiftUI

/// Sign in to the saved server: pick a profile, use Quick Connect, or type a username and password.
/// Also used to add another account while one is signed in.
struct LoginView: View {
    @Environment(SessionStore.self) private var store

    @State private var users: [UserDto] = []
    @State private var quickConnectEnabled = false
    @State private var hasLoaded = false
    @State private var selectedUserID: String?
    @State private var manual = false
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var showQuickConnect = false
    @FocusState private var focus: Field?

    private enum Field {
        case username
        case password
    }

    private var selectedUser: UserDto? {
        users.first { $0.id == selectedUserID }
    }

    /// The username/password card shows for a chosen profile with a password, or for manual sign-in.
    private var showsCredentials: Bool {
        manual || (hasLoaded && users.isEmpty) || selectedUser?.hasPassword != false && selectedUser != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                if !users.isEmpty {
                    profiles
                }

                if showsCredentials {
                    credentials
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.5))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                alternatives
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .toolbar {
            if store.isAddingAccount && store.session != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        store.isAddingAccount = false
                    }
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showsCredentials)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedUserID)
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .task(id: store.route?.address) {
            await loadOptions()
        }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView()
                .presentationDetents([.medium])
                .presentationBackground(Theme.surface)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 14) {
            LogoMark(size: 76)
            VStack(spacing: 6) {
                Text(store.server?.name ?? "Jellyfin")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                if let route = store.route {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Connected · \(route.kind.label)")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }
        }
    }

    private var profiles: some View {
        VStack(spacing: 18) {
            Text(store.isAddingAccount ? "Add another account" : "Who's watching?")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 16)], spacing: 20) {
                ForEach(users, id: \.id) { user in
                    let isSelected = user.id == selectedUserID
                    let alreadySignedIn = store.accounts.contains { $0.userID == user.id }
                    Button {
                        select(user)
                    } label: {
                        VStack(spacing: 8) {
                            AccountAvatar(
                                name: user.name ?? "?",
                                imageURL: user.id.flatMap { store.userImageURL(userID: $0, tag: user.primaryImageTag) },
                                size: 76,
                                isSelected: isSelected
                            )
                            .scaleEffect(isSelected ? 1.06 : 1)
                            .shadow(color: isSelected ? Color.accentColor.opacity(0.45) : .clear, radius: 12)
                            Text(user.name ?? "?")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if alreadySignedIn {
                                Text("Signed in")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var credentials: some View {
        VStack(spacing: 12) {
            if let selectedUser, !manual {
                Text("Password for \(selectedUser.name ?? "this user")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                InputField(systemImage: "person") {
                    TextField("Username", text: $username, prompt: Text("Username").foregroundStyle(Theme.text3))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }
            }
            InputField(systemImage: "lock") {
                SecureField("Password", text: $password, prompt: Text("Password").foregroundStyle(Theme.text3))
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
            }
            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    Text("Sign in")
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 50))
            .disabled(isSigningIn || username.isEmpty)
            .opacity(username.isEmpty ? 0.6 : 1)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var alternatives: some View {
        VStack(spacing: 12) {
            if quickConnectEnabled {
                Button {
                    showQuickConnect = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode")
                        Text("Use Quick Connect")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            if !users.isEmpty && !manual {
                Button("Sign in with a username instead") {
                    manual = true
                    selectedUserID = nil
                    username = ""
                    password = ""
                    errorMessage = nil
                    focus = .username
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Actions

    private func select(_ user: UserDto) {
        manual = false
        selectedUserID = user.id
        username = user.name ?? ""
        password = ""
        errorMessage = nil
        if user.hasPassword == false {
            Task { await signIn() }
        } else {
            focus = .password
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
        hasLoaded = true
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

/// A rounded input with a leading icon.
struct InputField<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 20)
            content
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised2))
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
        VStack(spacing: 22) {
            HStack {
                Text("Quick Connect")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(CircleButtonStyle(size: 34, fill: Theme.raised2))
                .accessibilityLabel("Cancel")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let code {
                Text("On a device where you're signed in to Jellyfin, open your user menu, choose Quick Connect, and enter:")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                        Text(String(character))
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .frame(width: 44, height: 56)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised2))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                HStack(spacing: 8) {
                    ProgressView()
                    Text(isSigningIn ? "Signing in…" : "Waiting for approval…")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                ProgressView("Getting a code…")
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: code)
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
