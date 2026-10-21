import Foundation
import JellyfinAPI
import Observation

/// One stretch of time in an item that the server has marked (intro, credits, ...).
struct PlaybackSegment: Equatable {
    let type: MediaSegmentType
    let start: Double
    let end: Double

    var skipTitle: String {
        switch type {
        case .intro: return "Skip intro"
        case .recap: return "Skip recap"
        case .preview: return "Skip preview"
        case .outro: return "Skip credits"
        case .commercial: return "Skip ad"
        default: return "Skip"
        }
    }
}

/// A chapter mark in a film or episode.
struct PlaybackChapter: Equatable {
    let index: Int
    let name: String
    let start: Double
    let imageTag: String?
}

/// Everything about what the player is playing: the current item, its server reporting,
/// skip markers, the next episode and the season's episode list. Switching episodes reuses
/// the same player, so a binge never leaves the player screen.
@MainActor
@Observable
final class PlaybackSession: Identifiable {
    let id = UUID()
    private(set) var api: LibraryAPI
    let player = MPVPlayer()

    private(set) var item: BaseItemDto
    private(set) var segments: [PlaybackSegment] = []
    private(set) var nextEpisode: BaseItemDto?
    private(set) var seasonEpisodes: [BaseItemDto] = []
    private(set) var chapters: [PlaybackChapter] = []
    /// Preview pictures for scrubbing, if the server made them for this video.
    private(set) var thumbnails: TrickplayThumbnails?
    @ObservationIgnored private var thumbnailLoader: Task<Void, Never>?
    @ObservationIgnored private let nowPlaying = NowPlaying()
    /// The user cancelled the next-episode card for the current item.
    var nextCardDismissed = false
    /// When the next-episode countdown ends; nil when no countdown is running.
    private(set) var countdownEnd: Date?

    /// The first file, which the video view starts once it has a size.
    let initialURL: URL
    let initialStart: Double

    @ObservationIgnored private var reporter: PlaybackReporter?
    /// The file being played, for reopening after an error.
    @ObservationIgnored private var currentURL: URL
    /// The last position where playback was running normally.
    @ObservationIgnored private var lastGoodPosition: Double = 0
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var retryFromPosition: Double = 0
    /// Reopening the stream after an error; the player shows "Reconnecting…".
    private(set) var isRecovering = false

    static let maxRetries = 3
    @ObservationIgnored private var mediaSourceID: String?
    @ObservationIgnored private var isSwitching = false

    static let nextCardLead: Double = 30
    static let countdownSeconds: Double = 10

    /// Playing downloads with no connection: nothing is asked of the server, and progress is kept
    /// on the phone until it can be sent.
    let isOffline: Bool
    /// The current item plays from a downloaded file.
    private(set) var isPlayingDownload = false

    /// Returns nil if the item has no playable source.
    init?(api: LibraryAPI, item: BaseItemDto, mediaSource: MediaSourceInfo? = nil, startSeconds: Double, offline: Bool = false) {
        guard let itemID = item.id,
              let source = mediaSource ?? item.mediaSources?.first,
              let url = Self.playableURL(api: api, itemID: itemID, mediaSourceID: source.id) else {
            return nil
        }
        self.api = api
        self.item = item
        isOffline = offline
        initialURL = url
        initialStart = startSeconds
        currentURL = url
        isPlayingDownload = url.isFileURL
        lastGoodPosition = startSeconds
        mediaSourceID = source.id
        reporter = offline ? nil : PlaybackReporter(client: api.client, itemID: itemID, mediaSourceID: source.id)
        Self.logPlay(item: item, source: source, startSeconds: startSeconds, local: url.isFileURL)
        player.externalSubtitles = externalSubtitles(for: item, source: source)
    }

    /// Subtitle files beside the video: the copies saved with a download, otherwise the server's.
    private func externalSubtitles(for item: BaseItemDto, source: MediaSourceInfo?) -> [ExternalSubtitle] {
        guard let itemID = item.id else { return [] }
        if isPlayingDownload {
            let saved = DownloadStore.shared.externalSubtitles(itemID)
            if !saved.isEmpty || isOffline {
                return saved
            }
        }
        return api.externalSubtitles(itemID: itemID, source: source)
    }

    /// The downloaded file if there is one (no data used, works offline), otherwise the stream.
    private static func playableURL(api: LibraryAPI, itemID: String, mediaSourceID: String?) -> URL? {
        DownloadStore.shared.fileURL(itemID: itemID, mediaSourceID: mediaSourceID)
            ?? api.streamURL(itemID: itemID, mediaSourceID: mediaSourceID)
    }

