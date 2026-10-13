import JellyfinAPI
import SwiftUI
import UIKit

/// Loads images with a memory cache and a disk cache. Image URLs include the image tag,
/// which changes when the image does, so cached copies never need revalidating.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    static let limitKey = "imageCache.limitMB"
    static let limitOptions = [100, 300, 500, 1000]

    private let diskCache = URLCache(
        memoryCapacity: 16 * 1024 * 1024,
        diskCapacity: (UserDefaults.standard.object(forKey: limitKey) as? Int ?? 300) * 1024 * 1024,
        directory: nil
    )
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = diskCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        // Decoded images, bounded by their size in memory (about 80 MB), so big libraries can't pile up.
        memory.totalCostLimit = 80 * 1024 * 1024
        memory.countLimit = 400
    }

    /// The most the image cache may use on disk. Above it, iOS drops the oldest images by itself.
    func setLimit(megabytes: Int) {
        diskCache.diskCapacity = megabytes * 1024 * 1024
        AppLog.shared.log("Image cache limit: \(megabytes) MB")
    }

    /// Bytes used on disk by downloaded images.
    var diskUsage: Int { diskCache.currentDiskUsage }

    func clear() {
        memory.removeAllObjects()
        diskCache.removeAllCachedResponses()
        AppLog.shared.log("Image cache cleared")
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) {
            return hit
        }
        // Artwork saved with a download.
        if url.isFileURL {
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
            if let image {
                memory.setObject(image, forKey: url as NSURL)
            }
            return image
        }
        guard let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        let data = result.0
        let image = await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.preparingForDisplay()
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }
}

/// An image from the server that fills its frame. Shows a grey placeholder until it loads.
struct RemoteImage: View {
    let url: URL?

    @State private var image: UIImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.raised2)
            if url == nil {
                // The item has no artwork on the server.
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.text3.opacity(0.6))
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let loaded = await ImageCache.shared.load(url)
            // Fade in images that came from the network; cached ones are already showing.
            if image == nil {
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            } else {
                image = loaded
            }
        }
    }
}

/// Image in a fixed aspect ratio, cropped to fit, with rounded corners.
struct ArtworkFrame<Decoration: View>: View {
    let url: URL?
    let aspectRatio: CGFloat
    var cornerRadius: CGFloat = 12
    @ViewBuilder var decoration: Decoration

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .overlay { decoration }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension ArtworkFrame where Decoration == EmptyView {
    init(url: URL?, aspectRatio: CGFloat, cornerRadius: CGFloat = 12) {
        self.init(url: url, aspectRatio: aspectRatio, cornerRadius: cornerRadius) { EmptyView() }
    }
}

/// Watched tick, or the number of unwatched episodes, in the top corner of a card.
struct WatchBadge: View {
    let item: BaseItemDto

    var body: some View {
        Group {
            if item.isPlayed {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.accent))
            } else if let count = item.userData?.unplayedItemCount, count > 0, item.type != .episode, item.type != .movie {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Theme.accent))
            }
        }
        .foregroundStyle(Theme.onAccent)
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// Thin progress bar along the bottom of a card for partly watched items.
struct ProgressOverlay: View {
    let item: BaseItemDto

    var body: some View {
        if let percent = item.userData?.playedPercentage, percent > 0, !item.isPlayed {
            VStack {
                Spacer()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.scrim)
                        Rectangle().fill(Theme.accent)
                            .frame(width: proxy.size.width * CGFloat(min(percent, 100) / 100))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

/// Portrait poster with the title underneath.
struct PosterCard: View {
    let item: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkFrame(url: api.imageURL(Artwork.poster(item), maxWidth: 300), aspectRatio: 2 / 3) {
                WatchBadge(item: item)
            }
            Text(item.name ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if let label = item.episodeLabel {
            return label
        }
        return item.productionYear.map { String($0) } ?? " "
    }
}

/// Wide 16:9 card: an episode still or backdrop, with a progress bar.
struct LandscapeCard: View {
    let item: BaseItemDto
    let api: LibraryAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkFrame(url: api.imageURL(Artwork.landscape(item), maxWidth: 600), aspectRatio: 16 / 9, cornerRadius: 14) {
                ZStack {
                    WatchBadge(item: item)
                    ProgressOverlay(item: item)
                }
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        item.type == .episode ? (item.seriesName ?? item.name ?? "") : (item.name ?? "")
    }

    private var subtitle: String? {
        guard item.type == .episode else {
            return item.productionYear.map { String($0) }
        }
        return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }
}
