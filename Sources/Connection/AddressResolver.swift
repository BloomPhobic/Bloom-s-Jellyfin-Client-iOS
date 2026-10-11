import Foundation

/// Picks the best address for a server: all addresses are probed at the same time, and the
/// highest-priority one that answers wins. A slow or dead higher-priority address only delays
/// the choice by a short grace period, never by a full timeout.
enum AddressResolver {
    struct Resolution: Sendable {
        let chosen: ProbeResult?
        /// Results in priority order. Addresses that were still being checked when a choice was made are missing.
        let results: [ProbeResult]
    }

    private enum Item: Sendable {
        case probe(ProbeResult)
        case graceOver
    }

    /// How long to wait for higher-priority addresses once a lower-priority one has answered.
    static let grace: Duration = .milliseconds(1500)

    static func resolve(_ addresses: [String], serverID: String?) async -> Resolution {
        guard !addresses.isEmpty else { return Resolution(chosen: nil, results: []) }

        return await withTaskGroup(of: Item.self) { group in
            for address in addresses {
                group.addTask { .probe(Self.check(await ServerProbe.probe(address), serverID: serverID)) }
            }

            var results: [String: ProbeResult] = [:]
            var graceStarted = false
            var chosen: ProbeResult?

            func best() -> (result: ProbeResult, isFinal: Bool)? {
                for address in addresses {
                    guard let result = results[address] else {
                        // A higher-priority address hasn't answered yet; remember the best answer below it.
                        let lower = addresses.drop(while: { $0 != address }).compactMap { results[$0] }.first { $0.isReachable }
                        return lower.map { ($0, false) }
                    }
                    if result.isReachable {
                        return (result, true)
                    }
                }
                return nil
            }

            while let item = await group.next() {
                switch item {
                case .probe(let result):
                    results[result.address] = result
                    if let found = best() {
                        if found.isFinal {
                            chosen = found.result
                        } else if !graceStarted {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: Self.grace)
                                return .graceOver
                            }
                        }
                    }
                case .graceOver:
                    chosen = best()?.result
                }
                if chosen != nil || results.count == addresses.count {
                    break
                }
            }
            group.cancelAll()

            return Resolution(chosen: chosen, results: addresses.compactMap { results[$0] })
        }
    }

    /// Treats an answer from a different Jellyfin server as a failure.
    static func check(_ result: ProbeResult, serverID: String?) -> ProbeResult {
        guard let serverID,
              case .reachable(let foundID, let name, _, _) = result.outcome,
              let foundID, foundID != serverID else {
            return result
        }
        return ProbeResult(address: result.address, outcome: .failed("A different Jellyfin server answered (\"\(name)\")"))
    }
}

extension ProbeResult {
    var serverID: String? {
        if case .reachable(let id, _, _, _) = outcome { return id }
        return nil
    }

    var serverName: String? {
        if case .reachable(_, let name, _, _) = outcome { return name }
        return nil
    }

    var milliseconds: Int? {
        if case .reachable(_, _, _, let ms) = outcome { return ms }
        return nil
    }
}
