import JellyfinAPI
import SwiftUI
import UIKit

/// Full-screen player: overlay controls, skip buttons, the next-episode card, subtitle options
/// and an episode list. Episodes switch inside the same player.
struct PlayerView: View {
    let session: PlaybackSession

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showControls = true
    @State private var showStats = false
    @State private var panel: PlayerPanel?
    @State private var scrubPosition: Double?
    /// When the viewer last touched the controls; they fade out a few seconds after that.
    @State private var lastInteraction = Date()
    @State private var offlineSince: Date?
    /// Touch tracking for tap (show/hide controls) and press-and-hold on the sides (faster playback).
    @GestureState private var isTouching = false
    @State private var touchStarted = false
    @State private var touchMoved = false
    @State private var didHold = false
    @State private var holdTimer: Task<Void, Never>?
    /// "Zoomed to fill" / "Fit to screen", shown briefly after a pinch.
    @State private var zoomMessage: String?
    @State private var zoomMessageTimer: Task<Void, Never>?

    private var player: MPVPlayer { session.player }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(player: player, url: session.initialURL, startSeconds: session.initialStart)
                .ignoresSafeArea()
            touchLayer
            if session.isRecovering || (player.errorMessage != nil && !session.showsError) {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Reconnecting…")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                }
            } else if player.isBuffering && player.errorMessage == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
            if showStats {
                statsPanel
            }
            // Kept in the view tree while hidden, so an open audio or subtitle menu isn't torn down
            // when the controls fade.
            controls
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls)
                .accessibilityHidden(!showControls)
            if player.isHoldingSpeed {
                holdSpeedBadge
            } else if let zoomMessage {
                badge(zoomMessage, systemImage: player.isZoomed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
            }
            // Skip and next-episode stay visible even when the controls are hidden.
            cornerActions
            connectionPill
            panelLayer
            if session.showsError, let error = player.errorMessage {
                errorPanel(error)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .modifier(AccentTint())
        .task {
            session.begin()
            await session.loadExtras()
        }
        .task {
            while !Task.isCancelled {
                player.refreshState()
                session.tick()
                if showStats {
                    player.refreshStats()
                }
                autoHideControls()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                player.setVideoEnabled(false, keepPlaying: PlayerSettings.backgroundAudio)
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
        .onChange(of: connectionDown, initial: true) { _, down in
            offlineSince = down ? .now : nil
        }
        .onChange(of: isTouching) { _, touching in
            // Also runs when iOS cancels the touch, so the speed never stays stuck.
            if !touching {
                holdTimer?.cancel()
                holdTimer = nil
                touchStarted = false
                player.endHoldSpeed()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: player.isHoldingSpeed)
        .animation(.easeInOut(duration: 0.15), value: zoomMessage)
        .onChange(of: scrubPosition) { lastInteraction = .now }
        .onChange(of: panel) { lastInteraction = .now }
        .onChange(of: player.isPaused) { lastInteraction = .now }
        .onAppear {
            OrientationLock.set(.landscape, rotateTo: .landscape)
        }
        .onDisappear {
            session.close()
            OrientationLock.set(.allButUpsideDown, rotateTo: .portrait)
        }
    }

    /// Tap anywhere to show or hide the controls. Press and hold the left or right third of the
    /// screen to play at the hold speed (2× unless changed) until you let go. Pinch out to crop
    /// the picture to fill the screen, pinch in to see all of it again.
    private var touchLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isTouching) { _, touching, _ in touching = true }
                        .onChanged { value in
                            if !touchStarted {
                                touchStarted = true
                                touchMoved = false
                                didHold = false
                                let side = proxy.size.width / 3
                                let x = value.startLocation.x
                                if x < side || x > proxy.size.width - side {
                                    holdTimer = Task {
                                        try? await Task.sleep(for: .milliseconds(350))
                                        guard !Task.isCancelled else { return }
                                        beginHold()
                                    }
                                }
                            }
                            if hypot(value.translation.width, value.translation.height) > 20 {
                                touchMoved = true
                                holdTimer?.cancel()
                            }
                        }
                        .onEnded { _ in
                            holdTimer?.cancel()
                            holdTimer = nil
                            touchStarted = false
                            player.endHoldSpeed()
                            if !didHold && !touchMoved {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showControls.toggle()
                                }
                                lastInteraction = .now
                            }
                        }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { _ in
                            // Two fingers: not a tap and not a hold.
                            touchMoved = true
                            holdTimer?.cancel()
                        }
                        .onEnded { value in
                            if value.magnification > 1.08 {
                                setZoom(true)
                            } else if value.magnification < 0.92 {
                                setZoom(false)
                            }
                        }
                )
        }
        .ignoresSafeArea()
    }

    private func setZoom(_ zoomed: Bool) {
        player.setZoomed(zoomed)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        zoomMessage = zoomed ? "Zoomed to fill" : "Fit to screen"
        zoomMessageTimer?.cancel()
        zoomMessageTimer = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            zoomMessage = nil
        }
    }

    private func beginHold() {
        guard !player.isPaused, panel == nil else { return }
        didHold = true
        player.beginHoldSpeed()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = false
        }
    }

    /// Top centre while the side of the screen is held: "2× ▸▸".
    private var holdSpeedBadge: some View {
        badge(PlayerSettings.label(PlayerSettings.holdSpeed), systemImage: "forward.fill")
            .accessibilityLabel("Playing at \(PlayerSettings.label(PlayerSettings.holdSpeed))")
    }

    /// A small message at the top centre of the video.
    private func badge(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
            Image(systemName: systemImage)
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.background.opacity(0.8)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 16)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .allowsHitTesting(false)
    }

    /// Hides the controls 4 s after the last touch, while playing. They stay up while paused,
    /// while scrubbing, while a panel is open, and with VoiceOver on.
    private func autoHideControls() {
        guard showControls, !player.isPaused, panel == nil, scrubPosition == nil,
              !UIAccessibility.isVoiceOverRunning,
              Date().timeIntervalSince(lastInteraction) > 4 else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            showControls = false
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                }
                .buttonStyle(CircleButtonStyle())
                .accessibilityLabel("Close player")

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: session.headline)
                        .font(.system(size: 15, weight: .bold))
                        .lineLimit(1)
                    if let subheadline = session.subheadline {
                        Text(verbatim: subheadline)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if session.chapters.count > 1 {
                        Button {
                            toggle(.chapters)
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(CircleButtonStyle(fill: panel == .chapters ? Theme.accent.opacity(0.35) : Theme.scrim))
                        .accessibilityLabel("Chapters")
                    }
                    if session.isEpisode {
                        Button {
                            toggle(.episodes)
                        } label: {
                            Image(systemName: panel == .episodes ? "rectangle.stack.fill" : "rectangle.stack")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(CircleButtonStyle(fill: panel == .episodes ? Theme.accent.opacity(0.35) : Theme.scrim))
                        .accessibilityLabel("Episodes")
                    }
                    Button {
                        toggle(.speed)
                    } label: {
                        if player.speed == 1 {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .font(.system(size: 16, weight: .semibold))
                        } else {
                            Text(PlayerSettings.label(player.speed))
                                .font(.system(size: 13, weight: .bold))
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(CircleButtonStyle(fill: panel == .speed ? Theme.accent.opacity(0.35) : Theme.scrim))
                    .accessibilityLabel("Playback speed, \(PlayerSettings.label(player.speed))")
                    AudioTrackMenu(player: player)
                    SubtitleTrackMenu(player: player)
                    Button {
                        toggle(.subtitles)
                    } label: {
                        Text("Aa")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(CircleButtonStyle(fill: panel == .subtitles ? Theme.accent.opacity(0.35) : Theme.scrim))
                    .accessibilityLabel("Subtitle size, style and timing")
                    Button {
                        showStats.toggle()
                        if showStats {
                            player.refreshStats()
                        }
                    } label: {
                        Image(systemName: showStats ? "info.circle.fill" : "info.circle")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Playback stats")
                }
            }

            Spacer()

            if panel == nil {
                transport
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Any tap on a button counts as activity and restarts the hide timer.
        .simultaneousGesture(TapGesture().onEnded { lastInteraction = .now })
        .foregroundStyle(Theme.text)
        .tint(Theme.text)
        .background(
            // A light scrim so white controls stay readable over bright video.
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    /// Play/pause, ±10 s and the seek bar. Hidden while a side panel is open.
    private var transport: some View {
        Group {
            HStack(spacing: 40) {
                Button {
                    player.seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle(size: 46, fill: Theme.scrim))
                .accessibilityLabel("Back 10 seconds")

                Button {
                    player.togglePause()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CircleButtonStyle(size: 56, fill: Theme.text.opacity(0.92)))
                .accessibilityLabel(player.isPaused ? "Play" : "Pause")

                Button {
                    player.seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle(size: 46, fill: Theme.scrim))
                .accessibilityLabel("Forward 10 seconds")
            }

            Spacer()

            HStack(spacing: 12) {
                Text(Self.format(scrubPosition ?? player.position))
                SeekBar(
                    position: player.position,
                    duration: player.duration,
                    segments: session.segments,
                    session: session,
                    scrubPosition: $scrubPosition
                ) { target in
                    player.seek(to: target)
                }
                Text("-" + Self.format(max(0, player.duration - (scrubPosition ?? player.position))))
                    .foregroundStyle(Theme.text2)
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }

    private func toggle(_ newPanel: PlayerPanel) {
        withAnimation(.easeInOut(duration: 0.25)) {
            panel = panel == newPanel ? nil : newPanel
            if panel != nil {
                showControls = true
            }
        }
    }

    /// Episodes or subtitle options: on the right in landscape (the video stays visible), from the
    /// bottom in portrait. Tapping outside closes it; the top bar stays usable to switch panels.
    @ViewBuilder
    private var panelLayer: some View {
        if let panel {
            GeometryReader { proxy in
                let landscape = proxy.size.width > proxy.size.height
                VStack(spacing: 0) {
                    // Leave the top bar uncovered.
                    Color.clear
                        .frame(height: 56)
                        .allowsHitTesting(false)
                    ZStack(alignment: landscape ? .trailing : .bottom) {
                        Color.black.opacity(0.2)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(panel) }
                        panelContent(panel)
                            .frame(width: landscape ? min(420, proxy.size.width * 0.45) : nil,
                                   height: landscape ? nil : proxy.size.height * 0.6)
                            .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(8)
                            .transition(.move(edge: landscape ? .trailing : .bottom).combined(with: .opacity))
                    }
                }
            }
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: PlayerPanel) -> some View {
        switch panel {
        case .episodes:
            EpisodePickerView(session: session) {
                toggle(.episodes)
            }
        case .subtitles:
            SubtitleOptionsView(player: player) {
                toggle(.subtitles)
            }
        case .speed:
            SpeedOptionsView(player: player) {
                toggle(.speed)
            }
        case .chapters:
            ChapterListView(session: session) {
                toggle(.chapters)
            }
        }
    }

    /// A downloaded file plays on regardless, so the connection doesn't matter then.
    private var connectionDown: Bool {
        (store.isOffline || store.isServerUnreachable) && !session.isPlayingDownload
    }

    /// Top centre, while the connection is down: how long the buffer will last, or that playback is
    /// waiting for the connection to come back. The full pill shows for the first few seconds, with
    /// the controls, and while stalled; otherwise it shrinks to a small icon in the top-left corner.
    /// Tap the screen to see it again.
    @ViewBuilder
    private var connectionPill: some View {
        let justWentOffline = offlineSince.map { Date().timeIntervalSince($0) < 5 } ?? false
        let expanded = showControls || player.isBuffering || justWentOffline
        Group {
            if connectionDown && player.errorMessage == nil {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    if expanded {
                        if player.isBuffering {
                            Text("Waiting for connection…")
                        } else {
                            Text("Offline · playing from buffer (\(Self.format(player.bufferedSeconds)) left)")
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, expanded ? 14 : 8)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.background.opacity(expanded ? 0.85 : 0.6)))
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.7), lineWidth: 1))
                .padding(.top, showControls ? 64 : 12)
                .padding(.leading, expanded ? 0 : 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(player.isBuffering ? "Offline, waiting for connection" : "Offline, playing from buffer")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: expanded ? .top : .topLeading)
        .animation(.easeInOut(duration: 0.25), value: connectionDown)
        .animation(.easeInOut(duration: 0.25), value: expanded)
        .allowsHitTesting(false)
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
                    HStack(spacing: 8) {
                        Image(systemName: "forward.end.fill")
                        Text(segment.skipTitle)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().fill(Theme.background.opacity(0.8)))
                    .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Above the seek bar when the controls are showing.
        .padding(.bottom, showControls ? 90 : 24)
        .padding(.trailing, 24)
        .animation(.easeInOut(duration: 0.2), value: session.showsNextCard)
        .animation(.easeInOut(duration: 0.2), value: session.activeSegment)
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
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.orange)
            Text(Self.friendly(message))
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(verbatim: "mpv: \(message)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text3)
            HStack(spacing: 10) {
                Button("Retry") {
                    session.retryNow()
                }
                .buttonStyle(PrimaryButtonStyle(height: 44))
                Button("Copy details") {
                    UIPasteboard.general.string = session.errorReport()
                }
                .buttonStyle(.bordered)
                .tint(Theme.text)
                Button("Close") {
                    close()
                }
                .buttonStyle(.bordered)
                .tint(Theme.text)
            }
            .frame(maxWidth: 420)
        }
        .foregroundStyle(Theme.text)
        .padding(24)
        .frame(maxWidth: 480)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .padding()
    }

    /// mpv's error, in words for the viewer.
    private static func friendly(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("unrecognized") || text.contains("no audio or video") || text.contains("unsupported") {
            return "This file can't be played. It may be damaged, or in a format the player can't read."
        }
        if text.contains("loading failed") || text.contains("network") || text.contains("tls") || text.contains("http") {
            return "The video couldn't be loaded from the server. Check your connection, then retry."
        }
        return "Playback stopped because of an error."
    }

    /// Stops playback, turns the (now black) player back to portrait, then removes it without the
    /// slide-down, so Home never shows in landscape on the way out.
    private func close() {
        session.close()
        showControls = false
        let wasLandscape = OrientationLock.isLandscape
        OrientationLock.set(.allButUpsideDown, rotateTo: .portrait)
        Task {
            if wasLandscape {
                try? await Task.sleep(for: .milliseconds(400))
            }
            withTransaction(\.disablesAnimations, true) {
                dismiss()
            }
        }
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

/// Seek bar with the server's intro/credits segments and the chapters marked. Drag anywhere on it
/// to scrub; a preview picture (if the server made them) and the chapter name show above your finger.
private struct SeekBar: View {
    let position: Double
    let duration: Double
    let segments: [PlaybackSegment]
    let session: PlaybackSession
    @Binding var scrubPosition: Double?
    let onCommit: (Double) -> Void

    @State private var isDragging = false
    /// The finger slid up off the bar: letting go won't jump anywhere.
    @State private var isCancelled = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let shown = scrubPosition ?? position
            let fraction = duration > 0 ? CGFloat(min(max(shown / duration, 0), 1)) : 0
            let track: CGFloat = isDragging ? 8 : 5
            let knob: CGFloat = isDragging ? 22 : 16
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: track)
                if duration > 0 {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: max(2, width * CGFloat((segment.end - segment.start) / duration)), height: track)
                            .offset(x: width * CGFloat(segment.start / duration))
                    }
                }
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * fraction, height: track)
                if duration > 0 {
                    // A small gap in the bar where each chapter starts.
                    ForEach(session.chapters.filter { $0.start > 1 && $0.start < duration - 1 }, id: \.index) { chapter in
                        Rectangle()
                            .fill(Color.black.opacity(0.7))
                            .frame(width: 2, height: track)
                            .offset(x: width * CGFloat(chapter.start / duration) - 1)
                    }
                }
                Circle()
                    .fill(Theme.text)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .offset(x: width * fraction - knob / 2)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if let scrubPosition, duration > 0 {
                    ScrubPreview(session: session, seconds: scrubPosition)
                        .alignmentGuide(.leading) { preview in
                            // Centred on the finger, but kept inside the bar's ends.
                            let centre = width * fraction - preview.width / 2
                            return -min(max(centre, 0), max(width - preview.width, 0))
                        }
                        .alignmentGuide(.bottom) { preview in preview.height + 34 }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        // Slide up away from the bar to look without jumping; come back down to carry on.
                        isCancelled = value.translation.height < -70
                        scrubPosition = isCancelled ? nil : Double(min(max(value.location.x / max(width, 1), 0), 1)) * duration
                    }
                    .onEnded { value in
                        if !isCancelled {
                            let target = Double(min(max(value.location.x / max(width, 1), 0), 1)) * duration
                            onCommit(target)
                        }
                        scrubPosition = nil
                        isDragging = false
                        isCancelled = false
                    }
            )
        }
        .frame(height: 30)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(position) / 60) minutes \(Int(position) % 60) seconds")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(position + 10, duration))
            case .decrement: onCommit(max(position - 10, 0))
            @unknown default: break
            }
        }
    }
}

