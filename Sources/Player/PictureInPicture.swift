import AVKit
import CoreMedia
import CoreVideo
import Metal
import MetalPerformanceShaders
import UIKit

/// Picture in picture: after swiping home, the video keeps playing in a small floating window.
/// iOS's window can only show an AVFoundation layer, and mpv draws into its own Metal layer, so
/// each picture mpv draws is also copied (without the black bars, and smaller) into a sample
/// buffer layer that iOS shows in the window.
@MainActor
final class PictureInPicture: NSObject {
    /// Sits behind mpv's layer, where iOS can find it. Its picture is only seen in the window.
    let displayLayer: AVSampleBufferDisplayLayer
    private(set) var isActive = false

    private weak var player: MPVPlayer?
    private weak var videoLayer: MPVMetalLayer?
    private var controller: AVPictureInPictureController?
    private let timebase: CMTimebase?
    private let frames: FrameCopier?
    private var wasPossible = false
    private var lastPaused: Bool?
    private var lastSpeed: Double?
    private var lastPosition: Double = 0
    private var lastDuration: Double = 0

    override init() {
        // The window's progress bar follows this clock; it's kept in step with mpv in update().
        let layer = AVSampleBufferDisplayLayer()
        let timebase = try? CMTimebase(sourceClock: CMClock.hostTimeClock)
        displayLayer = layer
        self.timebase = timebase
        frames = timebase.map { FrameCopier(renderer: layer.sampleBufferRenderer, timebase: $0) }
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.controlTimebase = timebase
    }

    /// Called as the player starts, before mpv draws anything.
    func attach(_ player: MPVPlayer, layer: MPVMetalLayer) {
        guard controller == nil, let frames, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.player = player
        videoLayer = layer
        layer.onFrame = { drawable in frames.copy(drawable) }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = PlayerSettings.pictureInPicture
        self.controller = controller
    }

    func detach() {
        controller?.stopPictureInPicture()
        controller = nil
        videoLayer?.onFrame = nil
        frames?.isActive = false
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Going home now will open the floating window (so the video should keep running).
    var willStartAutomatically: Bool {
        guard let controller, let player else { return false }
        return controller.canStartPictureInPictureAutomaticallyFromInline && controller.isPictureInPicturePossible && !player.isPaused
    }

    func stop() {
        guard isActive else { return }
        controller?.stopPictureInPicture()
    }

    /// Called every half second: keeps the window's play button and progress bar in step with
    /// mpv, and tells the copier where the picture is (inside the black bars).
    func update() {
        guard let controller, let player else { return }
        if controller.canStartPictureInPictureAutomaticallyFromInline != PlayerSettings.pictureInPicture {
            controller.canStartPictureInPictureAutomaticallyFromInline = PlayerSettings.pictureInPicture
        }
        if controller.isPictureInPicturePossible != wasPossible {
            wasPossible = controller.isPictureInPicturePossible
            AppLog.shared.log("Picture in picture \(wasPossible ? "ready" : "not available")")
        }
        frames?.crop = player.pictureArea()

        let paused = player.isPaused || player.isBuffering
        let speed = player.isHoldingSpeed ? PlayerSettings.holdSpeed : player.speed
        let expected = lastPosition + (lastPaused == false ? 0.5 * (lastSpeed ?? 1) : 0)
        let changed = paused != lastPaused || speed != lastSpeed || player.duration != lastDuration
            || abs(player.position - expected) > 1.5
        lastPaused = paused
        lastSpeed = speed
        lastPosition = player.position
        lastDuration = player.duration
        guard changed, let timebase else { return }
        try? timebase.setTime(CMTime(seconds: player.position, preferredTimescale: 600))
        try? timebase.setRate(paused ? 0 : speed)
        controller.invalidatePlaybackState()
    }

    /// iOS calls the delegates on the main thread; this makes sure of it either way.
    nonisolated private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onMain {
            isActive = true
            frames?.isActive = true
            player?.setVideoEnabled(true)
            AppLog.shared.log("Picture in picture started")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onMain {
            ended()
            AppLog.shared.log("Picture in picture stopped")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        onMain {
            ended()
            AppLog.shared.log("Picture in picture didn't start: \(message)", level: .warning)
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player is still open behind the window, so there's nothing to rebuild.
        completionHandler(true)
    }

    private func ended() {
        isActive = false
        frames?.isActive = false
        // Closed from the window while in another app: stop, like leaving the app usually does.
        if UIApplication.shared.applicationState == .background {
            player?.setVideoEnabled(false, keepPlaying: false)
        }
    }
}

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        onMain {
            guard let player, player.isPaused == playing else { return }
            player.togglePause()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let duration = onMain { player?.duration ?? 0 }
        guard duration > 0 else { return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity) }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        onMain { player?.isPaused ?? true }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let seconds = skipInterval.seconds
        onMain { player?.seek(by: seconds) }
        completionHandler()
    }
}

/// Copies mpv's pictures into small pixel buffers for the floating window. Called on mpv's
/// render thread; the copy itself runs on the GPU.
final class FrameCopier: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let lock = NSLock()
    private var active = false
    private var area: CGRect?

