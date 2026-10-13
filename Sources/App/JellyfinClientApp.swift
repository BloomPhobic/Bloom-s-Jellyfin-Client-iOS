import SwiftUI

@main
struct JellyfinClientApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .modifier(AccentTint())
                .preferredColorScheme(.dark)
        }
    }
}
