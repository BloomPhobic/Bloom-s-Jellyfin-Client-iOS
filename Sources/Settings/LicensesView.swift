import SwiftUI

/// The open-source software built into the app, each with its licence and a link to its source.
struct LicensesView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let url: String
        /// The licence text (or the project's copyright notice) bundled with the app.
        let file: String
        var id: String { name }
    }

    private static let app = Component(
        name: "Bloom's Player",
        license: "Mozilla Public License 2.0",
        url: "https://github.com/BloomPhobic/Bloom-s-Jellyfin-Client-iOS",
        file: "License-MPL-2.0"
    )

    /// How to rebuild the app with a modified mpv or FFmpeg, as the LGPL allows.
    static let relinkURL = URL(string: "https://github.com/BloomPhobic/Bloom-s-Jellyfin-Client-iOS#using-your-own-mpv-or-ffmpeg")!

    private static let components: [Component] = [
        Component(name: "Jellyfin Swift SDK", license: "Mozilla Public License 2.0", url: "https://github.com/jellyfin/jellyfin-sdk-swift", file: "License-MPL-2.0"),
        Component(name: "Get", license: "MIT", url: "https://github.com/kean/Get", file: "Notice-Get"),
        Component(name: "SwiftNIO Transport Services", license: "Apache License 2.0", url: "https://github.com/apple/swift-nio-transport-services", file: "License-Apache-2.0"),
        Component(name: "MPVKit", license: "LGPL 3.0", url: "https://github.com/mpvkit/MPVKit", file: "License-LGPL-3.0"),
        Component(name: "mpv", license: "LGPL 2.1 or later", url: "https://github.com/mpv-player/mpv", file: "License-LGPL-2.1"),
        Component(name: "FFmpeg", license: "LGPL 2.1 or later", url: "https://ffmpeg.org", file: "License-LGPL-2.1"),
        Component(name: "libplacebo", license: "LGPL 2.1 or later", url: "https://code.videolan.org/videolan/libplacebo", file: "License-LGPL-2.1"),
        Component(name: "libass", license: "ISC", url: "https://github.com/libass/libass", file: "Notice-libass"),
        Component(name: "FreeType", license: "FreeType License", url: "https://freetype.org", file: "Notice-FreeType"),
        Component(name: "FriBidi", license: "LGPL 2.1 or later", url: "https://github.com/fribidi/fribidi", file: "License-LGPL-2.1"),
        Component(name: "HarfBuzz", license: "MIT (Old MIT)", url: "https://github.com/harfbuzz/harfbuzz", file: "Notice-HarfBuzz"),
        Component(name: "libunibreak", license: "zlib", url: "https://github.com/adah1972/libunibreak", file: "Notice-libunibreak"),
        Component(name: "uchardet", license: "MPL 1.1 / LGPL 2.1 or later", url: "https://www.freedesktop.org/wiki/Software/uchardet/", file: "License-LGPL-2.1"),
        Component(name: "libbluray", license: "LGPL 2.1 or later", url: "https://code.videolan.org/videolan/libbluray", file: "License-LGPL-2.1"),
        Component(name: "dav1d", license: "BSD 2-Clause", url: "https://code.videolan.org/videolan/dav1d", file: "Notice-dav1d"),
        Component(name: "uavs3d", license: "BSD 3-Clause", url: "https://github.com/uavs3/uavs3d", file: "Notice-uavs3d"),
        Component(name: "libdovi", license: "MIT", url: "https://github.com/quietvoid/dovi_tool", file: "Notice-libdovi"),
        Component(name: "Little CMS", license: "MIT", url: "https://github.com/mm2/Little-CMS", file: "Notice-LittleCMS"),
        Component(name: "MoltenVK", license: "Apache License 2.0", url: "https://github.com/KhronosGroup/MoltenVK", file: "License-Apache-2.0"),
        Component(name: "shaderc", license: "Apache License 2.0", url: "https://github.com/google/shaderc", file: "License-Apache-2.0"),
        Component(name: "OpenSSL", license: "Apache License 2.0", url: "https://www.openssl.org", file: "License-Apache-2.0"),
        Component(name: "GnuTLS", license: "LGPL 2.1 or later", url: "https://gnutls.org", file: "License-LGPL-2.1"),
        Component(name: "Nettle", license: "LGPL 3.0 or later", url: "https://www.lysator.liu.se/~nisse/nettle/", file: "License-LGPL-3.0"),
        Component(name: "GMP", license: "LGPL 3.0 or later", url: "https://gmplib.org", file: "License-LGPL-3.0"),
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
                Text("Tap a project for its licence and a link to its source code.")
            }
            Section {
                Link(destination: Self.relinkURL) {
                    Text("Use your own mpv or FFmpeg")
                        .foregroundStyle(Theme.text)
                }
                NavigationLink("GNU GPL 3.0 (part of LGPL 3.0)") {
                    LicenseTextView(title: "GNU GPL 3.0", file: "License-GPL-3.0", sourceURL: nil)
                }
            } header: {
                Text("LGPL")
            } footer: {
                Text("Video playback uses the LGPL build of mpv and FFmpeg. The app is open source, so you can rebuild it with your own modified versions of these libraries; the link explains how.")
            }
        }
        .themedBackground()
        .navigationTitle("Open-source licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ component: Component) -> some View {
        NavigationLink {
            LicenseTextView(title: component.name, file: component.file, sourceURL: URL(string: component.url))
        } label: {
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

/// One licence text bundled with the app, with a link to the project's source code.
private struct LicenseTextView: View {
    let title: String
    let file: String
    let sourceURL: URL?

    private var text: String {
        Bundle.main.url(forResource: file, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The licence text is missing from this build."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let sourceURL {
                    Link("Source code", destination: sourceURL)
                }
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .themedBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
