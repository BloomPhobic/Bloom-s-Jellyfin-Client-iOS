import JellyfinAPI
import SwiftUI

/// A show: backdrop, Continue button, season pills and the selected season's episodes.
struct SeriesView: View {
    let api: LibraryAPI
    let seriesID: String
    let initialSeasonID: String?

    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var series: BaseItemDto?
    @State private var seasons: [BaseItemDto] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [BaseItemDto] = []
    @State private var loadedSeasonID: String?
    @State private var upNext: BaseItemDto?
    @State private var errorMessage: String?
    @State private var playback: PlaybackSession?
    @State private var isStartingPlayback = false
    @State private var downloadMessage: String?
    @State private var isQueueingSeason = false
    @State private var confirmRemoveSeason = false

    var body: some View {
        ScrollView {
            if let series {
                content(series)
                    .transition(.opacity)
            } else if let errorMessage {
                ErrorState(message: errorMessage) {
                    self.errorMessage = nil
                    await loadSeries()
                }
                .padding(.top, 120)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .overlay {
            if series == nil && errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle(series?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle(size: 36))
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let series {
                    Button {
                        Task { await setFavorite(!series.isFavorite) }
                    } label: {
                        Image(systemName: series.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(series.isFavorite ? Theme.accent : Theme.text)
                            .symbolEffect(.bounce, value: series.isFavorite)
                    }
                    .buttonStyle(CircleButtonStyle(size: 36))
                    .accessibilityLabel(series.isFavorite ? "Remove from favourites" : "Add to favourites")

                    Menu {
                        Button {
                            Task { await setPlayed(!series.isPlayed) }
                        } label: {
                            Label(series.isPlayed ? "Mark show unwatched" : "Mark show watched",
                                  systemImage: series.isPlayed ? "eye.slash" : "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.scrim))
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .task {
            guard series == nil else { return }
            await loadSeries()
        }
        .task(id: selectedSeasonID) {
            guard let selectedSeasonID, selectedSeasonID != loadedSeasonID else { return }
            await loadEpisodes(seasonID: selectedSeasonID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            Task { await reloadAfterChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentShouldRefresh)) { _ in
            Task {
                if series == nil {
                    errorMessage = nil
                    await loadSeries()
                } else {
                    await reloadAfterChange()
                }
            }
        }
        .fullScreenCover(item: $playback) { session in
            PlayerView(session: session)
                .environment(store)
        }
        .alert("Can't download", isPresented: Binding(get: { downloadMessage != nil }, set: { if !$0 { downloadMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadMessage ?? "")
        }
    }

    @ViewBuilder
    private func content(_ series: BaseItemDto) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BackdropHeader(url: api.imageURL(Artwork.backdrop(series) ?? Artwork.landscape(series), maxWidth: 1200), height: 250)

            VStack(alignment: .leading, spacing: 6) {
                Text(series.name ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(facts(series))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 20)
            .padding(.top, -24)

            VStack(alignment: .leading, spacing: 14) {
                if let upNext {
                    Button {
                        Task { await play(upNext) }
                    } label: {
                        HStack(spacing: 10) {
                            if isStartingPlayback {
                                ProgressView().tint(Theme.onAccent)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(continueTitle(upNext))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 50))
                    .disabled(isStartingPlayback)
                    .transition(.opacity)
                }
                if let overview = series.overview, !overview.isEmpty {
                    ExpandableText(text: overview)
                }
                GenreLinks(item: series, api: api)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if seasons.count > 1 {
                seasonPills
                    .padding(.top, 20)
            }

            if showsDownloads, !episodes.isEmpty {
                seasonDownloadBar
                    .padding(.horizontal, 16)
                    .padding(.top, seasons.count > 1 ? 14 : 22)
            }

            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    HStack(spacing: 4) {
                        NavigationLink(value: BrowseRoute.item(episode)) {
                            EpisodeRow(episode: episode, api: api)
                        }
                        .buttonStyle(PressableStyle())
                        .contextMenu {
                            Button {
                                Task { await togglePlayed(at: index) }
                            } label: {
                                Label(episode.isPlayed ? "Mark unwatched" : "Mark watched",
                                      systemImage: episode.isPlayed ? "eye.slash" : "checkmark.circle")
                            }
                        }
                        if showsDownloads, let id = episode.id {
                            EpisodeDownloadButton(itemID: id, api: api, canDownload: store.canDownload) { message in
                                downloadMessage = message
                            }
                        }
                    }
                }
            }
            .id(loadedSeasonID)
            .transition(.opacity)
            .padding(.horizontal, 16)
            .padding(.top, showsDownloads && !episodes.isEmpty ? 12 : (seasons.count > 1 ? 14 : 22))
            .padding(.bottom, 24)
        }
    }

    /// Download buttons show when the account may download, or something is downloaded already.
    private var showsDownloads: Bool {
        store.canDownload || episodes.contains { DownloadStore.shared.record($0.id) != nil }
    }

    /// The open season's episode count and its Download button (or how far the download is).
    private var seasonDownloadBar: some View {
        let records = episodes.compactMap { DownloadStore.shared.record($0.id) }
        let done = records.filter { $0.state == .done }.count
        let missing = episodes.count - records.count
        let seasonName = seasons.first { $0.id == loadedSeasonID }?.name ?? "season"
        return HStack(spacing: 10) {
            Text(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
            if missing > 0 && store.canDownload {
                Button {
                    Task {
                        isQueueingSeason = true
                        await downloadSeason()
                        isQueueingSeason = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isQueueingSeason {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(records.isEmpty ? "Download \(seasonName)" : "Download \(missing) more")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .foregroundStyle(Theme.accent)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .disabled(isQueueingSeason)
            } else if done < records.count {
                Label("Downloading \(done) of \(records.count)", systemImage: "arrow.down.circle.dotted")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .frame(height: 36)
            } else if !records.isEmpty {
                Button {
                    confirmRemoveSeason = true
                } label: {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .foregroundStyle(Theme.accent)
                        .background(Capsule().fill(Theme.raised))
                }
                .buttonStyle(PressableStyle())
                .confirmationDialog("Remove the downloads of \(seasonName)?", isPresented: $confirmRemoveSeason, titleVisibility: .visible) {
                    Button("Remove \(records.count == 1 ? "1 episode" : "\(records.count) episodes")", role: .destructive) {
                        for record in records {
                            DownloadStore.shared.delete(record.id)
                        }
                    }
                } message: {
                    Text("They stay on the server; only the copies on this iPhone are deleted.")
                }
            }
        }
    }

    private var seasonPills: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.id) { season in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedSeasonID = season.id
                            }
                        } label: {
                            Pill(title: season.name ?? "Season", isSelected: season.id == selectedSeasonID)
                        }
                        .buttonStyle(PressableStyle())
                        .id(season.id)
                        .accessibilityAddTraits(season.id == selectedSeasonID ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                if let selectedSeasonID {
                    proxy.scrollTo(selectedSeasonID, anchor: .center)
                }
            }
        }
    }

    private func facts(_ series: BaseItemDto) -> String {
        var parts: [String] = []
        if let year = series.productionYear {
            if let end = series.endDate.map({ Calendar.current.component(.year, from: $0) }), end != year {
                parts.append("\(year)–\(end)")
            } else {
                parts.append(String(year))
            }
        }
        if seasons.count > 0 {
            parts.append(seasons.count == 1 ? "1 season" : "\(seasons.count) seasons")
        }
        if let rating = series.officialRating {
            parts.append(rating)
        }
        if let score = series.communityRating {
            parts.append(String(format: "★ %.1f", score))
        }
        return parts.joined(separator: " · ")
    }

    private func continueTitle(_ episode: BaseItemDto) -> String {
        let label = episode.episodeLabel ?? "next episode"
        if episode.resumeSeconds > 0, !episode.isPlayed {
            return "Continue \(label) · \(ItemDetailView.timeText(episode.resumeSeconds))"
        }
        return "Play \(label)"
    }

    // MARK: - Loading

    private func loadSeries() async {
        do {
            async let seriesRequest = api.item(seriesID)
            async let seasonsRequest = api.seasons(seriesID: seriesID)
            let loadedSeries = try await seriesRequest
            let loadedSeasons = try await seasonsRequest
            withAnimation(.easeOut(duration: 0.25)) {
                series = loadedSeries
                seasons = loadedSeasons
            }
            // Open the requested season, otherwise the first one with unwatched episodes.
            selectedSeasonID = initialSeasonID
                ?? seasons.first(where: { ($0.userData?.unplayedItemCount ?? 0) > 0 })?.id
                ?? seasons.first?.id
            await loadUpNext()
        } catch {
            guard !AuthWatch.isCancellation(error) else { return }
            AuthWatch.report(error)
            errorMessage = error.localizedDescription
            AppLog.shared.log("Couldn't load the show: \(error.localizedDescription)", level: .error)
        }
    }

    private func loadUpNext() async {
        let next = try? await api.nextUp(seriesID: seriesID)
        withAnimation(.easeOut(duration: 0.2)) { upNext = next }
    }

    private func loadEpisodes(seasonID: String) async {
        do {
            let loaded = try await api.episodes(seriesID: seriesID, seasonID: seasonID)
            guard seasonID == selectedSeasonID else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                episodes = loaded
                loadedSeasonID = seasonID
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, !AuthWatch.isCancellation(error) else { return }
            AuthWatch.report(error)
            errorMessage = "Couldn't load episodes: \(error.localizedDescription)"
            AppLog.shared.log(errorMessage ?? "", level: .error)
        }
    }

    /// After playback or a watched change: seasons' counts, the episode list and Continue all change.
    private func reloadAfterChange() async {
        if let fresh = try? await api.item(seriesID) {
            series = fresh
        }
        if let seasonsNow = try? await api.seasons(seriesID: seriesID) {
            seasons = seasonsNow
        }
        if let selectedSeasonID {
            await loadEpisodes(seasonID: selectedSeasonID)
        }
        await loadUpNext()
    }

    // MARK: - Actions

    private func play(_ episode: BaseItemDto) async {
        guard let id = episode.id, !isStartingPlayback else { return }
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        do {
            let full = try await api.item(id)
            // No slide-up: the player appears at once and rotates to landscape straight away.
            withTransaction(\.disablesAnimations, true) {
                playback = PlaybackSession(api: api, item: full, startSeconds: full.isPlayed ? 0 : full.resumeSeconds)
            }
        } catch {
            AppLog.shared.log("Couldn't start \(episode.name ?? id): \(error.localizedDescription)", level: .error)
        }
    }

    /// Queues every episode of the open season that isn't downloaded yet. Stops at the first one
    /// that can't be (usually: not enough space).
    private func downloadSeason() async {
        for episode in episodes {
            guard let id = episode.id, DownloadStore.shared.record(id) == nil else { continue }
            if let message = await DownloadStore.shared.download(itemID: id, api: api) {
                downloadMessage = message
                return
            }
        }
    }

    private func setFavorite(_ favorite: Bool) async {
        do {
            let data = try await api.setFavorite(favorite, itemID: seriesID)
            withAnimation(.easeInOut(duration: 0.2)) { series?.userData = data }
            AppLog.shared.log("\(favorite ? "Added" : "Removed") \(series?.name ?? seriesID) \(favorite ? "to" : "from") favourites")
        } catch {
            AppLog.shared.log("Couldn't change favourite: \(error.localizedDescription)", level: .error)
        }
    }

    private func setPlayed(_ played: Bool) async {
        do {
            let data = try await api.setPlayed(played, itemID: seriesID)
            series?.userData = data
            AppLog.shared.log("Marked \(series?.name ?? seriesID) as \(played ? "watched" : "unwatched")")
            await reloadAfterChange()
        } catch {
            AppLog.shared.log("Couldn't change watched state: \(error.localizedDescription)", level: .error)
        }
    }

    private func togglePlayed(at index: Int) async {
        guard episodes.indices.contains(index), let id = episodes[index].id else { return }
        let played = !episodes[index].isPlayed
        do {
            let userData = try await api.setPlayed(played, itemID: id)
            if episodes.indices.contains(index), episodes[index].id == id {
                withAnimation(.easeInOut(duration: 0.2)) { episodes[index].userData = userData }
            }
            await loadUpNext()
        } catch {
            AppLog.shared.log("Couldn't change watched state: \(error.localizedDescription)", level: .error)
        }
    }
}

private struct EpisodeRow: View {
    let episode: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkFrame(url: api.imageURL(Artwork.landscape(episode), maxWidth: 400), aspectRatio: 16 / 9, cornerRadius: 10) {
                ZStack {
                    WatchBadge(item: episode)
                    ProgressOverlay(item: episode)
                }
            }
            .frame(width: 132)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(meta)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        let name = episode.name ?? "Episode"
        guard let number = episode.indexNumber else { return name }
        return "\(number). \(name)"
    }

    private var meta: String {
        var parts: [String] = []
        if let runtime = episode.runtimeText {
            parts.append(runtime)
        }
        if episode.isPlayed {
            parts.append("Watched")
        } else if episode.resumeSeconds > 0, let left = ItemDetailView.minutesLeft(episode) {
            parts.append(left)
        }
        return parts.joined(separator: " · ")
    }
}

/// The download button at the end of an episode row: Download, a progress ring (tap to pause or
/// continue), or Downloaded (tap to remove).
private struct EpisodeDownloadButton: View {
    let itemID: String
    let api: LibraryAPI
    let canDownload: Bool
    let showMessage: (String) -> Void

    @State private var isStarting = false
    @State private var confirmRemove = false

    var body: some View {
        let record = DownloadStore.shared.record(itemID)
        Button {
            tap(record)
        } label: {
            label(record)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(isStarting || (record == nil && !canDownload))
        .accessibilityLabel(accessibilityText(record))
        .confirmationDialog("Remove the download?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) {
                DownloadStore.shared.delete(itemID)
            }
        } message: {
            Text("It stays on the server; only the copy on this iPhone is deleted.")
        }
    }

    @ViewBuilder
    private func label(_ record: DownloadRecord?) -> some View {
        if isStarting {
            ProgressView().controlSize(.small)
        } else if let record {
            switch record.state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
            case .failed:
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.orange)
            case .queued, .downloading, .paused:
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, record.fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.4), value: record.fraction)
                    Image(systemName: record.state == .paused ? "arrow.down" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 22, height: 22)
            }
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22))
                .foregroundStyle(Theme.text2)
        }
    }

    private func tap(_ record: DownloadRecord?) {
        guard let record else {
            isStarting = true
            Task {
                if let message = await DownloadStore.shared.download(itemID: itemID, api: api) {
                    showMessage(message)
                }
                isStarting = false
            }
            return
        }
        switch record.state {
        case .queued, .downloading: DownloadStore.shared.pause(itemID)
        case .paused, .failed: DownloadStore.shared.resume(itemID)
        case .done: confirmRemove = true
        }
    }

    private func accessibilityText(_ record: DownloadRecord?) -> String {
        guard let record else { return "Download" }
        switch record.state {
        case .done: return "Downloaded. Remove download"
        case .failed: return "Download failed. Retry"
        case .paused: return "Download paused at \(Int(record.fraction * 100)) percent. Continue"
        case .queued, .downloading: return "Downloading, \(Int(record.fraction * 100)) percent. Pause"
        }
    }
}
