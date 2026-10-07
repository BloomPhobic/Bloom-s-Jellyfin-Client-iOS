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

    let layer = MPVMetalLayer()
    @ObservationIgnored private var core: MPVCore?

    private static let observedProperties = ["track-list", "pause", "paused-for-cache", "duration"]

    func start(url: URL) {
        guard core == nil else { return }
        configureAudioSession()

        let options: [(String, String)] = [
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
        isPaused = core.flag("pause")
        isBuffering = core.flag("paused-for-cache") || core.flag("seeking") || core.string("time-pos") == nil
        position = core.double("time-pos") ?? position
        duration = core.double("duration") ?? duration
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
        audioTracks = audio
        subtitleTracks = subtitles
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
            ("Output color", "\(value("video-out-params/primaries")) / \(value("video-out-params/gamma"))"),
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
                errorMessage = "Playback failed: \(error)"
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
