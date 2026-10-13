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
    @Environment(\.scenePhase) private var scenePhase
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
        .overlay(alignment: .top) {
            StatusBanner()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.appDidEnterBackground()
            case .active: store.appDidBecomeActive()
            default: break
            }
        }
        .onChange(of: store.isAddingAccount) {
            // The login screen for another account shows on Home.
            if store.isAddingAccount {
                selection = .home
                homeNavigator.path = []
            }
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
    /// Hides the system tab bar; the floating one replaces it.
    func tabBarSpace() -> some View {
        toolbar(.hidden, for: .tabBar)
    }
}

extension View {
    /// Blank space under a page, as tall as the floating tab bar, so the bar never covers the
    /// last items. Applied to every page (pushed pages don't inherit it from their stack).
    func tabBarClearance() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 84)
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
                    .foregroundStyle(isSelected ? Theme.accent : Theme.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.accent.opacity(0.15))
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

/// A slim banner under the status bar: no connection, server unreachable (retrying), or a notice
/// such as an expired sign-in. Tap to retry or dismiss.
private struct StatusBanner: View {
    @Environment(SessionStore.self) private var store

    private enum Kind: Equatable {
        case offline
        case unreachable
        case notice(String)
    }

    private var kind: Kind? {
        if let notice = store.notice { return .notice(notice) }
        if store.isOffline { return .offline }
        // With no address at all, the full "Not connected" screen shows instead.
        if store.isServerUnreachable && store.route != nil { return .unreachable }
        return nil
    }

    var body: some View {
        Group {
            if let kind {
                Button {
                    switch kind {
                    case .notice: store.notice = nil
                    case .offline, .unreachable: Task { await store.resolve() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(kind))
                        Text(text(kind))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if case .notice = kind {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.text3)
                        } else if store.isResolving {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(Theme.text)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.raised2))
                    .overlay(Capsule().strokeBorder(tint(kind).opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: kind) {
                    // Notices go away on their own after a while.
                    if case .notice = kind {
                        try? await Task.sleep(for: .seconds(8))
                        if !Task.isCancelled { store.notice = nil }
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: kind)
    }

    private func text(_ kind: Kind) -> String {
        switch kind {
        case .offline: return "No internet connection"
        case .unreachable: return "Can't reach \(store.server?.name ?? "the server") · retrying"
        case .notice(let message): return message
        }
    }

    private func icon(_ kind: Kind) -> String {
        switch kind {
        case .offline: return "wifi.slash"
        case .unreachable: return "exclamationmark.icloud"
        case .notice: return "person.crop.circle.badge.exclamationmark"
        }
    }

    private func tint(_ kind: Kind) -> Color {
        switch kind {
        case .offline, .unreachable: return .orange
        case .notice: return Theme.accent
        }
    }
}
