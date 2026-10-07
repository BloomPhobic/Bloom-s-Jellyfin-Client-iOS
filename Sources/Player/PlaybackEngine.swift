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

    func togglePause()
    func seek(to seconds: Double)
    func seek(by seconds: Double)
    func selectAudio(_ id: Int)
    /// Pass nil to turn subtitles off.
    func selectSubtitle(_ id: Int?)
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
}