/// "Up next" card with the next episode's still, a countdown (if autoplay is on), Play now and Cancel.
private struct NextEpisodeCard: View {
    let session: PlaybackSession
    let next: BaseItemDto

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkFrame(url: session.stillURL(next), aspectRatio: 16 / 9)
                .frame(width: 130)
            VStack(alignment: .leading, spacing: 6) {
                // Redraws on its own clock; nothing else on the card changes while counting down.
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(countdownText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
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
        guard let end = session.countdownEnd else { return "UP NEXT" }
        let seconds = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        return "UP NEXT IN \(seconds)"
    }
}

private enum PlayerPanel {
    case episodes
    case subtitles
    case speed
    case chapters
}

/// Above the finger while scrubbing: the preview picture, the chapter name and the time.
private struct ScrubPreview: View {
    let session: PlaybackSession
    let seconds: Double

    var body: some View {
        let chapter = session.chapter(at: seconds)
        VStack(spacing: 4) {
            if let thumbnails = session.thumbnails {
                ZStack {
                    Rectangle().fill(Color.black)
                    if let image = thumbnails.thumbnail(at: seconds) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 176, height: 176 / thumbnails.aspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
            }
            if session.chapters.count > 1, let chapter {
                Text(verbatim: chapter.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 176)
            }
            Text(ItemDetailView.timeText(seconds))
                .font(.system(size: 13, weight: .bold).monospacedDigit())
        }
        .padding(session.thumbnails == nil ? 8 : 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.6)))
        .foregroundStyle(Theme.text)
    }
}

