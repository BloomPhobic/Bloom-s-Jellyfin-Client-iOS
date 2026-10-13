import Foundation
import JellyfinAPI
import Network
import Observation
import UIKit

/// Holds the saved server, the address currently in use, and the signed-in accounts.
/// Access tokens are stored in the Keychain; a token works on every address of the same server.
@MainActor
@Observable
final class SessionStore {
    struct SavedSession: Codable, Identifiable, Equatable {
        let accessToken: String
        let userID: String
        let userName: String
        /// Each account signs in with its own device ID, so the server never treats one user's
        /// sign-in as replacing another's on this phone. nil = signed in before accounts existed
        /// (uses the install's ID).
        var deviceID: String?
        /// Profile picture tag, if the user has one.
        var imageTag: String?

        var id: String { userID }
    }

    struct Route: Equatable {
        let address: String
        let milliseconds: Int

        var kind: AddressKind { AddressKind.of(address) }
    }

    enum SessionError: LocalizedError {
        case incompleteResponse
        case notConnected
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .incompleteResponse: return "The server did not return a complete sign-in response."
            case .notConnected: return "Not connected to the server."
            case .unreachable(let reason): return reason
            }
        }
    }

    private static let accountsKey = "accounts"
    private static let legacySessionKey = "session"
    private static let currentUserKey = "currentUserID"
    private static let deviceIDKey = "deviceID"

    private(set) var server: ServerRecord?
    /// The address in use. It is kept while re-checking, so the app doesn't drop out of what it is showing.
    private(set) var route: Route?
    private(set) var isResolving = false
    private(set) var hasResolved = false
    private(set) var results: [String: ProbeResult] = [:]
    /// Every signed-in account on this server.
    private(set) var accounts: [SavedSession] = []
    /// The account in use.
    private(set) var session: SavedSession?
    /// The login screen is open to add another account while one is signed in.
    var isAddingAccount = false
    /// A short message for the banner at the top of the app (for example an expired sign-in).
    var notice: String?
    /// The phone has no network connection at all.
    private(set) var isOffline = false
    /// The last address check found nothing reachable. The previous address stays in use, and the
    /// check repeats every 15 s until one answers.
    private(set) var isServerUnreachable = false
    /// Client for the current route, with the access token when signed in.
    private(set) var client: JellyfinClient?

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var resolveAgain = false
    @ObservationIgnored private var checkGeneration = 0
    @ObservationIgnored private var sessionChecked = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var pathChangeTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var unauthorizedObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundedAt: Date?

    init() {
        server = ServerRecord.load()
        restoreSession()
        // Any request that comes back 401/403 triggers a token check (see AuthWatch).
        unauthorizedObserver = NotificationCenter.default.addObserver(forName: .requestUnauthorized, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckSession()
            }
        }
    }

    /// Connects to the saved server and starts watching for network changes. Safe to call more than once.
    func start() async {
        guard !didStart else { return }
        didStart = true
        startPathMonitor()
        await resolve()
    }

    // MARK: - Address resolution

    /// Checks every address of the saved server and switches to the best one that answers.
    func resolve() async {
        guard let addresses = server?.addresses, !addresses.isEmpty else { return }
        if isResolving {
            resolveAgain = true
            return
        }
        isResolving = true
        checkGeneration += 1
        let log = AppLog.shared
        log.log("Checking \(addresses.count) address(es)…")

        let resolution = await AddressResolver.resolve(addresses, serverID: server?.id)
        isResolving = false
        hasResolved = true
        guard server != nil else { return }

        results = Dictionary(resolution.results.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        for result in resolution.results {
            Self.log(result)
        }

        if let chosen = resolution.chosen, let ms = chosen.milliseconds {
            remember(serverID: chosen.serverID, name: chosen.serverName)
            let newRoute = Route(address: chosen.address, milliseconds: ms)
            if newRoute.address != route?.address {
                log.log("Using \(newRoute.kind.label): \(newRoute.address) (\(ms) ms)")
                route = newRoute
                rebuildClient()
            } else {
                route = newRoute
            }
            await checkSavedSession()
            if isServerUnreachable {
                isServerUnreachable = false
                log.log("Server reachable again")
                NotificationCenter.default.post(name: .contentShouldRefresh, object: nil)
            }
        } else if let route {
            isServerUnreachable = true
            scheduleRetry()
            log.log("No address answered. Still using \(route.address) until the next check.", level: .warning)
        } else {
            isServerUnreachable = true
            scheduleRetry()
            log.log("No address answered.", level: .error)
        }

        // Addresses that were still being checked when the choice was made: finish them in the background,
        // so the list shows a real result for each, and switch if a higher-priority one was just slow.
        let unfinished = addresses.filter { results[$0] == nil }
        if !unfinished.isEmpty {
            log.log("Finishing \(unfinished.count) check(s) in the background")
            finishChecks(unfinished)
        }

        if resolveAgain {
            resolveAgain = false
            await resolve()
        }
    }

    private func finishChecks(_ addresses: [String]) {
        let generation = checkGeneration
        let serverID = server?.id
        Task {
            let found = await ServerProbe.probeAll(addresses)
            // A newer check started meanwhile; its results win.
            guard generation == checkGeneration, server != nil else { return }
            for probe in found {
                let result = AddressResolver.check(probe, serverID: serverID)
                results[result.address] = result
                Self.log(result)
            }

            guard let order = server?.addresses,
                  let current = route,
                  let currentIndex = order.firstIndex(of: current.address) else { return }
            let higher = order.prefix(currentIndex).compactMap { results[$0] }
            guard let better = higher.first(where: { $0.isReachable }), let ms = better.milliseconds else { return }
            let newRoute = Route(address: better.address, milliseconds: ms)
            AppLog.shared.log("Switching to \(newRoute.kind.label): \(newRoute.address) (answered after the first choice, \(ms) ms)")
            route = newRoute
            rebuildClient()
        }
    }

    private static func log(_ result: ProbeResult) {
        switch result.outcome {
        case .reachable(_, let name, let version, let ms):
            AppLog.shared.log("OK \(result.address): \"\(name)\", server \(version), \(ms) ms")
        case .failed(let reason):
            AppLog.shared.log("FAIL \(result.address): \(reason)", level: .warning)
        }
    }

    /// While nothing answers, check again every 15 s.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task {
            while !Task.isCancelled, isServerUnreachable {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, isServerUnreachable else { break }
                await resolve()
            }
            retryTask = nil
        }
    }

    // MARK: - App lifecycle

    func appDidEnterBackground() {
        backgroundedAt = Date()
    }

    /// After a long time away, the network, the token and the pages may all be stale.
    func appDidBecomeActive() {
        defer { backgroundedAt = nil }
        guard let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > 10 * 60 else { return }
        AppLog.shared.log("Back after \(Int(Date().timeIntervalSince(backgroundedAt) / 60)) min; refreshing")
        sessionChecked = false
        Task {
            await resolve()
            NotificationCenter.default.post(name: .contentShouldRefresh, object: nil)
        }
    }

    /// A request was refused: make sure the token is still valid.
    func recheckSession() {
        guard session != nil else { return }
        sessionChecked = false
        Task { await checkSavedSession() }
    }

    /// Saves the server's ID and name the first time it is reached (or if the name changed).
    private func remember(serverID: String?, name: String?) {
        guard var record = server else { return }
        var changed = false
        if record.id == nil, let serverID {
            record.id = serverID
            changed = true
        }
        if let name, record.name != name {
            record.name = name
            changed = true
        }
        if changed {
            record.save()
            server = record
        }
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
            let signature = "\(path.status) \(interfaces)"
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.pathChanged(signature, satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "SessionStore.pathMonitor"))
        pathMonitor = monitor
    }

    private func pathChanged(_ signature: String, satisfied: Bool) {
        if isOffline == satisfied {
            isOffline = !satisfied
        }
        guard let previous = pathSignature else {
            pathSignature = signature
            return
        }
        guard signature != previous else { return }
        pathSignature = signature
        AppLog.shared.log("Network changed (\(signature)), checking addresses again")
        // Wait a moment: interfaces often change several times in a row (Wi-Fi joining, VPN reconnecting).
        pathChangeTask?.cancel()
        pathChangeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await resolve()
        }
    }

    // MARK: - Server and addresses

    /// Adds the first server from a single address. Throws if it isn't a reachable Jellyfin server.
    func addServer(address: String) async throws {
        let result = await ServerProbe.probe(address)
        guard case .reachable(let id, let name, let version, let ms) = result.outcome else {
            if case .failed(let reason) = result.outcome {
                AppLog.shared.log("FAIL \(address): \(reason)", level: .warning)
                throw SessionError.unreachable(reason)
            }
            throw SessionError.notConnected
        }
        let record = ServerRecord(id: id, name: name, addresses: [address])
        record.save()
        // Accounts belong to the previous server.
        accounts = []
        saveAccounts()
        session = nil
        server = record
        results = [address: result]
        route = Route(address: address, milliseconds: ms)
        hasResolved = true
        rebuildClient()
        AppLog.shared.log("Added server \"\(name)\" (\(version)) at \(address)")
    }

    /// Adds another address for the saved server. Returns a message to show, and whether it is an error.
    func addAddress(_ raw: String) async -> (message: String, isError: Bool) {
        guard var record = server else { return ("No server added yet.", true) }
        guard let url = ServerProbe.normalize(raw) else {
            return ("Enter a full address starting with http:// or https://", true)
        }
        let address = url.absoluteString
        guard !record.addresses.contains(address) else {
            return ("That address is already in the list.", true)
        }

        let result = await ServerProbe.probe(address)
        if let foundID = result.serverID, let id = record.id, foundID != id {
            AppLog.shared.log("Rejected \(address): a different server (\(result.serverName ?? "?"))", level: .warning)
            return ("That address leads to a different Jellyfin server (\"\(result.serverName ?? "?")\").", true)
        }

        record.insert(address)
        record.save()
        server = record
        results[address] = result
        AppLog.shared.log("Added address \(address) (\(AddressKind.of(address).label))")
        Task { await resolve() }

        if case .failed(let reason) = result.outcome {
            return ("Saved, but it didn't answer just now: \(reason)", false)
        }
        return ("Added as \(AddressKind.of(address).label).", false)
    }

    func removeAddresses(at offsets: IndexSet) {
        guard var record = server else { return }
        guard record.addresses.count > offsets.count else { return }
        record.addresses.remove(atOffsets: offsets)
        updateAddresses(record)
    }

    func moveAddresses(from source: IndexSet, to destination: Int) {
        guard var record = server else { return }
        record.addresses.move(fromOffsets: source, toOffset: destination)
        updateAddresses(record)
    }

    private func updateAddresses(_ record: ServerRecord) {
        record.save()
        server = record
        results = results.filter { record.addresses.contains($0.key) }
        AppLog.shared.log("Address order: \(record.addresses.joined(separator: ", "))")
        Task { await resolve() }
    }

    /// Signs out and removes the server and all its addresses.
    func forgetServer() async {
        for account in accounts {
            await remove(account)
        }
        ServerRecord.delete()
        server = nil
        route = nil
        results = [:]
        client = nil
        hasResolved = false
        AppLog.shared.log("Forgot the server")
    }

    // MARK: - Sign in

    /// A client without an access token, for the login screen. Each one has a fresh device ID,
    /// which the account keeps if the sign-in succeeds.
    func loginClient() throws -> JellyfinClient {
        guard let route, let url = URL(string: route.address) else { throw SessionError.notConnected }
        return Self.makeClient(url: url, accessToken: nil, deviceID: UUID().uuidString)
    }

    func publicUsers() async throws -> [UserDto] {
        try await loginClient().send(Paths.getPublicUsers).value
    }

    /// A user's profile picture on the current address.
    func userImageURL(userID: String, tag: String?) -> URL? {
        guard let tag, let client = try? loginClient() else { return nil }
        var parameters = Paths.GetUserImageParameters()
        parameters.userID = userID
        parameters.tag = tag
        return client.url(with: Paths.getUserImage(parameters: parameters))
    }

    func isQuickConnectEnabled() async -> Bool {
        do {
            let data = try await loginClient().data(for: Paths.getQuickConnectEnabled).value
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch {
            AppLog.shared.log("Quick Connect check failed: \(error.localizedDescription)", level: .warning)
            return false
        }
    }

    func signIn(username: String, password: String) async throws {
        let newClient = try loginClient()
        let result = try await newClient.signIn(username: username, password: password)
        try finishSignIn(client: newClient, result: result, method: "password")
    }

    /// Finishes a Quick Connect sign-in. `client` must be the one that ran the Quick Connect flow.
    func signIn(quickConnectSecret: String, client newClient: JellyfinClient) async throws {
        let result = try await newClient.signIn(quickConnectSecret: quickConnectSecret)
        try finishSignIn(client: newClient, result: result, method: "Quick Connect")
    }

    private func finishSignIn(client newClient: JellyfinClient, result: AuthenticationResult, method: String) throws {
        guard let token = newClient.accessToken, let userID = result.user?.id else {
            throw SessionError.incompleteResponse
        }
        let saved = SavedSession(
            accessToken: token,
            userID: userID,
            userName: result.user?.name ?? "?",
            deviceID: newClient.configuration.deviceID,
            imageTag: result.user?.primaryImageTag
        )
        AppLog.shared.addSecret(token)
        accounts.removeAll { $0.userID == userID }
        accounts.append(saved)
        saveAccounts()
        isAddingAccount = false
        activate(saved, checked: true)
        AppLog.shared.log("Signed in as \(saved.userName) with \(method) via \(route?.address ?? "?") (\(accounts.count) account(s))")
    }

    /// Switches to another signed-in account.
    func switchAccount(to account: SavedSession) {
        guard account != session else { return }
        isAddingAccount = false
        activate(account, checked: false)
        AppLog.shared.log("Switched to \(account.userName)")
        Task { await checkSavedSession() }
    }

    /// Signs the current account out; another signed-in account takes over if there is one.
    func signOut() async {
        guard let session else { return }
        await remove(session)
    }

    /// Signs an account out on the server and forgets it here.
    func remove(_ account: SavedSession) async {
        if let route, let url = URL(string: route.address) {
            let accountClient = Self.makeClient(url: url, accessToken: account.accessToken, deviceID: account.deviceID ?? Self.installDeviceID)
            do {
                try await accountClient.signOut()
            } catch {
                AppLog.shared.log("Sign-out request failed: \(error.localizedDescription)", level: .warning)
            }
        }
        forget(account)
        AppLog.shared.log("Signed out \(account.userName)")
    }

    /// Drops an account locally (token already invalid, or after signing out).
    private func forget(_ account: SavedSession) {
        accounts.removeAll { $0.userID == account.userID }
        saveAccounts()
        if session?.userID == account.userID {
            if let next = accounts.first {
                activate(next, checked: false)
                Task { await checkSavedSession() }
            } else {
                session = nil
                UserDefaults.standard.removeObject(forKey: Self.currentUserKey)
                rebuildClient()
            }
        }
    }

    private func activate(_ account: SavedSession, checked: Bool) {
        session = account
        sessionChecked = checked
        UserDefaults.standard.set(account.userID, forKey: Self.currentUserKey)
        rebuildClient()
    }

    private func saveAccounts() {
        if accounts.isEmpty {
            Keychain.delete(Self.accountsKey)
        } else if let data = try? JSONEncoder().encode(accounts) {
            Keychain.set(data, for: Self.accountsKey)
        }
    }

    private func restoreSession() {
        if let data = Keychain.data(for: Self.accountsKey),
           let saved = try? JSONDecoder().decode([SavedSession].self, from: data) {
            accounts = saved
        } else if let data = Keychain.data(for: Self.legacySessionKey),
                  let old = try? JSONDecoder().decode(SavedSession.self, from: data) {
            // Builds before multiple accounts kept a single session.
            accounts = [old]
            saveAccounts()
            Keychain.delete(Self.legacySessionKey)
            AppLog.shared.log("Moved the saved sign-in to the account list")
        }
        for account in accounts {
            AppLog.shared.addSecret(account.accessToken)
        }
        let currentID = UserDefaults.standard.string(forKey: Self.currentUserKey)
        session = accounts.first { $0.userID == currentID } ?? accounts.first
        if let session {
            AppLog.shared.log("Restored session for \(session.userName) (\(accounts.count) account(s))")
        }
    }

    /// Once per account switch or launch, makes sure the token still works. A token revoked on the
    /// server (for example from the Jellyfin dashboard) removes that account; network errors keep it.
    private func checkSavedSession() async {
        guard !sessionChecked, let current = session, let client,
              let url = client.url(with: Paths.getCurrentUser, queryAPIKey: true) else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard session?.userID == current.userID else { return }
            sessionChecked = true
            if status == 401 || status == 403 {
                AppLog.shared.log("The sign-in for \(current.userName) is no longer valid (HTTP \(status)). Please sign in again.", level: .warning)
                notice = "The sign-in for \(current.userName) has expired. Please sign in again."
                forget(current)
            } else {
                AppLog.shared.log("Saved sign-in OK for \(current.userName) (HTTP \(status))")
            }
        } catch {
            AppLog.shared.log("Couldn't check the saved sign-in: \(error.localizedDescription)", level: .warning)
        }
    }

    private func rebuildClient() {
        guard let route, let url = URL(string: route.address) else {
            client = nil
            return
        }
        client = Self.makeClient(url: url, accessToken: session?.accessToken, deviceID: session?.deviceID ?? Self.installDeviceID)
    }

    private static func makeClient(url: URL, accessToken: String?, deviceID: String) -> JellyfinClient {
        let configuration = JellyfinClient.Configuration(
            url: url,
            accessToken: accessToken,
            client: "Bloom for iOS",
            deviceName: UIDevice.current.name,
            deviceID: deviceID,
            version: AppInfo.version
        )
        return JellyfinClient(configuration: configuration)
    }

    /// A random ID that stays the same for this install. Used by accounts signed in before each
    /// account had its own.
    private static var installDeviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: deviceIDKey)
        return new
    }
}

extension Notification.Name {
    /// A request came back 401/403; the token may have been revoked.
    static let requestUnauthorized = Notification.Name("requestUnauthorized")
    /// The connection came back, or the app returned after a long time: pages should reload.
    static let contentShouldRefresh = Notification.Name("contentShouldRefresh")
}

/// Lets any screen report a failed request without knowing about accounts.
enum AuthWatch {
    static func report(_ error: Error) {
        let text = String(describing: error)
        if text.contains("unacceptableStatusCode(401)") || text.contains("unacceptableStatusCode(403)") {
            NotificationCenter.default.post(name: .requestUnauthorized, object: nil)
        }
    }

    /// Cancelled requests (the page went away, or a newer load replaced them) aren't failures.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
