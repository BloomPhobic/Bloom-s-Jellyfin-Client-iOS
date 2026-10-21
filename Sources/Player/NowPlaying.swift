import JellyfinAPI
import MediaPlayer
import UIKit

/// What's playing on the lock screen and in Control Center, and the play/pause, skip and seek
/// buttons there (also used by headphone and AirPods controls).
@MainActor
final class NowPlaying {
    private weak var session: PlaybackSession?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var info: [String: Any] = [:]
    private var artworkItemID: String?
    private var lastPaused: Bool?
    private var lastSpeed: Double?
    private var lastPosition: Double = 0

    func start(_ session: PlaybackSession) {
        self.session = session
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { session in
            if session.player.isPaused { session.player.togglePause() }
        }
        add(center.pauseCommand) { session in
            if !session.player.isPaused { session.player.togglePause() }
        }
        add(center.togglePlayPauseCommand) { session in
            session.player.togglePause()
        }
        center.skipForwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { session in
            session.player.seek(by: 10)
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipBackwardCommand) { session in
            session.player.seek(by: -10)
        }
        add(center.nextTrackCommand) { session in
            guard let next = session.nextEpisode else { return }
            Task { await session.play(next, resume: false) }
        }
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            return MainActor.assumeIsolated {
                guard let session = self?.session else { return .noActionableNowPlayingItem }
                session.player.seek(to: position)
                return .success
            }
        }
        center.changePlaybackPositionCommand.isEnabled = true
        targets.append((center.changePlaybackPositionCommand, seekTarget))
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackSession) -> Void) {
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let session = self?.session else { return .noActionableNowPlayingItem }
                action(session)
                return .success
            }
        }
        command.isEnabled = true
        targets.append((command, target))
    }

    /// Called every half second. Only touches the system when something changed, or when the
    /// position jumped (a seek); in between, iOS moves the time along by itself.
    func update() {
        guard let session else { return }
        let player = session.player
        let item = session.item
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = session.nextEpisode != nil

        var changed = false
        if artworkItemID != item.id {
            artworkItemID = item.id
            info = [
                MPMediaItemPropertyTitle: session.isEpisode ? (item.name ?? session.headline) : session.headline,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            ]
            if session.isEpisode {
                info[MPMediaItemPropertyArtist] = [item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
            } else if let year = item.productionYear {
                info[MPMediaItemPropertyArtist] = String(year)
            }
            loadArtwork(for: item, session: session)
            changed = true
        }
        let paused = player.isPaused || player.isBuffering
        let speed = player.isHoldingSpeed ? PlayerSettings.holdSpeed : player.speed
        let expected = lastPosition + (lastPaused == false ? 0.5 * (lastSpeed ?? 1) : 0)
        if paused != lastPaused || speed != lastSpeed || abs(player.position - expected) > 1.5 {
            changed = true
        }
        lastPaused = paused
        lastSpeed = speed
        lastPosition = player.position
        guard changed else { return }
        info[MPMediaItemPropertyPlaybackDuration] = player.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : speed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for item: BaseItemDto, session: PlaybackSession) {
        guard let url = session.stillURL(item) else { return }
        let itemID = item.id
        Task {
            guard let image = await ImageCache.shared.load(url), artworkItemID == itemID else { return }
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    /// Made outside the main actor: iOS asks for the picture from a background thread.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func stop() {
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets = []
        session = nil
        UIApplication.shared.endReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
