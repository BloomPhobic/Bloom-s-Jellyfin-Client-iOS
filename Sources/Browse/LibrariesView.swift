import JellyfinAPI
import SwiftUI

extension LibraryAPI {
    /// Library types a video client can show.
    private static let videoTypes: Set<CollectionType> = [.movies, .tvshows, .boxsets, .homevideos, .musicvideos]

    func videoLibraries() async throws -> [BaseItemDto] {
        try await libraries().filter { library in
            library.collectionType.map { Self.videoTypes.contains($0) } ?? true
        }
    }
}

/// One card among the libraries: a server library, or one of the two lists the app adds.
enum LibraryEntry: Identifiable {
    case library(BaseItemDto)
    case watchLater
    case favourites

    var id: String {
        switch self {
        case .library(let library): return library.id ?? ""
        case .watchLater: return "watchLater"
        case .favourites: return "favourites"
        }
    }

    var serverLibrary: BaseItemDto? {
        if case .library(let library) = self { return library }
        return nil
    }

    var name: String {
        switch self {
        case .library(let library): return library.name ?? "Library"
        case .watchLater: return HomeCollection.watchLater.title
        case .favourites: return HomeCollection.favourites.title
        }
    }

    var icon: String {
        switch self {
        case .watchLater: return "bookmark.fill"
        case .favourites: return "heart.fill"
        case .library(let library):
            switch library.collectionType {
            case .movies: return "film"
            case .tvshows: return "tv"
            case .boxsets: return "square.stack"
            case .homevideos: return "video"
            case .musicvideos: return "music.note.tv"
            default: return "folder"
            }
        }
    }

    var route: BrowseRoute {
        switch self {
        case .library(let library): return .library(library)
        case .watchLater: return .collection(.watchLater)
        case .favourites: return .collection(.favourites)
        }
    }

    static func orderKey(userID: String) -> String { "library.order.\(userID)" }

    /// The libraries, Watch later and Favourites in the saved order (comma-separated IDs). Anything
    /// not in it, such as a new library, comes after, in the server's order.
    static func ordered(_ libraries: [BaseItemDto], saved: String) -> [LibraryEntry] {
        let all = libraries.map(LibraryEntry.library) + [.watchLater, .favourites]
        let ids = saved.split(separator: ",").map(String.init)
        return ids.compactMap { id in all.first { $0.id == id } } + all.filter { !ids.contains($0.id) }
    }
}

/// A library or list: its image (or a large icon) with the name on a dark band. The caller sets the size.
struct LibraryEntryCard: View {
    let entry: LibraryEntry
    let api: LibraryAPI

    var body: some View {
        Color.clear
            .background(Theme.raised)
            .overlay {
                if let library = entry.serverLibrary {
                    RemoteImage(url: api.imageURL(Artwork.landscape(library), maxWidth: 640))
                } else {
                    Image(systemName: entry.icon)
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent.opacity(0.5))
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 7) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(entry.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background.opacity(0.75))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}

/// "See all" for the libraries: every card in a grid, and a drag list to put them in order.
struct LibrariesView: View {
    let api: LibraryAPI

    @AppStorage private var savedOrder: String
    @State private var libraries: [BaseItemDto]?
    @State private var errorMessage: String?
    @State private var reordering = false

    private let columns = [GridItem(.adaptive(minimum: 150 * Metrics.scale), spacing: 12)]

    init(api: LibraryAPI) {
        self.api = api
        _savedOrder = AppStorage(wrappedValue: "", LibraryEntry.orderKey(userID: api.userID))
    }

    private var entries: [LibraryEntry] { LibraryEntry.ordered(libraries ?? [], saved: savedOrder) }

    var body: some View {
        Group {
            if let errorMessage, libraries == nil {
                ErrorState(message: errorMessage) { await load() }
            } else if libraries == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reordering {
                orderList
            } else {
                grid
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Libraries")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if libraries != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if reordering && !savedOrder.isEmpty {
                        Button("Reset") {
                            withAnimation { savedOrder = "" }
                        }
                    }
                    Button(reordering ? "Done" : "Reorder") {
                        withAnimation { reordering.toggle() }
                    }
                }
            }
        }
        .task {
            guard libraries == nil else { return }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentShouldRefresh)) { _ in
            Task { await load() }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(entries) { entry in
                    RouteLink(entry.route) {
                        LibraryEntryCard(entry: entry, api: api)
                            .aspectRatio(210.0 / 118.0, contentMode: .fit)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var orderList: some View {
        List {
            ForEach(entries) { entry in
                Label(entry.name, systemImage: entry.icon)
                    .foregroundStyle(Theme.text)
                    .listRowBackground(Theme.surface)
            }
            .onMove { source, destination in
                var ids = entries.map(\.id)
                ids.move(fromOffsets: source, toOffset: destination)
                savedOrder = ids.joined(separator: ",")
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    private func load() async {
        do {
            libraries = try await api.videoLibraries()
            errorMessage = nil
        } catch {
            if Task.isCancelled || AuthWatch.isCancellation(error) { return }
            AuthWatch.report(error)
            errorMessage = error.localizedDescription
            AppLog.shared.log("Libraries: \(error.localizedDescription)", level: .error)
        }
    }
}
