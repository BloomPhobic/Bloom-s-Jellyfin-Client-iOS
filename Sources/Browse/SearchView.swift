import JellyfinAPI
import SwiftUI

/// Searches movies, shows and episodes as you type.
struct SearchView: View {
    let api: LibraryAPI

    @State private var query = ""
    @State private var results: [BaseItemDto] = []
    @State private var searchedTerm = ""
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(results, id: \.id) { item in
                NavigationLink(value: BrowseRoute.item(item)) {
                    SearchRow(item: item, api: api)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .overlay {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.isEmpty {
                ContentUnavailableView("Search", systemImage: "magnifyingglass", description: Text("Find movies, shows and episodes."))
            } else if let errorMessage {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if results.isEmpty && !isSearching && searchedTerm == term {
                ContentUnavailableView.search(text: term)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows and episodes")
        .navigationTitle("Search")
        .task(id: query) {
            // Wait for a pause in typing before searching.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
        .browseDestinations(api: api)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            searchedTerm = ""
            return
        }
        guard term != searchedTerm else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await api.search(term)
            guard !Task.isCancelled else { return }
            results = found
            searchedTerm = term
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            AppLog.shared.log("Search failed: \(error.localizedDescription)", level: .error)
        }
    }
}

private struct SearchRow: View {
    let item: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        HStack(spacing: 12) {
            ArtworkFrame(url: api.imageURL(Artwork.poster(item), maxWidth: 150), aspectRatio: 2 / 3)
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "Untitled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        switch item.type {
        case .episode:
            return [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        case .series:
            return ["Show", item.productionYear.map { String($0) }].compactMap { $0 }.joined(separator: " · ")
        default:
            return ["Movie", item.productionYear.map { String($0) }].compactMap { $0 }.joined(separator: " · ")
        }
    }
}
