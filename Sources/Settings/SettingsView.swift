import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @State private var imageCacheBytes = 0
    @AppStorage(ImageCache.limitKey) private var imageCacheLimit = 300
    @AppStorage(DownloadStore.cellularKey) private var downloadOverCellular = false
    @State private var confirmDeleteDownloads = false

    private var accentHex: String {
        get { AccentStore.shared.hex }
        nonmutating set { AccentStore.shared.hex = newValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    NavigationLink {
                        ConnectionView()
                            .tabBarClearance()
                    } label: {
                        LabeledContent("Connection") {
                            if let route = store.route {
                                Label(route.kind.label, systemImage: route.kind.systemImage)
                            } else {
                                Text(store.server == nil ? "No server" : "Not connected")
                            }
                        }
                    }
                }

                if !store.accounts.isEmpty {
                    AccountsSection()
                }

                Section("Accent colour") {
                    accentSwatches
                    ColorPicker("Custom colour", selection: accentBinding, supportsOpacity: false)
                }

                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                            .tabBarClearance()
                    } label: {
                        Label("Playback", systemImage: "play.rectangle")
                    }
                } footer: {
                    Text("Autoplay, picture in picture, playing when locked, HDR and decoding.")
                }

                Section {
                    LabeledContent("Downloads", value: DownloadStore.format(DownloadStore.shared.usedBytes(userID: store.session?.userID)))
                    Toggle("Download over mobile data", isOn: $downloadOverCellular)
                        .onChange(of: downloadOverCellular) {
                            DownloadStore.shared.cellularSettingChanged()
                        }
                    if !DownloadStore.shared.list(for: store.session?.userID).isEmpty {
                        Button("Delete all downloads", role: .destructive) {
                            confirmDeleteDownloads = true
                        }
                        .confirmationDialog("Delete all downloads?", isPresented: $confirmDeleteDownloads, titleVisibility: .visible) {
                            Button("Delete all", role: .destructive) {
                                DownloadStore.shared.deleteAll(userID: store.session?.userID)
                            }
                        } message: {
                            Text("Everything this account downloaded is removed from this iPhone. Nothing changes on the server.")
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Downloads are the original files, so big movies can take several GB. With mobile data off, downloads wait for Wi-Fi.")
                }

                Section {
                    LabeledContent("Image cache", value: ByteCountFormatter.string(fromByteCount: Int64(imageCacheBytes), countStyle: .file))
                    Picker("Keep up to", selection: $imageCacheLimit) {
                        ForEach(ImageCache.limitOptions, id: \.self) { megabytes in
                            Text(megabytes >= 1000 ? "\(megabytes / 1000) GB" : "\(megabytes) MB").tag(megabytes)
                        }
                    }
                    .onChange(of: imageCacheLimit) {
                        ImageCache.shared.setLimit(megabytes: imageCacheLimit)
                        imageCacheBytes = ImageCache.shared.diskUsage
                    }
                    Button("Clear image cache") {
                        ImageCache.shared.clear()
                        imageCacheBytes = ImageCache.shared.diskUsage
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Posters and backdrops are kept for faster loading. Past the limit, the oldest are removed automatically. Clearing only frees space; they download again when needed.")
                }

                Section {
                    LabeledContent("Version", value: "\(AppInfo.version) (build \(AppInfo.build))")
                    Link(destination: AppInfo.sourceURL) {
                        Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: AppInfo.privacyURL) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        LicensesView()
                            .tabBarClearance()
                    } label: {
                        Label("Open-source licences", systemImage: "doc.text")
                    }
                    NavigationLink {
                        DiagnosticsView()
                            .tabBarClearance()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Bloom's Player, a client for Jellyfin, by BloomPhobic. Jellyfin is a trademark of Jellyfin, Inc.; this app is not affiliated with or endorsed by the Jellyfin project.")
                }
            }
            .themedBackground()
            .tabBarClearance()
            .navigationTitle("Settings")
            .onAppear { imageCacheBytes = ImageCache.shared.diskUsage }
        }
    }

    private var accentSwatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(Appearance.presets, id: \.hex) { preset in
                Button {
                    accentHex = preset.hex
                } label: {
                    Circle()
                        .fill(Appearance.color(hex: preset.hex))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if accentHex.uppercased() == preset.hex {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.name)
            }
        }
        .padding(.vertical, 4)
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Appearance.color(hex: accentHex) },
            set: { accentHex = $0.hexString }
        )
    }
}

/// Everything about how videos play.
struct PlaybackSettingsView: View {
    @AppStorage(PlayerSettings.hdrPassthroughKey) private var hdrPassthrough = true
    @AppStorage(PlayerSettings.hardwareDecodingKey) private var hardwareDecoding = true
    @AppStorage(PlayerSettings.autoplayNextKey) private var autoplayNext = true
    @AppStorage(PlayerSettings.backgroundAudioKey) private var backgroundAudio = false
    @AppStorage(PlayerSettings.pictureInPictureKey) private var pictureInPicture = true

    var body: some View {
        List {
            Section {
                Toggle("Autoplay next episode", isOn: $autoplayNext)
            } footer: {
                Text("Near the end of an episode, a card shows the next one. With autoplay on, it plays after a 10-second countdown; with it off, it waits for you to tap Play now.")
            }

            Section {
                Toggle("Picture in picture", isOn: $pictureInPicture)
            } footer: {
                Text("Swipe home while a video plays and it carries on in a small window you can move around.")
            }

            Section {
                Toggle("Keep playing when locked", isOn: $backgroundAudio)
            } footer: {
                Text("The sound carries on when you lock the phone or switch apps, and you can pause or skip from the lock screen. When off, playback pauses.")
            }

            Section {
                Toggle("HDR passthrough", isOn: $hdrPassthrough)
                Toggle("Hardware decoding", isOn: $hardwareDecoding)
            } header: {
                Text("Video")
            } footer: {
                Text("Changes apply the next time a video starts.")
            }
        }
        .themedBackground()
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The log and checks, for tracking down problems.
struct DiagnosticsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink("Log") {
                    LogView()
                        .tabBarClearance()
                }
                Button("Run Keychain test") {
                    KeychainCheck.run()
                }
            } footer: {
                Text("The log records what the app and the player did, to send along when something goes wrong.")
            }
        }
        .themedBackground()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
