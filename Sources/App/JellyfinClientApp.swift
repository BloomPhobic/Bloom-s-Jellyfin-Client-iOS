import SwiftUI

@main
struct JellyfinClientApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()
    @AppStorage(Appearance.accentKey) private var accentHex = Appearance.defaultAccentHex

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Appearance.color(hex: accentHex))
                .preferredColorScheme(.dark)
                .onAppear(perform: Appearance.migrateDefault)
        }
    }
}
