import JellyfinAPI
import SwiftUI

/// A show: header, season picker and the selected season's episodes.
struct SeriesView: View {
    let api: LibraryAPI
    let seriesID: String
    let initialSeasonID: String?

    @State private var series: BaseItemDto?
    @State private var seasons: [BaseItemDto] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [BaseItemDto] = []
    @State private var loadedSeasonID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let series {
                Section {
                    DetailHeader(item: series, api: api)
                    if let binding = Binding($series) {
                        UserDataButtons(api: api, item: binding) {
                            Task { await reloadAfterChange() }
                        }
                    }
                    if let overview = series.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                    }
                }
                .listRowSeparator(.hidden)
            }

            if seasons.count > 1 {
                Section {
                    seasonPicker
                        .listRowInsets(EdgeInsets())
                }
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    NavigationLink(value: BrowseRoute.item(episode)) {
                        EpisodeRow(episode: episode, api: api)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await togglePlayed(at: index) }
                        } label: {
                            Label(episode.isPlayed ? "Unwatched" : "Watched",
                                  systemImage: episode.isPlayed ? "eye.slash" : "checkmark")
                        }
                        .tint(.accentColor)
                    }
                }
            } header: {
                if let season = seasons.first(where: { $0.id == selectedSeasonID }) {
                    Text(season.name ?? "Episodes")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .listStyle(.plain)
        .navigationTitle(series?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if series == nil && errorMessage == nil {
                ProgressView()
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
    }

    private var seasonPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons, id: \.id) { season in
                        let isSelected = season.id == selectedSeasonID
                        Button {
                            selectedSeasonID = season.id
                        } label: {
                            Text(season.name ?? "Season")
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.2)))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(season.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .onAppear {
                if let selectedSeasonID {
                    proxy.scrollTo(selectedSeasonID, anchor: .center)
                }
            }
        }
    }

    private func loadSeries() async {
        do {
            async let seriesRequest = api.item(seriesID)
            async let seasonsRequest = api.seasons(seriesID: seriesID)
            series = try await seriesRequest
            seasons = try await seasonsRequest
            // Open the requested season, otherwise the first one with unwatched episodes.
            selectedSeasonID = initialSeasonID
                ?? seasons.first(where: { ($0.userData?.unplayedItemCount ?? 0) > 0 })?.id
                ?? seasons.first?.id
        } catch {
            errorMessage = "Couldn't load the show: \(error.localizedDescription)"
            AppLog.shared.log(errorMessage ?? "", level: .error)
        }
    }

    private func loadEpisodes(seasonID: String) async {
        do {
            let loaded = try await api.episodes(seriesID: seriesID, seasonID: seasonID)
            guard seasonID == selectedSeasonID else { return }
            episodes = loaded
            loadedSeasonID = seasonID
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn't load episodes: \(error.localizedDescription)"
            AppLog.shared.log(errorMessage ?? "", level: .error)
        }
    }

    /// Marking the whole show watched changes every episode and season count, so reload them.
    private func reloadAfterChange() async {
        if let seasonsNow = try? await api.seasons(seriesID: seriesID) {
            seasons = seasonsNow
        }
        if let selectedSeasonID {
            await loadEpisodes(seasonID: selectedSeasonID)
        }
    }

    private func togglePlayed(at index: Int) async {
        guard episodes.indices.contains(index), let id = episodes[index].id else { return }
        let played = !episodes[index].isPlayed
        do {
            let userData = try await api.setPlayed(played, itemID: id)
            if episodes.indices.contains(index), episodes[index].id == id {
                episodes[index].userData = userData
            }
        } catch {
            AppLog.shared.log("Couldn't change watched state: \(error.localizedDescription)", level: .error)
        }
    }
}

private struct EpisodeRow: View {
    let episode: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkFrame(url: api.imageURL(Artwork.landscape(episode), maxWidth: 400), aspectRatio: 16 / 9) {
                ZStack {
                    WatchBadge(item: episode)
                    ProgressOverlay(item: episode)
                }
            }
            .frame(width: 140)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let runtime = episode.runtimeText {
                    Text(runtime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        let name = episode.name ?? "Episode"
        guard let number = episode.indexNumber else { return name }
        return "\(number). \(name)"
    }
}
