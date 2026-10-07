import Foundation

struct ProbeResult: Sendable {
    enum Outcome: Sendable {
        case reachable(serverName: String, version: String, milliseconds: Int)
        case failed(String)
    }

    let address: String
    let outcome: Outcome

    var isReachable: Bool {
        if case .reachable = outcome { return true }
        return false
    }
}

/// Checks whether Jellyfin servers answer, using the unauthenticated /System/Info/Public endpoint.
enum ServerProbe {
    private struct PublicInfo: Decodable {
        let serverName: String?
        let version: String?

        enum CodingKeys: String, CodingKey {
            case serverName = "ServerName"
            case version = "Version"
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Returns the address as a URL if it is a usable http:// or https:// address.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil else {
            return nil
        }
        return url
    }

    /// Probes all addresses at the same time and returns the results in the input order.
    static func probeAll(_ addresses: [String]) async -> [ProbeResult] {
        let byAddress = await withTaskGroup(of: ProbeResult.self) { group in
            for address in addresses {
                group.addTask { await ServerProbe.probe(address) }
            }
            var results: [String: ProbeResult] = [:]
            for await result in group {
                results[result.address] = result
            }
            return results
        }
        return addresses.compactMap { byAddress[$0] }
    }

    static func probe(_ address: String) async -> ProbeResult {
        guard let base = normalize(address) else {
            return ProbeResult(address: address, outcome: .failed("Not a valid http:// or https:// address"))
        }

        var request = URLRequest(url: base.appending(path: "System/Info/Public"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(address: address, outcome: .failed("No HTTP response"))
            }
            guard (200..<300).contains(http.statusCode) else {
                return ProbeResult(address: address, outcome: .failed("HTTP \(http.statusCode)"))
            }
            let info = try JSONDecoder().decode(PublicInfo.self, from: data)
            return ProbeResult(
                address: address,
                outcome: .reachable(
                    serverName: info.serverName ?? "?",
                    version: info.version ?? "?",
                    milliseconds: milliseconds
                )
            )
        } catch let error as URLError {
            return ProbeResult(address: address, outcome: .failed("\(error.localizedDescription) (URLError \(error.code.rawValue))"))
        } catch is DecodingError {
            return ProbeResult(address: address, outcome: .failed("Answered, but not with Jellyfin server info"))
        } catch {
            return ProbeResult(address: address, outcome: .failed(error.localizedDescription))
        }
    }
}
