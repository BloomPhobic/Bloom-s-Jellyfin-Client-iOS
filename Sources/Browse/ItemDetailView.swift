import JellyfinAPI
import SwiftUI

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var startSeconds: Double = 0
    /// Sends progress to the server; nil for test playback.
    var reporter: PlaybackReporter?
}

/// A movie, episode or video: artwork, details, Play/Resume, and watched and favourite toggles.
struct ItemDetailView: View {
    let api: LibraryAPI
    let itemID: String

    @Environment(BrowseNavigator.self) private var navigator
    @State private var item: BaseItemDto?
    @State private var errorMessage: String?
    @State private var playback: PlaybackRequest?

    var body: some View {
        List {
            if let item {
                Section {
                    DetailHeader(item: item, api: api)
                    playButtons(item)
                    if let binding = Binding($item) {
                        UserDataButtons(api: api, item: binding)
                    }
                    if let overview = item.overview, !overview.isEmpty {
                        ExpandableText(text: overview)
                    }
                    if let genres = item.genres, !genres.isEmpty {
                        Text(genres.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)

                if item.type == .episode, let seriesID = item.seriesID {
                    Section {
                        Button {
                            navigator.openSeries(id: seriesID, name: item.seriesName)
                        } label: {
                            Label("Go to \(item.seriesName ?? "show")", systemImage: "tv")
                        }
                    }
                }

                let sources = item.mediaSources ?? []
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    Section {
                        DisclosureGroup("Technical details") {
                            ForEach(Array(MediaSummary.lines(for: source).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if sources.count > 1 {
                            Button {
                                play(item: item, source: source, from: 0)
                            } label: {
                                Label("Play this version", systemImage: "play")
                            }
                        }
                    } header: {
                        Text(source.name ?? "Media source")
                    }
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if item == nil && errorMessage == nil {
                ProgressView()
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            // Show the new resume position and watched state.
            Task { await reload() }
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request)
        }
    }

    @ViewBuilder
    private func playButtons(_ item: BaseItemDto) -> some View {
        if let source = item.mediaSources?.first {
            let resume = item.resumeSeconds
            HStack {
                Button {
                    play(item: item, source: source, from: resume)
                } label: {
                    // An explicit HStack: inside a list, Label hides its icon but keeps its space, which pushed the text off-centre.
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(resume > 0 ? "Resume \(Self.timeText(resume))" : "Play")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if resume > 0 {
                    Button {
                        play(item: item, source: source, from: 0)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "backward.end.fill")
                            Text("From start")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        } else {
            Text("No playable file.")
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        if let fresh = try? await api.item(itemID) {
            item = fresh
        }
    }

    private func load() async {
        guard item == nil else { return }
        do {
            item = try await api.item(itemID)
        } catch {
            errorMessage = "Could not load item: \(error.localizedDescription)"
            AppLog.shared.log(errorMessage ?? "", level: .error)
        }
    }

    private func play(item: BaseItemDto, source: MediaSourceInfo, from startSeconds: Double) {
        guard let url = api.streamURL(itemID: itemID, mediaSourceID: source.id) else {
            errorMessage = "Could not build the stream URL."
            return
        }
        let log = AppLog.shared
        let title = [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        log.log("Play: \(title) [\(source.name ?? "source")]" + (startSeconds > 0 ? " from \(Self.timeText(startSeconds))" : ""))
        for line in MediaSummary.lines(for: source) {
            log.log("  \(line)")
        }
        log.log("  Options: HDR passthrough \(PlayerSettings.hdrPassthrough ? "on" : "off"), hardware decoding \(PlayerSettings.hardwareDecoding ? "on" : "off")")
        playback = PlaybackRequest(
            url: url,
            title: item.name ?? "",
            startSeconds: startSeconds,
            reporter: PlaybackReporter(client: api.client, itemID: itemID, mediaSourceID: source.id)
        )
    }

    static func timeText(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Backdrop, poster, title and the one-line facts (year, runtime, rating).
struct DetailHeader: View {
    let item: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let backdrop = Artwork.backdrop(item) {
                ArtworkFrame(url: api.imageURL(backdrop, maxWidth: 1200), aspectRatio: 16 / 9)
            } else if item.type == .episode {
                ArtworkFrame(url: api.imageURL(Artwork.landscape(item), maxWidth: 1200), aspectRatio: 16 / 9)
            }
            HStack(alignment: .top, spacing: 12) {
                if item.type != .episode {
                    ArtworkFrame(url: api.imageURL(Artwork.poster(item), maxWidth: 300), aspectRatio: 2 / 3)
                        .frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if item.type == .episode, let seriesName = item.seriesName {
                        Text([seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.name ?? "")
                        .font(.title2.bold())
                    if !facts.isEmpty {
                        Text(facts)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = item.productionYear {
            if item.type == .series, let end = item.endDate.map({ Calendar.current.component(.year, from: $0) }), end != year {
                parts.append("\(year)–\(end)")
            } else {
                parts.append(String(year))
            }
        }
        if let runtime = item.runtimeText, item.type != .series {
            parts.append(runtime)
        }
        if let rating = item.officialRating {
            parts.append(rating)
        }
        if let score = item.communityRating {
            parts.append(String(format: "★ %.1f", score))
        }
        return parts.joined(separator: " · ")
    }
}

/// Watched and favourite toggles. Updates the item with what the server returns.
struct UserDataButtons: View {
    let api: LibraryAPI
    @Binding var item: BaseItemDto
    var onChange: (() -> Void)?

    @State private var isUpdating = false

    var body: some View {
        // Two equal halves, so the buttons keep their size when the text changes.
        HStack(spacing: 12) {
            Button {
                Task { await update(played: !item.isPlayed) }
            } label: {
                toggleLabel(item.isPlayed ? "Watched" : "Mark watched",
                            systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
            }
            Button {
                Task { await update(favorite: !item.isFavorite) }
            } label: {
                toggleLabel(item.isFavorite ? "Favourite" : "Add to favourites",
                            systemImage: item.isFavorite ? "heart.fill" : "heart")
            }
        }
        .buttonStyle(.bordered)
        .disabled(isUpdating)
    }

    private func toggleLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }

    private func update(played: Bool? = nil, favorite: Bool? = nil) async {
        guard let id = item.id else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if let played {
                item.userData = try await api.setPlayed(played, itemID: id)
                AppLog.shared.log("Marked \(item.name ?? id) as \(played ? "watched" : "unwatched")")
            }
            if let favorite {
                item.userData = try await api.setFavorite(favorite, itemID: id)
                AppLog.shared.log("\(favorite ? "Added" : "Removed") \(item.name ?? id) \(favorite ? "to" : "from") favourites")
            }
            onChange?()
        } catch {
            AppLog.shared.log("Couldn't update \(item.name ?? id): \(error.localizedDescription)", level: .error)
        }
    }
}

/// Text that shows a few lines, with "More" to expand.
struct ExpandableText: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 4)
            if text.count > 200 {
                Button(isExpanded ? "Less" : "More") {
                    withAnimation { isExpanded.toggle() }
                }
                .font(.callout.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// Human-readable lines describing a media source, used on screen and in the log.
enum MediaSummary {
    static func lines(for source: MediaSourceInfo) -> [String] {
        var lines: [String] = []
        var header = "Container: \(source.container ?? "?")"
        if let bitrate = source.bitrate {
            header += ", \(bitrate / 1_000_000) Mbps"
        }
        if let size = source.size {
            header += ", " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        lines.append(header)

        for stream in source.mediaStreams ?? [] {
            guard let type = stream.type else { continue }
            switch type {
            case .video:
                lines.append("Video: " + videoDescription(stream))
            case .audio:
                lines.append("Audio: " + (stream.displayTitle ?? stream.codec ?? "?") + defaultMarker(stream))
            case .subtitle:
                let external = stream.isExternal == true ? " [external]" : ""
                lines.append("Sub: " + (stream.displayTitle ?? stream.codec ?? "?") + " (\(stream.codec ?? "?"))" + external + defaultMarker(stream))
            default:
                break
            }
        }
        return lines
    }

    private static func videoDescription(_ stream: MediaStream) -> String {
        var parts: [String] = []
        parts.append([stream.codec?.uppercased(), stream.profile].compactMap { $0 }.joined(separator: " "))
        if let width = stream.width, let height = stream.height {
            parts.append("\(width)x\(height)")
        }
        if let bitDepth = stream.bitDepth {
            parts.append("\(bitDepth)-bit")
        }
        if let range = stream.videoRangeType {
            parts.append(range.rawValue)
        }
        if let dvProfile = stream.dvProfile {
            parts.append("DV profile \(dvProfile)")
        }
        if let fps = stream.realFrameRate ?? stream.averageFrameRate {
            parts.append(String(format: "%.3f fps", Double(fps)))
        }
        return parts.joined(separator: ", ")
    }

    private static func defaultMarker(_ stream: MediaStream) -> String {
        stream.isDefault == true ? " [default]" : ""
    }
}
