import Foundation

enum SeerrError: LocalizedError {
    case notSignedIn
    case wrongLogin
    case noSession
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to the request server first."
        case .wrongLogin: return "Wrong username or password (Seerr must be set to Jellyfin sign-in)."
        case .noSession: return "The request server didn't start a session."
        case .http(let code): return "The request server answered HTTP \(code)."
        }
    }
}

struct SeerrResult: Decodable, Identifiable, Hashable {
    struct MediaInfo: Decodable, Hashable { let status: Int? }

    let tmdbID: Int
    let mediaType: String
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let mediaInfo: MediaInfo?

    enum CodingKeys: String, CodingKey {
        case tmdbID = "id"
        case mediaType, title, name, releaseDate, firstAirDate, posterPath, mediaInfo
    }

    var id: String { "\(mediaType)-\(tmdbID)" }
    var displayTitle: String { title ?? name ?? "Untitled" }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var posterURL: URL? { SeerrClient.poster(posterPath) }
    /// Seerr media status: 2 pending, 3 processing, 4 partly available, 5 available.
    var isAvailable: Bool { (mediaInfo?.status ?? 0) >= 4 }
    var isRequested: Bool { [2, 3].contains(mediaInfo?.status ?? 0) }
}

struct SeerrSeason: Decodable, Hashable {
    let seasonNumber: Int
    let name: String?
}

struct SeerrMyRequest: Identifiable {
    let id: Int
    /// Seerr request status: 1 pending, 2 approved, 3 declined.
    let status: Int
    let title: String
    let posterURL: URL?

    var statusLabel: String {
        switch status {
        case 2: return "Approved"
        case 3: return "Declined"
        default: return "Pending"
        }
    }
}

/// Talks to a Seerr (Jellyseerr/Overseerr) server. One fixed address, signed in with the user's Jellyfin login;
/// only the session cookie is kept (Keychain), never the password.
struct SeerrClient {
    static let urlKey = "seerrURL"

    let base: URL
    let userID: String

    private struct Ignored: Decodable {}
    private struct Page<T: Decodable>: Decodable { let results: [T] }
    private struct TvDetail: Decodable { let seasons: [SeerrSeason]? }
    private struct StatusInfo: Decodable { let version: String? }
    private struct TitleInfo: Decodable {
        let title: String?
        let name: String?
        let posterPath: String?
    }
    private struct RequestRow: Decodable {
        struct Media: Decodable {
            let tmdbId: Int?
            let mediaType: String?
        }
        let id: Int
        let status: Int
        let media: Media?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    static var savedURL: URL? {
        UserDefaults.standard.string(forKey: urlKey).flatMap(ServerProbe.normalize)
    }

    static func poster(_ path: String?) -> URL? {
        path.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") }
    }

    /// nil when no request server is set or nobody is signed in to Jellyfin.
    init?(userID: String?) {
        guard let base = Self.savedURL, let userID else { return nil }
        self.base = base
        self.userID = userID
    }

    private var cookieKey: String { "seerr.cookie.\(userID)" }
    var isSignedIn: Bool { Keychain.data(for: cookieKey) != nil }

    func signOut() {
        Keychain.delete(cookieKey)
    }

    func signIn(username: String, password: String) async throws {
        var request = URLRequest(url: base.appending(path: "api/v1/auth/jellyfin"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (_, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw (http.statusCode == 401 || http.statusCode == 403) ? SeerrError.wrongLogin : SeerrError.http(http.statusCode)
        }
        let headers = (http.allHeaderFields as? [String: String]) ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: base)
        guard let sid = cookies.first(where: { $0.name == "connect.sid" }) else { throw SeerrError.noSession }
        Keychain.set(Data("\(sid.name)=\(sid.value)".utf8), for: cookieKey)
    }

    /// Returns the server version. Needs no sign-in.
    static func test(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(for: URLRequest(url: url.appending(path: "api/v1/status")))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SeerrError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(StatusInfo.self, from: data).version ?? "?"
    }

    private func send<T: Decodable>(_ type: T.Type, method: String = "GET", _ path: String,
                                    query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        guard let cookie = Keychain.data(for: cookieKey).flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw SeerrError.notSignedIn
        }
        guard var components = URLComponents(url: base.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false) else {
            throw SeerrError.http(0)
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SeerrError.http(0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrError.http(0) }
        if http.statusCode == 401 || http.statusCode == 403 {
            signOut() // the cookie expired: ask for the password again
            throw SeerrError.notSignedIn
        }
        guard (200..<300).contains(http.statusCode) else { throw SeerrError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(_ term: String) async throws -> [SeerrResult] {
        let page = try await send(Page<SeerrResult>.self, "search", query: [URLQueryItem(name: "query", value: term)])
        return page.results.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
    }

    func seasons(tvID: Int) async throws -> [SeerrSeason] {
        let detail = try await send(TvDetail.self, "tv/\(tvID)")
        return (detail.seasons ?? []).filter { $0.seasonNumber > 0 }
    }

    /// seasons: nil requests all of them (ignored for movies).
    func request(_ result: SeerrResult, seasons: [Int]?) async throws {
        var body: [String: Any] = ["mediaType": result.mediaType, "mediaId": result.tmdbID]
        if result.mediaType == "tv" {
            if let seasons { body["seasons"] = seasons } else { body["seasons"] = "all" }
        }
        _ = try await send(Ignored.self, method: "POST", "request", body: body)
    }

    func myRequests() async throws -> [SeerrMyRequest] {
        let rows = try await send(Page<RequestRow>.self, "request",
                                  query: [URLQueryItem(name: "take", value: "50"), URLQueryItem(name: "sort", value: "added")]).results
        return await withTaskGroup(of: SeerrMyRequest.self) { group in
            for row in rows {
                group.addTask {
                    var info: TitleInfo?
                    if let type = row.media?.mediaType, let tmdb = row.media?.tmdbId {
                        info = try? await self.send(TitleInfo.self, "\(type)/\(tmdb)")
                    }
                    return SeerrMyRequest(id: row.id, status: row.status,
                                          title: info?.title ?? info?.name ?? "Unknown title",
                                          posterURL: Self.poster(info?.posterPath))
                }
            }
            var out: [SeerrMyRequest] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.id > $1.id }
        }
    }
}
