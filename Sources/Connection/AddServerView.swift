import SwiftUI

/// First-run screen: enter one address of a Jellyfin server.
struct AddServerView: View {
    @Environment(SessionStore.self) private var store

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                LogoMark(size: 84)
                    .padding(.top, 40)
                VStack(spacing: 8) {
                    Text("Welcome")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Connect to your Jellyfin server to get started.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.text2)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    InputField(systemImage: "globe") {
                        TextField("Server address", text: $address, prompt: Text(verbatim: "https://jellyfin.example.com").foregroundStyle(Theme.text3))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { Task { await connect() } }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        if isConnecting {
                            ProgressView().tint(Theme.onAccent)
                        } else {
                            Text("Connect")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 50))
                    .disabled(isConnecting || address.isEmpty)
                    .opacity(address.isEmpty ? 0.6 : 1)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))

                Text("You can add more addresses for the same server later (for example your local network and Tailscale) in Settings → Connection.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
    }

    private func connect() async {
        guard !isConnecting else { return }
        guard let url = ServerProbe.normalize(address) else {
            errorMessage = "Enter a full address starting with http:// or https://"
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await store.addServer(address: url.absoluteString)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shown when none of the server's addresses answered on launch.
struct ServerUnreachableView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        List {
            Section {
                Label("Can't reach \(store.server?.name ?? "the server")", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                Text("None of the server's addresses answered. Check your connection, and if you use Tailscale, that it is connected.")
                    .foregroundStyle(.secondary)
            }

            Section("Addresses") {
                ForEach(store.server?.addresses ?? [], id: \.self) { address in
                    AddressRow(address: address, result: store.results[address], isChosen: false)
                }
            }

            Section {
                Button {
                    Task { await store.resolve() }
                } label: {
                    HStack {
                        Text("Try again")
                        if store.isResolving {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(store.isResolving)
            }
        }
        .themedBackground()
        .navigationTitle("Not connected")
    }
}

/// Shown while the first address check is running.
struct ConnectingView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            LogoMark(size: 76)
            Text("Connecting to \(store.server?.name ?? "the server")…")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text2)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}
