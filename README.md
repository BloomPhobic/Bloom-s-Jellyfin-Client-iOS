# Jellyfin Client for iOS

A lightweight native iOS client for [Jellyfin](https://jellyfin.org), written in SwiftUI. Media is direct-played through mpv, so the server never has to transcode.

**Status:** early development (build pipeline and connection checks only).

## Install a development build

Each push to `main` is built on GitHub Actions and published as an unsigned `.ipa` on the [latest pre-release](../../releases/tag/latest). Install it with SideStore or LiveContainer, which sign it on the device.

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
open JellyfinClient.xcodeproj
```

Server addresses and credentials are entered in the app at runtime. Nothing server-specific is stored in this repository.
