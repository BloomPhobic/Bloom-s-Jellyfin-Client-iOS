import SwiftUI

/// The server's accounts, view only: who they are, when they last signed in and were active.
struct AdminUsersView: View {
    @Environment(SessionStore.self) private var store
    @State private var users: [UserRow] = []
    @State private var loaded = false
    @State private var errorMessage: String?

    private struct UserRow: Identifiable {
        let id: String
        let name: String
        let isAdmin: Bool
        let isDisabled: Bool
        let lastActive: Date?
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && users.isEmpty {
                    Text("No users.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                let admins = users.filter { $0.isAdmin }
                let others = users.filter { !$0.isAdmin }
                if !admins.isEmpty {
                    AdminGroupTitle(text: "Admins · \(admins.count)")
                    ForEach(admins) { userRow($0) }
                }
                if !others.isEmpty {
                    AdminGroupTitle(text: "Users · \(others.count)")
                    ForEach(others) { userRow($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func userRow(_ user: UserRow) -> some View {
        HStack(spacing: 12) {
            Text(String(user.name.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(user.isAdmin ? Theme.onAccent : Theme.accent)
                .frame(width: 42, height: 42)
                .background(Circle().fill(user.isAdmin ? Theme.accent : Theme.accent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(user.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("Last active " + AdminDate.ago(user.lastActive))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 0)
            if user.isDisabled { badge("Disabled", .red) }
        }
        .adminCard()
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func load() async {
        do {
            let rows = try await store.adminJSON("Users") as? [[String: Any]] ?? []
            var found: [UserRow] = []
            for row in rows {
                guard let id = row["Id"] as? String else { continue }
                let policy = row["Policy"] as? [String: Any]
                let last = AdminDate.parse(row["LastActivityDate"] as? String) ?? AdminDate.parse(row["LastLoginDate"] as? String)
                found.append(UserRow(
                    id: id,
                    name: row["Name"] as? String ?? "User",
                    isAdmin: policy?["IsAdministrator"] as? Bool ?? false,
                    isDisabled: policy?["IsDisabled"] as? Bool ?? false,
                    lastActive: last
                ))
            }
            users = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
            errorMessage = nil
            loaded = true
        } catch {
            guard !isCancelled(error) else { return }
            errorMessage = "Couldn't load the users: \(error.localizedDescription)"
            loaded = true
        }
    }
}