    // Only touched on mpv's render thread.
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var scaler: MPSImageBilinearScale?
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var lastCopy: CFTimeInterval = 0
    private var reportedProblem = false  // guarded by lock

    /// The widest the copy gets; the window is never bigger than this.
    private static let maxWidth: CGFloat = 1280

    init(renderer: AVSampleBufferVideoRenderer, timebase: CMTimebase) {
        self.renderer = renderer
        self.timebase = timebase
    }

    /// While the window is open every picture is copied; otherwise two a second, so the window
    /// has a picture ready when it opens.
    var isActive: Bool {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    /// Where the video is in mpv's picture, in pixels (without the black bars). Nil means all of it.
    var crop: CGRect? {
        get { lock.withLock { area } }
        set { lock.withLock { area = newValue } }
    }

    func copy(_ drawable: CAMetalDrawable) {
        let now = CACurrentMediaTime()
        guard isActive || now - lastCopy > 0.5 else { return }
        lastCopy = now

        let source = drawable.texture
        guard !source.isFramebufferOnly, source.usage.contains(.shaderRead) else {
            report("mpv's picture can't be read")
            return
        }
        let whole = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let visible = (crop ?? whole).intersection(whole)
        guard visible.width >= 16, visible.height >= 16, setUp(source.device) else { return }
        let factor = min(1, Self.maxWidth / visible.width)
        let width = Int(visible.width * factor) & ~1
        let height = Int(visible.height * factor) & ~1
        guard let pixelBuffer = makePixelBuffer(width: width, height: height),
              let textureCache, let queue, let scaler else { return }

        // Write the same kind of colour values mpv wrote, so the picture isn't darkened or washed out.
        let format: MTLPixelFormat = source.pixelFormat == .bgra8Unorm_srgb ? .bgra8Unorm_srgb : .bgra8Unorm
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, format, width, height, 0, &cvTexture)
        guard let cvTexture, let target = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let scaleX = Double(width) / visible.width
        let scaleY = Double(height) / visible.height
        var transform = MPSScaleTransform(scaleX: scaleX, scaleY: scaleY, translateX: -visible.minX * scaleX, translateY: -visible.minY * scaleY)
        withUnsafePointer(to: &transform) { pointer in
            scaler.scaleTransform = pointer
            scaler.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: target)
            scaler.scaleTransform = nil
        }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime(cvTexture) {}
            guard let self else { return }
            if let error = buffer.error {
                self.report("copy failed: \(error.localizedDescription)")
                return
            }
            self.show(pixelBuffer)
        }
        commandBuffer.commit()
    }

    private func setUp(_ device: MTLDevice) -> Bool {
        if self.device === device { return true }
        var cache: CVMetalTextureCache?
        guard let queue = device.makeCommandQueue(),
              CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            report("couldn't set up the GPU copy")
            return false
        }
        self.device = device
        self.queue = queue
        textureCache = cache
        scaler = MPSImageBilinearScale(device: device)
        return true
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize.width != width || poolSize.height != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// Hands a finished picture to the window, to show straight away.
    private func show(_ pixelBuffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timebase.time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if renderer.status == .failed {
            report("window picture failed: \(renderer.error?.localizedDescription ?? "unknown")")
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    /// Logs the first problem only, so a failing copy doesn't fill the log 60 times a second.
    private func report(_ problem: String) {
        let first = lock.withLock {
            defer { reportedProblem = true }
            return !reportedProblem
        }
        guard first else { return }
        Task { @MainActor in
            AppLog.shared.log("Picture in picture: \(problem)", level: .warning)
        }
    }
}
