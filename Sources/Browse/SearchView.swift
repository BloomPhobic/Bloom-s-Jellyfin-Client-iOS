import JellyfinAPI
import SwiftUI

/// Searches movies, shows and episodes as you type.
struct SearchView: View {
    let api: LibraryAPI
    /// Changes when the Search tab is tapped again: clear the search and show the first page.
    var resetToken = 0

    @State private var searchActive = false
    @State private var query = ""
    @State private var results: [BaseItemDto] = []
    @State private var searchedTerm = ""
    @State private var isSearching = false
    @State private var errorMessage: String?
    @AppStorage(SeerrClient.urlKey) private var seerrURL = ""

    private var requestsOn: Bool { ServerProbe.normalize(seerrURL) != nil }

    var body: some View {
        List {
            ForEach(results, id: \.id) { item in
                RouteLink(.item(item)) {
                    HStack(spacing: 8) {
                        SearchRow(item: item, api: api)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            if requestsOn, !results.isEmpty {
                NavigationLink {
                    RequestSearchView(term: query.trimmingCharacters(in: .whitespacesAndNewlines)).tabBarClearance()
                } label: {
                    Label("Can't find it? Request it", systemImage: "plus.circle")
                        .foregroundStyle(Theme.accent)
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
                if requestsOn {
                    ContentUnavailableView {
                        Label("No results for “\(term)”", systemImage: "magnifyingglass")
                    } description: {
                        Text("It isn't on the server.")
                    } actions: {
                        NavigationLink("Request it") {
                            RequestSearchView(term: term).tabBarClearance()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                } else {
                    ContentUnavailableView.search(text: term)
                }
            }
        }
        .searchable(text: $query, isPresented: $searchActive, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows and episodes")
        .navigationTitle("Search")
        .onChange(of: resetToken) {
            query = ""
            results = []
            searchedTerm = ""
            errorMessage = nil
            searchActive = false
        }
        .onChange(of: query) {
            // Clear at once so the old list never shows under the empty-state placeholder.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results = []
                searchedTerm = ""
                errorMessage = nil
            }
        }
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
            guard !Task.isCancelled, !AuthWatch.isCancellation(error) else { return }
            AuthWatch.report(error)
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
