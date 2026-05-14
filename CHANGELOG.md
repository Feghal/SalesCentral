# Changelog

All notable changes to the SalesCentral Swift SDK are tracked here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [semver](https://semver.org).

## [Unreleased]

### Changed
- `KeychainTokenStore` now mirrors the JWT to `UserDefaults` as a shadow.
  Keychain remains the primary; if a read misses (most likely after an
  App Store Connect app transfer changes the Team ID), the SDK falls back
  to the UserDefaults shadow and self-heals the keychain entry. Free
  guest users that haven't purchased anything keep their identity across
  app transfers; paying users continue to rely on `restorePurchases()`.

## [1.0.2] - 2026-05-11

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
