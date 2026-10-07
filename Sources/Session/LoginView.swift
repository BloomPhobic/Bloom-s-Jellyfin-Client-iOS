import SwiftUI

/// Temporary Phase 1 login. Phase 2 replaces it with address resolution, user lists and Quick Connect.
struct LoginView: View {
    let store: SessionStore

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var savedAddresses: [String] {
        UserDefaults.standard.stringArray(forKey: "serverAddresses") ?? []
    }

    var body: some View {
        Form {
            Section {
                TextField("https://jellyfin.example.com", text: $server)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !savedAddresses.isEmpty {
                    Menu("Use a saved address") {
                        ForEach(savedAddresses, id: \.self) { address in
                            Button(address) { server = address }
                        }
                    }
                }
            } header: {
                Text("Server")
            }

            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Account")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            Section {
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
                .disabled(isSigningIn || server.isEmpty || username.isEmpty)
            }
        }
        .navigationTitle("Sign in")
        .onAppear {
            if server.isEmpty, let first = savedAddresses.first {
                server = first
            }
        }
    }

    private func signIn() async {
        guard let url = ServerProbe.normalize(server) else {
            errorMessage = "Enter a full address starting with http:// or https://"
            return
        }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            try await store.signIn(server: url, username: username, password: password)
            password = ""
        } catch {
            errorMessage = error.localizedDescription
            AppLog.shared.log("Sign-in failed: \(error.localizedDescription)", level: .error)
        }
    }
}
