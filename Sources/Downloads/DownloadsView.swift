import JellyfinAPI
import SwiftUI

/// The Downloads tab: storage, a link to what's downloading, then movies and shows on the phone.
/// Works without a connection; tap anything to play it.
struct DownloadsView: View {
    @Environment(SessionStore.self) private var store
    @State private var playback: PlaybackSession?
    @State private var freeBytes: Int64 = 0

    private var downloads: DownloadStore { .shared }

    private var mine: [DownloadRecord] {
        downloads.list(for: store.session?.userID)
    }

    private var movies: [DownloadRecord] {
        mine.filter { $0.state == .done && !$0.isEpisode }
            .sorted { ($0.item.sortName ?? $0.item.name ?? "") < ($1.item.sortName ?? $1.item.name ?? "") }
    }

    /// Shows with at least one finished episode, in name order.
    private var shows: [DownloadedShow] {
        let episodes = mine.filter { $0.state == .done && $0.isEpisode }
        let grouped = Dictionary(grouping: episodes) { $0.item.seriesID ?? "" }
        return grouped.map { key, value in
            DownloadedShow(id: key, name: value.first?.item.seriesName ?? "Show", episodes: value.sorted(by: DownloadStore.episodeOrder))
        }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.session == nil {
                    DownloadsPlaceholder(icon: "person.crop.circle", title: "Not signed in", text: "Sign in on the Home tab to download movies and episodes.")
                } else if mine.isEmpty {
                    DownloadsPlaceholder(icon: "arrow.down.circle", title: "No downloads yet", text: "Tap Download on a movie or episode to watch it without a connection.")
                } else {
                    list
                }
            }
            .themedBackground()
            .tabBarClearance()
            .navigationTitle("Downloads")
        }
        .onAppear { freeBytes = DownloadFiles.freeBytes }
        .onChange(of: mine.count) { freeBytes = DownloadFiles.freeBytes }
        .fullScreenCover(item: $playback) { session in
            PlayerView(session: session)
                .environment(store)
        }
    }

    private var list: some View {
        List {
            Section {
                LabeledContent("On this iPhone", value: "\(DownloadStore.format(downloads.usedBytes(userID: store.session?.userID))) used · \(DownloadStore.format(freeBytes)) free")
                    .font(.subheadline)
                if !store.isConnected {
                    Label("You're offline. Downloads play as usual; your progress is sent to the server later.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(Theme.text2)
                }
                NavigationLink {
                    ActiveDownloadsView()
                } label: {
                    ActiveDownloadsLink(records: mine.filter { $0.state != .done }, userID: store.session?.userID)
                }
            }

            if movies.isEmpty && shows.isEmpty {
                Section {
                    Text("Finished downloads appear here.")
                        .font(.footnote)
                        .foregroundStyle(Theme.text3)
                }
            }

            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { record in
                        DownloadedItemButton(record: record, play: play)
                    }
                }
            }

            if !shows.isEmpty {
                Section("Shows") {
                    ForEach(shows) { show in
                        NavigationLink {
                            ShowDownloadsView(seriesID: show.id, name: show.name, play: play)
                        } label: {
                            ShowRow(show: show)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                for record in show.episodes {
                                    downloads.delete(record.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func play(_ record: DownloadRecord) {
        guard let api = store.apiForDownloads() else { return }
        let source = record.item.mediaSources?.first { $0.id == record.mediaSourceID }
        let session = PlaybackSession(
            api: api,
            item: record.item,
            mediaSource: source,
            startSeconds: record.resumeSeconds,
            offline: !store.isConnected
        )
        withTransaction(\.disablesAnimations, true) {
            playback = session
        }
    }
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

/// A show on the Downloads page: poster, name, episode count and size.
private struct ShowRow: View {
    let show: DownloadedShow

    var body: some View {
        let downloads = DownloadStore.shared
        let _ = downloads.artworkRevision
        let poster = show.episodes.lazy.compactMap { downloads.posterURL($0.id) }.first
        HStack(spacing: 12) {
            ArtworkFrame(url: poster, aspectRatio: 2 / 3, cornerRadius: 8)
                .frame(width: 52)
                .id(downloads.artworkRevision)
            VStack(alignment: .leading, spacing: 3) {
                Text(show.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                let unwatched = show.episodes.filter { !$0.isWatched }.count
                if unwatched > 0 {
                    Text("\(unwatched) unwatched")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        let count = show.episodes.count
        let size = show.episodes.reduce(Int64(0)) { $0 + $1.totalBytes }
        return "\(count == 1 ? "1 episode" : "\(count) episodes") · \(DownloadStore.format(size))"
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

    private var episodes: [DownloadRecord] {
        DownloadStore.shared.episodes(seriesID: seriesID, userID: store.session?.userID)
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

    var body: some View {
        List {
            ForEach(seasons) { season in
                Section(season.name) {
                    ForEach(season.episodes) { record in
                        DownloadedItemButton(record: record, play: play)
                    }
                }
            }
        }
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
            Text("Only the copies on this iPhone are deleted.")
        }
        .onChange(of: episodes.isEmpty) {
            if episodes.isEmpty {
                dismiss()
            }
        }
    }
}

/// A finished download as a row you tap to play, swipe or long-press to delete.
private struct DownloadedItemButton: View {
    let record: DownloadRecord
    let play: (DownloadRecord) -> Void

    var body: some View {
        Button {
            play(record)
        } label: {
            DownloadedRow(record: record)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                DownloadStore.shared.delete(record.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                DownloadStore.shared.delete(record.id)
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
            .frame(width: 104)
            .id(downloads.artworkRevision)
    }
}

/// Download tile for a movie or episode page: Download, the progress, or Downloaded (tap to remove).
struct DownloadTile: View {
    let api: LibraryAPI
    let item: BaseItemDto

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
            Text(record?.state == .done ? "It stays on the server; only the copy on this iPhone is deleted." : "What has downloaded so far is deleted.")
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
