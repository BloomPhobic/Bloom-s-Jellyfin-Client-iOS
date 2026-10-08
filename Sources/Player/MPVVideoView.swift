import SwiftUI
import UIKit

/// Hosts the mpv Metal layer and starts playback once the view has a real size.
struct MPVVideoView: UIViewRepresentable {
    let player: MPVPlayer
    let url: URL

    func makeUIView(context: Context) -> MPVHostView {
        let view = MPVHostView(videoLayer: player.layer)
        view.onFirstLayout = { [player, url] in
            player.start(url: url)
        }
        return view
    }

    func updateUIView(_ uiView: MPVHostView, context: Context) {}
}

final class MPVHostView: UIView {
    private let videoLayer: CAMetalLayer
    var onFirstLayout: (@MainActor () -> Void)?

    init(videoLayer: CAMetalLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        backgroundColor = .black
        videoLayer.framebufferOnly = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let drawableSize = Self.fixedDrawableSize(screen: window?.screen, bounds: bounds, scale: scale)
        videoLayer.frame = Self.aspectFit(drawableSize, in: bounds)
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = drawableSize
        CATransaction.commit()

        if bounds.width > 1, bounds.height > 1, let start = onFirstLayout {
            onFirstLayout = nil
            start()
        }
    }

    /// mpv's MoltenVK output only reads the drawable size when video starts, so it never sees rotation.
    /// Keep the drawable fixed at the screen's landscape size, and keep the layer the same shape
    /// (letterboxed in portrait) so the picture is scaled, never stretched.
    private static func fixedDrawableSize(screen: UIScreen?, bounds: CGRect, scale: CGFloat) -> CGSize {
        let size = screen?.nativeBounds.size ?? CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let factor = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * factor
        let height = size.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
