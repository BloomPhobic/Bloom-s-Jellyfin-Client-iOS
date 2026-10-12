import Foundation
import JellyfinAPI

/// The requests the browse screens make, for the signed-in user on the current address.
struct LibraryAPI {
    let client: JellyfinClient
    let userID: String

    private static let listFields: [ItemFields] = [.primaryImageAspectRatio, .childCount, .recursiveItemCount]

    // MARK: - Home

    func libraries() async throws -> [BaseItemDto] {
        var parameters = Paths.GetUserViewsParameters()
        parameters.userID = userID
        return try await client.send(Paths.getUserViews(parameters: parameters)).value.items ?? []
    }

    func resumeItems(limit: Int = 20) async throws -> [BaseItemDto] {
        var parameters = Paths.GetResumeItemsParameters()
        parameters.userID = userID
        parameters.limit = limit
        parameters.fields = Self.listFields
        parameters.mediaTypes = [.video]
        parameters.enableUserData = true
        return try await client.send(Paths.getResumeItems(parameters: parameters)).value.items ?? []
    }

    func nextUp(limit: Int = 20) async throws -> [BaseItemDto] {
        var parameters = Paths.GetNextUpParameters()
        parameters.userID = userID
        parameters.limit = limit
        parameters.fields = Self.listFields
        parameters.enableUserData = true
        // Episodes already in progress are in Continue watching.
        parameters.enableResumable = false
        return try await client.send(Paths.getNextUp(parameters: parameters)).value.items ?? []
    }

    /// Movies and episodes the user finished, most recent first.
    func watchHistory() async throws -> [BaseItemDto] {
        try await watchHistory(startIndex: 0, limit: 20).items
    }

    /// One page of the watch history, with the total count.
    func watchHistory(startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int) {
        var parameters = Paths.GetItemsParameters()
        parameters.userID = userID
        parameters.isRecursive = true
        parameters.includeItemTypes = [.movie, .episode]
        parameters.filters = [.isPlayed]
        parameters.sortBy = [.datePlayed]
        parameters.sortOrder = [.descending]
        parameters.startIndex = startIndex
        parameters.limit = limit
        parameters.enableTotalRecordCount = true
        parameters.fields = Self.listFields
        parameters.enableUserData = true
        let result = try await client.send(Paths.getItems(parameters: parameters)).value
        return (result.items ?? [], result.totalRecordCount ?? 0)
    }

    /// Where to pick up a show: the episode in progress, or the next unwatched one.
    func nextUp(seriesID: String) async throws -> BaseItemDto? {
        var parameters = Paths.GetNextUpParameters()
        parameters.userID = userID
        parameters.seriesID = seriesID
        parameters.limit = 1
        parameters.enableResumable = true
        parameters.enableUserData = true
        return try await client.send(Paths.getNextUp(parameters: parameters)).value.items?.first
    }

    func latest(in libraryID: String) async throws -> [BaseItemDto] {
        var parameters = Paths.GetLatestMediaParameters()
        parameters.userID = userID
        parameters.parentID = libraryID
        parameters.limit = 16
        parameters.fields = Self.listFields
        parameters.enableUserData = true
        return try await client.send(Paths.getLatestMedia(parameters: parameters)).value
    }

    // MARK: - Libraries and search

    /// One page of a library, collection or folder. Returns the items and the total count.
    func items(in parent: BaseItemDto, query: LibraryQuery, searchTerm: String? = nil, startIndex: Int, limit: Int) async throws -> (items: [BaseItemDto], total: Int) {
        var parameters = Paths.GetItemsParameters()
        if let searchTerm, !searchTerm.isEmpty {
            parameters.searchTerm = searchTerm
        }
        parameters.userID = userID
        parameters.parentID = parent.id
        parameters.startIndex = startIndex
        parameters.limit = limit
        parameters.enableTotalRecordCount = true
        parameters.enableUserData = true
        parameters.fields = Self.listFields
        parameters.sortBy = [query.sort.field, .sortName]
        parameters.sortOrder = [query.ascending ? .ascending : .descending]
        switch parent.collectionType {
        case .movies:
            parameters.isRecursive = true
            parameters.includeItemTypes = [.movie]
        case .tvshows:
            parameters.isRecursive = true
            parameters.includeItemTypes = [.series]
        case .boxsets:
            parameters.isRecursive = true
            parameters.includeItemTypes = [.boxSet]
        default:
            // Collections, folders and mixed libraries: show what is directly inside.
            parameters.isRecursive = false
        }
        if query.unplayedOnly {
            parameters.isPlayed = false
        }
        if query.favouritesOnly {
            parameters.isFavorite = true
        }
        let result = try await client.send(Paths.getItems(parameters: parameters)).value
        return (result.items ?? [], result.totalRecordCount ?? 0)
    }

