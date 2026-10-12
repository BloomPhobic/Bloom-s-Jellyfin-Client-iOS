import JellyfinAPI
import SwiftUI

/// Full-screen player: overlay controls, skip buttons, the next-episode card, subtitle options
/// and an episode list. Episodes switch inside the same player.
struct PlayerView: View {
    let session: PlaybackSession

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = true
    @State private var showStats = false
    @State private var showSubtitleOptions = false
    @State private var showEpisodes = false
    @State private var scrubPosition: Double?

    private var player: MPVPlayer { session.player }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(player: player, url: session.initialURL, startSeconds: session.initialStart)
                .ignoresSafeArea()
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }
            if player.isBuffering && player.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            if showStats {
                statsPanel
            }
            if showControls {
                controls
            }
            // Skip and next-episode stay visible even when the controls are hidden.
            cornerActions
            if let error = player.errorMessage {
                errorPanel(error)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await session.loadExtras()
        }
        .task {
            while !Task.isCancelled {
                player.refreshState()
                session.tick()
                if showStats {
                    player.refreshStats()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                player.setVideoEnabled(false)
            case .active:
                player.setVideoEnabled(true)
            default:
                break
            }
        }
        .onChange(of: store.client?.configuration.url) {
            if let client = store.client, let signedIn = store.session {
                session.handoff(to: LibraryAPI(client: client, userID: signedIn.userID))
            }
        }
        .onDisappear {
            session.close()
        }
        .sheet(isPresented: $showSubtitleOptions) {
            SubtitleOptionsView(player: player)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodePickerView(session: session) {
                showEpisodes = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 20) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                Text(verbatim: session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if session.isEpisode {
                    Button {
                        showEpisodes = true
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                }
                AudioTrackMenu(player: player)
                SubtitleTrackMenu(player: player)
                Button {
                    showSubtitleOptions = true
                } label: {
                    Image(systemName: "textformat.size")
                }
                Button {
                    showStats.toggle()
                    if showStats {
                        player.refreshStats()
                    }
                } label: {
                    Image(systemName: showStats ? "info.circle.fill" : "info.circle")
                }
            }
            .font(.title3)

            Spacer()

            HStack(spacing: 56) {
                Button {
                    player.seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                }
                Button {
                    player.togglePause()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                }
                Button {
                    player.seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                }
            }
            .font(.system(size: 36))

            Spacer()

            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { scrubPosition ?? player.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubPosition {
                            player.seek(to: target)
                            scrubPosition = nil
                        }
                    }
                )
                HStack {
                    Text(Self.format(scrubPosition ?? player.position))
                    Spacer()
                    Text(Self.format(player.duration))
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding()
        .foregroundStyle(.white)
        .tint(.white)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    /// Bottom-right: the next-episode card, or a skip button during a marked segment.
    @ViewBuilder
    private var cornerActions: some View {
        Group {
            if session.showsNextCard, let next = session.nextEpisode {
                NextEpisodeCard(session: session, next: next)
            } else if let segment = session.activeSegment {
                Button {
                    session.skip(segment)
                } label: {
                    Label(segment.skipTitle, systemImage: "forward.end.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Above the seek bar when the controls are showing.
        .padding(.bottom, showControls ? 90 : 24)
        .padding(.trailing, 24)
        .animation(.easeInOut(duration: 0.2), value: session.showsNextCard)
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(player.stats.enumerated()), id: \.offset) { _, row in
                Text(verbatim: "\(row.0): \(row.1)")
            }
            Button("Copy stats to log") {
                player.logStats()
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 56)
        .padding(.horizontal)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(verbatim: message)
                .multilineTextAlignment(.center)
            Text("Details are in Settings → Log.")
                .font(.caption)
            Button("Close") {
                close()
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }

    private func close() {
        session.close()
        dismiss()
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// "Up next" card with the next episode's still, a countdown (if autoplay is on), Play now and Cancel.
private struct NextEpisodeCard: View {
    let session: PlaybackSession
    let next: BaseItemDto

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkFrame(url: session.api.imageURL(Artwork.landscape(next), maxWidth: 400), aspectRatio: 16 / 9)
                .frame(width: 130)
            VStack(alignment: .leading, spacing: 6) {
                Text(countdownText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text([next.episodeLabel, next.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button {
                        Task { await session.play(next, resume: false) }
                    } label: {
                        Label("Play now", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") {
                        session.cancelNextCard()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .font(.subheadline)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var countdownText: String {
        // TimelineView isn't needed: the player's half-second tick already redraws this.
        guard let end = session.countdownEnd else { return "UP NEXT" }
        let seconds = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        return "UP NEXT IN \(seconds)"
    }
}

/// Subtitle size, style, boldness and timing. Size, style and bold are remembered; the timing
/// offset is for the current session only.
private struct SubtitleOptionsView: View {
    let player: MPVPlayer

    @AppStorage(SubtitleSettings.sizeKey) private var size = SubtitleSettings.Size.medium.rawValue
    @AppStorage(SubtitleSettings.styleKey) private var style = SubtitleSettings.Style.outline.rawValue
    @AppStorage(SubtitleSettings.boldKey) private var bold = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Size", selection: $size) {
                        ForEach(SubtitleSettings.Size.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Style", selection: $style) {
                        ForEach(SubtitleSettings.Style.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Bold", isOn: $bold)
                } header: {
                    Text("Look")
                } footer: {
                    Text("Applies to plain subtitles like SRT. Styled (ASS) subtitles keep their own look, except for size.")
                }

                Section {
                    HStack {
                        Button {
                            player.setSubtitleDelay(player.subtitleDelay - 0.1)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        VStack(spacing: 2) {
                            Text(String(format: "%+.1f s", player.subtitleDelay))
                                .font(.title3.monospacedDigit().weight(.semibold))
                            Text(delayHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            player.setSubtitleDelay(player.subtitleDelay + 0.1)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                    }
                    if player.subtitleDelay != 0 {
                        Button("Reset timing") {
                            player.setSubtitleDelay(0)
                        }
                    }
                } header: {
                    Text("Timing")
                }
            }
            .navigationTitle("Subtitles")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: size) { player.applySubtitleStyle() }
        .onChange(of: style) { player.applySubtitleStyle() }
        .onChange(of: bold) { player.applySubtitleStyle() }
    }

    private var delayHint: String {
        if player.subtitleDelay > 0 { return "Subtitles appear later" }
        if player.subtitleDelay < 0 { return "Subtitles appear earlier" }
        return "In sync with the file"
    }
}

/// The season's episodes inside the player; tap one to switch to it.
private struct EpisodePickerView: View {
    let session: PlaybackSession
    let onPick: () -> Void

    @State private var seasons: [BaseItemDto] = []
    @State private var seasonID: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(session.seasonEpisodes, id: \.id) { episode in
                    Button {
                        onPick()
                        Task { await session.play(episode, resume: true) }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkFrame(url: session.api.imageURL(Artwork.landscape(episode), maxWidth: 300), aspectRatio: 16 / 9) {
                                ZStack {
                                    WatchBadge(item: episode)
                                    ProgressOverlay(item: episode)
                                }
                            }
                            .frame(width: 110)
                            VStack(alignment: .leading, spacing: 2) {
                                Text([episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " "))
                                    .font(.subheadline.weight(episode.id == session.item.id ? .bold : .regular))
                                    .lineLimit(2)
                                if let runtime = episode.runtimeText {
                                    Text(runtime)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if episode.id == session.item.id {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
            .navigationTitle(seasons.first(where: { $0.id == (seasonID ?? session.item.seasonID) })?.name ?? "Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if seasons.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(seasons, id: \.id) { season in
                                Button(season.name ?? "Season") {
                                    seasonID = season.id
                                    Task { await session.loadSeason(season.id) }
                                }
                            }
                        } label: {
                            Label("Season", systemImage: "list.number")
                        }
                    }
                }
            }
        }
        .task {
            if let seriesID = session.item.seriesID {
                seasons = (try? await session.api.seasons(seriesID: seriesID)) ?? []
            }
            if session.seasonEpisodes.isEmpty {
                await session.loadSeason()
            }
        }
    }
}

/// Separate views so the menus only redraw when tracks change, not on every position update
/// (redrawing an open menu makes it flicker).
private struct AudioTrackMenu: View {
    let player: MPVPlayer

    var body: some View {
        Menu {
            ForEach(player.audioTracks) { track in
                Button {
                    player.selectAudio(track.id)
                } label: {
                    if track.isSelected {
                        Label(track.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: track.title)
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
        }
    }
}

private struct SubtitleTrackMenu: View {
    let player: MPVPlayer

    var body: some View {
        Menu {
            Button {
                player.selectSubtitle(nil)
            } label: {
                if player.subtitleTracks.contains(where: { $0.isSelected }) {
                    Text("Off")
                } else {
                    Label("Off", systemImage: "checkmark")
                }
            }
            ForEach(player.subtitleTracks) { track in
                Button {
                    player.selectSubtitle(track.id)
                } label: {
                    if track.isSelected {
                        Label(track.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: track.title)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
        }
    }
}
