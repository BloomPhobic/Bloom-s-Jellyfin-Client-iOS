import SwiftUI
import UIKit

struct RootView: View {
    @Environment(SessionStore.self) private var store
    @State private var didRunStartupChecks = false

    var body: some View {
        TabView {
            NavigationStack {
                SignedInGate { api in
                    HomeView(api: api)
                }
            }
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack {
                SignedInGate { api in
                    SearchView(api: api)
                }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task {
            guard !didRunStartupChecks else { return }
            didRunStartupChecks = true
            logStartupInfo()
            KeychainCheck.run()
            await store.start()
        }
    }

    private func logStartupInfo() {
        let log = AppLog.shared
        log.log("App started. \(AppInfo.versionDescription)")
        log.log("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        log.log("Bundle path: \(Bundle.main.bundlePath)")
    }
}
