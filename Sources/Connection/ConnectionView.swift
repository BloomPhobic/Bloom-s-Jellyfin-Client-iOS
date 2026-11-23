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
    @State private var addressToEdit: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let server = store.server {
                    chain(server)
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
        .confirmationDialog(addressToEdit ?? "Address", isPresented: Binding(get: { addressToEdit != nil }, set: { if !$0 { addressToEdit = nil } }), titleVisibility: .visible) {
            editButtons
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

    // MARK: The chain

    private var statusColor: Color {
        store.route != nil ? .green : (store.isResolving ? .orange : .red)
    }

    /// The route from this iPhone to the server: every address in priority order, each lit by its last
    /// check. The first one that answers is the one in use. Tap an address to move or remove it.
    private func chain(_ server: ServerRecord) -> some View {
        let addresses = server.addresses
        return VStack(alignment: .leading, spacing: 0) {
            node(icon: "iphone.gen3", color: Theme.accent, filled: false, lineColor: Theme.line, isLast: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This iPhone")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text("Tries every address at once. The first one in the list that answers wins.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                    checkButton
                }
            }
            ForEach(Array(addresses.enumerated()), id: \.element) { index, address in
                addressNode(address, index: index, count: addresses.count)
            }
            serverNode(server)
        }
    }

    private var checkButton: some View {
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
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Theme.accent.opacity(0.15)))
        }
        .buttonStyle(PressableStyle())
        .disabled(store.isResolving)
    }

    /// One stop on the chain: a round marker on the left with a line running down to the next stop.
    private func node<Content: View>(icon: String, color: Color, filled: Bool, lineColor: Color, isLast: Bool, @ViewBuilder content: () -> Content) -> some View {
        let inner = content()
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(filled ? Theme.onAccent : color)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(filled ? color : color.opacity(0.15)))
                    .overlay(Circle().strokeBorder(color.opacity(filled ? 0 : 0.6), lineWidth: 1.5))
                    .shadow(color: filled ? color.opacity(0.6) : .clear, radius: 10)
                if !isLast {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(lineColor)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: 46)
            inner
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 18)
        }
    }

    private func addressNode(_ address: String, index: Int, count: Int) -> some View {
        let kind = AddressKind.of(address)
        let isChosen = store.route?.address == address
        var color: Color = Theme.text3
        var status = "Not checked yet"
        var reachable = false
        if let result = store.results[address] {
            switch result.outcome {
            case .reachable(_, _, let version, let ms):
                color = isChosen ? Theme.accent : .green
                status = "\(ms) ms · server \(version)"
                reachable = true
            case .failed(let reason):
                color = .red
                status = reason
            }
        }
        let line: Color = reachable ? color.opacity(0.7) : Theme.line
        return node(icon: kind.systemImage, color: color, filled: isChosen, lineColor: line, isLast: false) {
            Button {
                addressToEdit = address
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(kind.label)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.text)
                        if isChosen {
                            Text("In use")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Capsule().fill(Theme.accent))
                        }
                        Spacer(minLength: 0)
                        Text("#\(index + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                    }
                    Text(address)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .lineLimit(2)
                    if AddressKind.isUnencryptedInternet(address) {
                        UnencryptedWarning(compact: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isChosen ? Theme.accent.opacity(0.7) : Theme.line, lineWidth: isChosen ? 1.5 : 1))
            }
            .buttonStyle(PressableStyle())
            .accessibilityHint("Move or remove this address")
        }
    }

    private func serverNode(_ server: ServerRecord) -> some View {
        let route = store.route
        var headline = "Not connected"
        if let route {
            headline = "Connected via \(route.kind.label) · \(route.milliseconds) ms"
        } else if store.isResolving {
            headline = "Checking…"
        }
        let version = route.flatMap { versionText(store.results[$0.address]) }
        return node(icon: route == nil ? "wifi.slash" : "server.rack", color: statusColor, filled: route != nil, lineColor: .clear, isLast: true) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                if let version {
                    Text("Jellyfin \(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                }
            }
            .frame(minHeight: 46, alignment: .leading)
        }
    }

    private func versionText(_ result: ProbeResult?) -> String? {
        guard let result else { return nil }
        if case .reachable(_, _, let version, _) = result.outcome { return version }
        return nil
    }

    /// Buttons of the tapped address's menu.
    @ViewBuilder
    private var editButtons: some View {
        if let address = addressToEdit, let addresses = store.server?.addresses, let index = addresses.firstIndex(of: address) {
            if index > 0 {
                Button("Move up") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        store.moveAddresses(from: IndexSet(integer: index), to: index - 1)
                    }
                }
            }
            if index < addresses.count - 1 {
                Button("Move down") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        store.moveAddresses(from: IndexSet(integer: index), to: index + 2)
                    }
                }
            }
            if addresses.count > 1 {
                Button("Remove", role: .destructive) {
                    // A second dialog can't open while this one is still closing.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { addressToRemove = address }
                }
            }
        }
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
