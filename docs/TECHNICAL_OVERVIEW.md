# ADBLX — Technical Overview (Single Source of Truth)

**Status:** Written 2026-09-09 at `32e2d93`. **Revised 2026-10-27** for the commits since then: §3.1, §3.2, §3.4, §6.3, §7A and §10 reflect the Layer 3 startup-race fix, the logging and CI changes, the compiler hardening and the DNS resolver wiring. Other sections are as of 2026-09-09.
**Purpose:** The one document that describes the whole app — every target, screen, extension, pipeline, the backend, CI/CD, and the backlog. When this doc and an older doc disagree, this doc wins. Deeper detail lives in the linked ADRs / Architecture / Audit / Validation files; §12 is the map.

> **Reading note on staleness.** `README.md`, `agent.md`/`AGENT.md`, `backend/README.md`, `docs/Architecture/TargetTopology.md`, and `docs/Architecture/Publisher.md` are all frozen at Sprint 2–8.05 and describe a codebase 6–9 sprints behind reality. `docs/AppStoreSetup.md` has pricing that contradicts the accepted monetization decision. Treat those as historical. See §11 for the full stale-doc list.

---

## 1. Product summary

ADBLX (working title "SHIELD") is an **iOS / iPadOS / macOS / visionOS ad and tracker blocker**. It blocks ads and trackers in Safari for free, and — for premium subscribers — adds device-wide DNS-level blocking and YouTube-in-Safari ad blocking.

**Three enforcement layers:**

| Layer | Mechanism | Tier | Runtime cost |
|---|---|---|---|
| **1 — Safari Content Blockers ×4** | Declarative WebKit content-blocking JSON (Ads / Privacy / Annoyances / Regional), ≤150K rules each | Free (Ads, Privacy) + Premium (Annoyances, Regional*) | Zero — WebKit compiles rules into a DFA, no per-request code |
| **2 — Local DNS packet tunnel** | On-device `NEPacketTunnelProvider` that answers blocked domains with NXDOMAIN and forwards the rest to a public resolver | Premium | ~1.3%/day battery (short-run measured; 24h soak still pending) |
| **3 — Safari Web Extension** | Manifest V3 extension injecting a DOM-state engine on `youtube.com` in Safari | Premium | Energy indistinguishable from baseline (Sprint 9 Gate C) |

\* Regional (India) filter category is wired end-to-end but **no production Regional filter list is registered yet** — the manifest ships 3 lists, not 4.

**Hard constraints (never violate — from the PRD):**

- **Zero data collection.** No third-party analytics/SDKs touching browsing data. Only MetricKit (aggregate, on-device). Logging policy (`docs/Architecture/Logging.md`): counts/durations/sizes/versions/checksums only — never URLs, domains, hostnames, rule text, cookies, or query strings, with no debug-build exception.
- **Never claim in-app YouTube/Facebook blocking.** Safari only. Marketing copy says "YouTube in Safari". (PRD NG1)
- **No on-device ML / per-query inference on the DNS tunnel hot path.** (PRD NG6 — verified respected: the hot path is a deterministic mmap binary search.)
- **Content-blocker rule compilation happens only in the main app**, never in extensions (~6MB extension memory limit).
- **Filter-list licenses are GPL / CC-BY-SA.** Attribution + pre-ship legal review required. The rule compiler is a **clean-room native Swift implementation** (ADR-0002) specifically to avoid linking GPL code (`SafariConverterLib`).

**Free vs Premium (as actually enforced in code today):**

| Capability | Free | Premium | Enforced where |
|---|---|---|---|
| Safari Ads + Privacy blocking | ✅ | ✅ | Always on |
| Safari Annoyances + Regional blocking | ⚠️ **not gated in the app UI** | ✅ | Only at install time — `UpdatePlanner` emits `.skipPremium` for `premium:true` manifest entries when not entitled. The Protection-tab category toggles and per-list rows are freely toggleable; `FilterListEntry.isPremium` is hardcoded `false` in `RealProtectionService`. |
| Filter auto-updates | ✅ | ✅ | Not gated |
| Per-site allowlist | ✅ | ✅ | Not gated |
| DNS Protection | ❌ | ✅ | `DNSProtectionViewModel` — paywall sheet on toggle if not entitled; live tunnel teardown on entitlement lapse |
| YouTube-in-Safari (Web Extension) | ❌ | ✅ | `background.js` fails closed unless the native bridge reports `premiumActive` |
| iCloud Sync | ❌ | ✅ (status only) | `ICloudSyncCoordinator` gates every op on `isPremiumEntitled()`; the Settings row is display-only (see §4.6) |

**Trial & pricing (PD-01, accepted 2026-08-26 — supersedes PRD §9):** 15-day universal trial, entirely app-side (Keychain, no payment info, monotonic anti-rollback). Product IDs and prices, **frozen**:

- `com.ADBLX.ADBLX.premium.monthly` — $1.99 / month
- `com.ADBLX.ADBLX.premium.annual` — $14.99 / year (the anchor)
- `com.ADBLX.ADBLX.premium.lifetime` — $39.99 one-time

> ⚠️ `docs/AppStoreSetup.md` and `Config/Configuration.storekit` still say **$19.99 / $49.99, no monthly**. PD-01 + Sprint 11 override that. Reconciling those two files is open backlog (§10).

---

## 2. Architecture at a glance

```
                                   ┌─────────────────────────────────────────────┐
                                   │              ADBLX.app (main app)            │
                                   │  SwiftUI · AppCompositionRoot (DI, no        │
                                   │  singletons) · 4 tabs                        │
                                   │                                             │
   backend (static, GitHub Pages)  │  ┌───────────────────────────────────────┐  │
   ┌─────────────────────────────┐ │  │ Filtering/  (main-app target ONLY)     │  │
   │ Publisher CLI (Swift)        │ │  │  validate → compose → compile (ABP →   │  │
   │  registry/ + metadata/ +     │ │  │  Safari JSON, ADBLXShared) → partition │  │
   │  public/filters/*.txt        │ │  │  → WKContentRuleListStore DFA gate →   │  │
   │        │  generate           │ │  │  atomic write → persist → reload       │  │
   │        ▼                     │ │  │  + Updates/ (manifest fetch, ETag/304, │  │
   │  public/manifest.json  ──────┼─┼──┼─▶ download, sha256 verify, txn+rollback│  │
   │        │  publish-pages.sh   │ │  │  + WebExtension/  (publish rules +     │  │
   │        ▼                     │ │  │     entitlement to App Group)          │  │
   │  gh-pages branch ──▶ Pages   │ │  │  + DNS/  (compile block/allow .bin     │  │
   │  999sreeharsha.github.io     │ │  │     artifacts to App Group)            │  │
   └─────────────────────────────┘ │  └───────────────────────────────────────┘  │
                                   └───────────────┬─────────────────────────────┘
                                                   │ App Group: group.com.ADBLX.shared
                          ┌────────────────────────┼───────────────────────┬──────────────────┐
                          ▼                        ▼                       ▼                  ▼
              ┌───────────────────┐   ┌───────────────────────┐  ┌──────────────────┐  ┌─────────────┐
              │ 4× Content Blocker │   │ ADBLXPacketTunnel      │  │ ADBLXSafari      │  │ (reads:     │
              │ extensions         │   │ (NEPacketTunnelProvider)│  │ WebExtension     │  │  Compiled/, │
              │ read Compiled/     │   │ reads DNS/generations/ │  │ reads WebExt/    │  │  DNS/,      │
              │ <Group>.json       │   │ *.bin (mmap)           │  │ generations/,   │  │  WebExt/)   │
              │ (bundled fallback) │   │ Layer 2 · premium      │  │ entitlement.json │  │             │
              │ Layer 1            │   │                       │  │ Layer 3 · premium│  │             │
              └───────────────────┘   └───────────────────────┘  └──────────────────┘  └─────────────┘
```

**Key invariants:**

- The **main app is the only place rules are compiled.** Extensions are read-only consumers of files in the shared App Group container.
- **Everything the app publishes to the container is written atomically** (temp file → `F_FULLFSYNC` → rename, or staging-dir move + pointer swap) so an extension never observes a partial file, even mid-crash.
- **Filter lists are fetched and compiled client-side from a CDN manifest** — new lists ship without an app update.
- **DNS blocklists are the exception:** they are bundled in the app binary (`oisd`, `peter-lowe`), with **no live-update path** — every DNS rule change needs an app release (see §6, §10).

---

## 3. Build system & project topology

### 3.1 Build system

- **Xcode project is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen).** `ADBLX.xcodeproj` is a committed build artifact — **never hand-edit it.** To change project structure: edit `project.yml`, run `xcodegen generate`, commit both.
  ```bash
  brew install xcodegen && xcodegen generate && open ADBLX.xcodeproj
  ```
