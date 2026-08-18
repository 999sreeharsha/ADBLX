# App Store Setup

## Single Source of Truth

The product identifiers and pricing in `Config/Configuration.storekit` are
canonical. App Store Connect must be configured to mirror them exactly. This
document does not restate values independently of that file — if the two
ever disagree, `Configuration.storekit` wins and this document (and App
Store Connect) must be corrected to match it.

> **Open product decision (not resolved by Sprint 8.05):**
> `Configuration.storekit` currently defines $19.99 annual / $49.99 lifetime.
> PRD v1.1 (`docs/adblock-prd-v1.1.md`) still lists older $14.99 / $39.99
> pricing. Sprint 8.05 does not rewrite the PRD; App Store Connect setup
> follows `.storekit` until product explicitly reconciles the two.

## Product Configuration

As of this writing, `Config/Configuration.storekit` defines:

| Product ID | Type | Price |
|---|---|---|
| `com.ADBLX.ADBLX.premium.annual` | Auto-Renewable Subscription | $19.99/year |
| `com.ADBLX.ADBLX.premium.lifetime` | Non-Consumable | $49.99 one-time |

`com.ADBLX.ADBLX.premium.annual` belongs to a subscription group (see
`Configuration.storekit` for the group identifier) since auto-renewable
subscriptions in App Store Connect must belong to one.

## App Store Connect Setup

Performed by the Apple Developer account owner:

1. Confirm an active Apple Developer Program membership.
2. Create the App Store Connect app record for ADBLX (bundle ID
   `com.ADBLX.ADBLX`).
3. Create a subscription group and add `com.ADBLX.ADBLX.premium.annual` to
   it as an auto-renewable subscription, priced at $19.99/year.
4. Add `com.ADBLX.ADBLX.premium.lifetime` as a non-consumable in-app
   purchase, priced at $49.99.
5. Confirm both product IDs match `Configuration.storekit` exactly
   (character-for-character — App Store Connect will treat any mismatch as
   an unrelated product).

## Sandbox Verification

Performed against a Sandbox tester account, tying back to the entitlement
code shipped in Sprint 8.0 (`EntitlementService`, `StoreKitSubscriptionService`):

- [ ] Annual subscription purchase succeeds.
- [ ] Lifetime purchase succeeds.
- [ ] Restore Purchases restores both correctly.
- [ ] `EntitlementService.isPremiumEntitled()` returns `true` immediately
      after purchase.
- [ ] `EntitlementService.isPremiumEntitled()` still returns `true` after a
      full app relaunch (confirms entitlement persists across launches, not
      just in-memory for the purchase session).

## Operational Status Log

| Date | Environment | Action | Performed By | Result | Notes |
|---|---|---|---|---|---|
