import SwiftUI

/// Server settings as cards: how the app is connected right now, every address with its check
/// result (reorder and remove with buttons), adding an address, and the account.
struct ConnectionView: View {
    @Environment(SessionStore.self) private var store

    @State private var newAddress = ""
    @State private var addMessage: (text: String, isError: Bool)?
    @State private var isAdding = false
    @State private var confirmForget = false
    @State private var addressToRemove: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let server = store.server {
                    heroCard(name: server.name)
                    addressesCard(server.addresses)
                    addCard
                    accountCard
                    Button("Forget this server", role: .destructive) {
                        confirmForget = true
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 4)
                } else {
                    Text("No server added yet. Add one on the Home tab.")
                        .foregroundStyle(Theme.text3)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .themedBackground()
        .navigationTitle("Connection")
        .refreshable { await store.resolve() }
        .confirmationDialog("Forget this server?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Sign out and forget", role: .destructive) {
                Task { await store.forgetServer() }
            }
        } message: {
            Text("This removes all of its addresses and signs you out.")
        }
        .confirmationDialog("Remove this address?", isPresented: Binding(get: { addressToRemove != nil }, set: { if !$0 { addressToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                remove()
            }
        } message: {
            Text(addressToRemove ?? "")
        }
    }

    // MARK: Cards

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .textCase(.uppercase)
    }

    /// The connection at a glance: server, route in use, speed and version.
    private func heroCard(name: String) -> some View {
        let route = store.route
        let color: Color = route == nil ? (store.isResolving ? .orange : .red) : .green
        let version = route.flatMap { versionText(store.results[$0.address]) }
        var headline = "Not connected"
        if let route {
            headline = "Connected via \(route.kind.label)"
        } else if store.isResolving {
            headline = "Checking…"
        }
        let speed = route.map { "\($0.milliseconds) ms" } ?? "n/a"
        return card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: route?.kind.systemImage ?? "wifi.slash")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(color.opacity(0.15)))
                        .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 8, height: 8)
                            Text(headline)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    statTile("Route", route?.kind.label ?? "None")
                    statTile("Speed", speed)
                    statTile("Server", version ?? "n/a")
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
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                .buttonStyle(PressableStyle())
                .disabled(store.isResolving)
            }
        }
    }

    private func statTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.raised2))
    }

    private func versionText(_ result: ProbeResult?) -> String? {
        guard let result else { return nil }
        if case .reachable(_, _, let version, _) = result.outcome { return version }
        return nil
    }

    private func addressesCard(_ addresses: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Addresses")
                .padding(.horizontal, 4)
            ForEach(Array(addresses.enumerated()), id: \.element) { index, address in
                addressCard(address, index: index, count: addresses.count)
            }
            Text("All addresses are checked at the same time, and the first one in this list that answers is used.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 4)
        }
    }

    private func addressCard(_ address: String, index: Int, count: Int) -> some View {
        let kind = AddressKind.of(address)
        let result = store.results[address]
        let isChosen = store.route?.address == address
        var color: Color = Theme.text3
        var status = "Not checked yet"
        if let result {
            switch result.outcome {
            case .reachable(_, _, let version, let ms):
                color = .green
                status = "Server \(version) · \(ms) ms"
            case .failed(let reason):
                color = .red
                status = reason
            }
        }
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(address)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(kind.label) · \(status)")
                            .font(.system(size: 12))
                            .foregroundStyle(color)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if isChosen {
                        Text("In use")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.green))
                    }
                }
                if AddressKind.isUnencryptedInternet(address) {
                    UnencryptedWarning(compact: true)
                }
                HStack(spacing: 8) {
                    Text("Priority \(index + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    smallButton("chevron.up", "Move up", enabled: index > 0) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            store.moveAddresses(from: IndexSet(integer: index), to: index - 1)
                        }
                    }
                    smallButton("chevron.down", "Move down", enabled: index < count - 1) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            store.moveAddresses(from: IndexSet(integer: index), to: index + 2)
                        }
                    }
                    smallButton("trash", "Remove address", enabled: count > 1) {
                        addressToRemove = address
                    }
                }
            }
        }
    }

    private func smallButton(_ icon: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.text3.opacity(0.5))
                .frame(width: 36, height: 32)
                .background(Capsule().fill(Theme.raised2))
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var addCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Add an address")
                HStack(spacing: 10) {
                    TextField("New address", text: $newAddress, prompt: Text(verbatim: "http://192.168.1.10:8096"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { Task { await add() } }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised2))
                    Button {
                        Task { await add() }
                    } label: {
                        Group {
                            if isAdding {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Add")
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 64, height: 42)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(newAddress.isEmpty || isAdding)
                    .opacity(newAddress.isEmpty ? 0.5 : 1)
                }
                if let addMessage {
                    Text(addMessage.text)
                        .font(.system(size: 13))
                        .foregroundStyle(addMessage.isError ? Color.red : Theme.text2)
                } else if AddressKind.isUnencryptedInternet(newAddress.trimmingCharacters(in: .whitespaces)) {
                    UnencryptedWarning(compact: false)
                } else {
                    Text("Add your home network and Tailscale addresses too: new ones go local network first, then Tailscale, then internet. Add them while you are on that network.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
        }
    }

    private var accountCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("Account")
                if let session = store.session {
                    HStack {
                        Text("Signed in as")
                            .foregroundStyle(Theme.text2)
                        Spacer()
                        Text(session.userName)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.text)
                    }
                    .font(.system(size: 15))
                    Button {
                        Task { await store.signOut() }
                    } label: {
                        Text("Sign out")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                    }
                    .buttonStyle(PressableStyle())
                } else {
                    Text("Not signed in")
                        .foregroundStyle(Theme.text3)
                }
            }
        }
    }

    private func remove() {
        guard let address = addressToRemove, let index = store.server?.addresses.firstIndex(of: address) else { return }
        addressToRemove = nil
        withAnimation(.easeInOut(duration: 0.25)) {
            store.removeAddresses(at: IndexSet(integer: index))
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