    /// A wide image of an item: the downloaded copy when there is one.
    func stillURL(_ item: BaseItemDto) -> URL? {
        DownloadStore.shared.stillURL(item.id) ?? api.imageURL(Artwork.landscape(item), maxWidth: 400)
    }

    var title: String {
        if item.type == .episode {
            return [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.name ?? ""
    }

    var isEpisode: Bool { item.type == .episode }

    /// Player title: the show for episodes, otherwise the item.
    var headline: String {
        isEpisode ? (item.seriesName ?? item.name ?? "") : (item.name ?? "")
    }

    /// "S3:E2 · Episode name" for episodes, the year for movies.
    var subheadline: String? {
        if isEpisode {
            let text = [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
            return text.isEmpty ? nil : text
        }
        return item.productionYear.map { String($0) }
    }

    // MARK: - Loading

    /// Loads the skip markers, the next episode and the season list for the current item.
    func loadExtras() async {
        guard let itemID = item.id else { return }
        await loadChapters()
        guard item.id == itemID else { return }
        if isOffline {
            loadOfflineExtras()
            return
        }
        do {
            let found = try await api.segments(itemID: itemID)
            segments = found.compactMap { segment -> PlaybackSegment? in
                guard let type = segment.type, let start = segment.startTicks, let end = segment.endTicks, end > start else { return nil }
                return PlaybackSegment(type: type, start: Double(start) / 10_000_000, end: Double(end) / 10_000_000)
            }
            .sorted { $0.start < $1.start }
        } catch {
            segments = []
            AppLog.shared.log("No skip markers: \(error.localizedDescription)", level: .warning)
        }
        do {
            if isEpisode {
                nextEpisode = try await api.nextEpisode(after: item)
            } else {
                nextEpisode = nil
            }
        } catch {
            nextEpisode = nil
            AppLog.shared.log("Couldn't find the next episode: \(error.localizedDescription)", level: .warning)
        }
        let names = segments.map { "\($0.type.rawValue) \(Int($0.start))–\(Int($0.end))s" }
        AppLog.shared.log("Markers: \(names.isEmpty ? "none" : names.joined(separator: ", ")); next: \(nextEpisode?.episodeLabel ?? "none")")
        await loadSeason()
    }

    /// Without a connection: skip markers saved with the download, and the show's other downloaded
    /// episodes for Next and the episode list.
    private func loadOfflineExtras() {
        let downloads = DownloadStore.shared
        let record = downloads.record(item.id)
        segments = (record?.segments ?? []).compactMap { segment -> PlaybackSegment? in
            guard let type = segment.type, let start = segment.startTicks, let end = segment.endTicks, end > start else { return nil }
            return PlaybackSegment(type: type, start: Double(start) / 10_000_000, end: Double(end) / 10_000_000)
        }
        .sorted { $0.start < $1.start }
        nextEpisode = isEpisode ? downloads.nextEpisode(after: item, userID: record?.userID) : nil
        seasonEpisodes = isEpisode ? downloads.episodes(seriesID: item.seriesID, userID: record?.userID).map(\.item) : []
        AppLog.shared.log("Offline: \(segments.count) marker(s); next: \(nextEpisode?.episodeLabel ?? "none")")
    }

    func loadSeason(_ seasonID: String? = nil) async {
        if isOffline {
            loadOfflineExtras()
            return
        }
        guard isEpisode, let seriesID = item.seriesID, let seasonID = seasonID ?? item.seasonID else { return }
        if let episodes = try? await api.episodes(seriesID: seriesID, seasonID: seasonID) {
            seasonEpisodes = episodes
        }
    }

    /// Chapters come with the item (also for downloads). Preview pictures need the server.
    private func loadChapters() async {
        thumbnailLoader?.cancel()
        var details = item
        if !isOffline, let itemID = item.id {
            do {
                if let fetched = try await api.playbackDetails(itemID) {
                    details.chapters = fetched.chapters ?? item.chapters
                    details.trickplay = fetched.trickplay ?? item.trickplay
                }
            } catch {
                AppLog.shared.log("Couldn't load chapters and previews: \(error.localizedDescription)", level: .warning)
            }
            guard item.id == itemID else { return }
        }
        let manifest = details.trickplay ?? [:]
        let sizes = manifest.map { key, value in "\(key): \(value.keys.sorted().joined(separator: "/"))" }
        AppLog.shared.log("Preview pictures on server: \(sizes.isEmpty ? "none" : sizes.joined(separator: ", ")) (playing source \(mediaSourceID ?? "?"))")
        chapters = (details.chapters ?? []).enumerated().compactMap { index, chapter in
            guard let ticks = chapter.startPositionTicks else { return nil }
            let name = chapter.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)"
            return PlaybackChapter(index: index, name: name, start: Double(ticks) / 10_000_000, imageTag: chapter.imageTag)
        }
        .sorted { $0.start < $1.start }
        thumbnails = isOffline ? nil : TrickplayThumbnails(item: details, mediaSourceID: mediaSourceID, client: api.client)
        if let thumbnails {
            thumbnailLoader = Task { await thumbnails.preload() }
        }
        AppLog.shared.log("Chapters: \(chapters.count); preview thumbnails: \(thumbnails == nil ? "none" : "yes")")
    }

    /// The chapter playing at a moment in the video.
    func chapter(at seconds: Double) -> PlaybackChapter? {
        chapters.last { $0.start <= seconds + 0.5 }
    }

    /// A chapter's picture from the server, if it has made one.
    func chapterImageURL(_ chapter: PlaybackChapter) -> URL? {
        guard !isOffline, let tag = chapter.imageTag, let itemID = item.id else { return nil }
        var parameters = Paths.GetItemImageByIndexParameters()
        parameters.maxWidth = 400
        parameters.tag = tag
        return api.client.url(with: Paths.getItemImageByIndex(itemID: itemID, imageType: "Chapter", imageIndex: chapter.index, parameters: parameters))
    }

    // MARK: - Playback

    /// Called by the player screen when it opens.
    func begin() {
        nowPlaying.start(self)
    }

    /// Called every half second by the player screen.
    func tick() {
        nowPlaying.update()
        if player.errorMessage != nil {
            recoverIfPossible()
            return
        }
        guard player.duration > 0, !player.isBuffering else { return }
        reporter?.update(position: player.position, isPaused: player.isPaused)
        if let itemID = item.id {
            DownloadStore.shared.noteProgress(itemID: itemID, position: player.position, duration: player.duration, synced: !isOffline)
        }
        lastGoodPosition = player.position
        // Playing fine for a while after a retry: allow fresh retries for the next problem.
        if retryCount > 0, player.position > retryFromPosition + 30 {
            retryCount = 0
        }

        // Start, keep or reset the next-episode countdown.
        if showsNextCard {
            if countdownEnd == nil, PlayerSettings.autoplayNext {
                countdownEnd = Date().addingTimeInterval(Self.countdownSeconds)
            }
            if let end = countdownEnd, Date() >= end {
                countdownEnd = nil
                if let next = nextEpisode {
                    Task { await play(next, resume: false) }
                }
            }
        } else if countdownEnd != nil {
            countdownEnd = nil
        }
    }

    /// The skip button to show now, if any. Credits on an episode with a next one show the card instead.
    var activeSegment: PlaybackSegment? {
        let position = player.position
        guard let segment = segments.first(where: { position >= $0.start && position < $0.end - 1 }) else { return nil }
        if segment.type == .outro, nextEpisode != nil {
            return nil
        }
        return segment
    }

    var showsNextCard: Bool {
        guard nextEpisode != nil, !nextCardDismissed, player.duration > 0 else { return false }
        if player.isAtEnd {
            return true
        }
        let position = player.position
        if let outro = segments.first(where: { $0.type == .outro }) {
            return position >= outro.start
        }
        return player.duration > Self.nextCardLead * 4 && position >= player.duration - Self.nextCardLead
    }

    // MARK: - Errors

    /// The error panel shows once automatic retries are used up.
    var showsError: Bool {
        player.errorMessage != nil && !isRecovering && retryCount >= Self.maxRetries
    }

    /// A stream that dropped (network blip, server restart) usually plays again when reopened at
    /// the same spot, so try that a few times before showing an error.
    private func recoverIfPossible() {
        guard !isRecovering, retryCount < Self.maxRetries else { return }
        retryCount += 1
        isRecovering = true
        retryFromPosition = lastGoodPosition
        let attempt = retryCount
        AppLog.shared.log("Playback error (\(player.errorMessage ?? "?")); reopening at \(ItemDetailView.timeText(lastGoodPosition)), attempt \(attempt) of \(Self.maxRetries)", level: .warning)
        Task {
            try? await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            player.load(url: currentURL, startSeconds: lastGoodPosition)
            isRecovering = false
        }
    }

    /// The Retry button on the error panel.
    func retryNow() {
        retryCount = 0
        AppLog.shared.log("Retrying at \(ItemDetailView.timeText(lastGoodPosition))")
        player.load(url: currentURL, startSeconds: lastGoodPosition)
    }

    /// Text for "Copy details": what was playing, the error, and the recent log.
    func errorReport() -> String {
        let recent = AppLog.shared.exportText.split(separator: "\n").suffix(60).joined(separator: "\n")
        return "\(title)\nError: \(player.errorMessage ?? "none")\n\n\(recent)"
    }

    func skip(_ segment: PlaybackSegment) {
        AppLog.shared.log("\(segment.skipTitle) → \(Int(segment.end))s")
        player.seek(to: segment.end)
    }

    func cancelNextCard() {
        nextCardDismissed = true
        countdownEnd = nil
    }

    /// Switches the player to another episode. `resume` starts at its saved position.
    func play(_ episode: BaseItemDto, resume: Bool) async {
        guard !isSwitching, let episodeID = episode.id else { return }
        isSwitching = true
        defer { isSwitching = false }
        countdownEnd = nil

        let full: BaseItemDto
        if isOffline, let record = DownloadStore.shared.record(episodeID) {
            full = record.item
        } else {
            do {
                full = try await api.item(episodeID)
            } catch {
                AppLog.shared.log("Couldn't open \(episode.name ?? episodeID): \(error.localizedDescription)", level: .error)
                return
            }
        }
        guard let source = full.mediaSources?.first,
              let url = Self.playableURL(api: api, itemID: episodeID, mediaSourceID: source.id) else {
            AppLog.shared.log("No playable file for \(full.name ?? episodeID)", level: .error)
            return
        }

        reporter?.stop()
        saveDownloadProgress()
        var start = resume && !full.isPlayed ? full.resumeSeconds : 0
        if resume, let record = DownloadStore.shared.record(episodeID), record.state == .done {
            start = record.resumeSeconds
        }
        Self.logPlay(item: full, source: source, startSeconds: start, local: url.isFileURL)
        item = full
        mediaSourceID = source.id
        segments = []
        chapters = []
        thumbnails = nil
        nextEpisode = nil
        nextCardDismissed = false
        reporter = isOffline ? nil : PlaybackReporter(client: api.client, itemID: episodeID, mediaSourceID: source.id)
        currentURL = url
        isPlayingDownload = url.isFileURL
        lastGoodPosition = start
        retryCount = 0
        player.externalSubtitles = externalSubtitles(for: full, source: source)
        player.load(url: url, startSeconds: start)
        await loadExtras()
    }

    /// The app switched to another server address (for example Tailscale dropped): reopen the stream
    /// from the new address at the same position.
    func handoff(to newAPI: LibraryAPI) {
        guard !isOffline, newAPI.client.configuration.url != api.client.configuration.url, let itemID = item.id else { return }
        api = newAPI
        if isPlayingDownload {
            // The file is on the phone; only the progress reports need the new address.
            reporter = PlaybackReporter(client: newAPI.client, itemID: itemID, mediaSourceID: mediaSourceID)
            return
        }
        guard let url = newAPI.streamURL(itemID: itemID, mediaSourceID: mediaSourceID) else { return }
        let position = player.position
        AppLog.shared.log("Address changed during playback; reopening from \(newAPI.client.configuration.url.absoluteString) at \(ItemDetailView.timeText(position))")
        // The old address may be gone, so start reporting through the new one.
        reporter = PlaybackReporter(client: newAPI.client, itemID: itemID, mediaSourceID: mediaSourceID)
        currentURL = url
        retryCount = 0
        player.externalSubtitles = externalSubtitles(for: item, source: item.mediaSources?.first { $0.id == mediaSourceID })
        player.load(url: url, startSeconds: position)
    }

    func close() {
        thumbnailLoader?.cancel()
        nowPlaying.stop()
        reporter?.stop()
        saveDownloadProgress()
        player.stop()
    }

    /// The final position on a downloaded file, so it's there next time even without a connection.
    private func saveDownloadProgress() {
        guard let itemID = item.id, player.duration > 0 else { return }
        DownloadStore.shared.noteProgress(itemID: itemID, position: player.position, duration: player.duration, synced: !isOffline, force: true)
    }

    private static func logPlay(item: BaseItemDto, source: MediaSourceInfo, startSeconds: Double, local: Bool) {
        let log = AppLog.shared
        let title = [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        log.log("Play: \(title) [\(local ? "downloaded file" : source.name ?? "source")]" + (startSeconds > 0 ? " from \(ItemDetailView.timeText(startSeconds))" : ""))
        for line in MediaSummary.lines(for: source) {
            log.log("  \(line)")
        }
        log.log("  Options: HDR passthrough \(PlayerSettings.hdrPassthrough ? "on" : "off"), hardware decoding \(PlayerSettings.hardwareDecoding ? "on" : "off")")
    }
}
