import Foundation
import Observation

@MainActor
@Observable
final class ConnectionCheckModel {
    private static let addressesKey = "serverAddresses"

    private(set) var addresses: [String]
    private(set) var results: [String: ProbeResult] = [:]
    private(set) var chosenAddress: String?
    private(set) var isChecking = false
    var newAddress = ""
    var inputError: String?

    init() {
        addresses = UserDefaults.standard.stringArray(forKey: Self.addressesKey) ?? []
    }

    func addAddress() {
        let text = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ServerProbe.normalize(text) else {
            inputError = "Enter a full address starting with http:// or https://"
            return
        }
        let address = url.absoluteString
        guard !addresses.contains(address) else {
            inputError = "That address is already in the list."
            return
        }
        addresses.append(address)
        newAddress = ""
        inputError = nil
        save()
    }

    func remove(at offsets: IndexSet) {
        addresses.remove(atOffsets: offsets)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        addresses.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Probes every address in parallel, then picks the first one in list order that answered.
    func check() async {
        guard !isChecking, !addresses.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }

        let log = AppLog.shared
        let snapshot = addresses
        results = [:]
        chosenAddress = nil
        log.log("Checking \(snapshot.count) address(es) in parallel…")

        let found = await ServerProbe.probeAll(snapshot)
        for result in found {
            results[result.address] = result
            switch result.outcome {
            case .reachable(let name, let version, let ms):
                log.log("OK \(result.address): \"\(name)\", server \(version), \(ms) ms")
            case .failed(let reason):
                log.log("FAIL \(result.address): \(reason)", level: .warning)
            }
        }

        chosenAddress = snapshot.first { results[$0]?.isReachable == true }
        if let chosenAddress {
            log.log("Would use: \(chosenAddress)")
        } else {
            log.log("No address answered.", level: .error)
        }
    }

    private func save() {
        UserDefaults.standard.set(addresses, forKey: Self.addressesKey)
        results = [:]
        chosenAddress = nil
    }
}
