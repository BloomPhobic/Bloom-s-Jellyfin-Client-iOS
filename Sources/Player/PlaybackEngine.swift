import Foundation

/// An audio or subtitle track offered by a playback engine.
struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let title: String
    let isSelected: Bool
}

/// A subtitle kept as its own file next to the video (an .srt or .ass beside the .mkv), so it
/// isn't inside the video stream and has to be given to the player separately.
struct ExternalSubtitle {
    let url: URL
    let title: String
    let language: String?
    let isDefault: Bool

    /// The file format to ask the server for: the original for formats the player reads, SRT
    /// (converted by the server) for other text formats. Picture subtitles are left out.
    static func format(_ stream: MediaStream) -> String? {
        switch stream.codec?.lowercased() {
        case "subrip", "srt": return "srt"
        case "ass": return "ass"
        case "ssa": return "ssa"
        case "webvtt", "vtt": return "vtt"
        default: return stream.isTextSubtitleStream == true ? "srt" : nil
        }
    }

    /// The external subtitle streams of a media source, with the format to fetch each in.
    static func streams(_ source: MediaSourceInfo?) -> [(stream: MediaStream, index: Int, format: String)] {
        (source?.mediaStreams ?? []).compactMap { stream in
            guard stream.type == .subtitle, stream.isExternal == true,
                  let index = stream.index, let format = format(stream) else { return nil }
            return (stream, index, format)
        }
    }

    init(url: URL, stream: MediaStream) {
        self.url = url
        title = stream.displayTitle ?? stream.title ?? stream.language ?? "External"
        language = stream.language
        isDefault = stream.isDefault == true
    }
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

    static let zoomToFillKey = "player.zoomToFill"

    /// Crop the picture to fill the screen instead of showing black bars. Pinch in the player to change.
    static var zoomToFill: Bool {
        get { UserDefaults.standard.bool(forKey: zoomToFillKey) }
        set { UserDefaults.standard.set(newValue, forKey: zoomToFillKey) }
    }

    static let backgroundAudioKey = "player.backgroundAudio"

    /// Keep the sound playing when the phone is locked or another app is opened.
    static var backgroundAudio: Bool {
        UserDefaults.standard.bool(forKey: backgroundAudioKey)
    }

    static let autoplayNextKey = "player.autoplayNext"

    /// Count down and play the next episode automatically; when off, the card waits for a tap.
    static var autoplayNext: Bool {
        UserDefaults.standard.object(forKey: autoplayNextKey) as? Bool ?? true
    }
}
