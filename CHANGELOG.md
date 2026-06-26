# Changelog

All notable changes to the SalesCentral Swift SDK are tracked here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [semver](https://semver.org).

## [1.1.4] - 2026-06-23

### Fixed
- Hardening pass (full-codebase bug hunt):
  - `spendCredits` no longer updates the cache stalely — `currentUser` now
    reflects the post-spend balance after the server responds.
  - `absorbBundle` no longer wipes the paywall / remote-config / experiment
    caches when a lean (or older-server) response omits those blocks; each is
    replaced only when present (matching `restorePurchases`).
  - The transaction-claim de-dupe cache now prunes oldest entries at its cap
    instead of wiping wholesale (a wipe could let an old txn be re-claimed and
    re-uploaded).
- Duplicate purchases / "not subscribed right after buying". A fresh purchase
  was uploaded twice — by `purchase()` and by the StoreKit observer — racing on
  the server; the loser hit the idempotency branch with a stale user and the
  backend then returned/persisted `premium = free`, so the app showed the
  paywall again and the user bought twice. Now the SDK de-duplicates the two
  uploads (`SalesClient.claimTransaction`), and the server re-reads the persisted
  user on an already-processed receipt so it never returns or saves stale
  entitlements (both `POST /purchases` and `POST /users/restore`). `purchase()`
  reflects the active subscription before `.success` returns.
- `clearUser()` now also wipes the stable `clientId`, so it's a genuine identity
  reset (the next create makes a new guest user) — previously the `clientId`
  survived and the create de-duplicated back to the same user.
- Offline first launch no longer breaks user creation. Previously, launching
  with no internet permanently marked the SDK "bootstrapped" with no user (so it
  never retried), and any later retry could create duplicate users. Now:
  bootstrap is **single-flight** (concurrent `start()` / `loadProducts` triggers
  share one attempt), `start()` only marks success when a user is actually
  established (so it retries), a **`NetworkMonitor`** auto-retries when the
  network returns, and the SDK sends a stable Keychain-persisted **client id**
  so a tokenless / lost-response retry resolves to the same user instead of
  duplicating (requires the matching server build).

### Changed
- Premium/trial state is now **expiry-aware on the client**. `PremiumState.isPaid`
  (and `SalesUser.isPaid` / `SalesStore.isPaid`), `SalesStore.tier`, and
  `isInTrial` now respect `expiresAt` / `trialEndsAt` — a lapsed subscription
  reports free **immediately, with no server round-trip**, fixing a bug where a
  long-running (never-killed) app kept showing "pro" after expiry. `nil`
  `expiresAt` still means no expiry (lifetime). Read `store.isPaid` / `store.tier`
  rather than the raw `user.premium.tier` to get the expiry-aware value.
- **Breaking (wire):** the `products` field in the create-or-fetch / restore
  responses is now an array of rich product objects instead of `[String]` SKU
  ids, decoded into `[SalesProduct]`. App code is unaffected — `loadProducts()`
  and the StoreKit fetch still resolve by SKU id (derived internally via
  `configuredProductIDs`). Requires the matching server build.
- **Breaking:** `spendCredits(_:reason:)` (on both `SalesClient` and
  `SalesStore`) now returns `Credits` instead of `Int`. Call sites that
  discard the result are unaffected; read `.balance` where you previously
  bound the returned `Int`.
- Date decoding now accepts ISO8601 strings with fractional seconds
  (the server's native `JSON.stringify` format, e.g.
  `2026-06-11T08:15:30.123Z`), fixing decode failures on date fields.

### Added
- `TokenStore.clearClientId()` — wipes the stored client id for a full identity
  reset (default no-op; implemented by the built-in stores). `clearUser()` calls it.
- `PremiumState.effectiveTier` — the raw `tier` while active, `"free"` once
  expired. `SalesStore.tier` now returns this.
- `SalesStore.refreshSubscription()` — cheap re-pull of subscription + premium
  that applies the server-reconciled `premium` to the cached user (so `isPaid` /
  `tier` reflect server changes like renewals / refunds, not just local expiry).
- Auto-refresh on app foreground — `bootstrap()` re-syncs subscription/premium
  when the app returns to the foreground (via a new `SessionTracker.onForeground`
  hook).
- Product effects in the catalog — apps can now read what a product *grants*
  before purchase (e.g. to render paywall benefit rows), no hard-coding.
  - `ProductEffect` — typed enum: `.setPremium(tier:durationDays:trialDurationDays:)`,
    `.grantCredits(amount:trialAmount:unlockAmount:unlockPeriod:)`,
    `.grantEntitlement(entitlement:durationDays:trialDurationDays:)`,
    `.unlockFeature(feature:)`, and `.unknown(type:)` for forward-compat.
  - `SalesProduct` — `{ productId, type, displayName, description,
    subscriptionPeriod?, effects: [ProductEffect] }`, delivered with the catalog.
  - `SalesStore.products` (`@Published`) + `SalesStore.effects(forProductID:)`;
    `SalesClient.configuredProducts` + `SalesClient.effects(forProductID:)`.
    StoreKit still owns price/title.
- Retention rewards — daily login credits with optional streaks, configured
  per app in the admin (App settings → Retention rewards; audience: all /
  free / premium users).
  - `claimReward()` on `SalesClient` and `SalesStore` — claims today's
    reward; the server enforces one claim per UTC day, eligibility, and
    streak progression, so call it wherever fits (app open or a button).
  - `RetentionStatus` (`client.retentionStatus`, `store.retention`,
    `store.rewardAvailable`) — claim availability, streak position
    ("day 3 of 7"), next amounts, `nextClaimAt`. Refreshed on every
    `ensureUser` / restore / claim.
  - `RetentionClaimResult` — granted amount / streak bonus / post-claim
    credits.
  - New optional `claimReward` token in `SalesConfig.Tokens` / the config
    plist. Existing configs keep working; regenerate from the admin's SDK
    config card to enable claiming.
- Drip-unlock credits. Products can grant credits on a release schedule
  (e.g. 36,500/year unlocking 100/day) — configured per-product in the
  admin; nothing to set up in the app.
  - `Credits.locked` — credits purchased but not yet spendable.
  - `Credits.nextUnlockAt` — when the next tranche unlocks.
  - `SalesStore.lockedCredits` / `SalesStore.nextCreditUnlockAt`
    convenience accessors.
  - On `insufficient_credits` (402), re-check `user.credits` to show
    "more credits unlock at <time>" instead of a bare paywall.
- `SalesPaywall.loadProducts()` — one-call StoreKit product loader for a
  paywall. Equivalent to `SalesCentral.loadProducts().filter` against
  `paywall.productIds`, but folds the ordering and the missing-SKU warning
  into a single ergonomic call. Shares the same prefetch cache as the
  top-level loader so calling it from multiple paywall views is free after
  first launch.
- SDK-wide verbose logging via `os.Logger` under the subsystem
  `com.salescentral.sdk` (categories: `sdk`, `http`, `store`, `paywall`,
  `push`, `session`, `observer`). Enabled in DEBUG, off in release; toggle
  anywhere with `SalesCentral.loggingEnabled = true`. Open Console.app and
  filter on the subsystem to watch boot → HTTP → StoreKit → purchase live.
- `SalesClient.setUserProperty(_:_:)` and `setUserProperties(_:)` — attach
  caller-defined attributes (name, email, plan_intent, …) to the current
  user. The admin's Users list searches across these full-text and the
  user detail drawer renders them as a typed key/value card. Values are
  scalar (`string` / `number` / `bool`); pass `nil` to delete a key.
  `SalesPropertyValue` is `Expressible*Literal` so call sites read naturally:
  `setUserProperties(["email": "alice@example.com", "lifetime_orders": 3])`.
- `SalesUser.properties` is now part of the response shape.
- Paywalls, remote config, and experiments (one shared mechanism).
  - `SalesClient.paywall(key:)` returns a server-defined paywall
    (`{ productIds, data }`). `data` is `[String: SalesAnyValue]` —
    your app picks the shape (headline / bullets / image / etc.).
  - `SalesClient.remoteConfig(_:default:)` — typed sync lookup against
    the server's remote-config store. Supports `String` / `Int` /
    `Double` / `Bool`.
  - `SalesClient.activeExperiments()` — the user's current sticky
    variant assignments, keyed by experiment.
  - `SalesClient.refreshConfig()` — force re-fetch of the paywall /
    remote-config / assignments bundle.
  - The same blocks ride on every `ensureUser` / `updateContext` /
    `restorePurchases` response, so first-launch app boot has the
    full bundle without an extra round-trip.
  - Variant assignment is server-side, sticky, and audience-gated
    (country / tier / version / device family / language). Each
    `Transaction` carries a snapshot of the assignments at purchase
    time for per-variant conversion reporting.

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
