import JellyfinAPI
import SwiftUI

/// Where a tap on a card leads.
enum BrowseRoute: Hashable {
    case item(BaseItemDto)
    case library(BaseItemDto)
    /// A library showing only one genre (from the genre links on a movie or show page).
    case genre(library: BaseItemDto, genre: String)
    case collection(HomeCollection)
    /// Every library as a grid, where their order can be changed.
    case libraries

    /// The same item or library, even if its details differ between two taps.
    func isSamePage(as other: BrowseRoute) -> Bool {
        switch (self, other) {
        case (.item(let a), .item(let b)), (.library(let a), .library(let b)): return a.id == b.id
        default: return self == other
        }
    }

    var logName: String {
        switch self {
        case .item(let item): return item.name ?? "item"
        case .library(let library): return library.name ?? "library"
        case .genre(_, let genre): return genre
        case .collection(let collection): return collection.title
        case .libraries: return "Libraries"
        }
    }
}

/// A tappable card that opens a page. A button that adds to the path, because
/// `NavigationLink(value:)` opened pages twice.
struct RouteLink<Content: View>: View {
    @Environment(BrowseNavigator.self) private var navigator
    private let route: BrowseRoute
    private let label: Content

    init(_ route: BrowseRoute, @ViewBuilder label: () -> Content) {
        self.route = route
        self.label = label()
    }

    var body: some View {
        Button {
            navigator.path.append(route)
        } label: {
            label
        }
    }
}

/// The Home rows that have a "see all" page.
enum HomeCollection: String, Hashable {
    case continueWatching
    case nextUp
    case history
    case favourites
    case watchLater

    var title: String {
        switch self {
        case .continueWatching: return "Continue watching"
        case .nextUp: return "Next up"
        case .history: return "Watch history"
        case .favourites: return "Favourites"
        case .watchLater: return "Watch later"
        }
    }
}

/// Opens the right screen for an item: shows and seasons get the episode browser,
/// collections and folders get a grid, everything else gets the detail page.
struct BrowseDestination: View {
    let route: BrowseRoute
    let api: LibraryAPI

    var body: some View {
        Group {
            destination
        }
        .tabBarClearance()
    }

    @ViewBuilder
    private var destination: some View {
        switch route {
        case .library(let library):
            LibraryView(api: api, parent: library)
        case .genre(let library, let genre):
            LibraryView(api: api, parent: library, genre: genre)
        case .collection(let collection):
            CollectionView(api: api, collection: collection)
        case .libraries:
            LibrariesView(api: api)
        case .item(let item):
            switch item.type {
            case .series:
                SeriesView(api: api, seriesID: item.id ?? "", initialSeasonID: nil)
            case .season:
                SeriesView(api: api, seriesID: item.seriesID ?? "", initialSeasonID: item.id)
            case .boxSet, .folder, .collectionFolder, .userView:
                LibraryView(api: api, parent: item)
            case .person:
                PersonView(api: api, personID: item.id ?? "")
            default:
                ItemDetailView(api: api, itemID: item.id ?? "")
            }
        }
    }
}

/// The pages open in one tab. Lets "Go to show" return to a show page that is already open
/// instead of stacking another copy on top.
@MainActor
@Observable
final class BrowseNavigator {
    /// Posted (with "id" and "name") to open a show's page on the Home tab, from another tab.
    static let openSeriesNotification = Notification.Name("openSeriesOnHome")

    var path: [BrowseRoute] = [] {
        // One tap can arrive as two pushes; two copies of a page must never stack.
        didSet {
            if path.count > oldValue.count, path.count > 1, path[path.count - 1].isSamePage(as: path[path.count - 2]) {
                AppLog.shared.log("Dropped a doubled page: \(path[path.count - 1].logName)")
                path.removeLast()
            } else if path != oldValue {
                AppLog.shared.log("Open pages: \(path.isEmpty ? "none" : path.map(\.logName).joined(separator: " > "))")
            }
        }
    }

    func openSeries(id: String, name: String?) {
        if let index = path.lastIndex(where: { route in
            if case .item(let item) = route { return item.type == .series && item.id == id }
            return false
        }) {
            path.removeLast(path.count - index - 1)
            return
        }
        var series = BaseItemDto()
        series.id = id
        series.name = name
        series.type = .series
        path.append(.item(series))
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
        Group {
            if store.server == nil {
                AddServerView()
            } else if store.route == nil {
                if store.hasResolved && !store.isResolving {
                    ServerUnreachableView()
                } else {
                    ConnectingView()
                }
            } else if let client = store.client, let session = store.session, !store.isAddingAccount {
                content(LibraryAPI(client: client, userID: session.userID))
                    // A new identity per account: switching users starts the page fresh and reloads it,
                    // instead of keeping the previous user's rows until a refresh.
                    .id(session.userID)
            } else {
                LoginView()
            }
        }
        .tabBarClearance()
        .animation(.easeInOut(duration: 0.3), value: store.session?.userID)
        .animation(.easeInOut(duration: 0.3), value: store.isAddingAccount)
    }
}

