import Foundation
import os

/// Lightweight logging for the SalesCentral SDK.
///
/// Lines route through Apple's unified logging system under the subsystem
/// `com.salescentral.sdk`, split into categories (`sdk`, `http`, `store`,
/// `push`, `paywall`, etc.). Open Console.app, filter on subsystem
/// `com.salescentral.sdk`, and you'll see the entire SDK conversation —
/// app launch through purchase round-trip.
///
/// Enabled by default in DEBUG builds, off in release. Override anywhere:
///
/// ```swift
/// SalesCentral.loggingEnabled = true   // also visible in release
/// SalesCentral.loggingEnabled = false  // silence everything
/// ```
public enum SalesLog {

    // MARK: - Toggle

    #if DEBUG
    public static var isEnabled: Bool = true
    #else
    public static var isEnabled: Bool = false
    #endif

    // MARK: - Categories

    public enum Category: String {
        case sdk       // boot / configure / reset
        case http      // HTTP requests + responses
        case store     // StoreKit product loads + purchases
        case push      // APNs token registration
        case paywall   // paywall lookup + filtering
        case session   // foreground session tracker
        case observer  // background transaction observer
        case outbox    // pre-user / offline analytics queue
    }

    // MARK: - API

    public static func debug(_ cat: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // Evaluate the autoclosure into a local before handing it to
        // `Logger`'s interpolation — that interpolation captures its
        // arguments in an escaping context, which would otherwise reject
        // our non-escaping autoclosure parameter at compile time.
        let text = message()
        loggerFor(cat).debug("\(text, privacy: .public)")
    }

    public static func info(_ cat: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        loggerFor(cat).info("\(text, privacy: .public)")
    }

    public static func warn(_ cat: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        loggerFor(cat).warning("\(text, privacy: .public)")
    }

    public static func error(_ cat: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        loggerFor(cat).error("\(text, privacy: .public)")
    }

    // MARK: - Internals

    private static func loggerFor(_ cat: Category) -> Logger {
        Logger(subsystem: "com.salescentral.sdk", category: cat.rawValue)
    }
}
