import SwiftUI

@main
struct JellyfinClientApp: App {
    @State private var session = SessionStore()
    @AppStorage(Appearance.accentKey) private var accentHex = Appearance.defaultAccentHex

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Appearance.color(hex: accentHex))
        }
    }
}
