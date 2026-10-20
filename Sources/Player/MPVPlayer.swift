import AVFoundation
import Observation
import UIKit

/// mpv-backed playback engine. Owns the Metal layer mpv renders into.
@MainActor
@Observable
final class MPVPlayer: PlaybackEngine {
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var errorMessage: String?
    private(set) var stats: [(String, String)] = []
    private(set) var isAtEnd = false
    /// Seconds of video downloaded ahead of the playback position.
    private(set) var bufferedSeconds: Double = 0
    private(set) var subtitleDelay: Double = 0
    /// The chosen playback speed. Kept for the next episode in the same player.
    private(set) var speed: Double = 1
    /// The edge of the screen is held down, so playback runs at the hold speed for now.
    private(set) var isHoldingSpeed = false

    let layer = MPVMetalLayer()
    @ObservationIgnored private var core: MPVCore?

    private static let observedProperties = ["track-list", "pause", "paused-for-cache", "duration"]

    func start(url: URL, startSeconds: Double = 0) {
        guard core == nil else { return }
        configureAudioSession()
        // MoltenVK sends PQ output but doesn't ask iOS for EDR (HDR) mode, so request it here.
        layer.wantsExtendedDynamicRangeContent = PlayerSettings.hdrPassthrough

        var options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", PlayerSettings.hardwareDecoding ? "videotoolbox" : "no"),
            ("target-colorspace-hint", PlayerSettings.hdrPassthrough ? "yes" : "no"),
            ("video-rotate", "no"),
            ("keep-open", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("subs-fallback", "yes"),
            ("embeddedfonts", "yes"),
        ]
        if startSeconds > 0 {
            options.append(("start", String(format: "%.3f", startSeconds)))
        }

        let onEvent: @Sendable (MPVCore.Event) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
        }