struct HomeView: View {
    let api: LibraryAPI
    /// Changes when the Home tab is tapped again: scroll back to the top.
    var scrollTop = 0

    @Environment(SessionStore.self) private var store
    @State private var resume: [BaseItemDto] = []
    @State private var nextUp: [BaseItemDto] = []
    @State private var history: [BaseItemDto] = []
    @State private var recommended: [BaseItemDto] = []
    @State private var libraries: [BaseItemDto] = []
    @State private var latest: [String: [BaseItemDto]] = [:]
    @State private var errorMessage: String?
    @State private var lastLoaded: Date?
    @State private var playback: PlaybackSession?
    @State private var isStartingPlayback = false
    @State private var isLoading = false
    @AppStorage private var libraryOrder: String

    init(api: LibraryAPI, scrollTop: Int = 0) {
        self.api = api
        self.scrollTop = scrollTop
        _libraryOrder = AppStorage(wrappedValue: "", LibraryEntry.orderKey(userID: api.userID))
    }

    private var libraryEntries: [LibraryEntry] { LibraryEntry.ordered(libraries, saved: libraryOrder) }

    /// The big card at the top: the most recent thing in progress, otherwise the first Next up.
    private var heroItem: BaseItemDto? { resume.first ?? nextUp.first }
    /// Loaded, without errors, and nothing at all to show.
    private var isEmpty: Bool {
        lastLoaded != nil && libraries.isEmpty && resume.isEmpty && nextUp.isEmpty && history.isEmpty
    }
    private var continueRow: [BaseItemDto] { resume.isEmpty ? [] : Array(resume.dropFirst()) }
    private var nextUpRow: [BaseItemDto] { resume.isEmpty ? Array(nextUp.dropFirst()) : nextUp }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header
                    .id("top")
                    // Above everything below, so nothing can take the account button's taps.
                    .zIndex(1)
                if let errorMessage {
                    ErrorState(message: errorMessage) {
                        await load()
                    }
                } else if isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "film.stack",
                        description: Text("This account has no libraries, or they're hidden from it.")
                    )
                    .padding(.top, 40)
                }
                if let heroItem {
                    hero(heroItem)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                if !libraries.isEmpty {
                    libraryCards
                }
                if !continueRow.isEmpty {
                    row("Continue watching", items: continueRow, wide: true, seeAll: .continueWatching)
                }
                if !nextUpRow.isEmpty {
                    row("Next up", items: nextUpRow, wide: true, seeAll: .nextUp)
                }
                if !recommended.isEmpty {
                    row("Recommended for you", items: recommended, wide: false)
                }
                ForEach(libraryEntries.compactMap(\.serverLibrary), id: \.id) { library in
                    if let items = latest[library.id ?? ""], !items.isEmpty {
                        row("Recently added in \(library.name ?? "library")", items: items, wide: false)
                    }
                }
                if !history.isEmpty {
                    row("Watch history", items: history, wide: true, seeAll: .history)
                }
                if lastLoaded == nil && errorMessage == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 16)
        }
        .onChange(of: scrollTop) {
            withAnimation { proxy.scrollTo("top", anchor: .top) }
        }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Home")
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            // SwiftUI can cancel the refresh task while the content changes; run the load outside it.
            await Task { await load() }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            // Reload the next time Home is shown.
            lastLoaded = .distantPast
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentShouldRefresh)) { _ in
            Task { await load() }
        }
        .task {
            // Reload when coming back to Home, but not on every tab switch.
            if lastLoaded.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                await load()
            }
        }
        .fullScreenCover(item: $playback) { session in
            PlayerView(session: session)
                .environment(store)
        }
        .browseDestinations(api: api)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.route == nil ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                    Text([store.server?.name, store.route?.kind.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text("Home")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(Theme.text)
                    if isLoading && lastLoaded != nil {
                        // Shown for every reload, including automatic ones (back online, back after a while).
                        ProgressView()
                            .tint(Theme.text3)
                            .transition(.opacity)
                            .accessibilityLabel("Refreshing")
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isLoading)
            }
            Spacer()
            AccountMenu()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func hero(_ item: BaseItemDto) -> some View {
        let isEpisode = item.type == .episode
        let inProgress = item.resumeSeconds > 0
        let kicker = [inProgress ? "CONTINUE" : "UP NEXT", item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
        let title = isEpisode ? (item.seriesName ?? item.name ?? "") : (item.name ?? "")
        let detail = [isEpisode ? item.name : nil, Self.timeLeft(item)].compactMap { $0 }.joined(separator: " · ")

        return Color.clear
            .frame(height: 236 * Metrics.scale)
            .overlay {
                RemoteImage(url: api.imageURL(Artwork.backdrop(item) ?? Artwork.landscape(item), maxWidth: 1000))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kicker)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.accent)
                        Text(title)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text2)
                                .lineLimit(1)
                        }
                    }
                    if let percent = item.userData?.playedPercentage, percent > 0 {
                        ProgressBar(fraction: percent / 100)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await play(item) }
                        } label: {
                            HStack(spacing: 8) {
                                if isStartingPlayback {
                                    ProgressView().tint(Theme.onAccent)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(inProgress ? "Resume \(ItemDetailView.timeText(item.resumeSeconds))" : "Play")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(height: 44))
                        .disabled(isStartingPlayback)
                        RouteLink(.item(item)) {
                            Image(systemName: "info")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .buttonStyle(CircleButtonStyle(size: 44, fill: Color.white.opacity(0.1)))
                        .accessibilityLabel("Details")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background.opacity(0.8))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
    }

    /// Big image cards for the libraries, in a horizontal scroll so they don't take much height.
    private var libraryCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            seeAllHeader("Libraries", route: .libraries)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(libraryEntries) { entry in
                        RouteLink(entry.route) {
                            LibraryEntryCard(entry: entry, api: api)
                                .frame(width: 210 * Metrics.scale, height: 118 * Metrics.scale)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func seeAllHeader(_ title: String, route: BrowseRoute) -> some View {
        RouteLink(route) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("See all")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), see all")
    }

    private func row(_ title: String, items: [BaseItemDto], wide: Bool, seeAll: HomeCollection? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let seeAll {
                seeAllHeader(title, route: .collection(seeAll))
            } else {
                SectionTitle(text: title)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items, id: \.id) { item in
                        RouteLink(.item(item)) {
                            if wide {
                                LandscapeCard(item: item, api: api)
                                    .frame(width: 224 * Metrics.scale)
                            } else {
                                PosterCard(item: item, api: api)
                                    .frame(width: 108 * Metrics.scale)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private static func timeLeft(_ item: BaseItemDto) -> String? {
        guard let total = item.runTimeTicks, total > 0 else { return nil }
        let position = item.userData?.playbackPositionTicks ?? 0
        guard position > 0 else { return item.runtimeText }
        let minutes = max(1, (total - position) / 600_000_000)
        return "\(minutes) min left"
    }

    // MARK: - Actions

    private func play(_ item: BaseItemDto) async {
        guard let id = item.id, !isStartingPlayback else { return }
        isStartingPlayback = true
        defer { isStartingPlayback = false }
        do {
            let full = try await api.item(id)
            // No slide-up: the player appears at once and rotates to landscape straight away.
            withTransaction(\.disablesAnimations, true) {
                playback = PlaybackSession(api: api, item: full, startSeconds: full.isPlayed ? 0 : full.resumeSeconds)
            }
        } catch {
            AppLog.shared.log("Couldn't start \(item.name ?? id): \(error.localizedDescription)", level: .error)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        async let resumeRequest = api.resumeItems()
        async let nextUpRequest = api.nextUp()
        async let librariesRequest = api.videoLibraries()
        async let historyRequest = api.watchHistory()
        async let recommendedRequest = api.recommendations()

        var failures: [String] = []
        var newResume = resume
        var newNextUp = nextUp
        var newLibraries = libraries
        var newHistory = history
        var newRecommended = recommended
        do { newResume = try await resumeRequest } catch { AuthWatch.report(error); failures.append("continue watching: \(error.localizedDescription)") }
        do { newNextUp = try await nextUpRequest } catch { failures.append("next up: \(error.localizedDescription)") }
        do {
            newLibraries = try await librariesRequest
        } catch {
            failures.append("libraries: \(error.localizedDescription)")
        }
        do { newRecommended = try await recommendedRequest } catch { failures.append("recommendations: \(error.localizedDescription)") }
        do { newHistory = try await historyRequest } catch { failures.append("watch history: \(error.localizedDescription)") }

        let api = api
        let libraryIDs = newLibraries.compactMap(\.id)
        let newLatest = await withTaskGroup(of: (String, [BaseItemDto]).self) { group in
            for id in libraryIDs {
                group.addTask { (id, (try? await api.latest(in: id)) ?? []) }
            }
            var found: [String: [BaseItemDto]] = [:]
            for await (id, items) in group {
                found[id] = items
            }
            return found
        }

        // Fade the rows in together instead of popping in one by one.
        withAnimation(.easeOut(duration: 0.3)) {
            resume = newResume
            nextUp = newNextUp
            libraries = newLibraries
            history = newHistory
            recommended = newRecommended
            latest = newLatest
        }
        lastLoaded = Date()
        if failures.isEmpty {
            errorMessage = nil
        } else {
            for failure in failures {
                AppLog.shared.log("Home: couldn't load \(failure)", level: .warning)
            }
            errorMessage = failures.count == 4 ? "The server didn't answer. Check your connection and try again." : nil
        }
        AppLog.shared.log("Home: \(resume.count) in progress, \(nextUp.count) next up, \(history.count) watched, \(libraries.count) libraries")
    }
}
