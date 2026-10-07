import Foundation
import Security

/// Phase 0 self-test: checks that the Keychain works inside the sideload environment
/// (LiveContainer / SideStore) and that values survive an app restart.
@MainActor
enum KeychainCheck {
    private static let service = "io.github.bloomphobic.jellyfinclient.selftest"
    private static let account = "selftest"

    private enum ReadResult {
        case value(String)
        case notFound
        case failed(OSStatus)
    }

    static func run() {
        let log = AppLog.shared

        switch read() {
        case .value(let previous):
            log.log("Keychain: found value from a previous launch (\(previous)). Persistence works.")
        case .notFound:
            log.log("Keychain: no value from a previous launch (expected on first launch).")
        case .failed(let status):
            log.log("Keychain: read failed, OSStatus \(status).", level: .error)
        }

        let newValue = ISO8601DateFormatter().string(from: Date())
        let writeStatus = write(newValue)
        guard writeStatus == errSecSuccess else {
            log.log("Keychain: write failed, OSStatus \(writeStatus).", level: .error)
            return
        }

        switch read() {
        case .value(let readBack) where readBack == newValue:
            log.log("Keychain: write and read-back OK.")
        case .value(let readBack):
            log.log("Keychain: read-back mismatch (wrote \(newValue), got \(readBack)).", level: .error)
        case .notFound:
            log.log("Keychain: value missing right after writing it.", level: .error)
        case .failed(let status):
            log.log("Keychain: read-back failed, OSStatus \(status).", level: .error)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read() -> ReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .notFound
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return .failed(status)
        }
        return .value(string)
    }

    private static func write(_ value: String) -> OSStatus {
        _ = SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }
}