        guard let newCore = MPVCore(
            layer: layer,
            options: options,
            observedProperties: Self.observedProperties,
            logLevel: "info",
            onEvent: onEvent
        ) else {
            errorMessage = "mpv failed to start."
            AppLog.shared.log("mpv failed to start", level: .error)
            return
        }
        core = newCore
        applySubtitleStyle()
        newCore.command(["loadfile", url.absoluteString, "replace"])
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        guard let core else { return }
        core.shutdown()
        self.core = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        AppLog.shared.log("Player closed")
    }

    func load(url: URL, startSeconds: Double) {
        guard let core else { return }
        // "start" is an option, so it applies to the next file and has to be reset for each load.
        core.setString("start", startSeconds > 0 ? String(format: "%.3f", startSeconds) : "none")
        errorMessage = nil
        isBuffering = true
        isAtEnd = false
        position = startSeconds
        duration = 0
        core.command(["loadfile", url.absoluteString, "replace"])
        core.setString("pause", "no")
    }

    // MARK: - Subtitles

    /// Applies the size and style from Settings. These affect plain subtitles (SRT and similar);
    /// ASS subtitles keep their own styling except for size.
    func applySubtitleStyle() {
        guard let core else { return }
        let size = SubtitleSettings.size
        let style = SubtitleSettings.style
        let options: [(String, String)] = [
            ("sub-scale", String(size.scale)),
            ("sub-bold", SubtitleSettings.bold ? "yes" : "no"),
            ("sub-border-size", String(style.borderSize)),
            ("sub-border-style", style == .box ? "background-box" : "outline-and-shadow"),
            ("sub-back-color", "#B0000000"),
        ]
        for (name, value) in options {
            let status = core.setString(name, value)
            if status < 0 {
                AppLog.shared.log("mpv: couldn't set \(name)=\(value): \(MPVCore.errorString(status))", level: .warning)
            }
        }
    }

    func setSubtitleDelay(_ seconds: Double) {
        guard let core else { return }
        let rounded = (seconds * 10).rounded() / 10
        core.setString("sub-delay", String(rounded))
        subtitleDelay = rounded
    }

    // MARK: - Speed

    func setSpeed(_ value: Double) {
        speed = value
        if !isHoldingSpeed {
            core?.setString("speed", String(value))
        }
    }

    /// Plays at the hold speed until `endHoldSpeed`, then goes back to the chosen speed.
    func beginHoldSpeed() {
        guard let core, !isHoldingSpeed, !isPaused else { return }
        isHoldingSpeed = true
        core.setString("speed", String(PlayerSettings.holdSpeed))
    }

    func endHoldSpeed() {
        guard isHoldingSpeed else { return }
        isHoldingSpeed = false
        core?.setString("speed", String(speed))
    }

    // MARK: - Controls

    func togglePause() {
        guard let core else { return }
        core.setString("pause", core.flag("pause") ? "no" : "yes")
        refreshState()
    }

    func seek(to seconds: Double) {
        core?.command(["seek", String(seconds), "absolute"])
    }

    func seek(by seconds: Double) {
        core?.command(["seek", String(seconds), "relative"])
    }

    func selectAudio(_ id: Int) {
        core?.setString("aid", String(id))
        refreshTracks()
    }

    func selectSubtitle(_ id: Int?) {
        core?.setString("sid", id.map { String($0) } ?? "no")
        refreshTracks()
    }

    /// Turns video output off while the app is in the background, to avoid a black screen on return.
    func setVideoEnabled(_ enabled: Bool) {
        guard let core else { return }
        if !enabled {
            core.setString("pause", "yes")
        }
        core.setString("vid", enabled ? "auto" : "no")
    }

    // MARK: - State

    func refreshState() {
        guard let core else { return }
        // Only assign on change: every assignment notifies SwiftUI, even with the same value.
        let paused = core.flag("pause")
        let buffering = core.flag("paused-for-cache") || core.flag("seeking") || core.string("time-pos") == nil
        let newPosition = core.double("time-pos") ?? position
        let newDuration = core.double("duration") ?? duration
        let atEnd = core.flag("eof-reached")
        if atEnd != isAtEnd { isAtEnd = atEnd }
        if paused != isPaused { isPaused = paused }
        if buffering != isBuffering { isBuffering = buffering }
        if newPosition != position { position = newPosition }
        if newDuration != duration { duration = newDuration }
        // Whole seconds only, so this doesn't redraw the player on every tiny change.
        let buffered = (core.double("demuxer-cache-duration") ?? 0).rounded(.down)
        if buffered != bufferedSeconds { bufferedSeconds = buffered }
    }

    private func refreshTracks() {
        guard let core, let count = core.string("track-list/count").flatMap({ Int($0) }) else { return }
        var audio: [MediaTrack] = []
        var subtitles: [MediaTrack] = []
        for index in 0..<count {
            let prefix = "track-list/\(index)/"
            guard let type = core.string(prefix + "type"),
                  let id = core.string(prefix + "id").flatMap({ Int($0) }) else { continue }
            var parts = [core.string(prefix + "lang"), core.string(prefix + "title"), core.string(prefix + "codec")]
            if let channels = core.string(prefix + "demux-channel-count") {
                parts.append("\(channels)ch")
            }
            let title = "#\(id) " + parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let track = MediaTrack(id: id, title: title, isSelected: core.flag(prefix + "selected"))
            if type == "audio" {
                audio.append(track)
            } else if type == "sub" {
                subtitles.append(track)
            }
        }
        if audio != audioTracks { audioTracks = audio }
        if subtitles != subtitleTracks { subtitleTracks = subtitles }
    }

    func refreshStats() {
        guard let core else {
            stats = []
            return
        }
        func value(_ name: String) -> String {
            core.string(name) ?? "–"
        }
        func mbps(_ name: String) -> String {
            core.double(name).map { String(format: "%.1f Mbps", $0 * 8 / 1_000_000) } ?? "–"
        }
        func bitsMbps(_ name: String) -> String {
            core.double(name).map { String(format: "%.1f Mbps", $0 / 1_000_000) } ?? "–"
        }
        let screen = UIScreen.main
        stats = [
            ("Video", "\(value("video-codec"))"),
            ("Format", "\(value("video-params/w"))x\(value("video-params/h")) \(value("video-params/pixelformat"))"),
            ("HW decode", value("hwdec-current")),
            ("Source color", "\(value("video-params/primaries")) / \(value("video-params/gamma")), peak \(value("video-params/sig-peak"))"),
            ("After filters", "\(value("video-out-params/primaries")) / \(value("video-out-params/gamma"))"),
            ("EDR", String(format: "headroom %.2f (max %.2f), layer %@", screen.currentEDRHeadroom, screen.potentialEDRHeadroom, layer.wantsExtendedDynamicRangeContent ? "on" : "off")),
            ("FPS", "\(value("container-fps")) → \(value("estimated-vf-fps"))"),
            ("Dropped", "decoder \(value("decoder-frame-drop-count")), output \(value("frame-drop-count"))"),
            ("Audio", "\(value("audio-codec-name")), \(value("audio-params/channel-count"))ch → \(value("current-ao"))"),
            ("Bitrate", "video \(bitsMbps("video-bitrate")), audio \(bitsMbps("audio-bitrate"))"),
            ("Network", "\(mbps("cache-speed")), buffered \(value("demuxer-cache-duration"))s"),
        ]
    }

    func logStats() {
        refreshStats()
        AppLog.shared.log("Stats at \(Int(position))s:")
        for (label, text) in stats {
            AppLog.shared.log("  \(label): \(text)")
        }
    }

    // MARK: - Events

    private func handle(_ event: MPVCore.Event) {
        switch event {
        case .log(let level, let prefix, let text):
            let appLevel: AppLog.Entry.Level
            switch level {
            case "fatal", "error": appLevel = .error
            case "warn": appLevel = .warning
            default: appLevel = .info
            }
            AppLog.shared.log("mpv[\(prefix)] \(text)", level: appLevel)
        case .propertyChanged(let name):
            if name == "track-list" {
                refreshTracks()
            } else {
                refreshState()
            }
        case .fileLoaded:
            AppLog.shared.log("mpv: file loaded")
            refreshTracks()
            refreshState()
        case .endFile(let error):
            if let error {
                errorMessage = error
                AppLog.shared.log("Playback failed: \(error)", level: .error)
            }
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            AppLog.shared.log("Audio session setup failed: \(error.localizedDescription)", level: .warning)
        }
    }
}

/// CAMetalLayer with two workarounds from the MPVKit demo.
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK can set drawableSize to 1x1 to force a presentation, which causes flicker.
    // https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR (HDR) mode only activates when this is set on the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}
