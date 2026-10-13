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
    @State private var loadedKey: LoadKey?
    @State private var searchText = ""
    /// The search text after a short pause in typing.
    @State private var searchTerm = ""

    private static let pageSize = 100
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    init(api: LibraryAPI, parent: BaseItemDto) {
        self.api = api
        self.parent = parent
        _query = State(initialValue: LibraryQuery.load(for: parent.id))
    }

    var body: some View {
        ScrollView {
            if total > 0 {
                Text(countText)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
            if query != LibraryQuery() {
                activeOptions
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: BrowseRoute.item(item)) {
                        PosterCard(item: item, api: api)
                    }
                    .buttonStyle(PressableStyle())
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
            if !isLoading && items.isEmpty, let errorMessage {
                ErrorState(message: errorMessage) {
                    await reload()
                }
            } else if !isLoading && items.isEmpty {
                ContentUnavailableView(
                    errorMessage == nil ? "Nothing here" : "Couldn't load",
                    systemImage: errorMessage == nil ? "film.stack" : "exclamationmark.triangle",
                    description: Text(errorMessage ?? (!searchTerm.isEmpty ? "Nothing matches \"\(searchTerm)\"." : query.unplayedOnly || query.favouritesOnly ? "Try turning off the filters." : ""))
                )
            }
        }
        .refreshable { await Task { await reload() }.value }
        .onReceive(NotificationCenter.default.publisher(for: .contentShouldRefresh)) { _ in
            Task { await reload() }
        }
        .animation(.easeInOut(duration: 0.25), value: query)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(parent.name ?? "Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                optionsMenu
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search \(parent.name ?? "this library")")
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searchTerm = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .task(id: LoadKey(query: query, search: searchTerm)) {
            // .task also runs when coming back from a pushed page; keep the grid (and scroll position) then.
            let key = LoadKey(query: query, search: searchTerm)
            guard key != loadedKey else { return }
            loadedKey = key
            query.save(for: parent.id)
            await reload()
        }
    }

    private struct LoadKey: Hashable {
        let query: LibraryQuery
        let search: String
    }

    private var countText: String {
        let noun: String
        switch parent.collectionType {
        case .movies: noun = total == 1 ? "movie" : "movies"
        case .tvshows: noun = total == 1 ? "show" : "shows"
        default: noun = total == 1 ? "item" : "items"
        }
        return searchTerm.isEmpty ? "\(total) \(noun)" : "\(total) \(noun) matching \"\(searchTerm)\""
    }

    /// Chips for every non-default option, each removable, plus Reset. Shown above the grid.
    private var activeOptions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if query.sort != .name || !query.ascending {
                    OptionChip(title: "\(query.sort.label) \(query.ascending ? "↑" : "↓")") {
                        query.sort = .name
                        query.ascending = true
                    }
                }
                if query.unplayedOnly {
                    OptionChip(title: "Unplayed") { query.unplayedOnly = false }
                }
                if query.favouritesOnly {
                    OptionChip(title: "Favourites") { query.favouritesOnly = false }
                }
                Button("Reset") {
                    query = LibraryQuery()
                }
                .font(.subheadline.weight(.semibold))
                .padding(.leading, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
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

    /// Loads the first page and then replaces the grid, so the old items stay visible meanwhile.
    private func reload() async {
        loadID += 1
        let id = loadID
        isLoading = true
        errorMessage = nil
        do {
            let page = try await api.items(in: parent, query: query, searchTerm: searchTerm, startIndex: 0, limit: Self.pageSize)
            guard id == loadID else { return }
            items = page.items
            total = page.total
        } catch {
            guard id == loadID else { return }
            report(error)
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, items.count < total else { return }
        let id = loadID
        isLoading = true
        do {
            let page = try await api.items(in: parent, query: query, searchTerm: searchTerm, startIndex: items.count, limit: Self.pageSize)
            guard id == loadID else { return }
            items += page.items
            total = page.total
        } catch {
            guard id == loadID else { return }
            report(error)
        }
        isLoading = false
    }

    private func report(_ error: Error) {
        // A cancelled request (the view went away, or a newer load replaced it) isn't a failure.
        if Task.isCancelled || AuthWatch.isCancellation(error) {
            return
        }
        AuthWatch.report(error)
        errorMessage = error.localizedDescription
        AppLog.shared.log("Library \(parent.name ?? ""): \(error.localizedDescription)", level: .error)
    }
}

/// A removable option, like "Unplayed ✕".
private struct OptionChip: View {
    let title: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark")
                    .font(.caption2.bold())
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.accent.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
            .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title)")
    }
}
