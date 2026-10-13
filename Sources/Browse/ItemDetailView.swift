import JellyfinAPI
import SwiftUI

/// A movie, episode or video: full-bleed backdrop, poster, facts, Resume/Play, and tiles for
/// Restart, Watched and Favourite.
struct ItemDetailView: View {
    let api: LibraryAPI
    let itemID: String

    @Environment(BrowseNavigator.self) private var navigator
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var item: BaseItemDto?
    @State private var errorMessage: String?
    @State private var playback: PlaybackSession?
    @State private var showFileDetails = false

    var body: some View {
        ScrollView {
            if let item {
                content(item)
                    .transition(.opacity)
            } else if let errorMessage {
                ErrorState(message: errorMessage) {
                    self.errorMessage = nil
                    await load()
                }
                .padding(.top, 120)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .overlay {
            if item == nil && errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle(item?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle(size: 36))
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .principal) {
                // The title is on the page itself.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            // Show the new resume position and watched state.
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contentShouldRefresh)) { _ in
            Task {
                if item == nil {
                    errorMessage = nil
                    await load()
                } else {
                    await reload()
                }
            }
        }
        .fullScreenCover(item: $playback) { session in
            PlayerView(session: session)
                .environment(store)
        }
    }

    @ViewBuilder
    private func content(_ item: BaseItemDto) -> some View {
        let isEpisode = item.type == .episode
        VStack(alignment: .leading, spacing: 0) {
            BackdropHeader(url: api.imageURL(Artwork.backdrop(item) ?? Artwork.landscape(item), maxWidth: 1200), height: 300)

            HStack(alignment: .bottom, spacing: 14) {
                if !isEpisode {
                    ArtworkFrame(url: api.imageURL(Artwork.poster(item), maxWidth: 300), aspectRatio: 2 / 3)
                        .frame(width: 108)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if isEpisode {
                        Text([item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(item.name ?? "")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    FactsRow(item: item)
                }
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, isEpisode ? -36 : -72)

            VStack(alignment: .leading, spacing: 14) {
                playSection(item)

                if let overview = item.overview, !overview.isEmpty {
                    ExpandableText(text: overview)
                        .padding(.top, 4)
                }

                if let genres = item.genres, !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(genres, id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.text2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.raised))
                            }
                        }
                    }
                }

                if isEpisode, let seriesID = item.seriesID {
                    Button {
                        navigator.openSeries(id: seriesID, name: item.seriesName)
                    } label: {
                        RowLabel(title: "Go to \(item.seriesName ?? "show")", subtitle: nil, systemImage: "tv")
                    }
                    .buttonStyle(PressableStyle())
                }

                fileDetails(item)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func playSection(_ item: BaseItemDto) -> some View {
        if let source = item.mediaSources?.first {
            let resume = item.isPlayed ? 0 : item.resumeSeconds
            Button {
                play(item: item, source: source, from: resume)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                    Text(resume > 0 ? "Resume from \(Self.timeText(resume))" : "Play")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 52))

            if resume > 0, let percent = item.userData?.playedPercentage {
                HStack(spacing: 10) {
                    ProgressBar(fraction: percent / 100)
                    if let left = Self.minutesLeft(item) {
                        Text(left)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                }
            }

            HStack(spacing: 10) {
                if resume > 0 {
                    Button {
                        play(item: item, source: source, from: 0)
                    } label: {
                        TileLabel(title: "Restart", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(TileButtonStyle())
                }
                if let binding = Binding($item) {
                    UserDataTiles(api: api, item: binding)
                }
                if store.canDownload || DownloadStore.shared.record(item.id) != nil {
                    DownloadTile(api: api, item: item)
                }
            }
        } else {
            Text("No playable file.")
                .foregroundStyle(Theme.text3)
        }
    }

    @ViewBuilder
    private func fileDetails(_ item: BaseItemDto) -> some View {
        let sources = item.mediaSources ?? []
        if let first = sources.first {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showFileDetails.toggle() }
                } label: {
                    RowLabel(
                        title: "File details",
                        subtitle: MediaSummary.short(for: first),
                        systemImage: nil,
                        trailing: showFileDetails ? "chevron.up" : "chevron.down"
                    )
                }
                .buttonStyle(.plain)

                if showFileDetails {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                            VStack(alignment: .leading, spacing: 4) {
                                if sources.count > 1 {
                                    Text(source.name ?? "Version")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                }
                                ForEach(Array(MediaSummary.lines(for: source).enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.text2)
                                        .textSelection(.enabled)
                                }
                                if sources.count > 1 {
                                    Button("Play this version") {
                                        play(item: item, source: source, from: 0)
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.top, 2)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func reload() async {
        if let fresh = try? await api.item(itemID) {
            withAnimation(.easeInOut(duration: 0.2)) { item = fresh }
        }
    }

    private func load() async {
        guard item == nil else { return }
        do {
            let loaded = try await api.item(itemID)
            withAnimation(.easeOut(duration: 0.25)) { item = loaded }
        } catch {
            guard !AuthWatch.isCancellation(error) else { return }
            AuthWatch.report(error)
            errorMessage = error.localizedDescription
            AppLog.shared.log("Could not load item: \(error.localizedDescription)", level: .error)
        }
    }

    private func play(item: BaseItemDto, source: MediaSourceInfo, from startSeconds: Double) {
        guard let session = PlaybackSession(api: api, item: item, mediaSource: source, startSeconds: startSeconds) else {
            errorMessage = "Could not build the stream URL."
            return
        }
        // No slide-up: the player appears at once and rotates to landscape straight away.
        withTransaction(\.disablesAnimations, true) {
            playback = session
        }
    }

    static func minutesLeft(_ item: BaseItemDto) -> String? {
        guard let total = item.runTimeTicks, total > 0 else { return nil }
        let position = item.userData?.playbackPositionTicks ?? 0
        let minutes = max(1, (total - position) / 600_000_000)
        return "\(minutes) min left"
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

/// Full-width image at the top of a detail page. It drifts slower than the page when scrolling
/// and stretches when pulled down, and fades into the background at the bottom.
struct BackdropHeader: View {
    let url: URL?
    let height: CGFloat

    var body: some View {
        let height = height
        return Color.clear
            .frame(height: height)
            .overlay {
                RemoteImage(url: url)
                    .visualEffect { content, proxy in
                        let offset = proxy.frame(in: .scrollView).minY
                        return content
                            .scaleEffect(offset > 0 ? 1 + offset / height : 1, anchor: .bottom)
                            .offset(y: offset > 0 ? 0 : -offset * 0.35)
                    }
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
            }
            .clipped()
    }
}

/// "2011 · 1h 58m · [12A] · ★ 5.6"
struct FactsRow: View {
    let item: BaseItemDto

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·")
                }
                Text(part)
            }
            if let rating = item.officialRating {
                if !parts.isEmpty {
                    Text("·")
                }
                Text(rating)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            }
            if let score = item.communityRating {
                Text(String(format: "· ★ %.1f", score))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Theme.text2)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var parts: [String] {
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
        return parts
    }
}

/// Icon over a short label, for tile buttons.
struct TileLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// A full-width row: optional icon, title, optional subtitle, trailing chevron.
struct RowLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    var trailing = "chevron.right"

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: trailing)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// Watched and Favourite tiles. Updates the item with what the server returns.
struct UserDataTiles: View {
    let api: LibraryAPI
    @Binding var item: BaseItemDto
    var onChange: (() -> Void)?

    @State private var isUpdating = false

    var body: some View {
        Button {
            Task { await update(played: !item.isPlayed) }
        } label: {
            TileLabel(title: "Watched", systemImage: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                .symbolEffect(.bounce, value: item.isPlayed)
        }
        .buttonStyle(TileButtonStyle(isOn: item.isPlayed))
        .accessibilityValue(item.isPlayed ? "On" : "Off")
        .disabled(isUpdating)

        Button {
            Task { await update(favorite: !item.isFavorite) }
        } label: {
            TileLabel(title: "Favourite", systemImage: item.isFavorite ? "heart.fill" : "heart")
                .symbolEffect(.bounce, value: item.isFavorite)
        }
        .buttonStyle(TileButtonStyle(isOn: item.isFavorite))
        .accessibilityValue(item.isFavorite ? "On" : "Off")
        .disabled(isUpdating)
    }

    private func update(played: Bool? = nil, favorite: Bool? = nil) async {
        guard let id = item.id else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if let played {
                let data = try await api.setPlayed(played, itemID: id)
                withAnimation(.easeInOut(duration: 0.2)) { item.userData = data }
                AppLog.shared.log("Marked \(item.name ?? id) as \(played ? "watched" : "unwatched")")
            }
            if let favorite {
                let data = try await api.setFavorite(favorite, itemID: id)
                withAnimation(.easeInOut(duration: 0.2)) { item.userData = data }
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
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Theme.text.opacity(0.85))
                .lineLimit(isExpanded ? nil : 4)
            if text.count > 200 {
                Button(isExpanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
                }
                .font(.system(size: 15, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Human-readable lines describing a media source, used on screen and in the log.
enum MediaSummary {
    /// One line like "1080p · HEVC · AAC 2.0 · 3 subtitles".
    static func short(for source: MediaSourceInfo) -> String {
        let streams = source.mediaStreams ?? []
        var parts: [String] = []
        if let video = streams.first(where: { $0.type == .video }) {
            if let height = video.height {
                parts.append(height >= 2000 ? "4K" : "\(height)p")
            }
            if let codec = video.codec {
                parts.append(codec.uppercased())
            }
            if let range = video.videoRangeType?.rawValue, range != "SDR" {
                parts.append(range)
            }
        }
        if let audio = streams.first(where: { $0.type == .audio && $0.isDefault == true }) ?? streams.first(where: { $0.type == .audio }) {
            var text = audio.codec?.uppercased() ?? "Audio"
            if let channels = audio.channels {
                text += channels == 6 ? " 5.1" : channels == 8 ? " 7.1" : channels == 2 ? " 2.0" : " \(channels)ch"
            }
            parts.append(text)
        }
        let subtitles = streams.filter { $0.type == .subtitle }.count
        if subtitles > 0 {
            parts.append(subtitles == 1 ? "1 subtitle" : "\(subtitles) subtitles")
        }
        return parts.joined(separator: " · ")
    }

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
