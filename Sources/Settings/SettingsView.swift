import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage(Appearance.accentKey) private var accentHex = Appearance.defaultAccentHex
    @AppStorage(PlayerSettings.hdrPassthroughKey) private var hdrPassthrough = true
    @AppStorage(PlayerSettings.hardwareDecodingKey) private var hardwareDecoding = true
    @AppStorage(PlayerSettings.autoplayNextKey) private var autoplayNext = true

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    NavigationLink {
                        ConnectionView()
                    } label: {
                        LabeledContent("Connection") {
                            if let route = store.route {
                                Label(route.kind.label, systemImage: route.kind.systemImage)
                            } else {
                                Text(store.server == nil ? "No server" : "Not connected")
                            }
                        }
                    }
                    if let session = store.session {
                        LabeledContent("Signed in as", value: session.userName)
                    }
                }

                Section("Accent colour") {
                    accentSwatches
                    ColorPicker("Custom colour", selection: accentBinding, supportsOpacity: false)
                }

                Section {
                    Toggle("Autoplay next episode", isOn: $autoplayNext)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Near the end of an episode, a card shows the next one. With autoplay on, it plays after a 10-second countdown; with it off, it waits for you to tap Play now.")
                }

                Section {
                    Toggle("HDR passthrough", isOn: $hdrPassthrough)
                    Toggle("Hardware decoding", isOn: $hardwareDecoding)
                } header: {
                    Text("Video")
                } footer: {
                    Text("Changes apply the next time a video starts.")
                }

                Section("Diagnostics") {
                    NavigationLink("Log") {
                        LogView()
                    }
                    Button("Run Keychain test") {
                        KeychainCheck.run()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "\(AppInfo.version) (build \(AppInfo.build))")
                }
            }
            .navigationTitle("Settings")
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
