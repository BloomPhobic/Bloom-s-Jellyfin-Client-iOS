import JellyfinAPI
import SwiftUI

/// Poster grid for a library, collection or folder, with sort and filter options.
struct LibraryView: View {
    let api: LibraryAPI
    let parent: BaseItemDto

    @State private var query: LibraryQuery
    @State private var items: [BaseItemDto] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadID = 0
    @State private var loadedQuery: LibraryQuery?

    private static let pageSize = 100
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    init(api: LibraryAPI, parent: BaseItemDto) {
        self.api = api
        self.parent = parent
        _query = State(initialValue: LibraryQuery.load(for: parent.id))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: BrowseRoute.item(item)) {
                        PosterCard(item: item, api: api)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == items.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding(.horizontal)
            if isLoading {
                ProgressView()
                    .padding()
            }
        }
        .overlay {
            if !isLoading && items.isEmpty {
                ContentUnavailableView(
                    errorMessage == nil ? "Nothing here" : "Couldn't load",
                    systemImage: errorMessage == nil ? "film.stack" : "exclamationmark.triangle",
                    description: Text(errorMessage ?? (query.unplayedOnly || query.favouritesOnly ? "Try turning off the filters." : ""))
                )
            }
        }
        .refreshable { await reload() }
        .navigationTitle(parent.name ?? "Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
        }
        .task(id: query) {
            // .task also runs when coming back from a pushed page; keep the grid (and scroll position) then.
            guard query != loadedQuery else { return }
            loadedQuery = query
            query.save(for: parent.id)
            await reload()
        }
    }

    private var optionsMenu: some View {
        Menu {
            Picker("Sort by", selection: sortBinding) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            Picker("Order", selection: $query.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            Section("Show only") {
                Toggle("Unplayed", isOn: $query.unplayedOnly)
                Toggle("Favourites", isOn: $query.favouritesOnly)
            }
        } label: {
            Image(systemName: query.unplayedOnly || query.favouritesOnly
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    /// Changing the sort also picks its natural order (A–Z for names, newest/highest first otherwise).
    private var sortBinding: Binding<LibrarySort> {
        Binding(
            get: { query.sort },
            set: { newSort in
                var updated = query
                updated.sort = newSort
                updated.ascending = newSort.defaultAscending
                query = updated
            }
        )
    }

    private func reload() async {
        items = []
        total = 0
        errorMessage = nil
        await loadMore(force: true)
    }

    private func loadMore(force: Bool = false) async {
        if force {
            loadID += 1
        } else if isLoading || items.count >= total {
            return
        }
        let id = loadID
        isLoading = true
        do {
            let page = try await api.items(in: parent, query: query, startIndex: items.count, limit: Self.pageSize)
            // The sort or filters changed while loading; the newer load takes over.
            guard id == loadID else { return }
            items += page.items
            total = page.total
        } catch {
            guard id == loadID else { return }
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                AppLog.shared.log("Library \(parent.name ?? ""): \(error.localizedDescription)", level: .error)
            }
        }
        isLoading = false
    }
}
