import SwiftUI

/// Server settings: the server's addresses in priority order, which one is in use, and the account.
struct ConnectionView: View {
    @Environment(SessionStore.self) private var store

    @State private var newAddress = ""
    @State private var addMessage: (text: String, isError: Bool)?
    @State private var isAdding = false
    @State private var confirmForget = false

    var body: some View {
        List {
            if let server = store.server {
                serverSection(name: server.name)
                addressSection(server.addresses)
                accountSection
                Section {
                    Button("Forget this server", role: .destructive) {
                        confirmForget = true
                    }
                }
            } else {
                Section {
                    Text("No server added yet. Add one on the Home tab.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connection")
        .toolbar {
            if store.server != nil {
                EditButton()
            }
        }
        .confirmationDialog("Forget this server?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Sign out and forget", role: .destructive) {
                Task { await store.forgetServer() }
            }
        } message: {
            Text("This removes all of its addresses and signs you out.")
        }
    }

    private func serverSection(name: String) -> some View {
        Section("Server") {
            LabeledContent("Name", value: name)
            LabeledContent("In use") {
                if let route = store.route {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(route.kind.label, systemImage: route.kind.systemImage)
                        Text("\(route.milliseconds) ms")
                            .font(.caption)
                    }
                } else {
                    Text("Not connected")
                }
            }
            Button {
                Task { await store.resolve() }
            } label: {
                HStack {
                    Text("Check addresses now")
                    if store.isResolving {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(store.isResolving)
        }
    }

    private func addressSection(_ addresses: [String]) -> some View {
        Section {
            ForEach(addresses, id: \.self) { address in
                AddressRow(
                    address: address,
                    result: store.results[address],
                    isChosen: store.route?.address == address
                )
            }
            .onDelete { store.removeAddresses(at: $0) }
            .onMove { store.moveAddresses(from: $0, to: $1) }
            .deleteDisabled(addresses.count < 2)

            HStack {
                TextField("New address", text: $newAddress, prompt: Text(verbatim: "http://192.168.1.10:8096"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await add() } }
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add") { Task { await add() } }
                        .disabled(newAddress.isEmpty)
                }
            }
        } header: {
            Text("Addresses")
        } footer: {
            if let addMessage {
                Text(addMessage.text)
                    .foregroundStyle(addMessage.isError ? Color.red : Color.secondary)
            } else {
                Text("All addresses are checked at the same time, and the first one in this list that answers is used. New addresses are placed local network first, then Tailscale, then internet. Tap Edit to reorder.")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if let session = store.session {
                LabeledContent("Signed in as", value: session.userName)
                Button("Sign out", role: .destructive) {
                    Task { await store.signOut() }
                }
            } else {
                Text("Not signed in")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add() async {
        guard !isAdding, !newAddress.isEmpty else { return }
        isAdding = true
        defer { isAdding = false }
        let outcome = await store.addAddress(newAddress)
        addMessage = (outcome.message, outcome.isError)
        if !outcome.isError {
            newAddress = ""
        }
    }
}

/// One server address with its type and the result of the last check.
struct AddressRow: View {
    let address: String
    let result: ProbeResult?
    let isChosen: Bool

    var body: some View {
        let kind = AddressKind.of(address)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isChosen {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let result {
                switch result.outcome {
                case .reachable(_, _, let version, let ms):
                    Text("\(kind.label) · server \(version) · \(ms) ms")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Text("\(kind.label) · \(reason)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("\(kind.label) · not checked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
