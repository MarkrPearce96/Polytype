import Foundation
import Network

/// Reports online/offline transitions (interface availability). Delivery is
/// ordered: path updates arrive on a serial queue and are forwarded to the main
/// thread via `DispatchQueue.main.async` (FIFO), so rapid offline→online flips
/// can't be reordered. `onChange` fires only when the state actually flips.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.typetranslator.network")
    private var lastOnline: Bool?

    /// Current connectivity, updated on the main actor. Defaults to online so the
    /// UI isn't pessimistic before the first path update arrives.
    private(set) var isOnline = true

    /// Called on the main actor whenever connectivity flips. `true` = online.
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = (path.status == .satisfied)
            // Hop to the main thread in FIFO order; do the dedup there so the
            // ordering established by the serial queue is preserved.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.lastOnline != online else { return }
                    self.lastOnline = online
                    self.isOnline = online
                    self.onChange?(online)
                }
            }
        }
        monitor.start(queue: queue)
    }
}
