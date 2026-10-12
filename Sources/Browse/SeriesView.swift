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
                            .foregroundStyle(series.isFavorite ? Color.accentColor : Theme.text)
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
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if seasons.count > 1 {
                seasonPills
                    .padding(.top, 20)
            }

            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
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
                }
            }
            .id(loadedSeasonID)
            .transition(.opacity)
            .padding(.horizontal, 16)
            .padding(.top, seasons.count > 1 ? 14 : 22)
            .padding(.bottom, 24)
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
            playback = PlaybackSession(api: api, item: full, startSeconds: full.isPlayed ? 0 : full.resumeSeconds)
        } catch {
            AppLog.shared.log("Couldn't start \(episode.name ?? id): \(error.localizedDescription)", level: .error)
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
