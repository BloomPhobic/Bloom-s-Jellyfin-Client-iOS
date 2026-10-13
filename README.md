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

## Privacy

The app talks only to the Jellyfin servers you add, and collects nothing. See the [privacy policy](https://bloomphobic.github.io/Bloom-s-Jellyfin-Client-iOS/privacy.html).

Jellyfin is a trademark of Jellyfin, Inc. This app is not affiliated with or endorsed by the Jellyfin project.