/// The chapters of the film or episode; tap one to jump to it.
private struct ChapterListView: View {
    let session: PlaybackSession
    let close: () -> Void

    var body: some View {
        let current = session.chapter(at: session.player.position)
        VStack(spacing: 0) {
            PanelHeader(title: "Chapters", close: close) { EmptyView() }
            ScrollViewReader { proxy in
                List {
                    ForEach(session.chapters, id: \.index) { chapter in
                        Button {
                            session.player.seek(to: chapter.start)
                            close()
                        } label: {
                            HStack(spacing: 12) {
                                if session.thumbnails != nil || chapter.imageTag != nil {
                                    ChapterPicture(session: session, chapter: chapter)
                                        .frame(width: 110)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: chapter.name)
                                        .font(.subheadline.weight(chapter == current ? .bold : .regular))
                                        .lineLimit(2)
                                    Text(ItemDetailView.timeText(chapter.start))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chapter == current {
                                    Image(systemName: "play.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .listRowBackground(Color.clear)
                        .id(chapter.index)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let current {
                        proxy.scrollTo(current.index, anchor: .center)
                    }
                }
            }
        }
    }
}

/// A chapter's picture: the preview picture at its start, or the server's chapter image.
private struct ChapterPicture: View {
    let session: PlaybackSession
    let chapter: PlaybackChapter

    var body: some View {
        if let thumbnails = session.thumbnails {
            ZStack {
                Rectangle().fill(Theme.raised2)
                if let image = thumbnails.thumbnail(at: chapter.start + 1) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ArtworkFrame(url: session.chapterImageURL(chapter), aspectRatio: 16 / 9, cornerRadius: 8)
        }
    }
}

/// Playback speed (for this player) and the speed used while holding the side of the screen
/// (remembered).
private struct SpeedOptionsView: View {
    let player: MPVPlayer
    let close: () -> Void

    @AppStorage(PlayerSettings.holdSpeedKey) private var holdSpeed = 2.0

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Speed", close: close) { EmptyView() }
            Form {
                Section {
                    SpeedChoices(choices: PlayerSettings.speedChoices, selected: player.speed) { speed in
                        player.setSpeed(speed)
                    }
                } header: {
                    Text("Playback speed")
                } footer: {
                    Text("Goes back to 1× when you close the player.")
                }
                Section {
                    SpeedChoices(choices: PlayerSettings.holdSpeedChoices, selected: holdSpeed) { speed in
                        holdSpeed = speed
                    }
                } header: {
                    Text("Hold speed")
                } footer: {
                    Text("Press and hold the left or right side of the screen to play at this speed. Let go to go back.")
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

/// A row of speed buttons, the selected one filled with the accent.
private struct SpeedChoices: View {
    let choices: [Double]
    let selected: Double
    let pick: (Double) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(choices, id: \.self) { speed in
                let isSelected = speed == selected
                Button {
                    pick(speed)
                } label: {
                    Text(PlayerSettings.label(speed))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(isSelected ? Theme.onAccent : Theme.text)
                        .background(Capsule().fill(isSelected ? Theme.accent : Theme.raised2))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Title row for a player panel, with a close button.
private struct PanelHeader<Trailing: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            trailing
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

/// Subtitle size, style, boldness and timing. Size, style and bold are remembered; the timing
/// offset is for the current session only.
private struct SubtitleOptionsView: View {
    let player: MPVPlayer
    let close: () -> Void

    @AppStorage(SubtitleSettings.sizeKey) private var size = SubtitleSettings.Size.medium.rawValue
    @AppStorage(SubtitleSettings.styleKey) private var style = SubtitleSettings.Style.outline.rawValue
    @AppStorage(SubtitleSettings.boldKey) private var bold = false

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Subtitles", close: close) { EmptyView() }
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
            .scrollContentBackground(.hidden)
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
        VStack(spacing: 0) {
            PanelHeader(title: seasonTitle, close: onPick) {
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons, id: \.id) { season in
                            Button(season.name ?? "Season") {
                                seasonID = season.id
                                Task { await session.loadSeason(season.id) }
                            }
                        }
                    } label: {
                        Label("Season", systemImage: "list.number")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                    }
                    .padding(.trailing, 8)
                }
            }
            List {
                ForEach(session.seasonEpisodes, id: \.id) { episode in
                    Button {
                        onPick()
                        Task { await session.play(episode, resume: true) }
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkFrame(url: session.stillURL(episode), aspectRatio: 16 / 9) {
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
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .task {
            if !session.isOffline, let seriesID = session.item.seriesID {
                seasons = (try? await session.api.seasons(seriesID: seriesID)) ?? []
            }
            if session.seasonEpisodes.isEmpty {
                await session.loadSeason()
            }
        }
    }

    private var seasonTitle: String {
        seasons.first(where: { $0.id == (seasonID ?? session.item.seasonID) })?.name ?? "Episodes"
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
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.scrim))
        }
        .accessibilityLabel("Audio track")
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
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.scrim))
        }
        .accessibilityLabel("Subtitles")
    }
}
