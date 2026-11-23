import SwiftUI

/// Seerr requests waiting for an answer, with Approve and Decline.
struct AdminRequestsView: View {
    @Environment(SessionStore.self) private var store
    @State private var pending: [SeerrMyRequest] = []
    @State private var note: String?
    @State private var loaded = false
    @State private var message: String?

    private var seerr: SeerrClient? { SeerrClient(userID: store.session?.userID) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let note {
                    Text(note).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && pending.isEmpty {
                    Text("Nothing waiting.").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                ForEach(pending) { request in
                    HStack(spacing: 12) {
                        ArtworkFrame(url: request.posterURL, aspectRatio: 2 / 3).frame(width: 44)
                        Text(request.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Spacer()
                        Button { Task { await answer(request, approve: true) } } label: {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Approve")
                        Button { Task { await answer(request, approve: false) } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Decline")
                    }
                    .adminCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toast($message)
    }

    private func load() async {
        defer { loaded = true }
        guard let seerr else {
            note = "Set up the request server under Settings → Requests."
            return
        }
        guard seerr.isSignedIn else {
            note = "Sign in to the request server under Settings → Requests."
            return
        }
        do {
            pending = try await seerr.myRequests(filter: "pending")
            note = nil
        } catch {
            guard !isCancelled(error) else { return }
            note = error.localizedDescription
        }
    }

    private func answer(_ request: SeerrMyRequest, approve: Bool) async {
        do {
            try await seerr?.resolve(request.id, approve: approve)
            pending.removeAll { $0.id == request.id }
            message = approve ? "Approved “\(request.title)”" : "Declined “\(request.title)”"
        } catch SeerrError.http(403) {
            message = "Your Seerr account can't manage requests."
        } catch {
            message = error.localizedDescription
        }
    }
}
