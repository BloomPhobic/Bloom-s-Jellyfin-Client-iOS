import JellyfinAPI
import SwiftUI

/// Where a tap on a card leads.
enum BrowseRoute: Hashable {
    case item(BaseItemDto)
    case library(BaseItemDto)
}

/// Opens the right screen for an item: shows and seasons get the episode browser,
/// collections and folders get a grid, everything else gets the detail page.
struct BrowseDestination: View {
    let route: BrowseRoute
    let api: LibraryAPI

    var body: some View {
        switch route {
        case .library(let library):
            LibraryView(api: api, parent: library)
        case .item(let item):
            switch item.type {
            case .series:
                SeriesView(api: api, seriesID: item.id ?? "", initialSeasonID: nil)
            case .season:
                SeriesView(api: api, seriesID: item.seriesID ?? "", initialSeasonID: item.id)
            case .boxSet, .folder, .collectionFolder, .userView:
                LibraryView(api: api, parent: item)
            default:
                ItemDetailView(api: api, itemID: item.id ?? "")
            }
        }
    }
}

extension View {
    func browseDestinations(api: LibraryAPI) -> some View {
        navigationDestination(for: BrowseRoute.self) { route in
            BrowseDestination(route: route, api: api)
        }
    }
}

/// Shows the connection and login screens until the user is signed in, then the content.
struct SignedInGate<Content: View>: View {
    @Environment(SessionStore.self) private var store
    @ViewBuilder let content: (LibraryAPI) -> Content

    var body: some View {
        if store.server == nil {
            AddServerView()
        } else if store.route == nil {
            if store.hasResolved && !store.isResolving {
                ServerUnreachableView()
            } else {
                ConnectingView()
            }
        } else if let client = store.client, let session = store.session {
            content(LibraryAPI(client: client, userID: session.userID))
        } else {
            LoginView()
        }
    }
}

struct HomeView: View {
    let api: LibraryAPI

    @Environment(SessionStore.self) private var store
    @State private var resume: [BaseItemDto] = []
    @State private var nextUp: [BaseItemDto] = []
    @State private var libraries: [BaseItemDto] = []
    @State private var latest: [String: [BaseItemDto]] = [:]
    @State private var errorMessage: String?
    @State private var lastLoaded: Date?

    /// Library types a video client can show.
    private static let videoLibraries: Set<CollectionType> = [.movies, .tvshows, .boxsets, .homevideos, .musicvideos]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                        Button("Try again") { Task { await load() } }
                    }
                    .padding(.horizontal)
                }
                if !resume.isEmpty {
                    row("Continue watching", items: resume, wide: true)
                }
                if !nextUp.isEmpty {
                    row("Next up", items: nextUp, wide: true)
                }
                ForEach(libraries, id: \.id) { library in
                    if let items = latest[library.id ?? ""], !items.isEmpty {
                        row("Recently added in \(library.name ?? "library")", items: items, wide: false)
                    }
                }
                if !libraries.isEmpty {
                    librariesRow
                }
                if lastLoaded == nil && errorMessage == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(store.server?.name ?? "Home")
        .refreshable { await load() }
        .task {
            // Reload when coming back to Home, but not on every tab switch.
            if lastLoaded.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                await load()
            }
        }
        .browseDestinations(api: api)
    }

    private func row(_ title: String, items: [BaseItemDto], wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.id) { item in
                        NavigationLink(value: BrowseRoute.item(item)) {
                            if wide {
                                LandscapeCard(item: item, api: api)
                                    .frame(width: 240)
                            } else {
                                PosterCard(item: item, api: api)
                                    .frame(width: 110)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var librariesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Libraries")
                .font(.title3.bold())
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(libraries, id: \.id) { library in
                        NavigationLink(value: BrowseRoute.library(library)) {
                            VStack(alignment: .leading, spacing: 4) {
                                ArtworkFrame(url: api.imageURL(Artwork.landscape(library), maxWidth: 600), aspectRatio: 16 / 9)
                                Text(library.name ?? "")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .frame(width: 200)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func load() async {
        async let resumeRequest = api.resumeItems()
        async let nextUpRequest = api.nextUp()
        async let librariesRequest = api.libraries()

        var failures: [String] = []
        do { resume = try await resumeRequest } catch { failures.append("continue watching: \(error.localizedDescription)") }
        do { nextUp = try await nextUpRequest } catch { failures.append("next up: \(error.localizedDescription)") }
        do {
            let all = try await librariesRequest
            libraries = all.filter { library in
                library.collectionType.map { Self.videoLibraries.contains($0) } ?? true
            }
        } catch {
            failures.append("libraries: \(error.localizedDescription)")
        }

        let api = api
        let libraryIDs = libraries.compactMap(\.id)
        latest = await withTaskGroup(of: (String, [BaseItemDto]).self) { group in
            for id in libraryIDs {
                group.addTask { (id, (try? await api.latest(in: id)) ?? []) }
            }
            var found: [String: [BaseItemDto]] = [:]
            for await (id, items) in group {
                found[id] = items
            }
            return found
        }

        lastLoaded = Date()
        if failures.isEmpty {
            errorMessage = nil
        } else {
            for failure in failures {
                AppLog.shared.log("Home: couldn't load \(failure)", level: .warning)
            }
            errorMessage = failures.count == 3 ? "Couldn't load the home screen." : nil
        }
        AppLog.shared.log("Home: \(resume.count) in progress, \(nextUp.count) next up, \(libraries.count) libraries")
    }
}
