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
    /// The user cancelled the next-episode card for the current item.
    var nextCardDismissed = false
    /// When the next-episode countdown ends; nil when no countdown is running.
    private(set) var countdownEnd: Date?

    /// The first file, which the video view starts once it has a size.
    let initialURL: URL
    let initialStart: Double

    @ObservationIgnored private var reporter: PlaybackReporter?
    @ObservationIgnored private var mediaSourceID: String?
    @ObservationIgnored private var isSwitching = false

    static let nextCardLead: Double = 30
    static let countdownSeconds: Double = 10

    /// Returns nil if the item has no playable source.
    init?(api: LibraryAPI, item: BaseItemDto, mediaSource: MediaSourceInfo? = nil, startSeconds: Double) {
        guard let itemID = item.id,
              let source = mediaSource ?? item.mediaSources?.first,
              let url = api.streamURL(itemID: itemID, mediaSourceID: source.id) else {
            return nil
        }
        self.api = api
        self.item = item
        initialURL = url
        initialStart = startSeconds
        mediaSourceID = source.id
        reporter = PlaybackReporter(client: api.client, itemID: itemID, mediaSourceID: source.id)
        Self.logPlay(item: item, source: source, startSeconds: startSeconds)
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

    func loadSeason(_ seasonID: String? = nil) async {
        guard isEpisode, let seriesID = item.seriesID, let seasonID = seasonID ?? item.seasonID else { return }
        if let episodes = try? await api.episodes(seriesID: seriesID, seasonID: seasonID) {
            seasonEpisodes = episodes
        }
    }

    // MARK: - Playback

    /// Called every half second by the player screen.
    func tick() {
        guard player.duration > 0, !player.isBuffering else { return }
        reporter?.update(position: player.position, isPaused: player.isPaused)

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
        do {
            full = try await api.item(episodeID)
        } catch {
            AppLog.shared.log("Couldn't open \(episode.name ?? episodeID): \(error.localizedDescription)", level: .error)
            return
        }
        guard let source = full.mediaSources?.first,
              let url = api.streamURL(itemID: episodeID, mediaSourceID: source.id) else {
            AppLog.shared.log("No playable file for \(full.name ?? episodeID)", level: .error)
            return
        }

        reporter?.stop()
        let start = resume && !full.isPlayed ? full.resumeSeconds : 0
        Self.logPlay(item: full, source: source, startSeconds: start)
        item = full
        mediaSourceID = source.id
        segments = []
        nextEpisode = nil
        nextCardDismissed = false
        reporter = PlaybackReporter(client: api.client, itemID: episodeID, mediaSourceID: source.id)
        player.load(url: url, startSeconds: start)
        await loadExtras()
    }

    /// The app switched to another server address (for example Tailscale dropped): reopen the stream
    /// from the new address at the same position.
    func handoff(to newAPI: LibraryAPI) {
        guard newAPI.client.configuration.url != api.client.configuration.url, let itemID = item.id else { return }
        api = newAPI
        guard let url = newAPI.streamURL(itemID: itemID, mediaSourceID: mediaSourceID) else { return }
        let position = player.position
        AppLog.shared.log("Address changed during playback; reopening from \(newAPI.client.configuration.url.absoluteString) at \(ItemDetailView.timeText(position))")
        // The old address may be gone, so start reporting through the new one.
        reporter = PlaybackReporter(client: newAPI.client, itemID: itemID, mediaSourceID: mediaSourceID)
        player.load(url: url, startSeconds: position)
    }

    func close() {
        reporter?.stop()
        player.stop()
    }

    private static func logPlay(item: BaseItemDto, source: MediaSourceInfo, startSeconds: Double) {
        let log = AppLog.shared
        let title = [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        log.log("Play: \(title) [\(source.name ?? "source")]" + (startSeconds > 0 ? " from \(ItemDetailView.timeText(startSeconds))" : ""))
        for line in MediaSummary.lines(for: source) {
            log.log("  \(line)")
        }
        log.log("  Options: HDR passthrough \(PlayerSettings.hdrPassthrough ? "on" : "off"), hardware decoding \(PlayerSettings.hardwareDecoding ? "on" : "off")")
    }
}
