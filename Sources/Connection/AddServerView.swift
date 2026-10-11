import SwiftUI

/// First-run screen: enter one address of a Jellyfin server.
struct AddServerView: View {
    @Environment(SessionStore.self) private var store

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("https://jellyfin.example.com", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await connect() } }
            } header: {
                Text("Server address")
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("You can add more addresses for the same server later (for example your local network and Tailscale) in the Connection tab.")
                }
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect")
                        if isConnecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isConnecting || address.isEmpty)
            }
        }
        .navigationTitle("Add a server")
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
        .navigationTitle("Not connected")
    }
}

/// Shown while the first address check is running.
struct ConnectingView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(store.server?.name ?? "the server")…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