- **No XcodeGen version is pinned** in `project.yml` — only prose in `TargetTopology.md` says "2.45.4+". CI's `brew install xcodegen` is unpinned. The 2026-09-09 draft of this doc claimed the committed `project.pbxproj` came from an older XcodeGen and failed the drift gate; **that did not reproduce on 2026-10-27**: regenerating with XcodeGen 2.45.4 from a clean checkout of `dev` left the whole repository unchanged. Reproducibility across other XcodeGen versions is untested, so pinning is still worthwhile — see §10.
- **Build settings:** `Config/Base.xcconfig` (warning/analyzer hardening — treats many warnings as errors), `Config/Debug.xcconfig`, `Config/Release.xcconfig`. `configFiles:` in `project.yml` wires only Debug/Release; `Base.xcconfig` is pulled in via `#include` at the top of each. `SWIFT_VERSION` and deployment targets are per-target in `project.yml`, not in the xcconfigs.
- **`DEVELOPMENT_TEAM`** = `93F78RF6FG`, set once in `project.yml` `settings.base`, inherited by every target. `CODE_SIGN_STYLE: Automatic` everywhere. No provisioning profiles checked in. (The DNS tunnel needs a **paid Apple Developer Program** membership to provision `packet-tunnel-provider`; the Sprint 11 hardware runs confirm this is now in place — the "Personal Team" language in older docs is stale.)
- **Lint/format:** `.swiftlint.yml` runs as a **non-failing pre-build phase**, and only over `ADBLX/` — `Extensions/` and both test targets are excluded. Custom rule `no_hardcoded_ui_string` bans hardcoded strings in `Text`/`Label`/`Button` (forces `Localizable.xcstrings` keys). `.swift-format` config exists but nothing invokes it.
- **Scheme:** exactly one, `ADBLX` (auto-scheme generation off). Builds the app + all 6 extensions; Test action runs `ADBLXTests` + `ADBLXUITests`.
- **`Config/Configuration.storekit`** (lifetime $39.99 / monthly $1.99 / annual $14.99) is the only StoreKit configuration. `project.yml` attaches it to the `ADBLX` scheme's Run action (`storeKitConfiguration`), so Xcode runs on a simulator or device use it. Set it there, not in Xcode's scheme editor: `xcodegen generate` overwrites the scheme. Older audit reports call it `Products.storekit`; no file by that name exists.

### 3.2 Targets (9)

Every buildable target is genuinely **multi-destination**: `platform: auto`, `supportedDestinations: [iOS, macOS, visionOS]`, `SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"`, `TARGETED_DEVICE_FAMILY: "1,2,7"`, all three deployment targets = `26.5`, `SWIFT_VERSION: 5.0`, `MARKETING_VERSION: 1.0`. Real macOS (AppKit `LD_RUNPATH` override present), **not Catalyst** — this was inherited from Xcode's multiplatform template and preserved, not decided; a "Platform Strategy ADR" is named-but-unwritten.

| Target | Product type | Bundle ID | NSExtension point / principal class | App Group | Links `ADBLXShared` |
|---|---|---|---|---|---|
| `ADBLX` | application | `com.ADBLX.ADBLX` | — | ✅ | ✅ (+ embeds all 6 extensions) |
| `ADBLXAdsBlocker` | app-extension | `com.ADBLX.ADBLX.AdsBlocker` | `com.apple.Safari.content-blocker` / `ContentBlockerRequestHandler` | ✅ | ❌ |
| `ADBLXPrivacyBlocker` | app-extension | `com.ADBLX.ADBLX.PrivacyBlocker` | same | ✅ | ❌ |
| `ADBLXAnnoyancesBlocker` | app-extension | `com.ADBLX.ADBLX.AnnoyancesBlocker` | same | ✅ | ❌ |
| `ADBLXRegionalBlocker` | app-extension | `com.ADBLX.ADBLX.RegionalBlocker` | same | ✅ | ❌ |
| `ADBLXPacketTunnel` | app-extension | `com.ADBLX.ADBLX.PacketTunnel` | `com.apple.networkextension.packet-tunnel` / `PacketTunnelProvider` | ✅ | ✅ |
| `ADBLXSafariWebExtension` | app-extension | `com.ADBLX.ADBLX.SafariWebExtension` | `com.apple.Safari.web-extension` / `SafariWebExtensionHandler` | ✅ | ✅ |
| `ADBLXTests` | bundle.unit-test | `com.ADBLX.ADBLXTests` | — | ❌ | ✅ |
| `ADBLXUITests` | bundle.ui-testing | `com.ADBLX.ADBLXUITests` | — | ❌ | ❌ |

Plus two SPM packages, **not** in the Xcode project:

- **`Packages/ADBLXShared`** (swift-tools 5.9, iOS 17 / macOS 14 / visionOS 1, **zero external dependencies** — the ADR-0002 clean-room requirement). Holds the ABP rule compiler, the DNS artifact format types, and the Web Extension bridge types. Consumed by app + PacketTunnel + SafariWebExtension + tests.
- **`backend/tools/Publisher`** (swift-tools 6.0, macOS 13, depends on `swift-argument-parser`). The filter-manifest publishing CLI. Completely separate from the Xcode build; **no CI job builds or tests it.**

- Extension bundle IDs **must** be dotted-nested under the app's (`com.ADBLX.ADBLX.<Suffix>`) — a hard iOS requirement. `ADBLXTests`/`ADBLXUITests` use the flat `com.ADBLX.<Target>` form.
- **App Group:** single identifier `group.com.ADBLX.shared` on 7 targets. `REGISTER_APP_GROUPS: YES` on all except `ADBLXPacketTunnel` (minor undocumented inconsistency). **Exception:** `DNSProtectionSettingsStore` uses `UserDefaults(suiteName: "group.com.ADBLX.ADBLX")` — a *different* suite string — for DNS settings keys only (not artifact paths). Bug-flag in §10.
- `ADBLX` also carries `com.apple.developer.ubiquity-kvstore-identifier` (iCloud KVS, for sync) and `com.apple.developer.networking.networkextension: [packet-tunnel-provider]`.
- **Entitlements and Info.plists are generated** from `project.yml`; never hand-edit them. Commit `32e2d93` hand-edited `ADBLX.entitlements` to add the iCloud KVS key, and any `xcodegen generate` then silently deleted it (breaking iCloud sync with no error). Fixed by declaring the key in `project.yml`. The Safari Web Extension target also declares `excludes: ["Tests/**"]` and `SFSafariWebExtensionManifestPath: "."` there.

### 3.3 App Group container layout

```
group.com.ADBLX.shared/
├── Filters/                         Raw verified source payload, one <filterID>.json per source
│   └── DNS/                         Bundled DNS blocklist snapshots (oisd, peter-lowe)
├── Compiled/
│   ├── Ads.json  Privacy.json       One partitioned, compiled Safari-CB JSON per FilterGroup.
│   ├── Annoyances.json Regional.json   Written ONLY by AtomicRuleWriter. Read by the 4 CB extensions.
├── Metadata/
│   ├── installed_filters.json       [InstalledFilter]  (ruleCount is GROUP-level, not per-source)
│   ├── manifest.json                CachedManifest (FilterManifest + ETag + signatureVerified)
│   ├── statistics.json              RuleStatistics (last compile pass)
│   ├── filter_preferences.json      Per-category / per-list enable flags
│   ├── allowlist.json               [AllowlistEntry]  (user allowlist)
│   └── update_throttle.json         Last successful update timestamp (6h throttle)
├── Previous/                        Transient rollback snapshot ({Compiled,Metadata,Filters}) — exists only during an UpdateCoordinator batch
├── WebExtension/
│   ├── current.json                 Atomic pointer → active generation
│   ├── generations/<NNNNNN>/{rules.json, manifest.json}
│   ├── entitlement.json             {state: premiumActive|free, updatedAt}  (independent lifecycle)
│   └── staging/
└── DNS/
    ├── current.json                 Atomic pointer → active generation
    ├── generations/<NNNNNN>/{block.bin, allow.bin, manifest.json}
    └── staging/
```

`FilterStore` (an `actor`) is the **only** type in the main app allowed to call `containerURL(forSecurityApplicationGroupIdentifier:)`; everything else routes through it. Extensions have their own minimal read-only container access.

### 3.4 CI/CD

