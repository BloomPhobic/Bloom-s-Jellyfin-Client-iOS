import JellyfinAPI
import SwiftUI

/// The Downloads tab: what's downloading, then movies and shows on the phone. Works without a
/// connection; tap anything finished to play it.
struct DownloadsView: View {
    @Environment(SessionStore.self) private var store
    @State private var playback: PlaybackSession?
    @State private var freeBytes: Int64 = 0

    private var downloads: DownloadStore { .shared }

    private var mine: [DownloadRecord] {
        downloads.list(for: store.session?.userID)
    }

    private var inProgress: [DownloadRecord] {
        mine.filter { $0.state != .done }.sorted { $0.addedAt < $1.addedAt }
    }

    private var movies: [DownloadRecord] {
        mine.filter { $0.state == .done && !$0.isEpisode }
            .sorted { ($0.item.sortName ?? $0.item.name ?? "") < ($1.item.sortName ?? $1.item.name ?? "") }
    }

    private struct ShowGroup: Identifiable {
        let id: String
        let name: String
        let episodes: [DownloadRecord]
    }

    /// Finished episodes grouped by show, shows in name order.
    private var shows: [ShowGroup] {
        let episodes = mine.filter { $0.state == .done && $0.isEpisode }
        let grouped = Dictionary(grouping: episodes) { $0.item.seriesID ?? "" }
        return grouped.map { key, value in
            ShowGroup(id: key, name: value.first?.item.seriesName ?? "Show", episodes: value.sorted(by: DownloadStore.episodeOrder))
        }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.session == nil {
                    placeholder(icon: "person.crop.circle", title: "Not signed in", text: "Sign in on the Home tab to download movies and episodes.")
                } else if mine.isEmpty {
                    placeholder(icon: "arrow.down.circle", title: "No downloads yet", text: "Tap Download on a movie or episode to watch it without a connection.")
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
            }

            if !inProgress.isEmpty {
                Section("Downloading") {
                    ForEach(inProgress) { record in
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

            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { record in
                        finishedRow(record)
                    }
                }
            }

            ForEach(shows) { show in
                Section(show.name) {
                    ForEach(show.episodes) { record in
                        finishedRow(record)
                    }
                }
            }
        }
    }

    private func finishedRow(_ record: DownloadRecord) -> some View {
        Button {
            play(record)
        } label: {
            DownloadedRow(record: record)
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                downloads.delete(record.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                downloads.delete(record.id)
            } label: {
                Label("Delete download", systemImage: "trash")
            }
        }
    }

    private func placeholder(icon: String, title: String, text: String) -> some View {
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

/// A download on its way: progress, status, and pause/resume.
private struct DownloadingRow: View {
    let record: DownloadRecord

    private var downloads: DownloadStore { .shared }

    var body: some View {
        HStack(spacing: 12) {
            DownloadArtwork(record: record)
            VStack(alignment: .leading, spacing: 5) {
                Text(DownloadStore.title(record.item))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                ProgressBar(fraction: record.fraction, height: 4)
                Text(downloads.statusText(record))
                    .font(.system(size: 12))
                    .foregroundStyle(record.state == .failed ? Color.orange : Theme.text3)
                    .lineLimit(2)
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
