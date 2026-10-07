import Foundation
import Observation
import UIKit

/// In-app log shown on the Log tab. The text can be copied and pasted into bug reports.
@MainActor
@Observable
final class AppLog {
    static let shared = AppLog()

    struct Entry: Identifiable {
        enum Level: String {
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"
        }

        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 1000

    /// Strings (like access tokens) that are replaced before anything is logged.
    @ObservationIgnored private var secrets: Set<String> = []

    private init() {}

    func addSecret(_ secret: String) {
        guard !secret.isEmpty else { return }
        secrets.insert(secret)
    }

    func log(_ message: String, level: Entry.Level = .info) {
        var text = message
        for secret in secrets {
            text = text.replacingOccurrences(of: secret, with: "<redacted>")
        }
        entries.append(Entry(date: Date(), level: level, message: text))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let lines = entries.map { entry in
            "\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)"
        }
        return ([AppInfo.versionDescription] + lines).joined(separator: "\n")
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    @MainActor
    static var versionDescription: String {
        "Version \(version) (build \(build)), iOS \(UIDevice.current.systemVersion)"
    }
}
