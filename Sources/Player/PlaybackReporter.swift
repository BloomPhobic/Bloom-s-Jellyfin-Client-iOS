import Foundation
import JellyfinAPI

extension Notification.Name {
    /// Posted after playback stops and the position has been sent, so lists can show the new progress.
    static let playbackStopped = Notification.Name("playbackStopped")
}

/// Tells the server what is playing and where, so progress, Continue watching and Next up stay in sync
/// with other clients. The server marks an item watched when it stops near the end.
@MainActor
final class PlaybackReporter {
    private let client: JellyfinClient
    private let itemID: String
    private let mediaSourceID: String?
    private let playSessionID = UUID().uuidString
    private var started = false
    private var lastReport = Date.distantPast
    private var lastPaused = false
    private var lastPosition: Double = 0

    private static let interval: TimeInterval = 10

    init(client: JellyfinClient, itemID: String, mediaSourceID: String?) {
        self.client = client
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
    }

    /// Called regularly while the player is open. Sends "started" once, then progress every 10 s
    /// and whenever pause changes.
    func update(position: Double, isPaused: Bool) {
        lastPosition = position
        if !started {
            started = true
            lastReport = Date()
            lastPaused = isPaused
            let body = state(position: position, isPaused: isPaused)
            send("start") { client in try await client.send(Paths.reportPlaybackStart(body)) }
            return
        }
        guard isPaused != lastPaused || Date().timeIntervalSince(lastReport) >= Self.interval else { return }
        lastReport = Date()
        lastPaused = isPaused
        let body = state(position: position, isPaused: isPaused)
        send("progress") { client in try await client.send(Paths.reportPlaybackProgress(body)) }
    }

    func stop() {
        guard started else { return }
        started = false
        var body = PlaybackStopInfo()
        body.itemID = itemID
        body.mediaSourceID = mediaSourceID
        body.playSessionID = playSessionID
        body.positionTicks = Self.ticks(lastPosition)
        let position = lastPosition
        let client = client
        Task {
            do {
                try await client.send(Paths.reportPlaybackStopped(body))
                AppLog.shared.log("Progress saved at \(ItemDetailView.timeText(position))")
            } catch {
                AppLog.shared.log("Couldn't save progress: \(error.localizedDescription)", level: .warning)
            }
            NotificationCenter.default.post(name: .playbackStopped, object: nil)
        }
    }

    private func state(position: Double, isPaused: Bool) -> PlaybackStateInfo {
        var info = PlaybackStateInfo()
        info.itemID = itemID
        info.mediaSourceID = mediaSourceID
        info.playSessionID = playSessionID
        info.positionTicks = Self.ticks(position)
        info.isPaused = isPaused
        info.canSeek = true
        info.playMethod = .directPlay
        return info
    }

    private func send(_ label: String, _ operation: @escaping @Sendable (JellyfinClient) async throws -> Void) {
        let client = client
        Task {
            do {
                try await operation(client)
            } catch {
                AppLog.shared.log("Playback \(label) report failed: \(error.localizedDescription)", level: .warning)
            }
        }
    }

    private static func ticks(_ seconds: Double) -> Int {
        Int(max(seconds, 0) * 10_000_000)
    }
}