    func search(_ term: String) async throws -> [BaseItemDto] {
        var parameters = Paths.GetItemsParameters()
        parameters.userID = userID
        parameters.searchTerm = term
        parameters.isRecursive = true
        parameters.includeItemTypes = [.movie, .series, .episode]
        parameters.limit = 60
        parameters.fields = Self.listFields
        parameters.enableUserData = true
        return try await client.send(Paths.getItems(parameters: parameters)).value.items ?? []
    }

    // MARK: - Items

    func item(_ itemID: String) async throws -> BaseItemDto {
        try await client.send(Paths.getItem(itemID: itemID, userID: userID)).value
    }

    func seasons(seriesID: String) async throws -> [BaseItemDto] {
        var parameters = Paths.GetSeasonsParameters()
        parameters.userID = userID
        parameters.enableUserData = true
        return try await client.send(Paths.getSeasons(seriesID: seriesID, parameters: parameters)).value.items ?? []
    }

    func episodes(seriesID: String, seasonID: String) async throws -> [BaseItemDto] {
        var parameters = Paths.GetEpisodesParameters()
        parameters.userID = userID
        parameters.seasonID = seasonID
        parameters.fields = [.overview, .primaryImageAspectRatio]
        parameters.enableUserData = true
        return try await client.send(Paths.getEpisodes(seriesID: seriesID, parameters: parameters)).value.items ?? []
    }

    /// The episode after this one, crossing into the next season if needed.
    func nextEpisode(after episode: BaseItemDto) async throws -> BaseItemDto? {
        guard let seriesID = episode.seriesID, let id = episode.id else { return nil }
        var parameters = Paths.GetEpisodesParameters()
        parameters.userID = userID
        parameters.startItemID = id
        parameters.limit = 2
        parameters.isMissing = false
        parameters.fields = [.overview, .primaryImageAspectRatio]
        parameters.enableUserData = true
        let items = try await client.send(Paths.getEpisodes(seriesID: seriesID, parameters: parameters)).value.items ?? []
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + 1) else { return nil }
        return items[index + 1]
    }

    /// Intro, recap, preview and credits markers, if the server has them.
    func segments(itemID: String) async throws -> [MediaSegmentDto] {
        try await client.send(Paths.getItemSegments(itemID: itemID)).value.items ?? []
    }

    func setPlayed(_ played: Bool, itemID: String) async throws -> UserItemDataDto {
        let request = played
            ? Paths.markPlayedItem(itemID: itemID, userID: userID)
            : Paths.markUnplayedItem(itemID: itemID, userID: userID)
        return try await client.send(request).value
    }

    func setFavorite(_ favorite: Bool, itemID: String) async throws -> UserItemDataDto {
        let request = favorite
            ? Paths.markFavoriteItem(itemID: itemID, userID: userID)
            : Paths.unmarkFavoriteItem(itemID: itemID, userID: userID)
        return try await client.send(request).value
    }

    // MARK: - URLs

    func imageURL(_ image: ImageRef?, maxWidth: Int) -> URL? {
        guard let image else { return nil }
        var parameters = Paths.GetItemImageParameters()
        parameters.maxWidth = maxWidth
        parameters.quality = 90
        parameters.tag = image.tag
        return client.url(with: Paths.getItemImage(itemID: image.itemID, imageType: image.type.rawValue, parameters: parameters))
    }

    /// Direct-play URL for a media source (static=true, so the server never transcodes).
    func streamURL(itemID: String, mediaSourceID: String?) -> URL? {
        let request = Paths.getVideoStream(itemID: itemID, parameters: .init(isStatic: true, mediaSourceID: mediaSourceID))
        return client.url(with: request, queryAPIKey: true)
    }
}

/// Sort and filter settings for a library grid. Saved per library.
struct LibraryQuery: Codable, Hashable {
    var sort: LibrarySort = .name
    var ascending = true
    var unplayedOnly = false
    var favouritesOnly = false

