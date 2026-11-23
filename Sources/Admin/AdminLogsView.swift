import SwiftUI

/// The server's log files; tap one to read its end.
struct AdminLogsView: View {
    @Environment(SessionStore.self) private var store
    @State private var files: [LogFile] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    private struct LogFile: Identifiable {
        let id: String
        let size: Int64
        let modified: Date?
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && files.isEmpty {
                    Text("No log files.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                ForEach(files) { file in
                    NavigationLink {
                        AdminLogFileView(name: file.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.id)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(AdminDate.ago(file.modified))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text3)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.text3)
                        }
                        .adminCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Server logs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let rows = try await store.adminJSON("System/Logs") as? [[String: Any]] ?? []
            var found: [LogFile] = []
            for row in rows {
                guard let name = row["Name"] as? String else { continue }
                found.append(LogFile(
                    id: name,
                    size: (row["Size"] as? NSNumber)?.int64Value ?? 0,
                    modified: AdminDate.parse(row["DateModified"] as? String)
                ))
            }
            files = found.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            errorMessage = nil
            loaded = true
        } catch {
            guard !isCancelled(error) else { return }
            errorMessage = "Couldn't load the logs: \(error.localizedDescription)"
            loaded = true
        }
    }
}

/// One log file, scrolled to its end. Only the last ~300 KB are shown.
private struct AdminLogFileView: View {
    let name: String

    @Environment(SessionStore.self) private var store
    @State private var text = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var copied = false

    private static let tailBytes = 300_000

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                    } else if isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: text) {
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                UIPasteboard.general.string = text
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityLabel("Copy")
            .disabled(text.isEmpty)
        }
        .task { await load() }
    }

    private func load() async {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        do {
            let data = try await store.adminCall("System/Logs/Log?name=\(encoded)")
            let tail = data.suffix(Self.tailBytes)
            var result = String(decoding: tail, as: UTF8.self)
            if data.count > Self.tailBytes, let newline = result.firstIndex(of: "\n") {
                // The cut is mid-line; start at the next whole line.
                result = String(result[result.index(after: newline)...])
            }
            text = result.isEmpty ? "(empty)" : result
            errorMessage = nil
        } catch {
            guard !isCancelled(error) else { return }
            errorMessage = "Couldn't load the log: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
