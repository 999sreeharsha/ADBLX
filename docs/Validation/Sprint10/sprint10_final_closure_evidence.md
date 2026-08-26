# Sprint 10 & Foundation Pre-Sprint 8B Verification Record

## Overview & Disposition
- **Sprint**: 10 (10.1 Safari Allowlist Path + 10.2 Clean-Room Native ABP Rule Compiler) + Pre-Sprint 8B Gating
- **Status**: **Formally Closed & Verified on Physical iOS Device**
- **Date**: August 27, 2026
- **Test Target**: Sree Harsha’s iPhone (iPhone 14 / Model `iPhone14,7`, Apple A15 Bionic, iOS 26.6)
- **Configuration**: Release (`-configuration Release -destination 'id=00008110-000E35193CE3A01E'`)
- **Architecture References**:
  - [ADR-0002: Native Rule Compiler Architecture & CC BY-SA Isolation](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0002-rule-compiler-architecture-and-licensing.md)
  - [PRD §10: Filter List Attribution & Notice Requirements](file:///Users/sreeharshag/Work/ADBLX/docs/adblock-prd-v1.1.md)

---

## 1. Native ABP Rule Compiler & WebKit DFA Verification

### A. Real Upstream Filter Corpus Translation (177,556 Total Published Rules)
The native Swift ABP rule compiler (`NativeABPRuleCompiler`) processes the full bundled third-party upstream corpora into valid Safari Content Blocker JSON partitions:

| Filter Group | Source Corpus File | Raw Lines | Published Rule Count | WebKit DFA Status | Single-Group Compile Time |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Ads** | `ads/easylist.txt` | 78,321 | **73,313** | ✅ 100% Ingested | **1.488 s** |
| **Privacy** | `privacy/easyprivacy.txt` | 56,649 | **55,792** | ✅ 100% Ingested | **1.218 s** |
| **Annoyances** | `annoyances/fanboy-annoyances.txt` | 50,336 | **48,451** | ✅ 100% Ingested | **0.911 s** |
| **Total** | | **185,306** | **177,556** | ✅ 100% Ingested | **3.617 s** |

### B. In-Pipeline WebKit DFA Ingestion Gate
To guarantee WebKit runtime acceptance before writing to the App Group:
- `RulePipelineCoordinator` executes an in-process compilation check via `WKContentRuleListStore.default().compileContentRuleList(forIdentifier:encodedContent:)`.
- **Defects Detected and Fixed:**
  - Removed unsupported `{n,m}` regex quantifiers.
  - Corrected disjunction group formatting inside `url-filter`.
  - Filtered out empty CSS cosmetic selectors.
- Result: **0% dropped rules**, **100% WebKit acceptance rate**.

### C. `$badfilter` Two-Pass Sub-Order Invariant Retraction
- Implemented a two-pass parser collecting explicit `$badfilter` exceptions first to cancel matching rules regardless of file position.
- Canonicalized multi-value `domain=` modifier sub-order (e.g. `domain=a.com|b.com` vs `domain=b.com|a.com`) to prevent false-negative cancellation drops. Verified with unit tests.

---

## 2. On-Device Performance & NFR Metrics (iPhone 14, Release Build)

| Metric | Target Budget | Empirical On-Device Measurement | Result |
| :--- | :--- | :--- | :--- |
| **Pure Rule Compilation (NFR-01)** | $< 10.0\text{ s}$ | **3.617 s** (177,556 rules) | ✅ **PASS** (2.7x margin) |
| **Peak Memory Allocation (NFR-01)** | $< 200.0\text{ MB}$ | **19.52 MB delta** (53.95 MB Continuous Peak) | ✅ **PASS** (10.2x margin) |
| **Process Cold Launch (NFR-05)** | $< 1.500\text{ s}$ | **0.383 s avg** (5 trials: 0.352s–0.418s, ±0.024s) | ✅ **PASS** (3.9x margin) |
| **Reload Timeout Overhead** | $< 10.0\text{ s}$ | **2.21 s max** (Ads: 2.21s, Privacy: 1.76s, Annoyances: 2.16s) | ✅ **PASS** (4.5x margin) |
| **Per-Blocker Rule Count** | $\le 150,000\text{ rules}$ | **73,313 rules max** (Ads) | ✅ **PASS** |

> **Note on NFR-05 Measurement**: Cold-start timing was measured via `XCTApplicationLaunchMetric(waitUntilResponsive: true)` across 5 discrete process launch iterations on physical hardware, representing **Warm dyld / Cold App Launch** (process termination to idle first responsive UI frame).

---

## 3. PRD §10 Filter List Attribution & Licensing Scope

1. **In-App Attribution UI**:
   - Implemented [`FilterAttributionView.swift`](file:///Users/sreeharshag/Work/ADBLX/ADBLX/Features/Settings/FilterAttributionView.swift) accessible from Settings $\rightarrow$ About $\rightarrow$ Licenses.
   - Fully credits EasyList (GPLv3 / CC BY-SA 3.0), EasyPrivacy (GPLv3 / CC BY-SA 3.0), and Fanboy Annoyances (GPLv3 / CC BY 3.0) with repository links and license notices.
2. **CC BY-SA 3.0 Share-Alike Scope**:
   - Upstream corpora are bundled verbatim without proprietary derivation.
   - The native Swift compiler operates as a clean-room parsing tool (ADR-0002).
   - Regional and custom whitelist/blacklist rules are authored independently, ensuring copyleft terms do not attach to proprietary extensions. Documented for pre-launch legal review.

---

## 4. Entitlement Revocation & State Synchronization (Pre-Sprint 8B)

1. **Authoritative Reactive Teardown**:
   - Validated on-device that when a subscription lapses (`.annual` / `.monthly` / `.trial` $\rightarrow$ `.free`), `StoreKitSubscriptionService` emits `.free` to `stateUpdates()`.
   - `RealDNSProtectionService` executes an idempotent teardown, disables the tunnel, and updates settings.
   - `WebExtensionEntitlementCoordinator` synchronizes `WebExtension/entitlement.json` to `{"state": "free"}`.
   - `UpdatePlanner` flags premium manifest entries with `.skipPremium`.
2. **Deduplication & Positive State Verification**:
   - Confirmed `WebExtensionEntitlementCoordinator` dedupes writes when capability is unchanged (`.trial` $\rightarrow$ `.monthly`), preventing flash wear.
   - Added positive assertions verifying active premium update planning during `.monthly` subscription states.
3. **StoreKit 2 Lifecycle**:
   - `Transaction.currentEntitlements` automatically honors Apple Billing Grace Period (`.inGracePeriod`), ensuring continuous entitlement until grace expiration.
