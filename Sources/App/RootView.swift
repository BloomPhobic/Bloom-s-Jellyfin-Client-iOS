import SwiftUI
import UIKit

struct RootView: View {
    @Environment(SessionStore.self) private var store
    @State private var didRunStartupChecks = false
    @State private var homeNavigator = BrowseNavigator()
    @State private var searchNavigator = BrowseNavigator()

    var body: some View {
        TabView {
            NavigationStack(path: $homeNavigator.path) {
                SignedInGate { api in
                    HomeView(api: api)
                }
            }
            .environment(homeNavigator)
            .tabItem { Label("Home", systemImage: "house") }

            NavigationStack(path: $searchNavigator.path) {
                SignedInGate { api in
                    SearchView(api: api)
                }
            }
            .environment(searchNavigator)
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onChange(of: store.session?.userID) {
            // Pages from a previous sign-in (or server) shouldn't stay open.
            homeNavigator.path = []
            searchNavigator.path = []
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
