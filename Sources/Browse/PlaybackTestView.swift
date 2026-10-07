import JellyfinAPI
import SwiftUI

/// Phase 1 tab: sign in, search for a file, inspect it, play it.
struct PlaybackTestView: View {
    @State private var store = SessionStore()

    var body: some View {
        NavigationStack {
            if let client = store.client, let session = store.session {
                SearchView(client: client, userID: session.userID)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Text("\(session.userName) @ \(session.serverURL.host() ?? "")")
                                Button("Sign out", role: .destructive) {
                                    Task { await store.signOut() }
                                }
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                    }
            } else {
                LoginView(store: store)
            }
        }
    }
}

private struct SearchView: View {
    let client: JellyfinClient
    let userID: String

    @State private var query = ""
    @State private var results: [BaseItemDto] = []
    @State private var isSearching = false
    @State private var message: String? = "Search for a movie or episode to test."

    var body: some View {
        List {
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
            ForEach(results, id: \.id) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Untitled")
                        if let subtitle = Self.subtitle(for: item) {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .overlay {
            if isSearching {
                ProgressView()
            }
        }
        .searchable(text: $query, prompt: "Movies and episodes")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .navigationTitle("Playback test")
        .navigationDestination(for: BaseItemDto.self) { item in
            ItemDetailView(client: client, userID: userID, itemID: item.id ?? "")
        }
    }

    private static func subtitle(for item: BaseItemDto) -> String? {
        if item.type == .episode {
            let season = item.parentIndexNumber.map { "S\($0)" } ?? ""
            let episode = item.indexNumber.map { "E\($0)" } ?? ""
            return [item.seriesName, season + episode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return item.productionYear.map { String($0) }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isSearching = true
        message = nil
        defer { isSearching = false }

        let parameters = Paths.GetItemsParameters(
            userID: userID,
            limit: 50,
            isRecursive: true,
            searchTerm: term,
            includeItemTypes: [.movie, .episode, .video]
        )
        do {
            let response = try await client.send(Paths.getItems(parameters: parameters))
            results = response.value.items ?? []
            if results.isEmpty {
                message = "No results for \"\(term)\"."
            }
        } catch {
            results = []
            message = "Search failed: \(error.localizedDescription)"
            AppLog.shared.log("Search failed: \(error.localizedDescription)", level: .error)
        }
    }
}
