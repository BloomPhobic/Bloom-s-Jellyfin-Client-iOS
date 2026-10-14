# Bloom's Player

A lightweight native iOS client for [Jellyfin](https://jellyfin.org), written in SwiftUI. Media is direct-played through mpv, so the server never has to transcode.

**Status:** early development. Working so far:

- Direct play through mpv (hardware decoding, HDR10 passthrough, ASS/PGS subtitles, audio and subtitle track selection)
- Servers with several addresses (for example local network, Tailscale and a public domain): all are checked at the same time and the highest-priority one that answers is used, and they are checked again when the network changes
- Sign in with the server's user list, a username and password, or Quick Connect; the sign-in is kept in the Keychain
- Home screen with Continue watching, Next up, Recently added per library, and library shortcuts
- Library grids with sort and filters, show pages with seasons and episodes, search, and watched and favourite toggles
- Accent colour setting

Next up: the full player (controls, subtitle options, skip intro, autoplay, and syncing progress to the server).

## Install a development build

Each push to `main` is built on GitHub Actions and published as an unsigned `.ipa` on the [latest pre-release](../../releases/tag/latest). Install it with SideStore or LiveContainer, which sign it on the device.

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open JellyfinClient.xcodeproj
```

Server addresses and credentials are entered in the app at runtime. Nothing server-specific is stored in this repository.

## Using your own mpv or FFmpeg

Video playback uses [MPVKit](https://github.com/mpvkit/MPVKit) 1.0.0, the LGPL build (mpv 0.41.0, FFmpeg n8.1.2), which is linked statically into the app. The LGPL lets you replace these libraries with modified versions. Because the app's full source is in this repository, you can rebuild it against your own copy (on a Mac with Xcode):

1. Clone MPVKit at the tag the app uses: `git clone --branch 1.0.0 https://github.com/mpvkit/MPVKit`.
2. Make your changes to mpv, FFmpeg or the other libraries in MPVKit's build scripts, then build them: `make build platform=ios`. The libraries end up in `dist/release`.
3. In MPVKit's `Package.swift`, point each `binaryTarget` at the local file, for example `path: "dist/release/Libmpv.xcframework.zip"` (MPVKit's README shows the full list).
4. In this repository's `project.yml`, replace the MPVKit package's `url` and `exactVersion` with `path: ../MPVKit` (the folder you cloned).
5. Run `xcodegen generate`, then build the app in Xcode.
6. Install the result on your device with your own Apple ID, SideStore or LiveContainer. You can also fork this repository and let its GitHub Actions workflow build an unsigned `.ipa` for you.

The app's own licence (MPL 2.0) and the licence of every library it includes are listed in the app under Settings → About → Open-source licences.

## Privacy

The app talks only to the Jellyfin servers you add, and collects nothing. See the [privacy policy](https://bloomphobic.github.io/Bloom-s-Jellyfin-Client-iOS/privacy.html).

Jellyfin is a trademark of Jellyfin, Inc. This app is not affiliated with or endorsed by the Jellyfin project.
