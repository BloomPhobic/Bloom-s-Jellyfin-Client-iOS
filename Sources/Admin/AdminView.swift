import SwiftUI

/// Admins only: server facts, scan/restart, and the Seerr requests waiting for an answer.
struct AdminView: View {
    @Environment(SessionStore.self) private var store
    @State private var info: Info?
    @State private var errorMessage: String?
    @State private var pending: [SeerrMyRequest] = []
    @State private var pendingNote: String?
    @State private var message: String?
    @State private var confirmRestart = false

    private struct Info {
        var name = ""
        var version = ""
        var movies = 0
        var series = 0
        var episodes = 0
    }

    private var seerr: SeerrClient? { SeerrClient(userID: store.session?.userID) }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(Theme.text2) }
                }
                if let info {
                    Section {
                        LabeledContent("Server", value: info.name)
                        LabeledContent("Version", value: info.version)
                        LabeledContent("Movies", value: "\(info.movies)")
                        LabeledContent("Shows", value: "\(info.series)")
                        LabeledContent("Episodes", value: "\(info.episodes)")
                    }
                }
                Section {
                    Button("Scan library") { Task { await scan() } }
                    Button("Restart server", role: .destructive) { confirmRestart = true }
                        .confirmationDialog("Restart the server?", isPresented: $confirmRestart, titleVisibility: .visible) {
                            Button("Restart", role: .destructive) { Task { await restart() } }
                        } message: {
                            Text("Everyone watching is cut off until it is back.")
                        }
                }
                Section("Pending requests") {
                    if let pendingNote {
                        Text(pendingNote).foregroundStyle(Theme.text2)
                    } else if pending.isEmpty {
                        Text("Nothing waiting.").foregroundStyle(Theme.text2)
                    }
                    ForEach(pending) { request in
                        HStack(spacing: 12) {
                            ArtworkFrame(url: request.posterURL, aspectRatio: 2 / 3).frame(width: 44)
                            Text(request.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                            Spacer()
                            Button { Task { await answer(request, approve: true) } } label: {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Approve")
                            Button { Task { await answer(request, approve: false) } } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Decline")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .themedBackground()
            .tabBarClearance()
            .navigationTitle("Admin")
            .refreshable { await load() }
            .task { await load() }
            .toast($message)
        }
    }

    private func load() async {
        await loadServer()
        await loadPending()
    }

    private func loadServer() async {
        do {
            var next = Info()
            let system = try JSONSerialization.jsonObject(with: await store.adminCall("System/Info")) as? [String: Any]
            next.name = system?["ServerName"] as? String ?? "?"
            next.version = system?["Version"] as? String ?? "?"
            let counts = try JSONSerialization.jsonObject(with: await store.adminCall("Items/Counts")) as? [String: Any]
            next.movies = counts?["MovieCount"] as? Int ?? 0
            next.series = counts?["SeriesCount"] as? Int ?? 0
            next.episodes = counts?["EpisodeCount"] as? Int ?? 0
            info = next
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load the server: \(error.localizedDescription)"
        }
    }

    private func loadPending() async {
        guard let seerr else {
            pendingNote = "Set up the request server under Settings → Requests."
            return
        }
        guard seerr.isSignedIn else {
            pendingNote = "Sign in to the request server under Settings → Requests."
            return
        }
        do {
            pending = try await seerr.myRequests(filter: "pending")
            pendingNote = nil
        } catch {
            pendingNote = error.localizedDescription
        }
    }

    private func answer(_ request: SeerrMyRequest, approve: Bool) async {
        do {
            try await seerr?.resolve(request.id, approve: approve)
            pending.removeAll { $0.id == request.id }
            message = approve ? "Approved “\(request.title)”" : "Declined “\(request.title)”"
        } catch SeerrError.http(403) {
            message = "Your Seerr account can't manage requests."
        } catch {
            message = error.localizedDescription
        }
    }

    private func scan() async {
        do {
            _ = try await store.adminCall("Library/Refresh", method: "POST")
            message = "Library scan started"
        } catch {
            message = "Couldn't start the scan: \(error.localizedDescription)"
        }
    }

    private func restart() async {
        do {
            _ = try await store.adminCall("System/Restart", method: "POST")
            message = "Server is restarting"
        } catch {
            message = "Couldn't restart: \(error.localizedDescription)"
        }
    }
}
