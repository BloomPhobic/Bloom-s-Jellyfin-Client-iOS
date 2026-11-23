import SwiftUI

/// Every device that has signed in to the server. Removing one signs that device out.
struct AdminDevicesView: View {
    @Environment(SessionStore.self) private var store
    @State private var devices: [Device] = []
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var message: String?
    @State private var deviceToRemove: Device?

    private struct Device: Identifiable {
        let id: String
        let name: String
        let app: String
        let user: String?
        let lastActive: Date?
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && devices.isEmpty {
                    Text("No devices.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                ForEach(devices) { device in
                    row(device)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toast($message)
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let device = deviceToRemove {
                    Task { await remove(device) }
                }
            }
        } message: {
            Text("\(deviceToRemove?.name ?? "It") is signed out and has to sign in again.")
        }
    }

    private func row(_ device: Device) -> some View {
        let isThis = device.id == store.session?.deviceID
        return HStack(spacing: 12) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(device.app)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                Text(activity(device))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isThis {
                Text("This device")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
            } else {
                Button {
                    deviceToRemove = device
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.raised2))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Remove \(device.name)")
            }
        }
        .adminCard()
    }

    private func activity(_ device: Device) -> String {
        let when = "Active " + AdminDate.ago(device.lastActive)
        guard let user = device.user, !user.isEmpty else { return when }
        return "\(user) · \(when)"
    }

    private func load() async {
        do {
            let object = try await store.adminJSON("Devices")
            var rows: [[String: Any]] = []
            if let wrapped = object as? [String: Any], let items = wrapped["Items"] as? [[String: Any]] {
                rows = items
            } else if let plain = object as? [[String: Any]] {
                rows = plain
            }
            var found: [Device] = []
            for row in rows {
                guard let id = row["Id"] as? String else { continue }
                let app = [row["AppName"] as? String, row["AppVersion"] as? String].compactMap { $0 }.joined(separator: " ")
                found.append(Device(
                    id: id,
                    name: row["CustomName"] as? String ?? row["Name"] as? String ?? "Device",
                    app: app,
                    user: row["LastUserName"] as? String,
                    lastActive: AdminDate.parse(row["DateLastActivity"] as? String)
                ))
            }
            devices = found.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            errorMessage = nil
            loaded = true
        } catch {
            guard !isCancelled(error) else { return }
            errorMessage = "Couldn't load the devices: \(error.localizedDescription)"
            loaded = true
        }
    }

    private func remove(_ device: Device) async {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = device.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? device.id
        do {
            _ = try await store.adminCall("Devices?id=\(encoded)", method: "DELETE")
            devices.removeAll { $0.id == device.id }
            message = "Removed \(device.name)"
        } catch {
            message = "Couldn't remove it: \(error.localizedDescription)"
        }
    }
}
