import Foundation
import Network

/// Minimal reachability watcher used to recover a bootstrap that failed because
/// the device was offline at first launch. Fires `onReconnect` exactly on the
/// transition into a satisfied (online) path — not on every update, and not for
/// the initial state — so the SDK can retry `start()` once the network returns.
///
/// `@unchecked Sendable`: the only mutable state (`wasSatisfied`) is touched
/// solely inside the serial `pathUpdateHandler`, which `NWPathMonitor` invokes
/// one-at-a-time on the provided queue.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.salescentral.netmonitor")
    private var wasSatisfied = false

    /// Called once each time connectivity transitions from unavailable to
    /// available. Invoked on a background queue.
    var onReconnect: (@Sendable () -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.wasSatisfied {
                self.onReconnect?()
            }
            self.wasSatisfied = satisfied
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
