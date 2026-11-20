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

/// The avatar button on Home: switch account, add one, or sign out.
struct AccountMenu: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        Menu {
            Section("Accounts") {
                ForEach(store.accounts) { account in
                    Button {
                        store.switchAccount(to: account)
                    } label: {
                        if account.userID == store.session?.userID {
                            Label(account.userName, systemImage: "checkmark")
                        } else {
                            Text(account.userName)
                        }
                    }
                }
            }
            Button {
                store.isAddingAccount = true
            } label: {
                Label("Add account", systemImage: "person.badge.plus")
            }
            if let session = store.session {
                Button(role: .destructive) {
                    Task { await store.signOut() }
                } label: {
                    Label("Sign out \(session.userName)", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            AccountAvatar(
                name: store.session?.userName ?? "?",
                imageURL: store.session.flatMap { store.userImageURL(userID: $0.userID, tag: $0.imageTag) }
            )
        }
        .accessibilityLabel("Account")
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
