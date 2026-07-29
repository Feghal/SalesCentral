# Changelog

All notable changes to the SalesCentral Swift SDK are tracked here. Format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [semver](https://semver.org).

## [1.3.5] - 2026-07-29

### Changed
- **The purchase log distinguishes applied from already-processed receipts.**
  `applied N receipt(s)` counted receipts the server accepted, not effects it
  granted — an `alreadyProcessed` result is a successful receipt that granted
  nothing on that call. Reading the count as an effect count made a purchase
  that left the account on the free tier look like a clean success. The line
  now reads `N receipt(s) applied, M already processed`.

### Server
- Purchases now answer `transaction_owner_mismatch` when the transaction is
  already recorded against a different SalesCentral account, instead of
  reporting success while granting nothing. `purchase()` surfaces it as
  `.notEntitled(reason:)`, and — like `ownership_boundary` — it is NOT terminal,
  so the transaction stays unfinished for StoreKit to redeliver once the
  ownership record is repaired.

## [1.3.4] - 2026-07-27

### Fixed
- **Unfinished transactions are now drained at startup.** `Transaction.updates`
  only carries NEW updates — it never replays a transaction the app left
  unfinished in an earlier process (an upload that failed mid-flight, or a
  crash between upload and `finish()`). Nothing retried those, and StoreKit
  kept handing the stale transaction back to `product.purchase()` instead of
  opening a purchase sheet. Once its window closed — minutes, in the sandbox,
  where a monthly subscription lasts 5 — every later purchase attempt was
  rejected as `expired_transaction`, while `restorePurchases()` still worked
  (it uploads `currentEntitlements`, which only contains LIVE entitlements).
  `startObservingTransactions()` now drains `Transaction.unfinished` before
  subscribing to the live stream.
- **Transaction finishing now follows the server's verdict.** Previously any
  HTTP 200 finished the transaction, including rejections a later attempt
  could satisfy — an unregistered SKU silently ate a paid consumable that no
  restore can recover. Both the observer and `purchase()` now finish only when
  the receipt was applied or rejected permanently
  (`expired_transaction`, `revoked_transaction`, `invalid_transaction`,
  `invalid_receipt`). `product_not_registered`, `ownership_boundary`,
  `production_receipt_on_sandbox_user` and `verification_failed` stay
  unfinished so Apple's redelivery retries them. See
  `SalesClient.terminalReceiptErrors`.

## [1.3.3] - 2026-07-18

### Added
- **AppTransaction production tier (Mac Catalyst / macOS ≤ 26).** On macOS
  through version 26, where `DCAppAttestService.isSupported` returns `false`,
  the SDK can now fall back to a **per-app opt-in production tier** via StoreKit 2
  `AppTransaction` — an Apple-signed JWS present on every App Store install.
  This tier proves "App Store install" (weaker than App Attest's per-device
  binding and replayable) but is strong enough for production use under the
  following constraints: (1) per-app opt-in via `allowAppTransactionTier`
  admin flag; (2) ≤5 users per installation proof (by `appTransactionId` or
  `deviceVerification` id); (3) free signup credits excluded; (4) money
  endpoints reachable; (5) tier claim integrity depends on strong
  `USER_JWT_SECRET`. Starting macOS 27 (post-WWDC26), App Attest re-enables
  with no code change. Added error codes `invalid_app_transaction`,
  `app_transaction_bundle_mismatch`, `app_transaction_tier_disabled`,
  `app_transaction_reuse_limit` to the attestation error set. See
  [INTEGRATION.md → Mac Catalyst / macOS](../docs/INTEGRATION.md#mac-catalyst--macos)
  for full details and security posture.

## [1.3.2] - 2026-07-18

### Added
- **Registered event ("super") properties.** `SalesCentral.setEventProperties([...])`
  (and `setEventProperty` / `removeEventProperty` / `clearEventProperties`)
  registers properties that the SDK merges into every subsequent `track` /
  `trackBatch` event, so you can segment events by a persistent trait without
  passing it at each call site. Per-call properties override a registered key.
  In-memory (re-register each launch). Typical use: an analytics-only app that
  handles subscriptions elsewhere registers `["plan": "premium"|"free"]` from
  its subscription callback, then segments event analytics by `properties.plan`.

## [1.3.1] - 2026-07-18

### Added
- **Analytics outbox.** `track` / `trackBatch` / `recordSession` calls that
  can't be sent — no user yet (slow or offline first launch), network
  failures, server 5xx — are now queued in an in-memory FIFO (cap 500,
  oldest dropped) and flushed automatically once sending becomes possible:
  after the user is established, on network reconnect, or on the next
  analytics call. Events keep their ORIGINAL `occurredAt`, so late delivery
  doesn't skew timelines. `recordSession` now throws only on permanent
  (validation-class) rejections; retryable failures queue and return
  normally. Known limitation: a response lost after the server recorded a
  batch can duplicate those events on retry (the events endpoint has no
  idempotency key). The queue is memory-only — items are lost if the app
  is killed before flush — and `clearUser()` empties it.

## [1.3.0] - 2026-07-17

### Added
- **Analytics-only mode.** Set `analyticsOnly` in `SalesCentral.plist` (or on
  `SalesConfig`) to integrate the SDK without the purchase machinery: the
  transaction tokens (`applyPurchases`, `currentSubscription`, `spendCredits`)
  become optional (`claimReward` already was), the SDK never starts the StoreKit
  transaction observer / product prefetch / subscription fetch, and
  transaction APIs throw `SalesError.invalidState("analytics_only")`.
  Identity, sessions, events, user properties, push, context capture, and
  remote config / experiments are unaffected. Generate the config with the
  new "Analytics-only" toggle on the admin's SDK config card — it keeps
  every token so the file also parses on pre-1.3.0 SDKs; trimming the
  transaction tokens is optional once the app is on 1.3.0+.

## [1.2.0] - 2026-07-03

### Added
- **Spend receipts.** `spendCredits` responses now populate two new optional
  `Credits` fields: `transactionId` (the debit's ledger id) and `receipt`
  (a short-lived signed proof of the debit, HS256 JWS). For work delivered
  by your own backend, charge first and send the `receipt` with the work
  request; the backend verifies it offline with the receipt signing secret
  from the admin panel (App Detail → Credentials) and delivers only against
  a valid, unconsumed receipt. Closes the tampered-client hole where
  server-delivered work could be consumed without ever charging. Both
  fields are `nil` on non-spend sources of `Credits`; no API breakage.

## [1.1.5] - 2026-06-23

### Fixed
- "Purchase with no sheet that leaves the user free." StoreKit can hand back an
  already-owned / expired entitlement (no purchase dialog — common in sandbox);
  the SDK uploaded it and reported `.success` even though nothing new was
  granted, and the user then showed as free. Now the backend rejects receipts it
  can't honor (`expired_transaction` / `revoked_transaction` /
  `product_not_registered`) instead of granting-then-downgrading, and
  `purchase()` returns the new `.notEntitled(reason:)` case instead of a
  misleading `.success` — so the app shows the paywall rather than unlocking.
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
- `PurchaseResult.notEntitled(reason:)` — returned by `purchase()` when StoreKit
  hands back a transaction that doesn't grant a current entitlement (already
  owned / expired) and the backend rejects it. Switch on it to show your paywall
  instead of unlocking.
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
