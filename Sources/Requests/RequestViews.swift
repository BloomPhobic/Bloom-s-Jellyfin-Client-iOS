import SwiftUI

/// Search the request server and ask for something that isn't on the Jellyfin server.
struct RequestSearchView: View {
    @Environment(SessionStore.self) private var store
    @State var query: String
    @State private var results: [SeerrResult] = []
    @State private var searchedTerm = ""
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var reload = 0
    @State private var justRequested: Set<String> = []
    @State private var seasonTarget: SeerrResult?
    @State private var message: String?

    init(term: String) {
        _query = State(initialValue: term)
    }

    private var client: SeerrClient? { SeerrClient(userID: store.session?.userID) }

    var body: some View {
        List {
            ForEach(results) { result in
                row(result).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .overlay {
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if client == nil {
                ContentUnavailableView("Requests are off", systemImage: "tray", description: Text("Add the request server in Settings → Requests."))
            } else if let errorMessage {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if results.isEmpty && !isSearching && searchedTerm == term && !term.isEmpty {
                ContentUnavailableView.search(text: term)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, anime")
        .navigationTitle("Request")
        .toolbar {
            NavigationLink {
                MyRequestsView().tabBarClearance()
            } label: {
                Image(systemName: "list.bullet")
            }
        }
        .task(id: "\(query)|\(reload)") {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search()
        }
        .sheet(isPresented: $showLogin) {
            SeerrLoginSheet(userID: store.session?.userID, defaultName: store.session?.userName ?? "") {
                reload += 1
            }
        }
        .sheet(item: $seasonTarget) { target in
            SeasonPicker(result: target) { done in
                seasonTarget = nil
                if done { markRequested(target) }
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ result: SeerrResult) -> some View {
        HStack(spacing: 12) {
            ArtworkFrame(url: result.posterURL, aspectRatio: 2 / 3)
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text([result.mediaType == "tv" ? "Show" : "Movie", result.year].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 8)
            if result.isAvailable {
                Text("On the server").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
            } else if result.isRequested || justRequested.contains(result.id) {
                Label("Requested", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            } else {
                Button("Request") { tapRequest(result) }
                    .font(.system(size: 14, weight: .bold))
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        }
    }

    private func tapRequest(_ result: SeerrResult) {
        if result.mediaType == "tv" {
            seasonTarget = result
            return
        }
        Task {
            do {
                try await client?.request(result, seasons: nil)
                markRequested(result)
            } catch {
                handle(error)
            }
        }
    }

    private func markRequested(_ result: SeerrResult) {
        justRequested.insert(result.id)
        message = "Requested “\(result.displayTitle)”."
    }

    private func handle(_ error: Error) {
        AppLog.shared.log("Request failed: \(error.localizedDescription)", level: .error)
        if case SeerrError.notSignedIn = error {
            showLogin = true
        } else {
            message = error.localizedDescription
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client else { return }
        guard !term.isEmpty else {
            results = []
            searchedTerm = ""
            return
        }
        guard client.isSignedIn else {
            showLogin = true
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await client.search(term)
            guard !Task.isCancelled else { return }
            results = found
            searchedTerm = term
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, !AuthWatch.isCancellation(error) else { return }
            if case SeerrError.notSignedIn = error {
                showLogin = true
            } else {
                errorMessage = error.localizedDescription
            }
            AppLog.shared.log("Request search failed: \(error.localizedDescription)", level: .error)
        }
    }
}

/// Pick which seasons to ask for.
private struct SeasonPicker: View {
    @Environment(SessionStore.self) private var store
    let result: SeerrResult
    let done: (Bool) -> Void

    @State private var seasons: [SeerrSeason] = []
    @State private var chosen: Set<Int> = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.text2)
                }
                ForEach(seasons, id: \.seasonNumber) { season in
                    Button {
                        if chosen.contains(season.seasonNumber) { chosen.remove(season.seasonNumber) } else { chosen.insert(season.seasonNumber) }
                    } label: {
                        HStack {
                            Text(season.name ?? "Season \(season.seasonNumber)").foregroundStyle(Theme.text)
                            Spacer()
                            if chosen.contains(season.seasonNumber) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            }
            .overlay { if isLoading { ProgressView() } }
            .navigationTitle(result.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Request") { Task { await submit() } }.disabled(chosen.isEmpty)
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        defer { isLoading = false }
        do {
            seasons = try await SeerrClient(userID: store.session?.userID)?.seasons(tvID: result.tmdbID) ?? []
            chosen = Set(seasons.map(\.seasonNumber))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() async {
        do {
            try await SeerrClient(userID: store.session?.userID)?.request(result, seasons: chosen.sorted())
            done(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SeerrLoginSheet: View {
    let userID: String?
    @State var defaultName: String
    let signedIn: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $defaultName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } footer: {
                    Text("Use your Jellyfin login. The password is only sent to the request server; the app keeps just the session.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                Button {
                    Task { await signIn() }
                } label: {
                    if isWorking { ProgressView() } else { Text("Sign in") }
                }
                .disabled(defaultName.isEmpty || password.isEmpty || isWorking)
            }
            .navigationTitle("Request server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func signIn() async {
        guard let client = SeerrClient(userID: userID) else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.signIn(username: defaultName, password: password)
            signedIn()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MyRequestsView: View {
    @Environment(SessionStore.self) private var store
    @State private var requests: [SeerrMyRequest] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        List {
            ForEach(requests) { request in
                HStack(spacing: 12) {
                    ArtworkFrame(url: request.posterURL, aspectRatio: 2 / 3)
                        .frame(width: 50)
                    Text(request.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(request.statusLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .themedBackground()
        .overlay {
            if let errorMessage {
                ErrorState(message: errorMessage) { await load() }
            } else if isLoading && requests.isEmpty {
                ProgressView()
            } else if requests.isEmpty {
                ContentUnavailableView("No requests yet", systemImage: "tray")
            }
        }
        .navigationTitle("My requests")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let client = SeerrClient(userID: store.session?.userID), client.isSignedIn else {
            errorMessage = SeerrError.notSignedIn.localizedDescription + " Open Request from Search once to sign in."
            return
        }
        do {
            requests = try await client.myRequests()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SeerrSettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage(SeerrClient.urlKey) private var url = ""
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var signedInRefresh = 0

    var body: some View {
        List {
            Section {
                TextField("https://requests.example.com", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await test() }
                } label: {
                    if isTesting { ProgressView() } else { Text("Test") }
                }
                .disabled(ServerProbe.normalize(url) == nil || isTesting)
                if let testResult {
                    Text(testResult).font(.footnote).foregroundStyle(Theme.text2)
                }
            } header: {
                Text("Request server (Seerr)")
            } footer: {
                Text("Leave empty to turn requests off. People sign in with their Jellyfin login the first time they request something.")
            }

            if let client = SeerrClient(userID: store.session?.userID) {
                Section {
                    NavigationLink("My requests") { MyRequestsView().tabBarClearance() }
                    if client.isSignedIn {
                        Button("Sign out of request server", role: .destructive) {
                            client.signOut()
                            signedInRefresh += 1
                        }
                    }
                }
                .id(signedInRefresh)
            }
        }
        .navigationTitle("Requests")
    }

    private func test() async {
        guard let base = ServerProbe.normalize(url) else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            testResult = "Connected. Seerr \(try await SeerrClient.test(base))"
        } catch {
            testResult = "Couldn't connect: \(error.localizedDescription)"
        }
    }
}
