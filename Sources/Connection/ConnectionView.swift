import SwiftUI

/// Server settings as a signal dashboard: a big gauge for the connection in use, then one compact
/// row per address (hold and drag to reorder, swipe right to remove) and adding an address.
struct ConnectionView: View {
    @Environment(SessionStore.self) private var store

    @State private var newAddress = ""
    @State private var addMessage: (text: String, isError: Bool)?
    @State private var isAdding = false
    @State private var confirmForget = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            if let server = store.server {
                gaugeSection(server)
                addressSection(server.addresses)
                Section {
                    Button("Forget this server", role: .destructive) {
                        confirmForget = true
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Theme.raised)
            } else {
                Text("No server added yet. Add one on the Home tab.")
                    .foregroundStyle(Theme.text3)
                    .listRowBackground(Color.clear)
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle("Connection")
        .toolbar {
            if (store.server?.addresses.count ?? 0) > 1 {
                Button(editMode.isEditing ? "Done" : "Reorder") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .refreshable { await store.resolve() }
        .confirmationDialog("Forget this server?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Sign out and forget", role: .destructive) {
                Task { await store.forgetServer() }
            }
        } message: {
            Text("This removes all of its addresses and signs you out.")
        }
    }

    // MARK: Gauge

    /// Green when fast, orange when slow, red when there is no connection.
    private var gaugeColor: Color {
        guard let route = store.route else { return store.isResolving ? .orange : .red }
        if route.milliseconds < 150 { return .green }
        if route.milliseconds < 400 { return .yellow }
        return .orange
    }

    /// A fuller ring means a faster connection (0 ms = full, 600 ms or more = almost empty).
    private var gaugeFill: Double {
        guard let route = store.route else { return 0 }
        return max(0.06, 1 - min(Double(route.milliseconds), 600) / 600)
    }

    private func gaugeSection(_ server: ServerRecord) -> some View {
        let route = store.route
        let color = gaugeColor
        var subtitle = "Not connected"
        if let route, let version = versionText(store.results[route.address]) {
            subtitle = "Jellyfin \(version)"
        } else if store.isResolving {
            subtitle = "Checking…"
        }
        return Section {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Theme.raised2, lineWidth: 16)
                    Circle()
                        .trim(from: 0, to: gaugeFill)
                        .stroke(color, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color.opacity(0.5), radius: 8)
                        .animation(.easeInOut(duration: 0.6), value: gaugeFill)
                    VStack(spacing: 2) {
                        if let route {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(route.milliseconds)")
                                    .font(.system(size: 46, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Theme.text)
                                Text("ms")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Theme.text3)
                            }
                            Label(route.kind.label, systemImage: route.kind.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(color)
                        } else {
                            Image(systemName: store.isResolving ? "dot.radiowaves.left.and.right" : "wifi.slash")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(color)
                            Text(store.isResolving ? "Checking…" : "No connection")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                }
                .frame(width: 210, height: 210)
                .padding(.top, 8)

                VStack(spacing: 3) {
                    Text(server.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                }

                Button {
                    Task { await store.resolve() }
                } label: {
                    HStack(spacing: 8) {
                        if store.isResolving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(store.isResolving ? "Checking…" : "Check now")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                .buttonStyle(PressableStyle())
                .disabled(store.isResolving)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func versionText(_ result: ProbeResult?) -> String? {
        guard let result else { return nil }
        if case .reachable(_, _, let version, _) = result.outcome { return version }
        return nil
    }

    // MARK: Addresses

    private func addressSection(_ addresses: [String]) -> some View {
        Section {
            ForEach(Array(addresses.enumerated()), id: \.element) { index, address in
                addressRow(address, index: index)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if addresses.count > 1 {
                            Button(role: .destructive) {
                                store.removeAddresses(at: IndexSet(integer: index))
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
            }
            .onMove { store.moveAddresses(from: $0, to: $1) }
            .listRowBackground(Theme.raised)

            HStack(spacing: 10) {
                TextField("New address", text: $newAddress, prompt: Text(verbatim: "http://192.168.1.10:8096"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await add() } }
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add") { Task { await add() } }
                        .fontWeight(.semibold)
                        .disabled(newAddress.isEmpty)
                }
            }
            .listRowBackground(Theme.raised)
        } header: {
            Text("Addresses · first that answers wins")
        } footer: {
            if let addMessage {
                Text(addMessage.text)
                    .foregroundStyle(addMessage.isError ? Color.red : Theme.text3)
            } else if AddressKind.isUnencryptedInternet(newAddress.trimmingCharacters(in: .whitespaces)) {
                UnencryptedWarning(compact: false)
            } else {
                Text("Tap Reorder, then drag the handles; swipe right to remove one. New addresses go local network first, then Tailscale, then internet.")
            }
        }
    }

    private func addressRow(_ address: String, index: Int) -> some View {
        let kind = AddressKind.of(address)
        let isChosen = store.route?.address == address
        var color: Color = Theme.text3
        var trailing = "…"
        if let result = store.results[address] {
            switch result.outcome {
            case .reachable(_, _, _, let ms):
                color = .green
                trailing = "\(ms) ms"
            case .failed:
                color = .red
                trailing = "failed"
            }
        }
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color.opacity(0.15)))
                .overlay(Circle().strokeBorder(color.opacity(0.6), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(address)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: kind.systemImage)
                    Text(kind.label)
                    if AddressKind.isUnencryptedInternet(address) {
                        Image(systemName: "lock.open.fill").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 4)
            Text(trailing)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            if isChosen {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
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
            if AddressKind.isUnencryptedInternet(address) {
                UnencryptedWarning(compact: true)
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

/// Warns that an internet address uses plain http, so the password and viewing aren't encrypted.
struct UnencryptedWarning: View {
    /// A one-line caption for address rows; otherwise the full explanation.
    let compact: Bool

    var body: some View {
        Label {
            Text(compact
                 ? "Not encrypted"
                 : "This internet address uses http, so your password and what you watch travel unencrypted. Use https if your server supports it.")
        } icon: {
            Image(systemName: "lock.open.fill")
        }
        .font(compact ? .caption : .system(size: 13, weight: .semibold))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
