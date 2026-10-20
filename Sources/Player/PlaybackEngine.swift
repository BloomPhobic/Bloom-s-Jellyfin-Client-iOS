import Foundation

/// An audio or subtitle track offered by a playback engine.
struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let title: String
    let isSelected: Bool
}

/// The player UI talks to this protocol, so the engine (mpv today, possibly AVPlayer as a fallback)
/// can be swapped without touching the UI.
@MainActor
protocol PlaybackEngine: AnyObject {
    var isPaused: Bool { get }
    var isBuffering: Bool { get }
    var position: Double { get }
    var duration: Double { get }
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    /// Playback reached the end of the file (the player stays on the last frame).
    var isAtEnd: Bool { get }
    var subtitleDelay: Double { get }

    func togglePause()
    func seek(to seconds: Double)
    func seek(by seconds: Double)
    func selectAudio(_ id: Int)
    /// Pass nil to turn subtitles off.
    func selectSubtitle(_ id: Int?)
    /// Replaces the current file, starting at `startSeconds`.
    func load(url: URL, startSeconds: Double)
    func applySubtitleStyle()
    func setSubtitleDelay(_ seconds: Double)
    func stop()
}

enum PlayerSettings {
    static let hdrPassthroughKey = "player.hdrPassthrough"
    static let hardwareDecodingKey = "player.hardwareDecoding"

    static var hdrPassthrough: Bool {
        UserDefaults.standard.object(forKey: hdrPassthroughKey) as? Bool ?? true
    }

    static var hardwareDecoding: Bool {
        UserDefaults.standard.object(forKey: hardwareDecodingKey) as? Bool ?? true
    }

    static let holdSpeedKey = "player.holdSpeed"
    static let speedChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let holdSpeedChoices: [Double] = [1.5, 2, 2.5, 3]

    /// The speed while the edge of the screen is held down.
    static var holdSpeed: Double {
        UserDefaults.standard.object(forKey: holdSpeedKey) as? Double ?? 2
    }

    /// "1×", "1.25×", "0.5×".
    static func label(_ speed: Double) -> String {
        let text = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)
        return text + "×"
    }

    static let autoplayNextKey = "player.autoplayNext"

    /// Count down and play the next episode automatically; when off, the card waits for a tap.
    static var autoplayNext: Bool {
        UserDefaults.standard.object(forKey: autoplayNextKey) as? Bool ?? true
    }
}
