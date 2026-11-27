import SwiftUI

/// Every Seerr request, like Settings > Requests: Pending (the default), Approved and Denied tabs
/// with counts. Pending ones can be approved or declined here.
struct AdminRequestsView: View {
    @Environment(SessionStore.self) private var store
    @State private var requests: [SeerrMyRequest] = []
    @State private var filter: SeerrMyRequest.Filter = .pending
    @State private var note: String?
    @State private var loaded = false
    @State private var message: String?

    private var seerr: SeerrClient? { SeerrClient(userID: store.session?.userID) }
    private var shown: [SeerrMyRequest] { requests.filter { filter.matches($0.status) } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let note {
                    Text(note).font(.system(size: 14)).foregroundStyle(Theme.text2)
                } else if loaded && shown.isEmpty {
                    Text("Nothing \(filter.rawValue.lowercased()).").font(.system(size: 14)).foregroundStyle(Theme.text2)
                }
                ForEach(shown) { request in
                    row(request)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !requests.isEmpty {
                Picker("", selection: $filter) {
                    ForEach(SeerrMyRequest.Filter.allCases, id: \.self) { option in
                        Text("\(option.rawValue) (\(requests.filter { option.matches($0.status) }.count))").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.background)
            }
        }
        .themedBackground()
        .tabBarClearance()
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toast($message)
    }

    private func row(_ request: SeerrMyRequest) -> some View {
        HStack(spacing: 12) {
            ArtworkFrame(url: request.posterURL, aspectRatio: 2 / 3).frame(width: 44)
            Text(request.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Spacer()
            if filter == .pending {
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
        }
        .adminCard()
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
            requests = try await seerr.myRequests()
            note = nil
        } catch {
            guard !isCancelled(error) else { return }
            note = error.localizedDescription
        }
    }

    private func answer(_ request: SeerrMyRequest, approve: Bool) async {
        do {
            try await seerr?.resolve(request.id, approve: approve)
            // Reload so the request moves to its new tab and the counts update.
            message = approve ? "Approved “\(request.title)”" : "Declined “\(request.title)”"
            await load()
        } catch SeerrError.http(403) {
            message = "Your Seerr account can't manage requests."
        } catch {
            message = error.localizedDescription
        }
    }
}
