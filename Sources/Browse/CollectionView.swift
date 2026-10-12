import JellyfinAPI
import SwiftUI

/// "See all" page for a Home row: everything in progress, everything up next, or the whole watch history.
struct CollectionView: View {
    let api: LibraryAPI
    let collection: HomeCollection

    @State private var items: [BaseItemDto] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private static let pageSize = 60
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: BrowseRoute.item(item)) {
                        LandscapeCard(item: item, api: api)
                    }
                    .buttonStyle(PressableStyle())
                    .onAppear {
                        if item.id == items.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if isLoading {
                ProgressView()
                    .padding()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay {
            if hasLoaded && !isLoading && items.isEmpty, let errorMessage {
                ErrorState(message: errorMessage) { await reload() }
            } else if hasLoaded && !isLoading && items.isEmpty {
                ContentUnavailableView(
                    errorMessage == nil ? "Nothing here yet" : "Couldn't load",
                    systemImage: errorMessage == nil ? "film.stack" : "exclamationmark.triangle",
                    description: errorMessage.map { Text($0) }
                )
            }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await Task { await reload() }.value }
        .task {
            guard !hasLoaded else { return }
            await reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentShouldRefresh)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            let page = try await fetch(startIndex: 0)
            withAnimation(.easeOut(duration: 0.25)) {
                items = page.items
                total = page.total
            }
            errorMessage = nil
        } catch {
            if Task.isCancelled || AuthWatch.isCancellation(error) { return }
            AuthWatch.report(error)
            errorMessage = error.localizedDescription
            AppLog.shared.log("\(collection.title): \(error.localizedDescription)", level: .error)
        }
    }

    private func loadMore() async {
        guard collection == .history, !isLoading, items.count < total else { return }
        isLoading = true
        defer { isLoading = false }
        if let page = try? await fetch(startIndex: items.count) {
            items += page.items
            total = page.total
        }
    }

    private func fetch(startIndex: Int) async throws -> (items: [BaseItemDto], total: Int) {
        switch collection {
        case .continueWatching:
            let found = try await api.resumeItems(limit: 100)
            return (found, found.count)
        case .nextUp:
            let found = try await api.nextUp(limit: 100)
            return (found, found.count)
        case .history:
            return try await api.watchHistory(startIndex: startIndex, limit: Self.pageSize)
        }
    }
}