- **`.github/workflows/ci.yml`** — on push/PR to `dev`/`main` + manual. `macos-15`. Steps: checkout → latest-stable Xcode → `brew install xcodegen` → `xcodegen generate` → **drift gate** (`git diff --exit-code`, whole repository, so generated entitlements and plists are covered too) → **AppGroup.swift byte-identity gate** (the 4 CB extensions' copies must be `cmp`-identical to `ADBLX/AppGroup.swift`) → discover an iOS simulator UDID → build the `ADBLX` scheme → `xcodebuild ... -only-testing:ADBLXTests test`.
- **Not in CI:** no caching, no artifacts, no release automation; `ADBLXUITests` excluded; **no macOS/visionOS build**; **no `ADBLXShared` standalone test**; **no `backend/tools/Publisher` build or test**; **no run of the Safari Web Extension's JS test suites** (there is no `package.json` — the `node:test` suites run only locally).
- **`.github/workflows/deploy-pages.yml`** — on push to the `gh-pages` branch. Publishes the branch contents verbatim to GitHub Pages. It builds nothing — `publish-pages.sh` (run locally) is what populates `gh-pages`.
- **Test count:** ~335 test declarations in `ADBLXTests` + suites in `ADBLXShared` + 44 in `Publisher` + 3 JS suites. Recent whole-suite runs: "215/215" (Sprint 11), all green.
- **`Scripts/find-simulator-udid.sh`** mirrors CI's simulator-discovery logic for local `xcodebuild` runs. Given a UDID, it checks that simulator exists instead. Each session should test on a simulator of its own (`docs/gotchas.md`).

---

## 4. The app — screens & navigation

### 4.1 Entry & composition

- **`ADBLXApp.swift`** (`@main`) constructs the object graph once in `init()` via **`AppCompositionRoot`** (a `enum` of factory functions — dependency injection, no global singletons, though a handful of `private static let` shared instances exist for trial/subscription/coordinators). Real services throughout: the `UIDependenciesConfiguration` enum has only a `.mock` case left, but `makeUIDependencies(.mock, ...)` builds **all Real implementations** (`RealHomeService`, `RealProtectionService`, `RealSettingsService`, real `StoreKitSubscriptionService`, real `UpdateCoordinator`). The `Mock*` services are preview/test-only.
- **Launch sequence** (`.task` on the root scene, skipped under XCTest):
  1. `trialExpiryRouter.evaluateRoute()`.
  2. Detached `.utility` task: `ContentBlockerBootstrap.ensureInitialRulesInstalled` → resolve premium entitlement → `WebExtensionBootstrap.ensureInitialWebExtensionRulesInstalled` → start the Web Extension entitlement coordinator + trial notification scheduler → **if `UpdateThrottle.shouldRun` (6h): `UpdateCoordinator.run()`** and record success.
- **No `BGAppRefreshTask` / background scheduling** anywhere. Updates are foreground-launch-only, throttled to 6h. PRD FR-03's 12–24h background refresh is not built.
- **`MetricsSubscriber`** registers with `MXMetricManager` and only logs "received N payloads" — no persistence, no upload.

### 4.2 Navigation — `RootTabView` / `AppTab`

Four fixed tabs, order frozen, none premium-gated:

| # | Tab | Icon | Hosts |
|---|---|---|---|
| 1 | Home | `house.fill` | `HomeView` (no `NavigationStack`) |
| 2 | Protection | `shield.fill` | `NavigationStack { SafariProtectionView }` |
| 3 | Premium | `star.fill` | `NavigationStack { PremiumView }` |
| 4 | Settings | `gearshape.fill` | `NavigationStack { SettingsView }` |

### 4.3 Home (`Features/Home/`)

Dashboard driven by `RealHomeService` reading `installed_filters.json`.

- **Real:** "Last Update" and "Rules" stat tiles (`ruleCount` summed per-group, taking the first entry per group to avoid the group-level-count double-count); the activity feed (every entry is a `.filtersSynchronized` item — Safari gives the app no block-event callback, so there is no real "trackers blocked" count); "Update Filters" button → `UpdateProgressSheet` → real `UpdateCoordinator.run(onPhaseChange:)`.
- **Placeholder / inert:** hardcoded `Text("v4.2.0")` version pill; "Safari" and "DNS" stat tiles show hardcoded strings; **"Reload Safari" button only re-fetches `HomeStatus`** — it does not reload content blockers; the profile icon is non-interactive.
- `isProtectionEnabled` is `true` whenever any filter is installed — it is **not** a real Safari-extension-enabled check. `HomeViewModel.loadWithBootstrapRetry` retries 3× to paper over a cold-launch race with the detached bootstrap.

### 4.4 Protection (`Features/Protection/`)

- **`SafariProtectionView`** — 4 category toggles (Ads/Privacy/Annoyances/Regional) backed by `FilterPreferencesStore` + **real `SFContentBlockerManager` state** via `SystemContentBlockerStateProvider`. Master state derives `.active` / `.partiallyActive` / `.disabledInSettings` / `.disabledByUser` / `.unavailable`. Toggling a category whose extension is disabled in Settings raises an "Open Settings" alert. **Real.**
  - **Placeholder / inert:** hero card "4,281 threats blocked" is a hardcoded literal; **"Speed Optimization" row has no action**; the premium-upsell card shows even to premium users.
  - Nav rows (real): "Advanced Filter Lists" → `AdvancedFilterListsView`; "DNS Protection" → `DNSProtectionView`; "Report Broken Site" → `BrokenSiteReportView` sheet.
- **`AdvancedFilterListsView`** — per-list enable/disable toggles, **real persistence** to `FilterPreferencesStore`. **But** `isPremium` is hardcoded `false` for every row, so no list is ever visually locked; and the **"Apply Changes" button only calls `load()`** — it does not recompile/reload the pipeline.
- **`DNSProtectionView`** (all strings hardcoded English, `swiftlint:disable`) — master toggle bound to a **real `NEPacketTunnelProvider`-backed** `RealDNSProtectionService` (provider bundle `com.ADBLX.ADBLX.PacketTunnel`); resolver selection (Quad9 / custom IPv4+IPv6); DNS allowlist add/remove (FR-08, zero-restart). Entitlement lapse → forced teardown + `isEnabled = false`. One-time activation disclosure alert.
- **Dead code:** `DNSFilteringSpikeView` / `DNSFilteringSpikeManager` (`swiftlint:disable all`, "8B-0.1A" spike) — not hosted anywhere.

### 4.5 Premium (`Features/Premium/`)

- **`PremiumView`** — pricing cards from `StoreKitSubscriptionService.fetchStatus()` (real `Product.products(for:)`); tapping a card runs a **real StoreKit 2 purchase**; "Restore" runs `AppStore.sync()`. If StoreKit returns no products (e.g. no config wired), the pricing section renders empty.
  - **Inert:** the **"Manage" button is an empty closure `{}`**; the comparison table is entirely hardcoded `Bool` literals.
- **Subscription/entitlement stack:**
  - `StoreKitSubscriptionService` (an `actor`, the app-wide instance) implements **both** `SubscriptionService` and `EntitlementService`. It is the single source of truth for entitlement: folds `Transaction.currentEntitlements` + the app-side trial into an `EntitlementState` (`lifetime > annual > monthly > trial > free`), and publishes changes via an `AsyncStream`. Transaction listener + foreground observer keep it fresh.
  - **Trial** (`Features/Premium/Trial/`): `TrialManager` (`actor`) + `TrialKeychainStore` (Keychain, survives reinstall, `kSecAttrAccessibleAfterFirstUnlock`) — 15-day record, monotonic `effectiveDate = max(now, lastObserved)` anti-rollback. `TrialNotificationScheduler` schedules 5 `UNCalendarNotificationTrigger` milestones (day 5/9/12/14/15), cancels them on any non-trial state. `TrialExpiryRouter` (`@Observable @MainActor`) watches the entitlement stream + foreground; on expiry-without-purchase-and-without-explicit-free-choice it force-presents a **non-dismissible `TrialExpiredDecisionView`** (`.fullScreenCover`) with equal-weight "View Plans" / "Continue Free" (the latter sets a one-time `userChoseFreeTier` Keychain flag).
  - No StoreKit-level intro offer — the trial is 100% app-side.

### 4.6 Settings (`Features/Settings/`)

Row-by-row status (verified against source; several rows are **deliberately half-wired** per Sprint 5B design):

| Row | Real behavior | Status |
|---|---|---|
| **Appearance** | `NavigationLink` → picker; persisted via `@AppStorage(AppearancePreference.storageKey)` (UserDefaults), applied via `.preferredColorScheme` at the app root; colors are adaptive asset-catalog tokens | ✅ Real, device-local |
| **Language** | Displays `Locale.current` language name; **no action** | ⚠️ Read-only — cannot change the app's language |
| **Notifications** | `NavigationLink` → `ComingSoonState` placeholder | ⚠️ Placeholder — no `UNUserNotificationCenter` permission wiring here |
| **Safari Help** | `NavigationLink` → `ComingSoonState` | ⚠️ Placeholder |
| **iCloud Sync** | Shows `PremiumBadge` + "on/off" where "on" == `isPremiumEntitled()`. No toggle, no action. | ⚠️ Display-only. `ICloudSyncCoordinator` exists (backed by `NSUbiquitousKeyValueStore`) and its **write path is live** (allowlist add/remove push to iCloud KVS via `RealSettingsService`), but **`startObserving()` is never called** — nothing pulls remote changes. And it syncs **only the allowlist**, not enabled filters (PRD FR-13 wanted both). |
| **Allowlist** | Add/remove domains; persisted via `AllowlistStore` (`allowlist.json`, atomic), then `pipeline.syncAllowlist()` is invoked | ✅ Storage + pipeline sync from the UI. Whether a listed domain is actually *exempted* from blocking depends on `SafariAllowlistCompiler` / `FilterPipeline.syncAllowlist` — enforcement was added after the "storage-only" gotcha was written; DNS allowlist enforcement is solid (ADR-0009), Safari-side unification is a Gate C2 conditional (§10). |
| **Report Broken Site** | Button → `BrokenSiteReportView` sheet | ✅ Real (mail) |
| **About** | `NavigationLink` → `AboutView` (real bundle version) → `FilterAttributionView` (hardcoded EasyList/EasyPrivacy/Fanboy attribution) | ✅ Real |

> `AboutView` links point to `https://adblx.app/*` while the manifest/report endpoints use `999sreeharsha.github.io/ADBLX`. `adblx.app` is likely unregistered — domain inconsistency to resolve.

### 4.7 Onboarding (`Features/Onboarding/`)

- **Live:** `TrialOnboardingView` — shown when `!hasCompletedOnboarding` (UserDefaults). "Start 15-day trial" (activates trial + requests notification auth) or "Continue Free" (no trial record). **No Safari-extension-enable detection or guidance** — FR-07 is not implemented.
- **Dead code:** `OnboardingView` (the older one, with static 3-step "enable in Settings" text) — only referenced in its own `#Preview`.

### 4.8 Broken Site reporting (`Features/BrokenSite/`)

- `BrokenSiteReportView` — domain field and breakage category picker. "Review Report" shows the whole report, then "Send by Mail" opens it. "Allow This Site" is a separate button.
- `RealBrokenSiteReporter` (`actor`) — sanitizes the domain to eTLD+1 (`SafariDomainNormalizer`) and builds a `BrokenSiteReport` (domain, category, app version, enabled groups; **no paths, cookies, or identifiers**). It never uses the network. Allowlisting goes through `SettingsService`, so the rules recompile.
- Delivery is a `mailto:` URL, falling back to the clipboard when no mail app opens. `BrokenSiteReport.recipient` is still `nil`, so the user fills in To. There is no backend (FR-14).

### 4.9 Update Progress (`Features/UpdateProgress/`)

- `UpdateProgressSheet` + `UpdateProgressModel` — on appearance, calls the **real** `UpdateCoordinator.run(onPhaseChange:)`; phases (`checking` / `downloading` / `installing` / `complete` / `failed`) are driven live by the coordinator.
- Triggered from Home's "Update Filters" button. (`SafariProtectionView` declares the sheet but has no live trigger for it anymore.) The launch-time `UpdateCoordinator.run()` call is separate and headless.

### 4.10 Design system (`ADBLX/DesignSystem/`)

Tokens transcribed verbatim from a Stitch design ("Serene Shield Unified", **dark theme only** — no light-mode color variants). `DesignColors` (hex constants), `DesignTypography` (Manrope / Inter families — **font files not bundled**, so it renders as system font), `DesignSpacing`, `DesignShape` ("Rounded Twelve"). Components: `Card`, `ComingSoonState`, `PremiumBadge`, `PrimaryButton`, `SettingsRow`, `ToggleRow` (defined + tested but **used by no feature screen** — Protection/DNS build their own inline toggles).

---

## 5. Filtering pipeline — Safari Content Blockers (Layer 1)

All of `ADBLX/Filtering/` is **main-app-target only**. The 4 CB extensions never compile — they only read finished JSON.

### 5.1 The pipeline — `FilterPipeline` (an `actor`)

`validate → compose → compile → partition → WKContentRuleListStore DFA gate → atomic write → persist metadata → reload`

| Stage | Type | What it does |
|---|---|---|
| Validate | `FilterValidator` | Rejects empty / >50MB / non-UTF-8 payloads. A sanity guard, not a rule budget. |
| Compose | `JSONArrayCompositionService` | Merges every `FilterSource` in a `GroupComposition` into one payload (decode-concat-reencode, `.sortedKeys` — deterministic). Handles both JSON-array (bundled fixtures) and ABP-text sources. Appends the compiled allowlist exception rules. |
| Compile | `NativeRuleCompilerAdapter` → **`ADBLXShared.NativeABPRuleCompiler`** | **Real ABP → Safari-CB-JSON compilation** (see §7B). Empty / already-JSON-array input passes through; real ABP text goes through the 2-pass compiler. (The old `PassthroughRuleCompiler` stub is test-only now. The ADR-0001/SafariConverterLib comment in `AppCompositionRoot` is stale.) |
| Partition | `GroupPartitioner` | Enforces the **150,000-rule-per-extension budget** (throws if exceeded). Maps a group to its extension bundle ID (`GroupExtensionIdentifiers`, exhaustive switch). Does not actually split — it's a budget gate + identifier lookup. |
| DFA gate | `WKContentRuleListStore.compileContentRuleList` | Before writing to disk, proves Safari's own runtime DFA compiler accepts the exact JSON. Rejection → `FilterPipelineError.webKitCompilationRejected`. (100% acceptance on the real corpus per Sprint 10.) |
| Write | `AtomicRuleWriter` | temp file → `F_FULLFSYNC` → rename. On any failure the destination is left untouched (FR-05 "keep last-good rules"). |
| Persist | `FilterStore.writeMetadata` | `installed_filters.json` (+ `statistics.json`). ⚠️ **Every same-group entry gets the whole group's aggregate `ruleCount`** — `InstalledFilter.ruleCount` is group-level, not per-source (`ComposedRules` never tracked per-source counts). |
| Reload | `ReloadCoordinator` | The **sole** call site of `SFContentBlockerManager.reloadContentBlocker` in the app. Every reload is bounded by a **10s timeout** (races an unstructured Task against the completion callback). `.immediate` reloads now; `.deferred` lets `UpdateCoordinator` batch one reload per affected extension at the end. |

**Entry points:** `install(_ composition:reloadStrategy:)`, `remove(filterID:group:reloadStrategy:)`, `syncAllowlist(reloadStrategy:)`, `installBundledSnapshotIfNeeded()` (per-group bundled baseline from `easylist.txt` / `easyprivacy.txt` / `fanboy-annoyances.txt` — no bundled Regional source).

### 5.2 The update pipeline — `Filtering/Updates/`

`UpdateCoordinator` (an `actor`) runs one transaction:

```
checking:   ManifestStore.load() → ManifestClient.fetch(previousETag:cached:)   [304 → upToDate, stop]
              on 200: fetch signatures/<sha256>.sig → ManifestVerifier       [signature, then every rule]
              rejected → nothing written, pending reloads retried, throw ManifestRejection
              unchanged (same version and content) → save new ETag, upToDate
            UpdatePlanner.plan(manifest, installed, isPremiumEntitled)     [pure diff, no I/O]
downloading: for every .install group: FilterDownloadClient.download each entry,
             then Checksum.verify(sha256) every file      [ALL groups verified before ANY write]
snapshot:   FilterStore.snapshotForRollback()             [copies Compiled/ + Metadata/ + Filters/ → Previous/]
installing: per group: FilterPipeline.install(GroupComposition, .deferred)
            per removal: FilterPipeline.remove(filterID:group:, .deferred)
commit:     ManifestStore.save(manifest, etag) → discardRollbackSnapshot()
            → ReloadCoordinator.reload(affected extensions)   [one reload each]
on any failure past download: FilterStore.restore(snapshot)   [→ .rolledBack]
            if restore itself throws → .rollbackFailed (snapshot left on disk, no auto-retry)
finally:    FilterDownloadClient.cleanupWorkspace()      [every exit path]
```

- **ETag / `If-None-Match` / 304** caching in `ManifestClient`. `HTTPSession` protocol seam → `MockHTTPSession` for tests (only the disabled live suite hits a real endpoint). Test manifests are signed with a test key through `SignedManifests` (`ADBLXTests/Filtering/Updates/`).
- **Manifest signatures (SEC-09):** `ManifestVerifier` with the keys and allowed base in `ManifestTrust`, and the built-in minimum from `BundledManifest`. See `docs/Security/ManifestTrust.md`. Until K1 and K2 are pinned, every manifest is rejected and the app stays on its bundled lists.
- **`RedirectGuard`** is the delegate of the app's one `URLSession`: no redirect off the original host or off HTTPS.
- `UpdatePlanner` emits `.install(group:entries:)` / `.keep` / `.remove(filterID:)` / `.skipPremium(entry)`.
- **`UpdateThrottle`** (an `actor`, `update_throttle.json`, 6h interval) is the scheduling policy, deliberately kept outside the transactional actor; `AutomaticUpdate.runIfDue` applies it at launch. It records on success and on a rejected manifest; any other failure stays retryable next launch.
- In-flight guard: concurrent callers await the same task; a generation counter closes a 3+-caller race.
- **Manifest endpoint (live):** `https://999sreeharsha.github.io/ADBLX/manifest.json` (GitHub Pages + Fastly CDN). Verified end-to-end on an iPhone 14 (200 + ETag, then 304, full OTA install + rollback).

### 5.3 The 4 Content-Blocker extensions

All 4 (`ADBLX{Ads,Privacy,Annoyances,Regional}Blocker`) are **structurally identical and fully migrated** — no "only Ads is real" situation. Each `ContentBlockerRequestHandler.beginRequest` resolves rules in this order, fresh every request:

1. App Group `Compiled/<Group>.json` — if present, use it.
2. Bundled `Resources/blockerList.json` (tiny placeholder fixtures) — fallback for first launch or a missing/corrupt container file.

Both paths are logged (`os.Logger`, subsystem `com.ADBLX.ADBLX`, category `AppGroup`) with the rule count loaded. Each extension has its own byte-identical copy of `AppGroup.swift` (CI enforces identity).

### 5.4 `ContentBlockerBootstrap` (launch)

The old "unconditional bundled-snapshot reinstall on every launch" is now **gated**: if a cached manifest exists **and** `Compiled/Ads.json` is on disk and >10,000 bytes, it skips. Only if that gate fails does it call `installBundledSnapshotIfNeeded()`. This closed the risk that a real OTA update would be reverted on next launch — the gate and the `UpdateCoordinator.run()` launch caller landed together (Sprint 8.0). ⚠️ The gate only inspects `Ads.json`, not the other 3 groups.

---

## 6. DNS packet tunnel (Layer 2)

`Extensions/ADBLXPacketTunnel/` — a genuine `NEPacketTunnelProvider` VPN (not an `NEDNSProxyProvider`, which needs supervised devices). Premium. **Runnable today** and device-verified (iPhone 14, iOS 26.5, Release build) for tunnel activation + system-wide DNS interception.

### 6.1 How it works

- **`startTunnel`** applies "Model A scoped DNS capture": a fake DNS server `198.51.100.1`, `NEDNSSettings(servers: [198.51.100.1], matchDomains: [""])` (claims all DNS), IPv4 `192.0.2.2/32`, `includedRoutes` = only the fake DNS `/32`, `excludedRoutes` = the upstream resolver `/32` (so the tunnel's own upstream socket traffic bypasses the tunnel — loop prevention). No general TCP/UDP relay; non-DNS packets that reach the loop are parsed and dropped.
- **Read loop** (`readPackets`, self-re-arming): `DNSPacketParser` parses IPv4/IPv6 + UDP + a DNS standard query (rejects fragments, compression pointers, responses, non-UDP, IPv6 extension-header chains). The question name is extracted **label-reversed and lowercased** into a 256-byte inline stack buffer (`net.doubleclick.ad`) — zero heap on this step except two small offset arrays.
- **Lookup** (`DNSLookupEngine.lookup`, `MappedDNSArtifact.contains`): allowlist first (suffix walk), then blocklist (suffix walk), else default-allow. Both lists are **mmap'd binary artifacts** (`.alwaysMapped`), lookup is a **branchless-ish binary search over sorted domain strings** — **zero heap allocation, no `read()`/`open()` on the query path**. (PRD NG6 — no ML, no inference, no per-query I/O — fully respected.)
- **Blocked** → `NXDOMAINResponseBuilder` synthesizes a full IP+UDP+DNS `NXDOMAIN` packet (swapped endpoints, recomputed IPv4-header + UDP checksums, QR/RA set, RD echoed) → `packetFlow.writePackets`. **No SOA / no negative-caching TTL** in the response.
- **Allowed** → `DNSUpstreamForwarder` (an `actor`) rewrites the DNS txid, sends via a raw non-blocking BSD UDP socket to the upstream on port 53, correlates the reply (source-IP + port validated against off-path injection), rewrites the txid back, synthesizes a full response packet, delivers via `packetFlow`. 5s timeout per query; capacity cap 512 in-flight (overflow → synthesized SERVFAIL). Timeout → client just gets nothing.
- **Hot-reload:** `handleAppMessage` (push from the app) + every 100th query (poll) → `DNSGenerationLoader.reloadIfUpdated` — checks `DNS/current.json` mtime, validates the new generation (SHA-256 + CRC32 + rule-count + strict sorted-order), and does an **atomic snapshot swap under an unfair lock, zero VPN restart** (ADR-0009, benchmarked 26–43ms). Any load failure → keep the current (Last-Known-Good) snapshot. If nothing loads at startup → **fail-open empty snapshot (everything allowed)**.

### 6.2 Artifact format (`ADBLXShared`)

`DNSArtifactFormat` — magic `"ADBL"` (`0x4C424441` LE), version 1, 32-byte little-endian header (`DNSArtifactHeader`: magic, version, ruleCount, offsetsTableSize, stringBlobSize, payloadCRC32, 2 reserved), then `[u32 offsets table][NUL-terminated sorted label-reversed UTF-8 blob]`. `DNSArtifactValidator` enforces size, magic, version, CRC32, and **strict ascending byte order with no duplicates** — the invariant the binary search relies on. `MappedDNSArtifact` mmaps + validates once at load. App-side generation is `DNSArtifactPublisher` (compile → validate → **core-domain false-positive guard** against ~24 protected domains like google/apple/youtube → atomic staging-move + `current.json` pointer swap → prune to active + 1 prior).

### 6.3 Intended vs current vs backlog

| | Status |
|---|---|
| Local packet-tunnel VPN, Model A scoped DNS, NXDOMAIN for blocked, forward the rest, mmap binary-search hot path, zero on-device compilation/ML | ✅ Implemented and device-verified |
| **Upstream resolver** | ⚠️ **Wired in code, not yet verified on a device.** `startTunnel` now uses the parsed `resolverOption`: `.quad9Default` gives Quad9 `9.9.9.9` / `2620:fe::fe`, any other option uses the configured `ipv4Address` / `ipv6Address` (it was previously hardcoded to Cloudflare `1.1.1.1` with the config discarded). The `DNSProtectionView` disclosure still says "Quad9 · encrypted upstream", but the transport is **plaintext UDP/53**, not encrypted. `DNSUpstreamForwarder.reconfigure()` exists but is never called, so changing the resolver needs a tunnel restart. |
| **IPv6 forwarding** | ⚠️ **Enabled by the same change, unverified on a device.** `upstreamIPv6` is no longer `nil` for Quad9, and `UpstreamResolverConfig.ipv6Address` now defaults to `2620:fe::fe`; the provider configures IPv6 and the forwarder opens a v6 socket when an address is set. Behaviour on IPv4-only networks and during network transitions has not been tested. |
| **NXDOMAIN caching / SOA** | ⚠️ Not implemented — no SOA, no negative-TTL, no response cache (ADR-0005's "bounded caching" language is unimplemented). |
| **DNS blocklist updates** | ❌ **Bundled-only** (`oisd`, `peter-lowe` in the app binary). No registry, no manifest, no CDN path — every DNS rule change requires an app release. |
| Gate A network-transition matrix (Wi-Fi↔Cellular handover, sleep/wake socket recovery, third-party VPN conflict) | ❌ Open — no `NEVPNStatus.reasserting` / path-monitor socket re-init. ADR-0004 stays "conditionally accepted". |
| Gate D — 24-hour on-device battery soak (NFR-02 <3%/day) | ❌ Open — short-run ~1.3%/day measured, full soak pending. |
| Diagnostic counters (ingress/blocked/forwarded/egress) | ⚠️ Incremented but **never surfaced to the app** — no `handleAppMessage` reply payload. If the DNS UI is meant to show "queries blocked", that pipe doesn't exist. |
| `DNSBenchmarkSpike.swift` + `dns_artifact.bin` (9.5MB, stale `ADBX` magic) | Moved to `spikes/dns-benchmark/`, outside every target (SEC-07). |

---

## 7. Safari Web Extension (Layer 3) & the ABP compiler

### 7A. Safari Web Extension — `Extensions/ADBLXSafariWebExtension/`

Manifest V3, `background.scripts` (not `service_worker` — Safari debugging bug, ADR-0010). Runs on **`m.youtube.com` / `www.youtube.com` only** (manifest match + a hardcoded `ALLOWED_HOSTS` set the tests byte-guard against the manifest). Permissions: `storage`, `nativeMessaging`. Premium.

- **`background.js`** — relays entitlement + generation state from the native bridge. 15-minute monotonic cache ceiling, warm `storage.local` cache, in-flight dedup. **Fails closed** on reported `free`/`unavailable`. One deviation from ADR-0012: a *pure transport failure* (bridge returned null) keeps a recently-verified premium entitlement for a 4-hour grace window (a transient event-page wake used to latch Layer 3 off for the session). **ADR-0012 §5 forbids this** ("no grace window, no fallback to a prior cached `premiumActive` value under any circumstance"), so it needs an ADR amendment or a revert. Freshness and the grace window are measured with `Date.now()` although ADR-0012 §3 specifies monotonic time; negative ages (clock moved backwards) now count as stale and fail closed. Rule data gets a separate 4-hour last-known-good grace, which the ADR does allow.
- **`content.js`** — config is **page-scoped**: one shared in-flight `getLayer3Config` request, never discarded because a navigation bumped `playerGeneration`, and `mountPlayer` asks for config rather than skipping when it has none (the earlier version dropped the reply whenever DOMContentLoaded or a `yt-*` event fired first, leaving Layer 3 off for the page's life). `mountedGeneration` keeps mounting idempotent. Logging: lifecycle lines only in shipped builds; verbose dumps behind `DIAG_VERBOSE` and navigation/observer measurements behind `DIAG_INSTRUMENTATION`, both `false` (tests enforce it). A 6-state detection FSM (`UNKNOWN` / `NORMAL_PLAYBACK` / `AD_CANDIDATE` / `AD_CONFIRMED` / `RESET_SETTLING` / `AMBIGUOUS_SAFE`) fed by config-driven selectors (ad-state classes, skip controls, ad badges) with hardcoded fallbacks. `MutationObserver` on the player with `childList` + `subtree` (⚠️ cost during playback unmeasured; the instrumentation logs callbacks per minute), `playerGeneration` monotonic guard on every async callback, SPA-lifecycle hooks (`yt-navigate-start/finish`, etc.), `<video>` rebinding. On `AD_CONFIRMED` it dispatches tiered interventions: **A** cosmetic suppression (inject `display:none` style), **B** synthetic skip-button click (debounced), **C** playback acceleration (16× + mute, with a safety timeout) — **compiled but `accelerationDisabled` should be `true` for v1** (see backlog), **E** deliberate non-intervention (default). Ownership-based restore preserves manual user speed/mute changes. Any exception → `AMBIGUOUS_SAFE`.
- **`SafariWebExtensionHandler.swift`** — thin `NSExtensionRequestHandling`; forwards `SFExtensionMessageKey` messages to `ADBLXShared.SafariWebExtensionBridgeProcessor`, which reads `WebExtension/current.json` + `entitlement.json` from the App Group (read-only) and answers the 2-message pull-only protocol: `checkVersion` (cheap) / `fetchGeneration` (only on generation mismatch, retry-once, never a partial payload).
- **Tests:** `Tests/{background,content,manifest}.test.js` — Node `node:test`, thorough (transport-failure grace, FSM paths, generation guarding, debounce, restore, retry). **No `package.json`, not run in CI.**
- **App-side publishing** (`ADBLX/Filtering/WebExtension/`): `WebExtensionRulePublisher` (validate → staging → immutable `generations/<NNNNNN>/` → atomic `current.json` swap → prune to active + 1 prior), `WebExtensionSchemaValidator` (size ≤10MB, selector counts/lengths, prohibited substrings like `javascript:`/`eval(`, combinator depth — **rejects, never clamps**), `WebExtensionEntitlementPublisher` (atomic `entitlement.json`), `WebExtensionEntitlementCoordinator` (`actor`, watches the entitlement stream, writes only on change). Bootstrapped at launch.
- ⚠️ **Rule data is static.** Only **Generation 1** is ever published — from a hardcoded `WebExtensionBootstrap.defaultRulesJSON` literal. Nothing feeds compiler output or a downloaded generation into `WebExtensionRulePublisher`; `UpdateCoordinator` handles Content Blocker groups only. The `cosmetics` / `antiAdblock` / general-cosmetic-filtering schema sections exist but have no consumer — `content.js` is YouTube-only.

### 7B. ABP rule compiler — `Packages/ADBLXShared/Sources/ADBLXShared/Compiler/`

A **clean-room native Swift** Adblock-Plus → Safari-Content-Blocker-JSON compiler (ADR-0002 — chosen specifically to avoid GPL `SafariConverterLib`; **zero external dependencies**). The GPL licensing question is **resolved by not linking it at all**.

`ABPLexer` (tokenize) → `ABPParser` (`ParsedABPRule`, pattern classification: domain-anchor / url-prefix / exact-match / wildcard / regex) → `ABPSemanticValidator` (`ValidationDisposition`: supported / unsupported-semantic / deferred-to-web-extension / invalid / ignored — every disposition **counted, never silently dropped**) → `SafariRuleGenerator` (ABP pattern → `url-filter` regex, resource-type mapping, load-type).

**2-pass** `NativeABPRuleCompiler`: pass 1 collects `$badfilter` retraction signatures; pass 2 compiles, skipping retracted rules, producing a `CompilationReport` (lines processed, compiled, skipped, deferred, invalid, badfilter, per-modifier skip counts, duration).

Supported modifiers (frozen by the Task 10.2.0 contract gate against a 185,306-line corpus): `$third-party`, `$~third-party`, `$domain=`, `$script`, `$image`, `$stylesheet`/`$css`, `$xmlhttprequest`/`$xhr`, `$websocket`, `$subdocument`, `$media`, `$font`, negated `$~type`. Unsupported → whole rule skipped + counted: `$popup`, `$csp`, `$redirect(-rule)`, `$rewrite`, `$important`, `$generichide`, `$genericblock`, `$match-case`, `$method`, `$document` on block rules. `##+js(...)` / `#?#` → deferred to Layer 2.

**Post-incident hardening** (after a YouTube black-screen bug where `$ping,third-party` compiled to a catch-all `.*` block that blocked the entire web):
- **Fix A** — `SafariRuleGenerator` drops patternless catch-all **block** rules (`url-filter: ".*"` with no `if-domain`).
- **Fix B** — `$ping` is now **unsupported** (was contract-classified as `→ raw`; over-blocked all XHR/fetch/WebSocket).
- **Fix C** — `NativeABPRuleCompiler.assertNoUnrestrictedBlockRules` hard-fails the whole compile if any unrestricted catch-all block rule survives.
- DFA-unsupported regex (`{n,m}` bounded repetition, `|` alternation) → rule dropped + counted.

**Wired into production:** `AppCompositionRoot.makeFilterPipeline` injects `NativeRuleCompilerAdapter`, which calls `NativeABPRuleCompiler.compileToJSON`. Delivered: 185,306 corpus lines → **177,556 Safari rules** (Ads 73.3K / Privacy 55.8K / Annoyances 48.5K), compile 3.617s, +19.5MB memory, on an iPhone 14. **Not** used by the backend Publisher (which only copies pre-existing payloads) and **not** used for the Web Extension `rules.json`.

---

## 8. Backend / filter publisher / downloads

`backend/` is **static data, not an API server** — "published as-is".

### 8.1 Layout

- `backend/registry/filters.json` — the filter registry (`registryVersion: 1`). 3 filters: **EasyList** (ads, free, default-on), **EasyPrivacy** (privacy, free, default-on), **Fanboy Annoyances** (annoyances, **premium**, default-off). **No Regional entry.**
- `backend/metadata/{easylist,easyprivacy,fanboy-annoyances}.json` — `{id, version}` sidecars (all currently `"2026-08-18"`).
- `backend/public/filters/{ads,privacy,annoyances}/*.txt` — the real upstream ABP-syntax payloads, committed verbatim (`regional/` has only `.gitkeep`). Note: these lists also exist a second time bundled in `ADBLX/Resources/Filters/` as the first-launch snapshot — keep in sync.
- `backend/public/manifest.json` — the golden committed manifest (`manifestVersion: "2026-08-18"`, 3 entries).

### 8.2 Publisher CLI (`backend/tools/Publisher/`)

Swift + `swift-argument-parser`. Commands:

| Command | Effect |
|---|---|
| `validate` | 1:1 consistency check across registry ↔ metadata ↔ payloads (accumulates all errors). Writes nothing. |
| `generate-docs` | Regenerates `backend/docs/FilterRegistry.md`. |
| `publish --publish-base-url <url>` | validate → for each filter: read payload, SHA-256, count rules (non-empty, non-`!` lines) → `ManifestBuilder` (sorts entries by id) → `ManifestVersion.resolve` (keeps the committed `manifestVersion` when entries are unchanged, otherwise requires a later `--manifest-version` UTC timestamp) → `ManifestJSONWriter` (**hand-built JSON string, fixed key order** — ADR-0001, because `JSONEncoder` key order is non-deterministic on Swift 6.3) → atomic write to `backend/public/manifest.json`. |
| `generate --publish-base-url <url>` | validate + generate-docs + publish. |

All-or-nothing; the existing `manifest.json` is untouched on any failure. **`PublisherPaths` are hardcoded** (no injection seam) → no true end-to-end CLI test. 44 unit/integration tests (golden fixtures use `cdn.adblx.com` and synthetic payloads).

### 8.3 Hosting & the download path

- `backend/tools/publish-pages.sh` — copies `backend/public/` **verbatim** to the `gh-pages` branch via a persistent worktree at `.gh-pages-worktree/`, writes a fixed `index.html`, commits, pushes. Self-bootstraps the orphan branch on first run.
- `.github/workflows/deploy-pages.yml` — on push to `gh-pages`, publishes the branch to GitHub Pages.
- **Live host:** `https://999sreeharsha.github.io/ADBLX/` (Fastly CDN in front). Manifest at `.../ADBLX/manifest.json`; filters at `.../ADBLX/backend/public/filters/<group>/<id>.txt`.
- **Client end:** `ManifestClient` (ETag/`If-None-Match`/304) → `UpdatePlanner` diff → `FilterDownloadClient` (GET each `sourceURL` to a temp file, no checksum) → `UpdateCoordinator` (`Checksum.verify` every file before any container write) → `FilterPipeline`.
- The whole path was verified on an iPhone 14 against the live endpoint.

### 8.4 Known backend defects (see also §10)

- **sourceURL shape disagreement.** `ManifestBuilder` code builds `{base}/filters/{group}/{id}.txt`; the committed manifest has `.../ADBLX/backend/public/filters/...` (only producible by passing `--publish-base-url .../ADBLX/backend/public`); `ManifestGeneration.md` and `Publisher.md` specify two other shapes; a Publisher test asserts the URL must **not** contain `backend/public` — which the production manifest violates.
- **Host-name drift.** `Publisher.md` and the Sprint 8.05 completion report say `harshaunofficial.github.io`; everything real uses `999sreeharsha.github.io`.
- **Manifest checksums are 63 hex chars, not 64** (spec mandates 64) — the committed `manifest.json` needs regeneration + republish.
- No CI job builds/tests the Publisher or runs `publish` — manifest generation is a manual local step.
- `backend/licenses/` is empty (`.gitkeep` only) despite the pre-ship attribution requirement.

---

## 9. Sprint timeline (what each delivered)

| Sprint | Delivered |
|---|---|
| **0** (07-14) | Repo bootstrap: XcodeGen migration, 9 targets, App Group, CI, runtime CB pipeline validated on simulator, extension embedding + nested bundle IDs fixed. |
| **1** (07-17) | `Filtering/` module: `FilterPipeline` actor + single-purpose stages, `PassthroughRuleCompiler` stub, Ads only. 28 tests. |
| **2** (07-18) | `Filtering/Updates/`: `ManifestClient` (ETag/304), `UpdatePlanner` (pure diff), `UpdateCoordinator` (transactional batch + rollback). Mock sessions only, no caller. |
| **3A** (07-19) | Group composition: compile one `FilterGroup` from N `FilterSource`s. `CompositionService`, `GroupComposition`, `GroupPartitioner` (150K/group). |
| **4A/4B/4C** (07-21) | UI from the frozen Stitch design: DesignSystem, Home/Protection/Premium/Settings/Onboarding screens, localization infrastructure (`Localizable.xcstrings`, `no_hardcoded_ui_string`). |
| **5A/5B** (07-22/26) | Composition-root ↔ service integration; feature screens on live data (`RealSettingsService`, `AllowlistStore` storage-only, `FilterPreferences`). |
| **6** (07-26) | Backend repo architecture frozen (`ManifestSpecification.md`, `ManifestGeneration.md`, `FilterRegistry.md`). No code. |
| **7** (07-27) | Publisher CLI implemented. ADR-0001 (manual JSON writer). Golden-fixture tests. |
| **8.0** (07-27) | `Filters/` raw-source cache, entitlement-gated `UpdatePlanner`/`UpdateCoordinator`, `EntitlementService` / `StoreKitSubscriptionService` wiring, `ContentBlockerBootstrap` gate + first `UpdateCoordinator.run()` caller. |
| **8.05** (07-28) | Manifest hosting via GitHub Pages, `AppStoreSetup.md`, `ManualVerification.md` for all 4 CBs, premium-revocation promoted to release blocker. "End of Foundation Phase." |
| **8.1** | DNS architecture decisions only (ADR-0003..0009 map). No code. |
| **8B** (08-24) | **Production Layer 2 DNS:** full artifact contract (`ADBLXShared`), app-side compilers/publisher, tunnel runtime (mmap binary search, LKG hot-reload), wire engine, Quad9 forwarder, DNS Settings UI. Gates 1–4 passed. |
| **9** (08-25) | **Layer 3 Safari Web Extension YouTube engine:** ADRs 0010–0013, DOM-state FSM, cosmetic + synthetic-skip interventions, acceleration compiled-but-disabled. 29 failure scenarios; hardware Gates A/B/C certified. |
| **10** (08-26) | ADR-0002 authored + **clean-room `NativeABPRuleCompiler`** in `ADBLXShared`; Task 10.2.0 contract gate; Safari allowlist path; in-pipeline `WKContentRuleListStore` DFA gate; `FilterAttributionView`; DNS entitlement P0 leak + `MockSubscriptionService` hotfixed. 177,556 rules on device. |
| **11** (08-26) | **Unified entitlement authority + 15-day trial + premium sync:** `StoreKitSubscriptionService` actor, `EntitlementState` precedence, `TrialManager`/Keychain (monotonic), 5 notification milestones, `TrialExpiryRouter` + `TrialExpiredDecisionView`, `WebExtensionEntitlementCoordinator`, broken-site reporting, iCloud sync (`NSUbiquitousKeyValueStore`). Frozen product IDs. 215/215 tests; deployed to iPhone 14. |

> From Sprint 8B on, the project **stopped producing `docs/superpowers/specs/` + `/plans/` files** and switched to Architecture + Audit + Validation docs. A reader looking for `…sprint9…` specs will find nothing — the Sprint 9 "specs" are the eight `docs/Architecture/sprint_9_youtube_*.md` files.

---

## 10. Backlog & deferred work

Consolidated from `docs/Audit/*`, `docs/gotchas.md`, `docs/Validation/*`, and the source audits. Grouped by area; 🔴 = release-relevant, ⚠️ = correctness/UX gap, ○ = post-v1.0.

### Filtering (Layer 1)
- ○ Confirm all 4 CB groups seed on a genuine clean install (the bootstrap gate only checks `Ads.json`).
- ⚠️ Verify the Safari-side allowlist actually compiles to `ignore-previous-rules` inside `FilterPipeline.installGroup` and that Safari + DNS allowlists are unified (Gate C2 is "conditional" — ADR-0009 covers DNS only).
- ⚠️ Surface **per-extension reload failures** in `SafariProtectionView` (FR-06). `ReloadCoordinator`'s timeout branch is untested.
- ⚠️ `InstalledFilter.ruleCount` is group-level — blocks any per-filter rule-count UI; needs a `[String: Int]` per-source map threaded through `CompositionService`.
- 🔴 **Premium filter revocation on entitlement lapse.** `UpdatePlanner` only gates *new* premium installs; an already-installed premium filter whose subscription lapses keeps blocking forever (no `.remove`-on-lapse path). Promoted to a **release blocker before DNS ships** (Sprint 8.05) — and DNS has shipped. DNS/web-ext have reactive teardown; the premium *filter list* does not.
- ○ Physical-device AdBlock-Tester re-run for a real G1 score (the historic 46/100 was the synthetic fallback only).

### DNS (Layer 2)
- 🔴 **Device-verify the resolver wiring** (done in code, see §6.3), including IPv6 on IPv4-only networks. Still open: wire `DNSUpstreamForwarder.reconfigure`, and fix the "encrypted upstream" copy (transport is plaintext UDP/53) or add DoT/DoH.
- ⚠️ **IPv6 forwarding** — currently entirely absent (`upstreamIPv6 = nil`).
- ⚠️ **NXDOMAIN SOA / negative-caching** — unimplemented (ADR-0005's caching language).
- 🔴 **DNS blocklist live-update path** — bundled-only today; every DNS rule change needs an app release. Needs a DNS registry + manifest pipeline.
- 🔴 **Gate A** network-transition matrix (Wi-Fi↔Cellular handover, sleep/wake socket recovery, third-party VPN conflict). ADR-0004 can't move to "accepted" until this passes.
- 🔴 **Gate D** — 24-hour on-device battery soak (NFR-02 <3%/day).
- ⚠️ Export the diagnostic counters (ingress/blocked/forwarded) to the app so the DNS UI can show real numbers.
- ○ EDNS / large-response / TCP fallback (4096-byte cap, no TC-bit handling). IPv6 extension-header chains dropped.
- ✅ Remove `DNSBenchmarkSpike.swift` + the 9.5MB stale `dns_artifact.bin` from the extension bundle (moved to `spikes/dns-benchmark/`).
- ○ `DNSProtectionSettingsStore` uses the wrong App Group suite string (`group.com.ADBLX.ADBLX` vs `group.com.ADBLX.shared`) — settings-only, but fix it.

### Web Extension (Layer 3)
- 🔴 **Wire Web-Extension `rules.json` generation into the update pipeline** — today it's frozen at the bundled Generation-1 literal.
- 🔴 Set `accelerationDisabled: true` in `defaultRulesJSON` for v1 (Task 8 said so; the literal currently has it `false`). Confirm `youtubeLayer3Disabled` intent.
- 🔴 **Resolve the ADR-0012 §5 conflict** over the entitlement grace window on bridge transport failure: amend the ADR or revert the grace window.
- 🔴 Device-verify the startup-race fix: 10 cold loads (5 on `www`, 5 on `m.youtube.com`), force-quitting Safari between loads; each must log exactly one `sending` and reach `got config`. Record `sending`→`got config` times to decide whether caching the entitlement flag in `storage.local` is worth it.
- 🔴 Choose the SPA navigation signal for `m.youtube.com` from the `DIAG_INSTRUMENTATION` readings (it is not yet known that the `yt-*` events fire there), then remove `installNavigationInstrumentation()`.
- ⚠️ Measure the player observer (`childList` + `subtree`); if above 1 callback/second in plain playback, restore the class-only observer plus a non-subtree `childList` observer on the video container.
- ⚠️ The remaining lifecycle `diag` lines still log from release builds; gate them too if that is unwanted.
- ⚠️ Add a CI step that runs the three `node:test` suites (needs a `package.json` or a `node --test` step).
- ○ Implement or explicitly defer the general cosmetic-filtering + anti-adblock Layer 3 categories (ADR-0011/0013) — currently dead schema.
- ○ Re-introduce the Candidate B unrendered-skip-button guard behind a regression test (`content.test.js:832` is `test.skip`).

### Premium / Monetization
- 🔴 **Reconcile pricing.** PD-01 + Sprint 11 (frozen): $1.99 / $14.99 / $39.99, monthly retained. `docs/AppStoreSetup.md` + `Config/Configuration.storekit`: $19.99 / $49.99, no monthly. Pick one; the founder SKU decision (all-3 vs annual+lifetime) is recorded as still-open.
- 🔴 StoreKit 2 sandbox lifecycle / Billing Grace Period / billing-retry QA with accelerated renewal.
- ⚠️ "Manage" button in `PremiumView` is an empty closure — wire `showManageSubscriptions`.
- ○ The permanently-`.disabled` `fetchStatusReturnsTwoPlans` test — re-check on each Xcode upgrade.

### UI
- 🔴 **Interactive multi-step onboarding** with live `SFContentBlockerManager.getStateOfContentBlocker` polling (FR-07 — gates the G6 ≥70% enablement goal).
- ⚠️ Home: replace hardcoded `v4.2.0` pill, Safari/DNS stat tiles, and the "Reload Safari" behavior with real state. Protection: remove the hardcoded "4,281 threats blocked"; wire or remove "Speed Optimization"; hide the upsell for premium users.
- ⚠️ `AdvancedFilterListsView` "Apply Changes" button does nothing but `load()` — wire it to a recompile/reload or remove it.
- ⚠️ Settings: wire "Notifications" (real `UNUserNotificationCenter` status) and give iCloud Sync an actual toggle + call `ICloudSyncCoordinator.startObserving()` (the read/observe path is dormant); sync **enabled filters**, not just the allowlist (FR-13).
- ⚠️ FR-09: render uninstalled remote manifest entries + per-extension rule-budget meters.
- ○ Accessibility audit — VoiceOver labels + Dynamic Type (NFR-06); no verification record exists.
- ○ FR-17: actual translations for Hindi/Japanese/Spanish/German/French + an in-app language picker (the Language row is read-only).
- ○ FR-15: custom filter-list URL import + rule-budget warning (P2).
- ○ Fix `adblx.app` links in `AboutView` (domain likely unregistered).
- ○ Remove dead UI: `OnboardingView`, `DNSFilteringSpikeView`/`Manager`; adopt or delete `ToggleRow`.

### Backend / Infra
- 🔴 Fix the sourceURL-shape disagreement (code vs committed manifest vs 2 docs vs a test assertion).
- 🔴 Regenerate `manifest.json` — 63-char checksums must be 64.
- 🔴 Fix host-name drift in `Publisher.md` + the 8.05 report (`harshaunofficial` → `999sreeharsha`).
- ⚠️ Pin XcodeGen (add `options.xcodeGenVersion` or a CI pin) and regenerate `project.pbxproj` with 2.45.4+ so the drift gate is stable.
- ⚠️ Commit the pending `project.yml` working-tree changes (iCloud KVS entitlement, Safari-WebExt Tests exclude + `SFSafariWebExtensionManifestPath`).
- ⚠️ Add CI coverage for `ADBLXShared`, `backend/tools/Publisher`, and the JS suites; add a macOS/visionOS build.
- ⚠️ FR-14: reports go by mail, and the recipient address is still to be decided (`BrokenSiteReport.recipient`).
- ⚠️ Register a production **Regional (India)** filter list (`shield-india`, PRD Appendix C) or formally defer the 4th CB group.
- ○ `BGAppRefreshTask` background scheduling (`com.ADBLX.ADBLX.filterRefresh`) — only the 6h foreground throttle exists.
- ○ NFR-03 (update success ≥99%) and NFR-04 (manifest p95 <300ms) have no measurement mechanism under the zero-analytics constraint.

### Compliance / Legal
- 🔴 Pre-launch legal sign-off: ADR-0002 clean-room tool-vs-derivative isolation + the PRD §10 filter-list attribution screen, to counsel.
- 🔴 DNS bundled lists (`oisd`, `peter-lowe`) pending pre-ship legal sign-off.
- 🔴 App Store: Network Extension entitlement request (VPN-misuse rejection risk); "YouTube in Safari" wording only (NG1).
- ⚠️ Populate `backend/licenses/`.

### Doc hygiene
- Rewrite / retire `README.md`, `agent.md`, `backend/README.md`, `TargetTopology.md`, `Publisher.md` (all Sprint 2–8.05).
- Reconcile `AppStoreSetup.md` pricing with PD-01.
- ADR index: promote ADR-0006 and ADR-0009 to "Resolved & Adopted" (file headers already say so); promote ADRs 0010–0013 from "Proposed" (Sprint 9 shipped them); move ADR-0004 when Gate A passes.
- Fix broken ADR links in the Sprint 11 validation docs (`0001-initial-architecture.md`, `0009-unified-allowlist-harmonization.md` don't exist).
- Rename or reframe `task.md` (it's the completed Sprint 8B list, not a live tracker).

---

## 11. Stale docs — do not trust as-is

| Doc | Problem |
|---|---|
| `README.md` | "Sprint 2 complete, next milestone Sprint 3." ~9 sprints behind. |
| `agent.md` / `AGENT.md` | Same. Hard-constraints section still valid; state section is not. Also self-inconsistent on platform scope. |
| `backend/README.md` | "publishing guide / manifest schema deferred to later Sprint 6 commits" — long since delivered. |
| `docs/Architecture/TargetTopology.md` | "Current as of Sprint 3A." Its "not here yet" list is mostly done (live endpoint, `UpdateCoordinator` caller, StoreKit, DNS, web ext all shipped). PacketTunnel entitlement "deferred" is false. Doesn't cover the DNS/Web-Ext subsystems, `ADBLXShared` compiler, or monetization. |
| `docs/Architecture/Publisher.md` | Wrong host, wrong sourceURL shape, wrong first-time-setup command. Module/CLI description is fine. |
| `docs/Architecture/DNSFilteringArchitecture.md` | Sprint-8.1-era; lists ADR-0006 "Proposed", omits ADR-0009. |
| `docs/AppStoreSetup.md` | Pricing contradicts the accepted PD-01. `.storekit` filename differs from other docs. |
| `docs/ADR/README.md` | ADR-0006/0009 rows say "Proposed" though their files say "Resolved & Adopted"; ADRs 0010–0013 "Proposed" though Sprint 9 shipped them. |
| `docs/adblock-prd-v1.1.md` §9, §12 | §9 monetization superseded by PD-01 (noted in-file). §12 7-sprint plan bears no relation to actual sprint 0–11 execution. "7-day trial" prose overridden to 15-day by PD-01. |
| `docs/Validation/Sprint11/*` | Two broken ADR links (`0001-initial-architecture.md`, `0009-unified-allowlist-harmonization.md`). |
| `docs/superpowers/plans/2026-07-28-sprint-8.05-completion-report.md` | Says manifest host `harshaunofficial.github.io` (migrated, never updated). |
| `backend/public/manifest.json` | 63-char checksums (should be 64); may be stale vs current payloads. |
| `task.md` | Named like a live tracker; is the (all-complete) Sprint 8B task list. |
| `docs/Architecture/ManualVerification.md` | "Last verified" tables only have Sprint-0 Ads entries; on-device evidence in `v1.0_remaining_issues_audit.md` not cross-referenced. |

---

## 12. Document map — where deeper detail lives

| Topic | Doc |
|---|---|
| **Product requirements** (scope, FR-01..17, NFRs, non-goals NG1..6, India list) | `docs/adblock-prd-v1.1.md` (treat §9/§12 as superseded) |
| **Monetization & trial** (authoritative) | `docs/Architecture/PD-01-monetization-and-trial.md` |
| **Architecture decisions** | `docs/ADR/0001`..`0013` + `docs/ADR/README.md` index |
| — manifest JSON writer | ADR-0001 |
| — rule compiler / licensing (clean-room) | ADR-0002 |
| — DNS: VPN scope / interception model / NXDOMAIN / upstream / encrypted-DNS boundary | ADR-0003 · 0004 · 0005 · 0006 · 0007 |
| — DNS: filter representation / allowlist architecture | ADR-0008 · 0009 |
| — Web Extension: execution model / data lifecycle / bridge / capability boundary | ADR-0010 · 0011 · 0012 · 0013 |
| **Build / targets** (partly stale — cross-check `project.yml`) | `docs/Architecture/TargetTopology.md` |
| **Logging policy** | `docs/Architecture/Logging.md` |
| **Coding standards** (localization, FormatStyle) | `docs/coding-standards.md` |
| **Known pitfalls** | `docs/gotchas.md` |
| **DNS architecture narrative** | `docs/Architecture/DNSFilteringArchitecture.md` + `sprint_8b_*` |
| **YouTube Layer 3 design** (the Sprint 9 "specs") | `docs/Architecture/sprint_9_youtube_*.md` (8 files) |
| **Compiler contract** (frozen grammar) | `docs/Architecture/task_10_2_0_compiler_contract_gate.md` |
| **Publisher / manifest** | `docs/Architecture/Publisher.md` (host/URL stale) + `backend/docs/{ManifestSpecification,ManifestGeneration,FilterRegistry,RegistryRoadmap}.md` |
| **App Store setup** (pricing stale) | `docs/AppStoreSetup.md` |
| **Manual verification checklists** | `docs/Architecture/ManualVerification.md` |
| **Product audits / gate reviews / backlog origin** | `docs/Audit/{post_sprint9_product_audit,sprint10_preimplementation_gate,v1.0_remaining_issues_audit}.md` |
| **Test evidence** | `docs/Validation/` (`adblock-tester-audit.md`, `Sprint9/`, `Sprint10/`, `Sprint11/`) |
| **Sprint specs & plans (0 → 8.05 only)** | `docs/superpowers/specs/` + `docs/superpowers/plans/` |
| **Local block-test page** | `docs/blocktest/` |
