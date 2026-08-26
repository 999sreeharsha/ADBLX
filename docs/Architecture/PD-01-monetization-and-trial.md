# PD-01 — Monetization, Trial, and Paywall Decisions

**Date:** 2026-08-26 · **Status:** Accepted, supersedes PRD §9 trial terms
**Owner:** Harsha · **Scope:** Pricing tiers, universal trial mechanics, notification schedule, effective entitlement resolution, and the two paywall surfaces (day-15 forced decision, contextual locked-feature upsell)

---

## 1. Supersession notice

**PRD `adblock-prd-v1.1.md` §9 states a "7-day free trial."** This document changes that to a **15-day universal trial** and adds mechanics not in the PRD at all. §9 is updated to point to this decision record as the authoritative source of truth.

---

## 2. Pricing tiers (final)

| Tier | Price | Mechanism |
|---|---|---|
| Free | $0 | Safari CB blocking (Ads/Privacy groups) only, forever |
| Monthly | $1.99/mo | StoreKit 2 auto-renewable subscription |
| Annual | $14.99/yr (anchor) | StoreKit 2 auto-renewable subscription |
| Lifetime | $39.99 | StoreKit 2 non-consumable IAP |

**No separate StoreKit-managed trial/introductory offer on any subscription product.** The trial is universal, app-side, and independent of which plan a user eventually picks (see §3). Monthly is **retained** — reversing the earlier "Annual + Lifetime only" lean — because the 15-day universal trial already does the job "let me try before I commit" was meant to solve; Monthly's remaining job is giving a converted trial user a low-commitment way to *stay* paid, not a way to sample the product.

---

## 3. Trial mechanics & effective entitlement resolution

- **Every install** gets full Premium access (DNS filtering, YouTube-in-Safari, regional lists, iCloud sync, custom list import, Mac app) for **15 days**, starting from first launch. No payment method requested at any point during this window.
- **Anti-casual-abuse storage:** Trial state is stored in Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`) to resist ordinary uninstall/reinstall resets. This is an anti-casual-abuse measure and is not treated as tamper-proof or as a guaranteed permanent anti-abuse mechanism.
- **`TrialManager`** manages trial activation, remaining duration, and expiry.
- **`EntitlementService` is the single source of truth for the effective entitlement:**
  ```swift
  public enum EntitlementState: Sendable, Equatable {
      case trial(expiresAt: Date)
      case monthly(expiresAt: Date)
      case annual(expiresAt: Date)
      case lifetime
      case free
  }

  public extension EntitlementState {
      var hasPremiumAccess: Bool {
          switch self {
          case .trial, .monthly, .annual, .lifetime:
              return true
          case .free:
              return false
          }
      }
  }
  ```
- **Unified Expiry / Lapse Transition Path:** Trial expiry and subscription lapse feed the exact same transition path:
  ```text
  Premium access ends
          │
          ▼
  EntitlementService publishes .free
          │
          ├── Immediate DNS tunnel teardown
          ├── DNS UI becomes locked
          ├── Premium feature gates update
          └── Free-tier UI remains usable
  ```
- **First-launch onboarding screen** (`TrialOnboardingView`) explains the trial and countdown; shown exactly once, gated on Keychain having no stored start date. Requests notification permission at this point (contextual ask, not cold-open).

---

## 4. Notification schedule & cancellation rule

Five local notifications (`UNCalendarNotificationTrigger`, on-device only, no server/push infrastructure), scheduled once at trial activation:

| Day | Purpose |
|---|---|
| 5 | Early reminder |
| 9 | Mid-trial reminder |
| 12 | Approaching end |
| 14 | 1 day left |
| 15 | Trial ends today |

**Notification Cancellation Rule:**
When effective entitlement resolves to an active paid subscription/lifetime purchase, or when the user explicitly chooses "Continue with Free" on the Day-15 decision screen, `TrialNotificationScheduler.cancelPendingTrialNotifications()` cancels all remaining scheduled trial notifications immediately.

---

## 5. Day-15 expiry: forced decision screen

When `TrialManager.state == .expired` **and** no active StoreKit entitlement exists **and** the user has not already made a persisted free-tier choice:

- **`TrialExpiredDecisionView`** is shown — **non-dismissible** (no swipe-away, no tap-outside, no hidden skip). This is the one deliberately "blocking" surface in the whole design.
- **"Continue with Free" is a first-class, equally-weighted option** on this screen, not a de-emphasized link or hidden gesture — this is what keeps the forced decision from crossing into a hostage-pattern paywall, which would sit badly against a privacy/trust-first brand.
- Choosing Free **writes a second Keychain flag** (`userChoseFreeTier`) so this screen **never reappears** for that user — it's a one-time decision, not a recurring gate.
- Choosing any paid plan routes into `StoreKitSubscriptionService`; success updates `EntitlementService` to `.monthly`, `.annual`, or `.lifetime`.

**App Store review note:** this pattern is acceptable provided free functionality is genuinely usable and not crippled to non-functionality — true here, since Free retains real Safari CB blocking per the PRD's feature matrix.

---

## 6. Post-free-choice re-engagement: contextual paywall

Rather than re-surfacing the day-15 screen on a timer (rejected — reads as nagging, no genuine new signal), re-engagement is **contextual**: tied to the user tapping a control that gates a specific Premium feature (DNS toggle, YouTube extension enable, Regional filter toggle, iCloud sync, custom list import, Mac app entry).

- **`ContextualPaywallView`** — a dismissible sheet ("Not now" always available), shown per-feature, per-tap. Not a recurring or scheduled prompt.
- Premium-gated controls are shown **visibly disabled/locked** (not hidden), so free users can see what they're missing without hunting for it.

---

## 7. What's explicitly out of scope / not decided here

- **Silent auto-drop to Free with no decision screen** — rejected; risks losing a willing payer who simply didn't notice the transition.
- **Full app-lock with no free escape hatch at day 15** — rejected; considered but not chosen, in favor of the equally-weighted "Continue with Free" option.
- **Time-based re-paywalling of free users** — rejected in favor of contextual, locked-feature-tap triggering only.
- **Marketing/ASO plan** — parallel track.
