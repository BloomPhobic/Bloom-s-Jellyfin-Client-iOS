import SwiftUI

/// The server's activity log: sign-ins, playback, failures. Newest first.
struct AdminActivityView: View {
    @Environment(SessionStore.self) private var store
    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    private struct Entry: Identifiable {
        let id: Int
        let name: String
        let detail: String?
        let severity: String
        let date: Date?

        var icon: String {
            switch severity {
            case "Error", "Critical": return "xmark.octagon.fill"
            case "Warning": return "exclamationmark.triangle.fill"
            default: return "info.circle.fill"
            }
        }

        var color: Color {
            switch severity {
            case "Error", "Critical": return .red
            case "Warning": return .orange
            default: return Theme.text3
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && entries.isEmpty {
                    Text("Nothing recorded yet.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.icon)
                            .font(.system(size: 18))
                            .foregroundStyle(entry.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text2)
                                    .lineLimit(3)
                            }
                            Text(AdminDate.ago(entry.date))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                    .adminCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let body = try await store.adminJSON("System/ActivityLog/Entries?limit=60") as? [String: Any]
            let rows = body?["Items"] as? [[String: Any]] ?? []
            entries = rows.enumerated().map { index, row in
                Entry(
                    id: index,
                    name: row["Name"] as? String ?? "Event",
                    detail: row["ShortOverview"] as? String ?? row["Overview"] as? String,
                    severity: row["Severity"] as? String ?? "Information",
                    date: AdminDate.parse(row["Date"] as? String)
                )
            }
            errorMessage = nil
            loaded = true
        } catch {
            guard !isCancelled(error) else { return }
            errorMessage = "Couldn't load the activity: \(error.localizedDescription)"
            loaded = true
        }
    }
}
