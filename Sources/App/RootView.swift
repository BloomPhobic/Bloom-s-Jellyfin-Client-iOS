import SwiftUI
import UIKit

enum AppTab: Hashable, CaseIterable {
    case home
    case search
    case settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    func icon(selected: Bool) -> String {
        switch self {
        case .home: return selected ? "house.fill" : "house"
        case .search: return "magnifyingglass"
        case .settings: return selected ? "gearshape.fill" : "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var store
    @State private var didRunStartupChecks = false
    @State private var selection: AppTab = .home
    @State private var homeNavigator = BrowseNavigator()
    @State private var searchNavigator = BrowseNavigator()

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $homeNavigator.path) {
                SignedInGate { api in
                    HomeView(api: api)
                }
            }
            .environment(homeNavigator)
            .tabBarSpace()
            .tag(AppTab.home)

            NavigationStack(path: $searchNavigator.path) {
                SignedInGate { api in
                    SearchView(api: api)
                }
            }
            .environment(searchNavigator)
            .tabBarSpace()
            .tag(AppTab.search)

            SettingsView()
                .tabBarSpace()
                .tag(AppTab.settings)
        }
        .overlay(alignment: .bottom) {
            FloatingTabBar(selection: $selection) { tab in
                // Tapping the current tab again goes back to its first page.
                withAnimation {
                    switch tab {
                    case .home: homeNavigator.path = []
                    case .search: searchNavigator.path = []
                    case .settings: break
                    }
                }
            }
            .ignoresSafeArea(.keyboard)
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

private extension View {
    /// Hides the system tab bar and keeps content clear of the floating one.
    func tabBarSpace() -> some View {
        toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 76)
            }
    }
}

/// The floating capsule tab bar. The highlight slides between tabs and the icon bounces when chosen.
private struct FloatingTabBar: View {
    @Binding var selection: AppTab
    let reselect: (AppTab) -> Void

    @Namespace private var highlight
    @State private var bounces: [AppTab: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let isSelected = tab == selection
                Button {
                    if isSelected {
                        reselect(tab)
                    } else {
                        bounces[tab, default: 0] += 1
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selection = tab
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon(selected: isSelected))
                            .font(.system(size: 19, weight: .semibold))
                            .symbolEffect(.bounce, value: bounces[tab, default: 0])
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : Theme.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.15))
                                .matchedGeometryEffect(id: "highlight", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(5)
        .frame(width: 300)
        .background(Capsule().fill(Theme.raised2.opacity(0.96)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .padding(.bottom, 6)
    }
}
