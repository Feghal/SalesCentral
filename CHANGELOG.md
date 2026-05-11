# Changelog

All notable changes to the SalesCentral Swift SDK are tracked here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [semver](https://semver.org).

## [Unreleased]

## [1.0.0] - 2026-XX-XX

### Added
- `SalesConfig` with per-app token URLs.
- `SalesClient` actor: `ensureUser`, `updateContext`, `restorePurchases`,
  `applyReceipts` / `applyReceipt`, `currentSubscription`, `spendCredits`,
  `recordSession`, `track` / `trackBatch`, `clearUser`.
- `StoreKitObserver` — auto-uploads `Transaction.updates` JWS to the server.
- `SessionTracker` — records foreground time on `UIApplication` lifecycle.
- `SalesStore` — `ObservableObject` SwiftUI wrapper.
- `UserContext.current()` — automatic device/locale/app capture.
- `TokenStore` protocol with `KeychainTokenStore` (default) and `InMemoryTokenStore`.
- `SalesError` with `.code` for branching (`insufficient_credits`, …).
