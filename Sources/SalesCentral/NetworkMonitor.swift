import Foundation
import Network

/// Minimal reachability watcher. Fires `onReconnect` on the transition into
/// a satisfied (online) path — not on every update. NOTE: NWPathMonitor
/// delivers the CURRENT path as its first update and `wasSatisfied` starts
/// false, so a monitor started while already ONLINE fires once immediately.
/// Both call sites accept that: the bootstrap-retry monitor starts only
/// after an offline failure (first update is unsatisfied), and the outbox
/// monitor treats the immediate fire as one bounded extra flush attempt
/// per backlog episode.
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
