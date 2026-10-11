import Foundation
import JellyfinAPI
import Network
import Observation
import UIKit

/// Holds the saved server, the address currently in use, and the signed-in session.
/// The access token is stored in the Keychain; it works on every address of the same server.
@MainActor
@Observable
final class SessionStore {
    struct SavedSession: Codable {
        let accessToken: String
        let userID: String
        let userName: String
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

    private static let keychainKey = "session"
    private static let deviceIDKey = "deviceID"

    private(set) var server: ServerRecord?
    /// The address in use. It is kept while re-checking, so the app doesn't drop out of what it is showing.
    private(set) var route: Route?
    private(set) var isResolving = false
    private(set) var hasResolved = false
    private(set) var results: [String: ProbeResult] = [:]
    private(set) var session: SavedSession?
    /// Client for the current route, with the access token when signed in.
    private(set) var client: JellyfinClient?

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var resolveAgain = false
    @ObservationIgnored private var sessionChecked = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var pathChangeTask: Task<Void, Never>?

    init() {
        server = ServerRecord.load()
        restoreSession()
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
        let log = AppLog.shared
        log.log("Checking \(addresses.count) address(es)…")

        let resolution = await AddressResolver.resolve(addresses, serverID: server?.id)
        isResolving = false
        hasResolved = true
        guard server != nil else { return }

        results = Dictionary(resolution.results.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        for result in resolution.results {
            switch result.outcome {
            case .reachable(_, let name, let version, let ms):
                log.log("OK \(result.address): \"\(name)\", server \(version), \(ms) ms")
            case .failed(let reason):
                log.log("FAIL \(result.address): \(reason)", level: .warning)
            }
        }
        let skipped = addresses.count - resolution.results.count
        if skipped > 0 {
            log.log("Not waiting for \(skipped) lower-priority address(es)")
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
        } else if let route {
            log.log("No address answered. Still using \(route.address) until the next check.", level: .warning)
        } else {
            log.log("No address answered.", level: .error)
        }

        if resolveAgain {
            resolveAgain = false
            await resolve()
        }
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
            Task { @MainActor in
                self?.pathChanged(signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "SessionStore.pathMonitor"))
        pathMonitor = monitor
    }

    private func pathChanged(_ signature: String) {
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
        if session != nil {
            clearSession()
        }
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
        if session != nil {
            await signOut()
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

    /// A client without an access token, for the login screen.
    func loginClient() throws -> JellyfinClient {
        guard let route, let url = URL(string: route.address) else { throw SessionError.notConnected }
        return Self.makeClient(url: url, accessToken: nil)
    }

    func publicUsers() async throws -> [UserDto] {
        try await loginClient().send(Paths.getPublicUsers).value
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
        let saved = SavedSession(accessToken: token, userID: userID, userName: result.user?.name ?? "?")
        AppLog.shared.addSecret(token)
        if let data = try? JSONEncoder().encode(saved) {
            Keychain.set(data, for: Self.keychainKey)
        }
        session = saved
        sessionChecked = true
        rebuildClient()
        AppLog.shared.log("Signed in as \(saved.userName) with \(method) via \(route?.address ?? "?")")
    }

    func signOut() async {
        if let client, session != nil {
            do {
                try await client.signOut()
            } catch {
                AppLog.shared.log("Sign-out request failed: \(error.localizedDescription)", level: .warning)
            }
        }
        clearSession()
        AppLog.shared.log("Signed out")
    }

    private func clearSession() {
        Keychain.delete(Self.keychainKey)
        session = nil
        rebuildClient()
    }

    private func restoreSession() {
        // Older builds saved the server URL in the session too; it is ignored when decoding.
        guard let data = Keychain.data(for: Self.keychainKey),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else {
            return
        }
        AppLog.shared.addSecret(saved.accessToken)
        session = saved
        AppLog.shared.log("Restored session for \(saved.userName)")
    }

    /// Once per launch, makes sure the saved token still works. A token revoked on the server
    /// (for example from the Jellyfin dashboard) signs the app out; network errors keep it.
    private func checkSavedSession() async {
        guard !sessionChecked, session != nil, let client,
              let url = client.url(with: Paths.getCurrentUser, queryAPIKey: true) else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            sessionChecked = true
            if status == 401 || status == 403 {
                AppLog.shared.log("The saved sign-in is no longer valid (HTTP \(status)). Please sign in again.", level: .warning)
                clearSession()
            } else {
                AppLog.shared.log("Saved sign-in OK (HTTP \(status))")
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
        client = Self.makeClient(url: url, accessToken: session?.accessToken)
    }

    private static func makeClient(url: URL, accessToken: String?) -> JellyfinClient {
        let configuration = JellyfinClient.Configuration(
            url: url,
            accessToken: accessToken,
            client: "Jellyfin Client iOS",
            deviceName: UIDevice.current.name,
            deviceID: deviceID,
            version: AppInfo.version
        )
        return JellyfinClient(configuration: configuration)
    }

    /// A random ID that stays the same for this install, so the server sees one device.
    private static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: deviceIDKey)
        return new
    }
}
