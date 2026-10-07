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

    private init() {}

    func log(_ message: String, level: Entry.Level = .info) {
        entries.append(Entry(date: Date(), level: level, message: message))
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
    @MainActor
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (build \(build)), iOS \(UIDevice.current.systemVersion)"
    }
}
