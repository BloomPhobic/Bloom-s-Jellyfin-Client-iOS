import Foundation
import JellyfinAPI
import Observation
import UIKit

/// The small preview pictures Jellyfin makes along a video ("trickplay"), shown above the seek bar
/// while scrubbing. The server stores them as grids of thumbnails in a few large images (tiles);
/// the tiles are fetched once the player opens and cut up on the phone.
@MainActor
@Observable
final class TrickplayThumbnails {
    private let client: JellyfinClient
    private let itemID: String
    private let mediaSourceID: String?
    private let width: Int
    private let height: Int
    private let columns: Int
    private let rows: Int
    private let count: Int
    /// Seconds between thumbnails.
    private let interval: Double

    private var tiles: [Int: CGImage] = [:]
    @ObservationIgnored private var requested: Set<Int> = []

    /// Nil when the server has no thumbnails for this video.
    init?(item: BaseItemDto, mediaSourceID: String?, client: JellyfinClient) {
        guard let itemID = item.id, let manifest = item.trickplay, !manifest.isEmpty else { return nil }
        let resolutions = mediaSourceID.flatMap { manifest[$0] } ?? (manifest.count == 1 ? manifest.values.first : nil)
        // The smallest size that is still sharp on a phone; usually there is only 320.
        let options = (resolutions ?? [:]).values.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        guard let info = options.first(where: { ($0.width ?? 0) >= 320 }) ?? options.last,
              let width = info.width, let height = info.height,
              let columns = info.tileWidth, let rows = info.tileHeight,
              let count = info.thumbnailCount, let interval = info.interval,
              width > 0, height > 0, columns > 0, rows > 0, count > 0, interval > 0 else { return nil }
        self.client = client
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.count = count
        self.interval = Double(interval) / 1000
    }

    private var tileCount: Int {
        (count + columns * rows - 1) / (columns * rows)
    }

    /// Width divided by height, for laying out the preview before it loads.
    var aspectRatio: CGFloat {
        CGFloat(width) / CGFloat(height)
    }

    /// The picture for a moment in the video, or nil while its tile is still loading.
    func thumbnail(at seconds: Double) -> UIImage? {
        let index = min(max(Int(seconds / interval), 0), count - 1)
        let perTile = columns * rows
        let tile = index / perTile
        guard let image = tiles[tile] else {
            load(tile)
            return nil
        }
        let within = index % perTile
        let rect = CGRect(x: (within % columns) * width, y: (within / columns) * height, width: width, height: height)
        return image.cropping(to: rect).map { UIImage(cgImage: $0) }
    }

    /// Fetches every tile in the background, one after another, so scrubbing never waits.
    /// A two-hour film is usually under ten small images.
    func preload() async {
        for tile in 0..<tileCount {
            guard !Task.isCancelled else { return }
            await fetch(tile)
        }
    }

    private func load(_ tile: Int) {
        Task { await fetch(tile) }
    }

    private func fetch(_ tile: Int) async {
        guard !requested.contains(tile) else { return }
        requested.insert(tile)
        do {
            let request = Paths.getTrickplayTileImage(itemID: itemID, width: width, index: tile, mediaSourceID: mediaSourceID)
            let data = try await client.send(request).value
            let image = await Task.detached(priority: .utility) {
                UIImage(data: data)?.cgImage
            }.value
            if let image {
                tiles[tile] = image
            } else {
                requested.remove(tile)
            }
        } catch {
            requested.remove(tile)
            if tile == 0 {
                AppLog.shared.log("Preview thumbnails didn't load: \(error.localizedDescription)", level: .warning)
            }
        }
    }
}
