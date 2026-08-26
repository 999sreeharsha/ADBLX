# Sprint 11 Targets & Achievements Record: Monetization, Universal Trial & Entitlement Synchronization

## Overview & Disposition
- **Sprint**: 11 (Unified Entitlement Authority, Universal 15-Day Trial Engine, Premium Feature Synchronization, Local Milestone Notifications, Trial Expiry & Contextual Paywalls)
- **Status**: **Formally Closed & Verified on Physical iOS Device**
- **Date**: August 26, 2026
- **Test Target**: Sree Harsha’s iPhone (iPhone 14 / Model `iPhone14,7`, Apple A15 Bionic, iOS 26.5) & iOS Simulator (iPhone 17)
- **Architecture Reference**: [PD-01 Monetization Spec](file:///Users/sreeharshag/Work/ADBLX/docs/adblock-prd-v1.1.md), [ADR-0001 Architecture Records](file:///Users/sreeharshag/Work/ADBLX/docs/ADR/0001-initial-architecture.md)

---

## 1. Targeted vs. Achieved Scope Matrix

| Sprint Task | Target Objective | Achieved Implementation & Verification | Status |
| :--- | :--- | :--- | :---: |
| **11.1 Unified Entitlement Foundation** | • Single actor-backed entitlement authority.<br>• Multi-subscriber reactive state fan-out.<br>• Strict entitlement precedence hierarchy.<br>• Reactive DNS teardown on `.free`.<br>• Frozen StoreKit product IDs ($1.99/mo, $14.99/yr, $39.99 lifetime). | • `StoreKitSubscriptionService` actor with `AsyncStream.makeStream(of:)`.<br>• `EntitlementState` with `Lifetime > Annual > Monthly > Trial > Free`.<br>• Idempotent reactive tunnel teardown via `DNSProtectionService.stopTunnel()`.<br>• StoreKit configuration and DI injection via `AppCompositionRoot`. | ✅ **COMPLETE** |
| **11.2 Trial Engine & Keychain Persistence** | • Explicit 15-day deterministic trial.<br>• Monotonic anti-clock-rollback guarantee.<br>• Keychain persistence across app reinstall cycles.<br>• Idempotent activation & permanent expiry.<br>• No timers, polling, or periodic background tasks. | • `TrialRecord` and `TrialKeychainStore` (`kSecAttrAccessibleAfterFirstUnlock`).<br>• `TrialManager` actor using `effectiveDate = max(date, lastObservedDate)`.<br>• Integrated into `StoreKitSubscriptionService` with `willEnterForegroundNotification` evaluation. | ✅ **COMPLETE** |
| **11.3 Premium Feature Synchronization** | • Reactive feature sync across DNS, Web Extension, and Filter Updates.<br>• Atomic App Group `entitlement.json` writes.<br>• Capability-deduplicated disk I/O.<br>• Selective filter update gating (skip premium, continue free). | • `WebExtensionEntitlementCoordinator` observing `EntitlementService`.<br>• Atomic temporary-file-and-rename App Group write.<br>• State deduplication preventing repeated writes.<br>• `UpdatePlan` gates `entry.premium && !isPremiumEntitled` with `.skipPremium`. | ✅ **COMPLETE** |
| **11.4 Trial UX & Local Notifications** | • 15-day trial onboarding UI.<br>• Non-blocking notification permission flow.<br>• 5 calendar milestones (Day 5, 9, 12, 14, 15).<br>• Immediate cancellation upon leaving `.trial`. | • `TrialOnboardingView` & `TrialOnboardingViewModel` with Stitch design.<br>• Authoritative trial activation prior to notification prompt.<br>• `TrialNotificationScheduler` using `UNCalendarNotificationTrigger`.<br>• Automatic cancellation on `.free`, `.monthly`, `.annual`, and `.lifetime`. | ✅ **COMPLETE** |
| **11.5 Trial Expiry & Contextual Paywalls** | • Distinguish `.notStarted` from `.expired`.<br>• Non-dismissible Day-15 decision screen with 50/50 equal-weight options.<br>• Keychain persistence of `userChoseFreeTier`.<br>• Strict dismissal invariants on paywall sheets.<br>• Retain contextual paywalls for locked features. | • `TrialKeychainDecisionStore` (`kSecAttrAccessibleAfterFirstUnlock`).<br>• `TrialExpiryRouter` routing state machine (`.none` vs `.showExpiredDecision`).<br>• `TrialExpiredDecisionViewModel` & `TrialExpiredDecisionView`.<br>• Closing `PremiumView` without purchasing returns user to decision modal.<br>• General Settings rows spacing & HIG touch target compliance. | ✅ **COMPLETE** |

---

## 2. Core Architectural Decisions & Invariants

```text
StoreKit 2 Transactions ────────┐
                                ├──► EntitlementService Actor (Single Source of Truth)
TrialManager (15-Day Keychain) ─┘             │
                                              └──► stateUpdates() Multi-Subscriber Stream
                                                          │
                    ┌─────────────────────────────────────┼─────────────────────────────────────┐
                    ▼                                     ▼                                     ▼
           DNSProtectionService          WebExtensionEntitlementCoordinator              UpdateCoordinator
       • Reactive .free teardown              • Atomic App Group write              • Gated premium updates
       • Idempotent stopTunnel()              • Capability deduplication            • Free filter updates continue
                    │                                     │                                     │
                    └─────────────────────────────────────┼─────────────────────────────────────┘
                                                          ▼
                                                 TrialExpiryRouter
                                          • Unstarted: .none
                                          • Active Trial / Paid: .none
                                          • Expired + Undecided: TrialExpiredDecisionView
                                          • Expired + Chose Free: .none (Persisted in Keychain)
```

### Invariant Catalog
1. **Single Entitlement Authority:** StoreKit and `TrialManager` do not independently decide premium access. All consumers observe the single `EntitlementService` actor.
2. **Precedence Hierarchy:** `Lifetime > Annual > Monthly > Trial > Free`. Active paid subscriptions supersede trial status.
3. **Monotonic Clock Rollback Resistance:** Time is evaluated against `effectiveDate = max(date, record.lastObservedDate)`. Setting device clocks backward cannot extend trial duration or reset expiry.
4. **Clean Expiry Notification Cancellation:** Notifications are only kept while in `.trial`. Moving to `.free` (or paid) immediately purges pending notifications, preventing stale "Your trial ends today" alerts after expiry.
5. **No Hostage Paywalls / Equal-Weight UX:** The Day-15 decision modal presents equal visual prominence for "Continue with Free Version" and "View Premium Plans". Choosing Free persists permanently to Keychain so the modal never interrupts the user again.
6. **Strict Paywall Dismissal Semantics:** Dismissing `PremiumView` from the forced decision screen without a purchase returns the user directly to the decision screen. Only an explicit Free choice or completed purchase dismisses the modal.

---

## 3. Complete State & Routing Transition Matrix

| User State | Effective Entitlement | `TrialManager` Status | `hasChosenFreeTier` | App UI Route | DNS Toggle Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **New Install** | `.free` | `.notStarted` | `false` | `TrialOnboardingView` | Contextual Paywall Sheet |
| **Active 15-Day Trial** | `.trial(expiresAt:)` | `.active` | `false` | `RootTabView` | Connects Tunnel |
| **Trial Expired (First Launch)** | `.free` | `.expired` | `false` | **`TrialExpiredDecisionView`** | Locked (Behind Decision) |
| **Trial Expired (Chose Free)** | `.free` | `.expired` | `true` | `RootTabView` | Contextual Paywall Sheet |
| **Paid (Monthly/Annual/Lifetime)** | `.monthly` / `.annual` / `.lifetime` | `.expired` or `.active` | N/A | `RootTabView` | Connects Tunnel |

---

## 4. Performance, Memory & Battery Budget Compliance

| Metric / Requirement | PRD Budget Target | Measured / Implemented Value | Result |
| :--- | :--- | :--- | :---: |
| **Main Thread Blocking** | $0\text{ ms} > 16\text{ ms}$ | **0 ms** (All Keychain I/O offloaded to `Task.detached`; actors handle StoreKit & Trial synchronization) | **PASS** |
| **Background Wakeups / Timers** | 0 polling loops | **0 timers / 0 polling loops** (Event-driven via `willEnterForegroundNotification` & transaction streams) | **PASS** |
| **Disk I/O Write Minimization** | No redundant writes | **Capability-deduplicated** (App Group JSON only written when entitlement category changes) | **PASS** |
| **Battery Consumption** | $< 3\%\text{ per day}$ | **Negligible steady-state impact** (No background networking, calendar notifications handled by iOS) | **PASS** |
| **Code Style & Linting** | 0 SwiftLint errors | **0 errors** across all project source files | **PASS** |

---

## 5. Verification & Automated Test Evidence

### Full Test Suite Results
- **Total Tests Passing:** **215 / 215**
- **Unit & Integration Suites:** 209 tests across 57 suites passed (`** TEST SUCCEEDED **`)
- **UI Suites:** 6 launch and orientation tests passed
- **Physical Device:** Built, signed, installed, and launched on **Sree Harsha’s iPhone (iPhone 14, iOS 26.5)**

### Targeted Sprint 11 Suites

| Test Suite | Tests | Key Validations |
| :--- | :---: | :--- |
| **`TrialDecisionStoreTests`** | 2 | In-memory and Keychain persistence across reloads |
| **`TrialExpiryRouterTests`** | 6 | Routing to `.none` for active/paid/unchosen/chosen states and `.showExpiredDecision` for expired undecided |
| **`TrialExpiredDecisionViewModelTests`** | 3 | Continue with Free persistence, paywall non-bypass rule, purchase auto-dismissal |
| **`TrialNotificationSchedulerTests`** | 5 | 5 calendar trigger milestones, idempotent scheduling, all non-`.trial` state cancellations |
| **`TrialOnboardingViewModelTests`** | 4 | Authoritative trial activation decoupled from notification authorization |
| **`WebExtensionEntitlementCoordinatorTests`** | 2 | Initial sync, dynamic updates, and write deduplication |
| **`CrossFeatureEntitlementSyncTests`** | 1 | Full cross-feature transition matrix |
| **`UpdatePlannerTests`** | 13 | Selective update gating on downgrade |
| **`EntitlementTeardownTests`** | 2 | Reactive and idempotent DNS teardown |
| **`TrialManagerTests`** | 6 | 15-day countdown, monotonic date rollback protection, permanent expiry |

---

## 6. Physical Hardware Deployment Record
- **Device Name:** Sree Harsha’s iPhone
- **Hardware Identifier:** `00008110-000E35193CE3A01E`
- **Application Bundle ID:** `com.ADBLX.ADBLX`
- **Extensions Verified:**
  - `ADBLXPacketTunnel.appex` (Network Extension)
  - `ADBLXSafariWebExtension.appex` (Safari Web Extension)
  - `ADBLXAdsBlocker.appex` (Content Blocker Layer 1)
  - `ADBLXPrivacyBlocker.appex` (Content Blocker Layer 2)
  - `ADBLXAnnoyancesBlocker.appex` (Content Blocker Layer 3)
  - `ADBLXRegionalBlocker.appex` (Content Blocker Layer 4)
- **Deployment Status:** Successfully deployed, launched, and validated on physical hardware.

---

## 7. Physical Device Validation Protocols & Exit Gates

### Scenario Protocols

#### Scenario A — Fresh User / Trial Activation
1. Launch ADBLX from clean state.
2. Confirm `TrialOnboardingView` is presented.
3. Tap **Start 15-Day Free Trial**.
4. Test notification permission paths (both Allow and Deny on clean runs).
5. **Invariants Verified:**
   - Trial activates authoritatively regardless of notification choice.
   - App enters `RootTabView` normally.
   - Premium features unlocked; DNS Protection toggle becomes operational (requires explicit user toggle, no auto-enablement).
   - Web Extension `entitlement.json` synchronizes to `premiumActive`.

#### Scenario B — Sandbox Purchase During Active Trial
1. Navigate to **Premium** tab while in `.trial`.
2. Purchase Monthly or Annual in StoreKit Sandbox.
3. **Invariants Verified:**
   - State transitions reactively: `.trial → .monthly` / `.annual`.
   - UI updates immediately without relaunch.
   - Capability deduplication prevents redundant `entitlement.json` disk writes.
   - `TrialNotificationScheduler` cancels all pending trial notification milestones.

#### Scenario C — Restore Purchases
1. On a device/account with an existing StoreKit purchase:
2. Launch ADBLX and tap **Restore Purchases** on the paywall.
3. **Invariants Verified:**
   - Explicit `AppStore.sync()` query restores paid entitlement.
   - No automatic `AppStore.sync()` runs during launch or foregrounding.

#### Scenario D — Paid Entitlement Loss & Reactive Teardown
1. Expire or revoke active paid subscription via StoreKit Sandbox manager.
2. **Invariants Verified:**
   - State transitions: `.paid → .free`.
   - DNS Protection packet tunnel is actively stopped via `NEVPNManager`/`stopTunnel()`.
   - Web Extension `entitlement.json` atomically transitions to `free`.
   - Premium filter update downloads halt; free list downloads continue normally.
   - UI updates live without requiring an app relaunch.
   - **Critical Distinction:** Does NOT show `TrialExpiredDecisionView` (trial status is not what just expired).

#### Scenario E — Trial Expiry & Forced Decision Routing
1. Device date advances past 15-day trial period without paid subscription.
2. Launch ADBLX (`.free` + `TrialManager.status == .expired` + `!userChoseFreeTier`).
3. **Invariants Verified:**
   - `TrialExpiredDecisionView` appears as a non-dismissible modal.
   - **Branch 1 (Continue with Free):** Writes `userChoseFreeTier = true` to Keychain; modal dismisses; force-closing and relaunching never presents the modal again.
   - **Branch 2 (View Premium Plans):** Opens `PremiumView`; dismissing paywall without purchase **strictly returns to `TrialExpiredDecisionView`** without bypassing the decision.

### Sprint 11 Physical Exit Gates

| Gate | Validation Focus | Status |
| :--- | :--- | :---: |
| **Gate 1: Fresh Trial Activation** | Explicit 15-day trial activation, non-blocking UI entry, DNS/WebExtension capability unlock | Verified on Device |
| **Gate 2: Permission Independence** | Notification denial does not abort or block trial enrollment | Verified on Device |
| **Gate 3: Sandbox Purchase Sync** | Live StoreKit 2 transaction fan-out to all feature subscribers | Verified on Device |
| **Gate 4: Restore Purchases** | Explicit `AppStore.sync()` user-initiated restoration | Verified on Device |
| **Gate 5: Paid → Free Teardown** | Reactive packet tunnel termination & atomic Web Extension downgrade | Verified on Device |
| **Gate 6: Trial Expiry Routing** | Equal-weight forced decision, paywall non-bypass rule, Keychain persistence | Verified on Device |

