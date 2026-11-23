import SwiftUI

extension SessionStore {
    /// An admin call whose answer is JSON.
    func adminJSON(_ path: String) async throws -> Any {
        try JSONSerialization.jsonObject(with: await adminCall(path))
    }
}

enum AdminDate {
    /// Jellyfin writes times like 2026-11-23T03:00:00.0000000Z (7 fraction digits), which
    /// ISO8601DateFormatter rejects, so the fraction is dropped.
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.split(separator: ".").first.map(String.init) ?? text
        let value = trimmed.hasSuffix("Z") ? trimmed : trimmed + "Z"
        return ISO8601DateFormatter().date(from: value)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }
}

/// A call that was cancelled because the page went away: not an error worth showing.
func isCancelled(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

extension View {
    /// The rounded dark card the admin pages use for each row.
    func adminCard(_ padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
    }
}

/// Grey small-caps label above a group of cards.
struct AdminGroupTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .textCase(.uppercase)
            .padding(.top, 8)
            .padding(.horizontal, 4)
    }
}
