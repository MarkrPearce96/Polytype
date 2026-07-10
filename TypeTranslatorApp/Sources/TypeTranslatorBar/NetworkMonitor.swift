import Foundation
import Network

/// Reports online/offline transitions (interface availability) on the main
/// actor. Fires `onChange` only when the state actually flips, not on every
/// path update.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.typetranslator.network")
    private var lastOnline: Bool?

    /// Called on the main actor whenever connectivity flips. `true` = online.
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.lastOnline != online else { return }
                self.lastOnline = online
                self.onChange?(online)
            }
        }
        monitor.start(queue: queue)
    }
}
