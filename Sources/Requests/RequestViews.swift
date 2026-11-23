import SwiftUI

extension View {
    /// A short message that slides in just above the page's bottom space and goes away by itself.
    func toast(_ text: Binding<String?>) -> some View {
        modifier(ToastModifier(text: text))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text {
                    Text(text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: text)
            .task(id: text) {
                guard text != nil else { return }
                try? await Task.sleep(for: .seconds(3.5))
                if !Task.isCancelled { text = nil }
            }
    }
}

/// Same size for every state so the list lines up; filled = you can tap it.
private struct StatePill: View {
    enum Kind { case action, requested, neutral }
    let title: String
    let icon: String?
    let kind: Kind

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
            Text(title)
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(kind == .action ? Theme.onAccent : kind == .requested ? Theme.accent : Theme.text3)
        .frame(width: 112, height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(kind == .action ? Theme.accent : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(kind == .action ? Color.clear : (kind == .requested ? Theme.accent.opacity(0.7) : Theme.line), lineWidth: 1))
    }
}

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
    @State private var detailTarget: SeerrResult?
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
            } else if term.isEmpty {
                ContentUnavailableView("Request something", systemImage: "magnifyingglass", description: Text("Search for a movie, show or anime."))
            } else if results.isEmpty && !isSearching && searchedTerm == term {
                ContentUnavailableView.search(text: term)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, anime")
        .navigationTitle("Request")
        .toolbar {
            NavigationLink {
                MyRequestsView().navigationTitle("My requests").tabBarClearance()
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
            SeasonPicker(result: target) { count in
                seasonTarget = nil
                if let count { markRequested(target, seasons: count) }
            }
        }
        .navigationDestination(item: $detailTarget) { target in
            RequestDetailView(result: target) { justRequested.insert($0.id) }
                .tabBarClearance()
        }
        .toast($message)
    }

    @ViewBuilder
    private func row(_ result: SeerrResult) -> some View {
        HStack(spacing: 12) {
            // Tapping the title area opens the detail page; the pill on the right requests.
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
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { detailTarget = result }
            .accessibilityAddTraits(.isButton)
            if result.isAvailable {
                StatePill(title: "On server", icon: "checkmark.circle", kind: .neutral)
            } else if result.isRequested || justRequested.contains(result.id) {
                StatePill(title: "Requested", icon: "checkmark", kind: .requested)
            } else {
                Button { tapRequest(result) } label: {
                    StatePill(title: "Request", icon: "plus", kind: .action)
                }
                .buttonStyle(PressableStyle())
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

    private func markRequested(_ result: SeerrResult, seasons: Int? = nil) {
        justRequested.insert(result.id)
        let what = seasons.map { $0 == 1 ? " (1 season)" : " (\($0) seasons)" } ?? ""
        message = "Requested “\(result.displayTitle)”\(what). It shows under My requests."
    }

    private func handle(_ error: Error) {
        AppLog.shared.log("Request failed: \(error.localizedDescription)", level: .error)
        if case SeerrError.notSignedIn = error {
            showLogin = true
        } else {
            message = "Couldn't send the request: \(error.localizedDescription)"
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

/// Backdrop, facts, overview and cast for one title, so you can tell it is the right one before requesting.
struct RequestDetailView: View {
    @Environment(SessionStore.self) private var store
    let result: SeerrResult
    /// Called after a successful request, so the list behind can show it as Requested.
    let onRequested: (SeerrResult) -> Void

    @State private var detail: SeerrDetail?
    @State private var errorMessage: String?
    @State private var requestedHere = false
    @State private var showSeasons = false
    @State private var message: String?

    private var status: Int { detail?.mediaInfo?.status ?? result.mediaInfo?.status ?? 0 }

    var body: some View {
        Group {
            if let errorMessage, detail == nil {
                ErrorState(message: errorMessage) { await load() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let backdrop = SeerrClient.image(detail?.backdropPath, "w780") {
                            ArtworkFrame(url: backdrop, aspectRatio: 16 / 9, cornerRadius: 14)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            ArtworkFrame(url: SeerrClient.image(detail?.posterPath ?? result.posterPath, "w342"), aspectRatio: 2 / 3)
                                .frame(width: 100)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(detail?.title ?? detail?.name ?? result.displayTitle)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Theme.text)
                                if !facts.isEmpty {
                                    Text(facts)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.text2)
                                }
                                if let genres = detail?.genres?.compactMap(\.name), !genres.isEmpty {
                                    Text(genres.joined(separator: " · "))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.text3)
                                }
                                stateButton.padding(.top, 4)
                            }
                        }
                        if let tagline = detail?.tagline, !tagline.isEmpty {
                            Text(tagline)
                                .font(.system(size: 14).italic())
                                .foregroundStyle(Theme.text2)
                        }
                        if let overview = detail?.overview, !overview.isEmpty {
                            ExpandableText(text: overview)
                        } else if detail != nil {
                            Text("No description.").font(.system(size: 14)).foregroundStyle(Theme.text3)
                        }
                        if let cast = detail?.credits?.cast?.prefix(8).compactMap(\.name), !cast.isEmpty {
                            Text("Cast")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.text)
                                .padding(.top, 4)
                            Text(cast.joined(separator: ", "))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                    .padding(16)
                }
                .overlay { if detail == nil { ProgressView() } }
            }
        }
        .themedBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showSeasons) {
            SeasonPicker(result: result) { count in
                showSeasons = false
                if let count { didRequest(seasons: count) }
            }
        }
        .toast($message)
    }

    @ViewBuilder
    private var stateButton: some View {
        if status >= 4 {
            StatePill(title: "On server", icon: "checkmark.circle", kind: .neutral)
        } else if [2, 3].contains(status) || requestedHere {
            StatePill(title: "Requested", icon: "checkmark", kind: .requested)
        } else {
            Button { tapRequest() } label: {
                StatePill(title: "Request", icon: "plus", kind: .action)
            }
            .buttonStyle(PressableStyle())
        }
    }

    /// Year, length or seasons, and the TMDB score.
    private var facts: String {
        var parts: [String] = []
        let dates: [String?] = [detail?.releaseDate, detail?.firstAirDate, result.releaseDate, result.firstAirDate]
        if let date = dates.compactMap({ $0 }).first(where: { $0.count >= 4 }) {
            parts.append(String(date.prefix(4)))
        }
        if result.mediaType == "tv" {
            if let n = detail?.numberOfSeasons { parts.append(n == 1 ? "1 season" : "\(n) seasons") }
        } else if let minutes = detail?.runtime, minutes > 0 {
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        if let score = detail?.voteAverage, score > 0 {
            parts.append("★ " + String(format: "%.1f", score))
        }
        return parts.joined(separator: " · ")
    }

    private func tapRequest() {
        if result.mediaType == "tv" {
            showSeasons = true
            return
        }
        Task {
            do {
                try await SeerrClient(userID: store.session?.userID)?.request(result, seasons: nil)
                didRequest(seasons: nil)
            } catch {
                AppLog.shared.log("Request failed: \(error.localizedDescription)", level: .error)
                message = "Couldn't send the request: \(error.localizedDescription)"
            }
        }
    }

    private func didRequest(seasons: Int?) {
        requestedHere = true
        onRequested(result)
        let what = seasons.map { $0 == 1 ? " (1 season)" : " (\($0) seasons)" } ?? ""
        message = "Requested “\(result.displayTitle)”\(what). It shows under My requests."
    }

    private func load() async {
        guard let client = SeerrClient(userID: store.session?.userID) else { return }
        do {
            detail = try await client.detail(result)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            AppLog.shared.log("Request detail failed: \(error.localizedDescription)", level: .error)
        }
    }
}

/// Pick which seasons to ask for.
private struct SeasonPicker: View {
    @Environment(SessionStore.self) private var store
    let result: SeerrResult
    /// The number of seasons requested, or nil when cancelled.
    let done: (Int?) -> Void

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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
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
            done(chosen.count)
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
                if let address = SeerrClient.savedURL?.absoluteString, AddressKind.isUnencryptedInternet(address) {
                    UnencryptedWarning(compact: false)
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
    @State private var needsLogin = false
    @State private var showLogin = false
    @State private var detailTarget: SeerrResult?
    @State private var filter: Filter = .pending
    @State private var pickedInitialFilter = false

    private enum Filter: String, CaseIterable {
        case pending = "Pending"
        case approved = "Approved"
        case denied = "Denied"

        /// Seerr: 2 approved, 3 declined; anything else (pending, or a status newer than this app knows) counts as pending.
        func matches(_ status: Int) -> Bool {
            switch self {
            case .pending: return status != 2 && status != 3
            case .approved: return status == 2
            case .denied: return status == 3
            }
        }
    }

    private var client: SeerrClient? { SeerrClient(userID: store.session?.userID) }
    private var shown: [SeerrMyRequest] { requests.filter { filter.matches($0.status) } }

    var body: some View {
        List {
            ForEach(shown) { request in
                HStack(spacing: 12) {
                    ArtworkFrame(url: request.posterURL, aspectRatio: 2 / 3)
                        .frame(width: 50)
                    Text(request.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .contentShape(Rectangle())
                .onTapGesture { detailTarget = request.asResult }
                .listRowBackground(Color.clear)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !requests.isEmpty {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { option in
                        Text("\(option.rawValue) (\(requests.filter { option.matches($0.status) }.count))").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.background)
            }
        }
        .navigationDestination(item: $detailTarget) { target in
            RequestDetailView(result: target) { _ in }
                .tabBarClearance()
        }
        .listStyle(.plain)
        .themedBackground()
        .overlay {
            if client == nil {
                ContentUnavailableView("Requests are off", systemImage: "tray", description: Text("Add the request server in the Server tab."))
            } else if needsLogin {
                ContentUnavailableView {
                    Label("Sign in", systemImage: "person.crop.circle")
                } description: {
                    Text("Use your Jellyfin login to see your requests.")
                } actions: {
                    Button("Sign in") { showLogin = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
            } else if let errorMessage {
                ErrorState(message: errorMessage) { await load() }
            } else if isLoading && requests.isEmpty {
                ProgressView()
            } else if requests.isEmpty {
                ContentUnavailableView("No requests yet", systemImage: "tray")
            } else if shown.isEmpty {
                ContentUnavailableView("Nothing \(filter.rawValue.lowercased())", systemImage: "tray")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showLogin) {
            SeerrLoginSheet(userID: store.session?.userID, defaultName: store.session?.userName ?? "") {
                Task { await load() }
            }
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let client else { return }
        guard client.isSignedIn else {
            needsLogin = true
            showLogin = true
            return
        }
        needsLogin = false
        do {
            requests = try await client.myRequests()
            errorMessage = nil
            // First load: open on the first tab that has something in it.
            if !pickedInitialFilter {
                pickedInitialFilter = true
                if shown.isEmpty, let first = Filter.allCases.first(where: { option in requests.contains { option.matches($0.status) } }) {
                    filter = first
                }
            }
        } catch {
            if case SeerrError.notSignedIn = error {
                needsLogin = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Settings → Requests: opens on your requests once the request server is set up and signed in;
/// the server address and sign-out live in the Server tab.
struct RequestsHubView: View {
    private enum Tab: String, CaseIterable {
        case requests = "Requests"
        case server = "Server"
    }

    @Environment(SessionStore.self) private var store
    @AppStorage(SeerrClient.urlKey) private var url = ""
    @State private var chosen: Tab?

    private var tab: Tab {
        chosen ?? (SeerrClient(userID: store.session?.userID)?.isSignedIn == true ? .requests : .server)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { chosen = $0 })) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            switch tab {
            case .requests: MyRequestsView()
            case .server: SeerrSettingsView()
            }
        }
        .themedBackground()
        .navigationTitle("Requests")
        .toolbar {
            if ServerProbe.normalize(url) != nil {
                NavigationLink {
                    RequestSearchView(term: "").tabBarClearance()
                } label: {
                    Image(systemName: "plus")
                }
            }
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
                // verbatim: otherwise the placeholder is drawn as a blue link
                TextField("Address", text: $url, prompt: Text(verbatim: "https://requests.example.com"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if AddressKind.isUnencryptedInternet(url.trimmingCharacters(in: .whitespaces)) {
                    UnencryptedWarning(compact: false)
                }
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

            if let client = SeerrClient(userID: store.session?.userID), client.isSignedIn {
                Section {
                    Button("Sign out of request server", role: .destructive) {
                        client.signOut()
                        signedInRefresh += 1
                    }
                }
                .id(signedInRefresh)
            }
        }
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
