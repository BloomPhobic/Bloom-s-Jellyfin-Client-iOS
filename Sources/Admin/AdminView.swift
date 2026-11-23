import SwiftUI

/// Admins only: server facts, per-library scan, who is watching, and the Seerr requests waiting for an answer.
struct AdminView: View {
    @Environment(SessionStore.self) private var store
    @State private var server = ServerInfo()
    @State private var libraries: [Library] = []
    @State private var watching: [Watcher] = []
    @State private var pending: [SeerrMyRequest] = []
    @State private var pendingNote: String?
    @State private var errorMessage: String?
    @State private var message: String?
    @State private var confirmRestart = false
    @State private var scanning: Set<String> = []

    private struct ServerInfo {
        var name = "Server"
        var version = ""
        var movies = 0
        var series = 0
        var episodes = 0
    }

    private struct Library: Identifiable {
        let id: String
        let name: String
        let type: String
        var count: Int?

        var icon: String {
            switch type {
            case "movies": return "film.fill"
            case "boxsets": return "square.stack.fill"
            case "tvshows": return "tv.fill"
            case "music": return "music.note"
            case "books": return "book.fill"
            default: return "folder.fill"
            }
        }

        var unit: String {
            switch type {
            case "movies": return "movies"
            case "tvshows": return "shows"
            case "boxsets": return "collections"
            case "music": return "albums"
            case "books": return "books"
            default: return "items"
            }
        }

        /// What this kind of library holds, as a Jellyfin item type (nil = any non-folder item).
        var countedType: String? {
            switch type {
            case "movies": return "Movie"
            case "tvshows": return "Series"
            case "boxsets": return "BoxSet"
            case "music": return "MusicAlbum"
            case "books": return "Book"
            default: return nil
            }
        }
    }

    private struct Watcher: Identifiable {
        let id: String
        let user: String
        let title: String
        let device: String
        let paused: Bool
    }

