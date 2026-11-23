import SwiftUI

/// A user's round profile picture, or their initial on a tinted circle.
struct AccountAvatar: View {
    let name: String
    let imageURL: URL?
    var size: CGFloat = 40
    var isSelected = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.raised2)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Theme.text)
            if imageURL != nil {
                RemoteImage(url: imageURL)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
        )
    }
}

/// The avatar button on Home: opens the account switcher.
struct AccountMenu: View {
    @Environment(SessionStore.self) private var store
    @State private var showSwitcher = false

    var body: some View {
        Button {
            AppLog.shared.log("Account button tapped")
            showSwitcher = true
        } label: {
            AccountAvatar(
                name: store.session?.userName ?? "?",
                imageURL: store.session.flatMap { store.userImageURL(userID: $0.userID, tag: $0.imageTag) }
            )
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
        .sheet(isPresented: $showSwitcher) {
            AccountSwitcherSheet()
                .environment(store)
        }
    }
}

/// Every account as a card: tap one to switch, add another, or sign out of the current one.
private struct AccountSwitcherSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showAuthorize = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Accounts")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(CircleButtonStyle(size: 34))
                .accessibilityLabel("Close")
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.accounts) { account in
                        accountCard(account)
                    }
                    addCard
                    authorizeCard
                }
            }
            .scrollIndicators(.hidden)
            if let session = store.session {
                Button {
                    dismiss()
                    Task { await store.signOut() }
                } label: {
                    Label("Sign out \(session.userName)", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.surface)
        .sheet(isPresented: $showAuthorize) {
            QuickConnectAuthorizeView()
                .environment(store)
        }
        .onAppear { AppLog.shared.log("Account sheet shown") }
    }

    private var authorizeCard: some View {
        Button {
            showAuthorize = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.raised2))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Authorize Quick Connect")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Sign in a TV or another device")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    private func accountCard(_ account: SessionStore.SavedSession) -> some View {
        let isCurrent = account.userID == store.session?.userID
        return Button {
            if !isCurrent { store.switchAccount(to: account) }
            dismiss()
        } label: {
            HStack(spacing: 14) {
                AccountAvatar(
                    name: account.userName,
                    imageURL: store.userImageURL(userID: account.userID, tag: account.imageTag),
                    size: 52,
                    isSelected: isCurrent
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.userName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(isCurrent ? "Signed in now" : "Tap to switch")
                        .font(.system(size: 13))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text3)
                }
                Spacer(minLength: 0)
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: isCurrent ? 22 : 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isCurrent ? Theme.accent.opacity(0.7) : Theme.line, lineWidth: isCurrent ? 1.5 : 1))
        }
        .buttonStyle(PressableStyle())
    }

    private var addCard: some View {
        Button {
            dismiss()
            store.isAddingAccount = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.accent.opacity(0.15)))
                Text("Add account")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Settings: the account in use as a card (picture and password inside), then the other accounts
/// to switch to, and Add account.
struct AccountsSection: View {
    @Environment(SessionStore.self) private var store

    private var others: [SessionStore.SavedSession] {
        store.accounts.filter { $0.userID != store.session?.userID }
    }

    var body: some View {
        Group {
            if let current = store.session {
                Section {
                    NavigationLink {
                        ProfileView()
                            .tabBarClearance()
                    } label: {
                        HStack(spacing: 14) {
                            AccountAvatar(
                                name: current.userName,
                                imageURL: store.userImageURL(userID: current.userID, tag: current.imageTag),
                                size: 52,
                                isSelected: true
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(current.userName)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text("Picture and password")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.text3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button("Sign out", role: .destructive) {
                            Task { await store.remove(current) }
                        }
                    }
                } header: {
                    Text("Signed in as")
                }
            }

            Section {
                ForEach(others) { account in
                    Button {
                        store.switchAccount(to: account)
                    } label: {
                        HStack(spacing: 12) {
                            AccountAvatar(
                                name: account.userName,
                                imageURL: store.userImageURL(userID: account.userID, tag: account.imageTag),
                                size: 34
                            )
                            Text(account.userName)
                                .foregroundStyle(Theme.text)
                            Spacer()
                            Text("Switch")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .swipeActions {
                        Button("Sign out", role: .destructive) {
                            Task { await store.remove(account) }
                        }
                    }
                }
                Button {
                    store.isAddingAccount = true
                } label: {
                    Label("Add account", systemImage: "person.badge.plus")
                }
            } header: {
                Text(others.isEmpty ? "Accounts" : "Other accounts")
            } footer: {
                Text("Swipe an account to sign it out. Each account keeps its own watch progress.")
            }
        }
    }
}
