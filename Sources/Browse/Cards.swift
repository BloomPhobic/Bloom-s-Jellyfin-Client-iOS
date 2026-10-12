import JellyfinAPI
import SwiftUI
import UIKit

/// Loads images with a memory cache and a disk cache. Image URLs include the image tag,
/// which changes when the image does, so cached copies never need revalidating.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024, directory: nil)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private init() {
        memory.countLimit = 300
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) {
            return hit
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
            memory.setObject(image, forKey: url as NSURL)
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
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ImageCache.shared.load(url)
        }
    }
}

/// Image in a fixed aspect ratio, cropped to fit, with rounded corners.
struct ArtworkFrame<Decoration: View>: View {
    let url: URL?
    let aspectRatio: CGFloat
    @ViewBuilder var decoration: Decoration

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { RemoteImage(url: url) }
            .overlay { decoration }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension ArtworkFrame where Decoration == EmptyView {
    init(url: URL?, aspectRatio: CGFloat) {
        self.init(url: url, aspectRatio: aspectRatio) { EmptyView() }
    }
}

/// Watched tick, or the number of unwatched episodes, in the top corner of a card.
struct WatchBadge: View {
    let item: BaseItemDto

    var body: some View {
        Group {
            if item.isPlayed {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .padding(5)
                    .background(Circle().fill(Color.accentColor))
            } else if let count = item.userData?.unplayedItemCount, count > 0, item.type != .episode, item.type != .movie {
                Text(verbatim: "\(count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .foregroundStyle(.white)
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
                        Rectangle().fill(.black.opacity(0.5))
                        Rectangle().fill(Color.accentColor)
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
                .font(.caption)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            ArtworkFrame(url: api.imageURL(Artwork.landscape(item), maxWidth: 600), aspectRatio: 16 / 9) {
                ZStack {
                    WatchBadge(item: item)
                    ProgressOverlay(item: item)
                }
            }
            Text(title)
                .font(.caption)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