    private static func key(_ libraryID: String) -> String { "library.query.\(libraryID)" }

    static func load(for libraryID: String?) -> LibraryQuery {
        guard let libraryID,
              let data = UserDefaults.standard.data(forKey: key(libraryID)),
              let query = try? JSONDecoder().decode(LibraryQuery.self, from: data) else {
            return LibraryQuery()
        }
        return query
    }

    func save(for libraryID: String?) {
        guard let libraryID, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(libraryID))
    }
}

enum LibrarySort: String, Codable, CaseIterable, Identifiable {
    case name
    case dateAdded
    case releaseDate
    case rating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date added"
        case .releaseDate: return "Release date"
        case .rating: return "Rating"
        }
    }

    var field: ItemSortBy {
        switch self {
        case .name: return .sortName
        case .dateAdded: return .dateCreated
        case .releaseDate: return .premiereDate
        case .rating: return .communityRating
        }
    }

    /// Names read A–Z; dates and ratings are most useful newest/highest first.
    var defaultAscending: Bool { self == .name }
}

/// One image of an item on the server.
struct ImageRef: Hashable {
    let itemID: String
    let type: ImageType
    let tag: String?
}

/// Picks the best image for each kind of card.
enum Artwork {
    /// Portrait poster (2:3). Seasons fall back to the show's poster. Episodes always use the show's
    /// poster, because an episode's own image is a wide still that looks wrong cropped to a poster.
    static func poster(_ item: BaseItemDto) -> ImageRef? {
        if item.type == .episode, let id = item.seriesID, let tag = item.seriesPrimaryImageTag {
            return ImageRef(itemID: id, type: .primary, tag: tag)
        }
        if let id = item.id, let tag = item.imageTags?[ImageType.primary.rawValue] {
            return ImageRef(itemID: id, type: .primary, tag: tag)
        }
        if let id = item.seriesID, let tag = item.seriesPrimaryImageTag {
            return ImageRef(itemID: id, type: .primary, tag: tag)
        }
        if let id = item.parentPrimaryImageItemID, let tag = item.parentPrimaryImageTag {
            return ImageRef(itemID: id, type: .primary, tag: tag)
        }
        return nil
    }

    /// Wide image (16:9): an episode's own still, otherwise a thumb or backdrop of the item or its show.
    static func landscape(_ item: BaseItemDto) -> ImageRef? {
        if let id = item.id {
            if item.type == .episode || item.type == .collectionFolder || item.type == .userView,
               let tag = item.imageTags?[ImageType.primary.rawValue] {
                return ImageRef(itemID: id, type: .primary, tag: tag)
            }
            if let tag = item.imageTags?[ImageType.thumb.rawValue] {
                return ImageRef(itemID: id, type: .thumb, tag: tag)
            }
            if let tag = item.backdropImageTags?.first {
                return ImageRef(itemID: id, type: .backdrop, tag: tag)
            }
        }
        if let id = item.parentThumbItemID, let tag = item.parentThumbImageTag {
            return ImageRef(itemID: id, type: .thumb, tag: tag)
        }
        return backdrop(item)
    }

    /// Large background image for detail pages.
    static func backdrop(_ item: BaseItemDto) -> ImageRef? {
        if let id = item.id, let tag = item.backdropImageTags?.first {
            return ImageRef(itemID: id, type: .backdrop, tag: tag)
        }
        if let id = item.parentBackdropItemID, let tag = item.parentBackdropImageTags?.first {
            return ImageRef(itemID: id, type: .backdrop, tag: tag)
        }
        return nil
    }
}

extension BaseItemDto {
    /// "S1:E3" for episodes.
    var episodeLabel: String? {
        guard type == .episode else { return nil }
        let season = parentIndexNumber.map { "S\($0)" } ?? ""
        let episode = indexNumber.map { "E\($0)" } ?? ""
        let label = [season, episode].filter { !$0.isEmpty }.joined(separator: ":")
        return label.isEmpty ? nil : label
    }

    var runtimeText: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        let minutes = ticks / 600_000_000
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    var resumeSeconds: Double {
        Double(userData?.playbackPositionTicks ?? 0) / 10_000_000
    }

    var isPlayed: Bool { userData?.isPlayed == true }
    var isFavorite: Bool { userData?.isFavorite == true }
}