    private var seerr: SeerrClient? { SeerrClient(userID: store.session?.userID) }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                    }
                    actions
                    manageSection
                    stats
                    librariesSection
                    if !watching.isEmpty { watchingSection }
                    requestsSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .themedBackground()
            .tabBarClearance()
            .navigationTitle("Admin")
            .refreshable { await load() }
            .task { await load() }
            .toast($message)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(errorMessage == nil ? Color.green : Color.orange)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                Text(server.version.isEmpty ? " " : "Jellyfin \(server.version)")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            pill("Scan all", "arrow.triangle.2.circlepath") { Task { await scan(id: nil, name: "all libraries") } }
            pill("Restart", "power") { confirmRestart = true }
        }
        .confirmationDialog("Restart the server?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await restart() } }
        } message: {
            Text("Everyone watching is cut off until it is back.")
        }
    }

    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Capsule().fill(Theme.raised))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Pages for the rest of the server's admin jobs, kept off the dashboard so it stays short.
    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Manage")
            VStack(spacing: 0) {
                manageLink("Scheduled tasks", "Run or stop scans and clean-ups", "clock.arrow.circlepath") { AdminTasksView() }
                manageDivider
                manageLink("Activity", "Sign-ins, playback and failures", "list.bullet.rectangle") { AdminActivityView() }
                manageDivider
                manageLink("Devices", "Signed-in devices; remove one", "iphone.gen3") { AdminDevicesView() }
                manageDivider
                manageLink("Users", "Accounts and when they were last active", "person.2.fill") { AdminUsersView() }
                manageDivider
                manageLink("Server logs", "Read the log files", "doc.text.magnifyingglass") { AdminLogsView() }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised))
        }
    }

    private var manageDivider: some View {
        Divider().overlay(Theme.line).padding(.leading, 62)
    }

    private func manageLink<Destination: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder destination: () -> Destination) -> some View {
        let page = destination()
        return NavigationLink {
            page
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            tile("Movies", "\(server.movies)", "film.fill", .pink)
            tile("Shows", "\(server.series)", "tv.fill", .indigo)
            tile("Episodes", "\(server.episodes)", "play.rectangle.fill", .teal)
            tile("Pending requests", "\(pending.count)", "tray.fill", .orange)
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Spacer()
                Text(value).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised))
    }

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Libraries")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(libraries) { library in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: library.icon).foregroundStyle(Theme.accent)
                            Spacer()
                            Button {
                                Task { await scan(id: library.id, name: library.name) }
                            } label: {
                                if scanning.contains(library.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.text2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Scan \(library.name)")
                        }
                        Text(library.name).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(library.count.map { "\($0) \(library.unit)" } ?? "…")
                            .font(.system(size: 13)).foregroundStyle(Theme.text3)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised))
                }
            }
        }
    }

    private var watchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Watching now")
            ForEach(watching) { watcher in
                HStack(spacing: 12) {
                    Image(systemName: watcher.paused ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(watcher.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text("\(watcher.user) · \(watcher.device)").font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
            }
        }
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Pending requests")
            if let pendingNote {
                Text(pendingNote).font(.system(size: 14)).foregroundStyle(Theme.text2)
            } else if pending.isEmpty {
                Text("Nothing waiting.").font(.system(size: 14)).foregroundStyle(Theme.text2)
            }
            ForEach(pending) { request in
                HStack(spacing: 12) {
                    ArtworkFrame(url: request.posterURL, aspectRatio: 2 / 3).frame(width: 44)
                    Text(request.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                    Button { Task { await answer(request, approve: true) } } label: {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Approve")
                    Button { Task { await answer(request, approve: false) } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Decline")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
    }

    // MARK: Loading

    private func load() async {
        await loadServer()
        async let sessions: Void = loadWatching()
        async let requests: Void = loadPending()
        _ = await (sessions, requests)
    }

    private func json(_ path: String) async throws -> Any {
        try JSONSerialization.jsonObject(with: await store.adminCall(path))
    }

    private func loadServer() async {
        do {
            var next = ServerInfo()
            let system = try await json("System/Info") as? [String: Any]
            next.name = system?["ServerName"] as? String ?? "Server"
            next.version = system?["Version"] as? String ?? ""
            let counts = try await json("Items/Counts") as? [String: Any]
            next.movies = counts?["MovieCount"] as? Int ?? 0
            next.series = counts?["SeriesCount"] as? Int ?? 0
            next.episodes = counts?["EpisodeCount"] as? Int ?? 0
            server = next
            errorMessage = nil
            await loadLibraries()
        } catch {
            errorMessage = "Couldn't load the server: \(error.localizedDescription)"
        }
    }

    private func loadLibraries() async {
        guard let rows = try? await json("Library/VirtualFolders") as? [[String: Any]] else { return }
        var found: [Library] = []
        for row in rows {
            guard let id = row["ItemId"] as? String else { continue }
            let name = row["Name"] as? String ?? "Library"
            let type = row["CollectionType"] as? String ?? ""
            found.append(Library(id: id, name: name, type: type, count: nil))
        }
        libraries = found
        for index in found.indices {
            let id = found[index].id
            let filter = found[index].countedType.map { "IncludeItemTypes=\($0)" } ?? "IsFolder=false"
            let query = "Items?ParentId=\(id)&Recursive=true&Limit=0&\(filter)"
            guard let data = try? await store.adminCall(query),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = body["TotalRecordCount"] as? Int,
                  index < libraries.count, libraries[index].id == id else { continue }
            libraries[index].count = total
        }
    }

    private func loadWatching() async {
        guard let rows = try? await json("Sessions?ActiveWithinSeconds=300") as? [[String: Any]] else { return }
        var found: [Watcher] = []
        for row in rows {
            guard let item = row["NowPlayingItem"] as? [String: Any], let id = row["Id"] as? String else { continue }
            let state = row["PlayState"] as? [String: Any]
            let name = item["Name"] as? String ?? "Something"
            let series = item["SeriesName"] as? String
            let title = series.map { "\($0) · \(name)" } ?? name
            found.append(Watcher(id: id, user: row["UserName"] as? String ?? "?", title: title,
                                 device: row["DeviceName"] as? String ?? "?", paused: state?["IsPaused"] as? Bool ?? false))
        }
        watching = found
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

    // MARK: Actions

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

    /// id nil scans everything; otherwise only that library.
    private func scan(id: String?, name: String) async {
        if let id { scanning.insert(id) }
        defer { if let id { scanning.remove(id) } }
        do {
            let path = id.map { "Items/\($0)/Refresh?Recursive=true&MetadataRefreshMode=Default&ImageRefreshMode=Default" } ?? "Library/Refresh"
            _ = try await store.adminCall(path, method: "POST")
            message = "Scanning \(name)"
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
