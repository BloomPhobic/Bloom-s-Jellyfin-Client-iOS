import SwiftUI
import UIKit

struct LogView: View {
    private var log: AppLog { AppLog.shared }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(log.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.date, format: .dateTime.hour().minute().second()) · \(entry.level.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(color(for: entry.level))
                        Text(entry.message)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: log.entries.count) {
                    if let last = log.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) {
                        log.clear()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: log.exportText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = log.exportText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    private func color(for level: AppLog.Entry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
