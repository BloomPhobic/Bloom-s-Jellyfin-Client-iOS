import JellyfinAPI
import SwiftUI

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// Shows the technical details of an item's files and starts direct playback.
struct ItemDetailView: View {
    let client: JellyfinClient
    let userID: String
    let itemID: String

    @State private var item: BaseItemDto?
    @State private var errorMessage: String?
    @State private var playback: PlaybackRequest?
    @AppStorage(PlayerSettings.hdrPassthroughKey) private var hdrPassthrough = true
    @AppStorage(PlayerSettings.hardwareDecodingKey) private var hardwareDecoding = true

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let item {
                ForEach(Array((item.mediaSources ?? []).enumerated()), id: \.offset) { _, source in
                    sourceSection(item: item, source: source)
                }
                Section("Player options (apply on next play)") {
                    Toggle("HDR passthrough", isOn: $hdrPassthrough)
                    Toggle("Hardware decoding", isOn: $hardwareDecoding)
                }
            } else if errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle(item?.name ?? "Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playback) { request in
            PlayerView(request: request)
        }
    }

    @ViewBuilder
    private func sourceSection(item: BaseItemDto, source: MediaSourceInfo) -> some View {
        Section {
            Button {
                play(item: item, source: source)
            } label: {
                Label("Play (direct)", systemImage: "play.fill")
            }
            ForEach(Array(MediaSummary.lines(for: source).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text(source.name ?? "Media source")
        }
    }

    private func load() async {
        guard item == nil else { return }
        do {
            item = try await client.send(Paths.getItem(itemID: itemID, userID: userID)).value
        } catch {
            errorMessage = "Could not load item: \(error.localizedDescription)"
            AppLog.shared.log(errorMessage ?? "", level: .error)
        }
    }

    private func play(item: BaseItemDto, source: MediaSourceInfo) {
        let request = Paths.getVideoStream(
            itemID: itemID,
            parameters: .init(isStatic: true, mediaSourceID: source.id)
        )
        guard let url = client.url(with: request, queryAPIKey: true) else {
            errorMessage = "Could not build the stream URL."
            return
        }
        let log = AppLog.shared
        log.log("Play: \(item.name ?? itemID) [\(source.name ?? "source")]")
        for line in MediaSummary.lines(for: source) {
            log.log("  \(line)")
        }
        log.log("  Options: HDR passthrough \(hdrPassthrough ? "on" : "off"), hardware decoding \(hardwareDecoding ? "on" : "off")")
        playback = PlaybackRequest(url: url, title: item.name ?? "")
    }
}

/// Human-readable lines describing a media source, used on screen and in the log.
enum MediaSummary {
    static func lines(for source: MediaSourceInfo) -> [String] {
        var lines: [String] = []
        var header = "Container: \(source.container ?? "?")"
        if let bitrate = source.bitrate {
            header += ", \(bitrate / 1_000_000) Mbps"
        }
        if let size = source.size {
            header += ", " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        lines.append(header)

        for stream in source.mediaStreams ?? [] {
            guard let type = stream.type else { continue }
            switch type {
            case .video:
                lines.append("Video: " + videoDescription(stream))
            case .audio:
                lines.append("Audio: " + (stream.displayTitle ?? stream.codec ?? "?") + defaultMarker(stream))
            case .subtitle:
                let external = stream.isExternal == true ? " [external]" : ""
                lines.append("Sub: " + (stream.displayTitle ?? stream.codec ?? "?") + " (\(stream.codec ?? "?"))" + external + defaultMarker(stream))
            default:
                break
            }
        }
        return lines
    }

    private static func videoDescription(_ stream: MediaStream) -> String {
        var parts: [String] = []
        parts.append([stream.codec?.uppercased(), stream.profile].compactMap { $0 }.joined(separator: " "))
        if let width = stream.width, let height = stream.height {
            parts.append("\(width)x\(height)")
        }
        if let bitDepth = stream.bitDepth {
            parts.append("\(bitDepth)-bit")
        }
        if let range = stream.videoRangeType {
            parts.append(range.rawValue)
        }
        if let dvProfile = stream.dvProfile {
            parts.append("DV profile \(dvProfile)")
        }
        if let fps = stream.realFrameRate ?? stream.averageFrameRate {
            parts.append(String(format: "%.3f fps", Double(fps)))
        }
        return parts.joined(separator: ", ")
    }

    private static func defaultMarker(_ stream: MediaStream) -> String {
        stream.isDefault == true ? " [default]" : ""
    }
}
