import SwiftUI

/// Full-screen player with minimal overlay controls and a stats panel for testing.
struct PlayerView: View {
    let request: PlaybackRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = MPVPlayer()
    @State private var showControls = true
    @State private var showStats = false
    @State private var scrubPosition: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MPVVideoView(player: player, url: request.url)
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
            if let error = player.errorMessage {
                errorPanel(error)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            while !Task.isCancelled {
                player.refreshState()
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
        .onDisappear {
            player.stop()
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
                Text(verbatim: request.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                AudioTrackMenu(player: player)
                SubtitleTrackMenu(player: player)
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
            Text("Details are in the Log tab.")
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
        player.stop()
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
