import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Foreground-time tracker. Listens to `UIApplication` lifecycle
/// notifications and posts a finished session to the server every time the
/// app moves to the background.
///
/// Usage:
///
///     let tracker = SessionTracker(client: salesClient)
///     tracker.start()
///
/// Lifetime is the caller's responsibility — typically hold a reference
/// on your `AppDelegate` / `@main` scene container.
@MainActor
public final class SessionTracker {
    private let client: SalesClient
    private var startedAt: Date?
    private var observers: [Any] = []

    public init(client: SalesClient) {
        self.client = client
    }

    /// Begin tracking. Idempotent.
    public func start() {
        #if canImport(UIKit)
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.foreground() })
        observers.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.background() })
        // Also flush on outright termination — best-effort.
        observers.append(nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.background() })
        // If the app boots with the scene already active, count from now.
        if UIApplication.shared.applicationState == .active {
            startedAt = Date()
        }
        #endif
    }

    public func stop() {
        #if canImport(UIKit)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        startedAt = nil
        #endif
    }

    private func foreground() {
        if startedAt == nil { startedAt = Date() }
    }

    private func background() {
        guard let start = startedAt else { return }
        startedAt = nil
        let end = Date()
        let duration = max(0, Int(end.timeIntervalSince(start)))
        let client = self.client
        Task.detached(priority: .background) {
            try? await client.recordSession(start: start, end: end, durationSec: duration)
        }
    }
}
