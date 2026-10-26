import Foundation
import Network
import Combine

/// App-wide reachability signal (NWPathMonitor, iOS 12+). Chat screens use it
/// to reconnect the event stream immediately when the network comes back
/// instead of waiting out the exponential backoff.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isSatisfied = true
    /// Bumped on every path change that ends in `.satisfied` (Wi-Fi ↔ cellular
    /// handover, VPN up, returning from offline).
    @Published private(set) var satisfiedGeneration = 0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "remotepi.network-monitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.update(satisfied: satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    private func update(satisfied: Bool) {
        if satisfied { satisfiedGeneration &+= 1 }
        if isSatisfied != satisfied { isSatisfied = satisfied }
    }
}
