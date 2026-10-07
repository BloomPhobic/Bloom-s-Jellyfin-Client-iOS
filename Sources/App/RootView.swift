import SwiftUI
import UIKit

struct RootView: View {
    @State private var didRunStartupChecks = false

    var body: some View {
        TabView {
            PlaybackTestView()
                .tabItem { Label("Play", systemImage: "play.rectangle") }
            ConnectionView()
                .tabItem { Label("Connection", systemImage: "network") }
            LogView()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .task {
            guard !didRunStartupChecks else { return }
            didRunStartupChecks = true
            logStartupInfo()
            KeychainCheck.run()
        }
    }

    private func logStartupInfo() {
        let log = AppLog.shared
        log.log("App started. \(AppInfo.versionDescription)")
        log.log("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        log.log("Bundle path: \(Bundle.main.bundlePath)")
    }
}
