import JellyfinAPI
import SwiftUI

/// The Downloads tab: storage, a link to what's downloading, then movies and shows on the phone.
/// Works without a connection; tap anything to play it.
struct DownloadsView: View {
    /// Changes when the Downloads tab is tapped again: pops back to this page.
    var resetToken = 0
    @Environment(SessionStore.self) private var store
    @State private var playback: PlaybackSession?
    @State private var freeBytes: Int64 = 0
    @State private var path: [DownloadsRoute] = []
    @State private var pendingForeign: [DownloadRecord] = []

    private var downloads: DownloadStore { .shared }

    /// Finished downloads of every account on this device, so they stay watchable whoever is signed in.
    private var everyone: [DownloadRecord] {
        downloads.list(for: nil)
    }

    /// Unfinished downloads belong to the signed-in account (only it has the access to continue them).
    private var mine: [DownloadRecord] {
        downloads.list(for: store.session?.userID)
    }

    private var movies: [DownloadRecord] {
        everyone.filter { $0.state == .done && !$0.isEpisode }
            .sorted { ($0.item.sortName ?? $0.item.name ?? "") < ($1.item.sortName ?? $1.item.name ?? "") }
    }

    /// Shows with at least one finished episode, in name order.
    private var shows: [DownloadedShow] {
        let episodes = everyone.filter { $0.state == .done && $0.isEpisode }
        let grouped = Dictionary(grouping: episodes) { $0.item.seriesID ?? "" }
        return grouped.map { key, value in
            DownloadedShow(id: key, name: value.first?.item.seriesName ?? "Show", episodes: value.sorted(by: DownloadStore.episodeOrder))
        }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if everyone.isEmpty {
                    DownloadsPlaceholder(icon: "arrow.down.circle", title: "No downloads yet", text: "Tap Download on a movie or episode to watch it without a connection.")
                } else {
                    list
                }
            }
            .themedBackground()
            .tabBarClearance()
            .navigationTitle("Downloads")
            .navigationDestination(for: DownloadsRoute.self) { route in
                switch route {
                case .active:
                    ActiveDownloadsView()
                case .show(let id, let name):
                    ShowDownloadsView(seriesID: id, name: name, play: play)
                }
            }
        }
        .onChange(of: resetToken) { path = [] }
        // One tap can arrive as two pushes; two copies of a page must never stack.
        .onChange(of: path) { old, new in
            if new.count > old.count, new.count > 1, new[new.count - 1] == new[new.count - 2] { path.removeLast() }
        }
        .onAppear { freeBytes = DownloadFiles.freeBytes }
        .onChange(of: everyone.count) { freeBytes = DownloadFiles.freeBytes }
        .fullScreenCover(item: $playback) { session in
            PlayerView(session: session)
                .environment(store)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                storageCard
                    .padding(.horizontal, 16)

                if movies.isEmpty && shows.isEmpty {
                    Text("Finished downloads appear here.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 20)
                }

                if !movies.isEmpty {
                    posterGrid("Movies") {
                        ForEach(movies) { record in
                            Button {
                                play(record)
                            } label: {
                                MovieCard(record: record)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu {
                                Button {
                                    downloads.setWatched(record.id, !record.isWatched)
                                } label: {
                                    Label(record.isWatched ? "Mark unwatched" : "Mark watched",
                                          systemImage: record.isWatched ? "eye.slash" : "checkmark.circle")
                                }
                                Button(role: .destructive) {
                                    requestDelete(record)
                                } label: {
                                    Label("Delete download", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !shows.isEmpty {
                    posterGrid("Shows") {
                        ForEach(shows) { show in
                            NavigationLink(value: DownloadsRoute.show(id: show.id, name: show.name)) {
                                ShowCard(show: show)
                            }
                            .buttonStyle(PressableStyle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    downloads.deleteOrAsk(show.episodes, currentUserID: store.session?.userID) { pendingForeign = $0 }
                                } label: {
                                    Label("Delete all episodes", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
        .foreignDeleteDialog($pendingForeign)
    }

    /// A title with a grid of poster cards under it; the page scrolls down as a whole.
    private func posterGrid<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], spacing: 18) {
                content()
            }
            .padding(.horizontal, 16)
        }
    }

    /// What the downloads use against what is free, and the link to what is downloading now.
    private var storageCard: some View {
        let used = downloads.usedBytes(userID: nil)
        let total = used + freeBytes
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        let unfinished = mine.filter { $0.state != .done }
        let wanted = unfinished.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = unfinished.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let overall = wanted > 0 ? Double(received) / Double(wanted) : 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DownloadStore.format(used))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("downloaded")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("\(DownloadStore.format(freeBytes)) free")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
            ProgressBar(fraction: used > 0 ? max(fraction, 0.02) : 0, height: 8)
            if !store.isConnected {
                Label("You're offline. Downloads play as usual; your progress is sent to the server later.", systemImage: "wifi.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text2)
            }
            Divider().overlay(Theme.line)
            NavigationLink(value: DownloadsRoute.active) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ActiveDownloadsLink(records: unfinished, userID: store.session?.userID)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                    }
                    if !unfinished.isEmpty {
                        ProgressBar(fraction: overall, height: 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func requestDelete(_ record: DownloadRecord) {
        downloads.deleteOrAsk([record], currentUserID: store.session?.userID) { pendingForeign = $0 }
    }

    private func play(_ record: DownloadRecord) {
        guard let api = store.apiForDownloads(userID: record.userID) else { return }
        let source = record.item.mediaSources?.first { $0.id == record.mediaSourceID }
        let session = PlaybackSession(
            api: api,
            item: record.item,
            mediaSource: source,
            startSeconds: record.resumeSeconds,
            offline: !store.isConnected || store.session == nil
        )
        withTransaction(\.disablesAnimations, true) {
            playback = session
        }
    }
}

private enum DownloadsRoute: Hashable {
    case active
    case show(id: String, name: String)
}

/// A show's finished episodes, for the Downloads page.
private struct DownloadedShow: Identifiable {
    let id: String
    let name: String
    let episodes: [DownloadRecord]
}

/// Big icon, title and a line of text, for empty pages.
private struct DownloadsPlaceholder: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.text3)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The row that opens the Downloading page: how many are going, the speed, and any failures.
private struct ActiveDownloadsLink: View {
    let records: [DownloadRecord]
    let userID: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: records.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                // Redrawn every second so the speed disappears when downloads stall.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(summary(now: context.date))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(failedCount > 0 ? Color.orange : Theme.text3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var failedCount: Int {
        records.filter { $0.state == .failed }.count
    }

    private func summary(now: Date) -> String {
        guard !records.isEmpty else { return "Nothing right now" }
        var parts: [String] = []
        let active = records.filter { $0.state == .queued || $0.state == .downloading }.count
        let paused = records.filter { $0.state == .paused }.count
        if active > 0 { parts.append("\(active) in progress") }
        if paused > 0 { parts.append("\(paused) paused") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if let speed = DownloadStore.shared.totalSpeed(userID: userID, now: now) {
            parts.append(DownloadStore.formatSpeed(speed))
        }
        return parts.joined(separator: " · ")
    }
}

/// Everything not finished yet: downloading, paused and failed, with the total speed.
private struct ActiveDownloadsView: View {
    @Environment(SessionStore.self) private var store
    @State private var confirmCancelAll = false

    private var downloads: DownloadStore { .shared }

    private var records: [DownloadRecord] {
        downloads.list(for: store.session?.userID)
            .filter { $0.state != .done }
            .sorted { $0.addedAt < $1.addedAt }
    }

    private var active: [DownloadRecord] {
        records.filter { $0.state == .queued || $0.state == .downloading }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                DownloadsPlaceholder(icon: "checkmark.circle", title: "Nothing downloading", text: "Finished downloads are on the Downloads page.")
            } else {
                List {
                    Section {
                        overview
                    }
                    section("Downloading", active)
                    section("Paused", records.filter { $0.state == .paused })
                    section("Failed", records.filter { $0.state == .failed })
                }
            }
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Downloading")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                Menu {
                    Button {
                        downloads.pauseAll(userID: store.session?.userID)
                    } label: {
                        Label("Pause all", systemImage: "pause.circle")
                    }
                    Button {
                        downloads.resumeAll(userID: store.session?.userID)
                    } label: {
                        Label("Resume all", systemImage: "arrow.down.circle")
                    }
                    Button(role: .destructive) {
                        confirmCancelAll = true
                    } label: {
                        Label("Cancel all", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Cancel all downloads?", isPresented: $confirmCancelAll, titleVisibility: .visible) {
            Button("Cancel all", role: .destructive) {
                for record in records {
                    downloads.delete(record.id)
                }
            }
        } message: {
            Text("Unfinished downloads are deleted. Finished ones stay.")
        }
    }

    /// Total speed and how much of everything has arrived.
    private var overview: some View {
        let total = records.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = records.reduce(Int64(0)) { $0 + $1.receivedBytes }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(DownloadStore.format(received)) of \(DownloadStore.format(total))")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let speed = downloads.totalSpeed(userID: store.session?.userID, now: context.date) {
                        Label(DownloadStore.formatSpeed(speed), systemImage: "speedometer")
                    } else {
                        Text(active.isEmpty ? "Stopped" : "Waiting")
                    }
                }
                .foregroundStyle(Theme.text2)
            }
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.text)
            ProgressBar(fraction: total > 0 ? Double(received) / Double(total) : 0, height: 4)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [DownloadRecord]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { record in
                    DownloadingRow(record: record)
                        .swipeActions {
                            Button(role: .destructive) {
                                downloads.delete(record.id)
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        }
                }
            }
        }
    }
}

/// A poster with its title and a few lines under it, for the Downloads rows.
private struct DownloadPosterCard: View {
    let poster: URL?
    let title: String
    let subtitle: String
    var accentLine: String?
    var owner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ArtworkFrame(url: poster, aspectRatio: 2 / 3, cornerRadius: 14)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            if let accentLine {
                Text(accentLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            if let owner {
                Text(owner)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Theme.raised2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MovieCard: View {
    let record: DownloadRecord

    var body: some View {
        let downloads = DownloadStore.shared
        let _ = downloads.artworkRevision
        DownloadPosterCard(
            poster: downloads.posterURL(record.id),
            title: record.item.name ?? "Movie",
            subtitle: DownloadStore.format(record.totalBytes),
            accentLine: record.isWatched ? nil : "Unwatched",
            owner: downloads.owners(of: [record])
        )
        .id(downloads.artworkRevision)
    }
}

/// A show on the Downloads page: poster, name, episode count and size.
private struct ShowCard: View {
    let show: DownloadedShow

    var body: some View {
        let downloads = DownloadStore.shared
        let _ = downloads.artworkRevision
        let poster = show.episodes.lazy.compactMap { downloads.posterURL($0.id) }.first
        let unwatched = show.episodes.filter { !$0.isWatched }.count
        let count = show.episodes.count
        let size = show.episodes.reduce(Int64(0)) { $0 + $1.totalBytes }
        DownloadPosterCard(
            poster: poster,
            title: show.name,
            subtitle: "\(count == 1 ? "1 episode" : "\(count) episodes") · \(DownloadStore.format(size))",
            accentLine: unwatched > 0 ? "\(unwatched) unwatched" : nil,
            owner: downloads.owners(of: show.episodes)
        )
        .id(downloads.artworkRevision)
    }
}

/// One show's downloaded episodes, by season.
private struct ShowDownloadsView: View {
    let seriesID: String
    let name: String
    let play: (DownloadRecord) -> Void

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var selectedSeason: Int?
    @State private var pendingForeign: [DownloadRecord] = []

    private var episodes: [DownloadRecord] {
        DownloadStore.shared.episodes(seriesID: seriesID, userID: nil)
    }

    private struct Season: Identifiable {
        let id: Int
        let name: String
        let episodes: [DownloadRecord]
    }

    private var seasons: [Season] {
        let grouped = Dictionary(grouping: episodes) { $0.item.parentIndexNumber ?? 0 }
        return grouped.keys.sorted().map { number in
            let list = grouped[number] ?? []
            let name = list.first?.item.seasonName ?? (number == 0 ? "Specials" : "Season \(number)")
            return Season(id: number, name: name, episodes: list)
        }
    }

    private func requestDelete(_ record: DownloadRecord) {
        DownloadStore.shared.deleteOrAsk([record], currentUserID: store.session?.userID) { pendingForeign = $0 }
    }

    /// The season chosen with the pills, or the first one while none is chosen (or it was emptied).
    private var shownSeason: Season? {
        seasons.first { $0.id == selectedSeason } ?? seasons.first
    }

    private var seasonPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons) { season in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedSeason = season.id }
                    } label: {
                        Pill(title: season.name, isSelected: season.id == shownSeason?.id)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(season.id == shownSeason?.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    var body: some View {
        List {
            if store.isConnected && store.session != nil {
                Button {
                    NotificationCenter.default.post(name: BrowseNavigator.openSeriesNotification, object: nil, userInfo: ["id": seriesID, "name": name])
                } label: {
                    RowLabel(title: "Go to \(name)", subtitle: nil, systemImage: "tv")
                }
                .buttonStyle(PressableStyle())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if seasons.count > 1 {
                seasonPills
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if let season = shownSeason {
                Section(seasons.count > 1 ? "" : season.name) {
                    ForEach(season.episodes) { record in
                        DownloadedItemButton(record: record, play: play, requestDelete: requestDelete)
                    }
                }
            }
        }
        .foreignDeleteDialog($pendingForeign)
        .themedBackground()
        .tabBarClearance()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete all episodes")
        }
        .confirmationDialog("Delete all downloaded episodes of \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes")", role: .destructive) {
                for record in episodes {
                    DownloadStore.shared.delete(record.id)
                }
            }
        } message: {
            Text(DownloadStore.shared.message("Only the copies on this iPhone are deleted.", for: episodes, currentUserID: store.session?.userID))
        }
        .onChange(of: episodes.isEmpty) {
            if episodes.isEmpty {
                dismiss()
            }
        }
    }
}

extension View {
    /// Asks "Ana downloaded this. Delete it anyway?" for downloads another account made; set `pending`
    /// (usually through `DownloadStore.deleteOrAsk`) to show it.
    func foreignDeleteDialog(_ pending: Binding<[DownloadRecord]>) -> some View {
        modifier(ForeignDeleteDialog(pending: pending))
    }
}

struct ForeignDeleteDialog: ViewModifier {
    @Binding var pending: [DownloadRecord]
    @Environment(SessionStore.self) private var store

    func body(content: Content) -> some View {
        let shown = Binding(get: { !pending.isEmpty }, set: { if !$0 { pending = [] } })
        let owners = DownloadStore.shared.foreignNames(for: pending, currentUserID: store.session?.userID)
        let records = pending
        return content.sheet(isPresented: shown) {
            ForeignDeleteSheet(records: records, owners: owners) {
                for record in records {
                    DownloadStore.shared.delete(record.id)
                }
                pending = []
            } cancel: {
                pending = []
            }
        }
    }
}

/// The warning before deleting a download another account on this phone made.
private struct ForeignDeleteSheet: View {
    let records: [DownloadRecord]
    let owners: [String]
    let confirm: () -> Void
    let cancel: () -> Void

    private var what: String {
        if records.count == 1 {
            return records[0].item.name ?? "this download"
        }
        return "\(records.count) downloads"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.orange.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.orange.opacity(0.5), lineWidth: 1.5))
                .padding(.top, 26)
            Text("Not your download")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Downloaded by " + owners.joined(separator: ", "))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
            Text("Deleting \(what) removes it from this iPhone for everyone who uses it. It stays on the server and can be downloaded again.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: confirm) {
                Text("Delete anyway")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Color.red))
            }
            .buttonStyle(PressableStyle())
            Button(action: cancel) {
                Text("Keep it")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Theme.raised2))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
    }
}

/// A finished download as a row you tap to play, swipe or long-press to delete.
private struct DownloadedItemButton: View {
    let record: DownloadRecord
    let play: (DownloadRecord) -> Void
    /// Handled by the list that owns the row (it asks first when another account made the download).
    let requestDelete: (DownloadRecord) -> Void

    var body: some View {
        Button {
            play(record)
        } label: {
            DownloadedRow(record: record)
        }
        .buttonStyle(.plain)
        .swipeActions {
            // Not role: .destructive, which makes the row vanish before anything is confirmed.
            Button {
                requestDelete(record)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button {
                DownloadStore.shared.setWatched(record.id, !record.isWatched)
            } label: {
                Label(record.isWatched ? "Mark unwatched" : "Mark watched",
                      systemImage: record.isWatched ? "eye.slash" : "checkmark.circle")
            }
            Button(role: .destructive) {
                requestDelete(record)
            } label: {
                Label("Delete download", systemImage: "trash")
            }
        }
    }
}

/// A finished download: artwork, title, size and watch state.
private struct DownloadedRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            DownloadArtwork(record: record)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                if let owner = DownloadStore.shared.owners(of: [record]) {
                    Text(owner)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }
                if !record.isWatched, record.resumeSeconds > 0, let duration = runtimeSeconds, duration > 0 {
                    ProgressBar(fraction: record.resumeSeconds / duration, height: 3)
                        .frame(width: 90)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        let item = record.item
        if record.isEpisode {
            let name = item.name ?? "Episode"
            return [item.episodeLabel, name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.name ?? "Movie"
    }

    private var runtimeSeconds: Double? {
        record.item.runTimeTicks.map { Double($0) / 10_000_000 }
    }

    private var meta: String {
        var parts = [DownloadStore.format(record.totalBytes)]
        if let runtime = record.item.runtimeText {
            parts.append(runtime)
        }
        if record.isWatched {
            parts.append("Watched")
        } else if record.resumeSeconds > 0, let duration = runtimeSeconds {
            parts.append("\(max(1, Int(duration - record.resumeSeconds) / 60)) min left")
        }
        return parts.joined(separator: " · ")
    }
}

/// A download on its way: progress, sizes, percentage and speed, and pause/resume.
private struct DownloadingRow: View {
    let record: DownloadRecord

    private var downloads: DownloadStore { .shared }

    var body: some View {
        HStack(spacing: 12) {
            DownloadArtwork(record: record)
            VStack(alignment: .leading, spacing: 4) {
                if record.isEpisode, let show = record.item.seriesName {
                    Text(show)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                ProgressBar(fraction: record.fraction, height: 4)
                    .padding(.vertical, 2)
                // Re-read every second so a stalled download stops showing a speed.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let lines = downloads.statusLines(record)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(lines.sizes)
                            .foregroundStyle(Theme.text3)
                        Text(lines.status)
                            .foregroundStyle(record.state == .failed ? Color.orange : Theme.text3)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button {
                switch record.state {
                case .queued, .downloading: downloads.pause(record.id)
                case .paused, .failed: downloads.resume(record.id)
                case .done: break
                }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(record.state == .paused || record.state == .failed ? "Resume" : "Pause")
        }
    }

    private var title: String {
        let item = record.item
        guard record.isEpisode else { return item.name ?? "Movie" }
        return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    private var icon: String {
        switch record.state {
        case .queued, .downloading: return "pause.circle.fill"
        case .failed: return "arrow.clockwise.circle.fill"
        case .paused, .done: return "arrow.down.circle.fill"
        }
    }
}

/// The artwork saved with a download (the episode still, or a movie's backdrop).
private struct DownloadArtwork: View {
    let record: DownloadRecord

    var body: some View {
        let downloads = DownloadStore.shared
        // Read so the row redraws once the artwork has been saved.
        let _ = downloads.artworkRevision
        ArtworkFrame(url: downloads.stillURL(record.id) ?? downloads.posterURL(record.id), aspectRatio: 16 / 9, cornerRadius: 8)
            .frame(width: 104 * Metrics.scale)
            .id(downloads.artworkRevision)
    }
}

/// Download tile for a movie or episode page: Download, the progress, or Downloaded (tap to remove).
struct DownloadTile: View {
    let api: LibraryAPI
    let item: BaseItemDto

    @Environment(SessionStore.self) private var store
    @State private var message: String?
    @State private var confirmRemove = false
    @State private var isStarting = false

    private var downloads: DownloadStore { .shared }

    var body: some View {
        let record = downloads.record(item.id)
        Button {
            tap(record)
        } label: {
            TileLabel(title: title(record), systemImage: icon(record))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(TileButtonStyle(isOn: record?.state == .done))
        .disabled(isStarting)
        .confirmationDialog(record?.state == .done ? "Remove the download?" : "Cancel the download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(record?.state == .done ? "Remove download" : "Cancel download", role: .destructive) {
                if let id = item.id {
                    downloads.delete(id)
                }
            }
        } message: {
            let base = record?.state == .done ? "It stays on the server; only the copy on this iPhone is deleted." : "What has downloaded so far is deleted."
            Text(downloads.message(base, for: record.map { [$0] } ?? [], currentUserID: store.session?.userID))
        }
        .alert("Can't download", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func tap(_ record: DownloadRecord?) {
        guard let id = item.id else { return }
        switch record?.state {
        case nil:
            isStarting = true
            Task {
                message = await downloads.download(itemID: id, api: api)
                isStarting = false
            }
        case .paused, .failed:
            downloads.resume(id)
        case .queued, .downloading, .done:
            confirmRemove = true
        }
    }

    private func title(_ record: DownloadRecord?) -> String {
        guard let record else { return "Download" }
        switch record.state {
        case .done: return "Downloaded"
        case .queued: return "Queued"
        case .downloading: return record.receivedBytes > 0 ? "\(Int(record.fraction * 100))%" : "Starting"
        case .paused: return "Paused"
        case .failed: return "Retry"
        }
    }

    private func icon(_ record: DownloadRecord?) -> String {
        guard let record else { return "arrow.down.circle" }
        switch record.state {
        case .done: return "checkmark.circle.fill"
        case .queued, .downloading: return "arrow.down.circle.dotted"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.arrow.circlepath"
        }
    }
}
