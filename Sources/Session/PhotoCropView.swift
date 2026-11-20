import SwiftUI
import UIKit

/// A picked photo waiting to be cropped.
struct PhotoToCrop: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Move and zoom a photo under a round window, like a messaging app's profile picture editor.
/// Done hands back the square the circle covers, at most 512 px.
struct PhotoCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onDone: (UIImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxZoom: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 24, proxy.size.height - 220)
            let centre = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2 - 10)
            let cropRect = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            let total = Self.baseScale(image, side: side) * zoom

            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * total, height: image.size.height * total)
                    .position(x: centre.x + offset.width, y: centre.y + offset.height)
                    .allowsHitTesting(false)
                // Dim everything outside the round window.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addEllipse(in: cropRect)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Circle()
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .position(centre)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = clamp(CGSize(width: committedOffset.width + value.translation.width,
                                              height: committedOffset.height + value.translation.height), side: side, zoom: zoom)
                    }
                    .onEnded { _ in committedOffset = offset }
                    .simultaneously(with:
                        MagnifyGesture()
                            .onChanged { value in
                                zoom = min(max(committedZoom * value.magnification, 1), Self.maxZoom)
                                offset = clamp(offset, side: side, zoom: zoom)
                            }
                            .onEnded { _ in
                                committedZoom = zoom
                                committedOffset = offset
                            }
                    )
            )
            .overlay(alignment: .top) {
                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Text("Move and scale")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Choose") {
                        onDone(cropped(side: side))
                    }
                    .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, proxy.safeAreaInsets.top + 12)
            }
        }
        // One coordinate space for the picture, the dimming and the ring: the whole screen.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Scale at which the photo's short side exactly fills the window.
    private static func baseScale(_ image: UIImage, side: CGFloat) -> CGFloat {
        side / max(min(image.size.width, image.size.height), 1)
    }

    /// Keeps the photo covering the whole window.
    private func clamp(_ proposed: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
        let total = Self.baseScale(image, side: side) * zoom
        let maxX = max((image.size.width * total - side) / 2, 0)
        let maxY = max((image.size.height * total - side) / 2, 0)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    private func cropped(side: CGFloat) -> UIImage {
        let total = Self.baseScale(image, side: side) * zoom
        let visible = side / total
        let originX = image.size.width / 2 - offset.width / total - visible / 2
        let originY = image.size.height / 2 - offset.height / total - visible / 2
        let output = min(visible, 512)
        let factor = output / visible
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            image.draw(in: CGRect(x: -originX * factor, y: -originY * factor,
                                  width: image.size.width * factor, height: image.size.height * factor))
        }
    }
}

/// The profile picture full screen. Tap anywhere to close.
struct AvatarPreview: View {
    let url: URL?
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteImage(url: url)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(20)
            }
            .accessibilityLabel("Close")
        }
        .preferredColorScheme(.dark)
    }
}
