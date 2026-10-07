import Foundation
import JellyfinAPI
import Observation
import UIKit

/// Holds the signed-in Jellyfin session. The access token is stored in the Keychain.
@MainActor
@Observable
final class SessionStore {
    struct SavedSession: Codable {
        let serverURL: URL
        let accessToken: String
        let userID: String
        let userName: String
    }

    enum SessionError: LocalizedError {
        case incompleteResponse

        var errorDescription: String? {
            "The server did not return a complete sign-in response."
        }
    }

    private static let keychainKey = "session"
    private static let deviceIDKey = "deviceID"

    private(set) var client: JellyfinClient?
    private(set) var session: SavedSession?

    init() {
        restore()
    }

    func signIn(server: URL, username: String, password: String) async throws {
        let newClient = Self.makeClient(url: server, accessToken: nil)
        let result = try await newClient.signIn(username: username, password: password)
        guard let token = newClient.accessToken, let userID = result.user?.id else {
            throw SessionError.incompleteResponse
        }
        let saved = SavedSession(
            serverURL: server,
            accessToken: token,
            userID: userID,
            userName: result.user?.name ?? username
        )
        AppLog.shared.addSecret(token)
        if let data = try? JSONEncoder().encode(saved) {
            Keychain.set(data, for: Self.keychainKey)
        }
        client = newClient
        session = saved
        AppLog.shared.log("Signed in as \(saved.userName) on \(server.absoluteString)")
    }

    func signOut() async {
        if let client {
            do {
                try await client.signOut()
            } catch {
                AppLog.shared.log("Sign-out request failed: \(error.localizedDescription)", level: .warning)
            }
        }
        Keychain.delete(Self.keychainKey)
        client = nil
        session = nil
        AppLog.shared.log("Signed out")
    }

    private func restore() {
        guard let data = Keychain.data(for: Self.keychainKey),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else {
            return
        }
        AppLog.shared.addSecret(saved.accessToken)
        client = Self.makeClient(url: saved.serverURL, accessToken: saved.accessToken)
        session = saved
        AppLog.shared.log("Restored session for \(saved.userName) on \(saved.serverURL.absoluteString)")
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
