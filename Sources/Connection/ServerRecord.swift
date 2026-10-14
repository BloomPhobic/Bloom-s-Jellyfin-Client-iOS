import Foundation

/// What kind of network an address is on. Used for the default priority order and for labels.
enum AddressKind: Int, Comparable {
    case local
    case tailscale
    case internet

    var label: String {
        switch self {
        case .local: return "Local network"
        case .tailscale: return "Tailscale"
        case .internet: return "Internet"
        }
    }

    var systemImage: String {
        switch self {
        case .local: return "house"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .internet: return "globe"
        }
    }

    /// A plain-http address on the internet: passwords and everything else travel unencrypted.
    /// Local network and Tailscale addresses are fine (Tailscale encrypts on its own).
    static func isUnencryptedInternet(_ address: String) -> Bool {
        URL(string: address)?.scheme?.lowercased() == "http" && of(address) == .internet
    }

    static func < (lhs: AddressKind, rhs: AddressKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func of(_ address: String) -> AddressKind {
        guard let host = URL(string: address)?.host()?.lowercased() else { return .internet }
        if host.hasSuffix(".ts.net") {
            return .tailscale
        }
        if host.hasSuffix(".local") || host == "localhost" || !host.contains(".") && !host.contains(":") {
            return .local
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254), (127, _):
                return .local
            case (172, 16...31):
                return .local
            case (100, 64...127):
                return .tailscale
            default:
                return .internet
            }
        }
        if host.hasPrefix("fd") || host.hasPrefix("fe80") || host.hasPrefix("[fd") || host.hasPrefix("[fe80") {
            return host.hasPrefix("fd7a:115c:a1e0") || host.hasPrefix("[fd7a:115c:a1e0") ? .tailscale : .local
        }
        return .internet
    }
}

/// The saved server: its addresses in priority order (first = preferred).
/// The server ID is filled in on the first successful connection and used to make sure
/// every address leads to the same server.
struct ServerRecord: Codable, Equatable {
    var id: String?
    var name: String
    var addresses: [String]

    private static let key = "server"
    private static let legacyAddressesKey = "serverAddresses"

    @MainActor
    static func load() -> ServerRecord? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let record = try? JSONDecoder().decode(ServerRecord.self, from: data) {
            return record
        }
        // Phase 0/1 kept a plain list of addresses for the connection check.
        if let legacy = defaults.stringArray(forKey: legacyAddressesKey), !legacy.isEmpty {
            var record = ServerRecord(id: nil, name: URL(string: legacy[0])?.host() ?? "Server", addresses: [])
            for address in legacy {
                record.insert(address)
            }
            record.save()
            defaults.removeObject(forKey: legacyAddressesKey)
            AppLog.shared.log("Moved \(legacy.count) saved address(es) to the new server settings")
            return record
        }
        return nil
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Adds an address after the existing ones of the same or a closer kind (local, then Tailscale, then internet).
    /// Returns false if it is already in the list.
    @discardableResult
    mutating func insert(_ address: String) -> Bool {
        guard !addresses.contains(address) else { return false }
        let kind = AddressKind.of(address)
        let index = addresses.lastIndex { AddressKind.of($0) <= kind }.map { $0 + 1 } ?? 0
        addresses.insert(address, at: index)
        return true
    }
}
