import SwiftUI

/// The open-source software built into the app, each with its licence and a link to its source.
struct LicensesView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let url: String
        var id: String { name }
    }

    private static let app = Component(
        name: "Bloom's Player",
        license: "Mozilla Public License 2.0",
        url: "https://github.com/BloomPhobic/Bloom-s-Jellyfin-Client-iOS"
    )

    private static let components: [Component] = [
        Component(name: "Jellyfin Swift SDK", license: "Mozilla Public License 2.0", url: "https://github.com/jellyfin/jellyfin-sdk-swift"),
        Component(name: "Get", license: "MIT", url: "https://github.com/kean/Get"),
        Component(name: "SwiftNIO Transport Services", license: "Apache License 2.0", url: "https://github.com/apple/swift-nio-transport-services"),
        Component(name: "MPVKit", license: "LGPL 3.0", url: "https://github.com/mpvkit/MPVKit"),
        Component(name: "mpv", license: "LGPL 2.1 or later", url: "https://github.com/mpv-player/mpv"),
        Component(name: "FFmpeg", license: "LGPL 2.1 or later", url: "https://ffmpeg.org"),
        Component(name: "libplacebo", license: "LGPL 2.1 or later", url: "https://code.videolan.org/videolan/libplacebo"),
        Component(name: "libass", license: "ISC", url: "https://github.com/libass/libass"),
        Component(name: "FreeType", license: "FreeType License", url: "https://freetype.org"),
        Component(name: "FriBidi", license: "LGPL 2.1 or later", url: "https://github.com/fribidi/fribidi"),
        Component(name: "HarfBuzz", license: "MIT (Old MIT)", url: "https://github.com/harfbuzz/harfbuzz"),
        Component(name: "libunibreak", license: "zlib", url: "https://github.com/adah1972/libunibreak"),
        Component(name: "uchardet", license: "MPL 1.1 / LGPL 2.1 or later", url: "https://www.freedesktop.org/wiki/Software/uchardet/"),
        Component(name: "libbluray", license: "LGPL 2.1 or later", url: "https://code.videolan.org/videolan/libbluray"),
        Component(name: "dav1d", license: "BSD 2-Clause", url: "https://code.videolan.org/videolan/dav1d"),
        Component(name: "uavs3d", license: "BSD 3-Clause", url: "https://github.com/uavs3/uavs3d"),
        Component(name: "libdovi", license: "MIT", url: "https://github.com/quietvoid/dovi_tool"),
        Component(name: "Little CMS", license: "MIT", url: "https://github.com/mm2/Little-CMS"),
        Component(name: "MoltenVK", license: "Apache License 2.0", url: "https://github.com/KhronosGroup/MoltenVK"),
        Component(name: "shaderc", license: "Apache License 2.0", url: "https://github.com/google/shaderc"),
        Component(name: "OpenSSL", license: "Apache License 2.0", url: "https://www.openssl.org"),
        Component(name: "GnuTLS", license: "LGPL 2.1 or later", url: "https://gnutls.org"),
        Component(name: "Nettle", license: "LGPL 3.0 or later", url: "https://www.lysator.liu.se/~nisse/nettle/"),
        Component(name: "GMP", license: "LGPL 3.0 or later", url: "https://gmplib.org"),
    ]

    var body: some View {
        List {
            Section {
                row(Self.app)
            } footer: {
                Text("The app's own source code.")
            }
            Section {
                ForEach(Self.components) { row($0) }
            } header: {
                Text("Built with")
            } footer: {
                Text("Video playback uses the LGPL build of mpv and FFmpeg. Each link leads to the project's source code and full licence text.")
            }
        }
        .themedBackground()
        .navigationTitle("Open-source licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ component: Component) -> some View {
        Link(destination: URL(string: component.url)!) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: component.name)
                    .foregroundStyle(Theme.text)
                Text(verbatim: component.license)
                    .font(.caption)
                    .foregroundStyle(Theme.text2)
            }
        }
    }
}
