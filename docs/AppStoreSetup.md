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

## Billing Grace Period

Enabled in App Store Connect on 2026-11-20:

| Setting | Value |
|---|---|
| Grace period length | 16 days |
| Eligibility | Only Paid-to-Paid Renewals: a renewal after a paid period. A free trial or offer converting to paid gets no grace period. |
| Environments | Sandbox and production |

When a renewal fails, StoreKit keeps the subscription in `Transaction.currentEntitlements` for the
grace period. Its `expirationDate` has already passed by then, and the grace period's end is in the
renewal info. After that the subscription is in billing retry and grants nothing.

How the app handles it (`StoreKitSubscriptionService.resolve`, `BillingGracePeriodTests`):
- **In a grace period:** entitled. Access lasts until the grace period ends, read from the
  subscription's signed renewal info. The web extension and the tunnel stop exactly at the grace
  end, without the usual 7 days of slack (`EntitlementState.validUntil`), so 16 days stays 16.
- **Renewal info that doesn't verify:** no grace. Access stays what the transaction itself gives.
- **In billing retry after the grace period, or with none:** not entitled, even if StoreKit still
  lists the transaction.

Local StoreKit testing matches: `Config/Configuration.storekit` has Enable Billing Retry on Renewal
(`_renewalBillingIssuesEnabled`) and Enable Billing Grace Period (`_billingGracePeriodEnabled`) on.
These are the key names Xcode 27 writes from its Editor menu, and it reads them as on.

The file is in Xcode 27's format (6.3), the format Xcode 27 writes when the file is opened.
CI runs Xcode 27.2 on the `xcode-27` runner (`.github/workflows/ci.yml`), so it reads the same format.

If the length or eligibility changes in App Store Connect, update this table. The code needs no
change, because the grace end comes from StoreKit.

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
- [ ] With the Sandbox tester's renewals set to fail, a subscription past its renewal date stays
      Premium during the grace period, and YouTube ad skipping (the web extension) keeps working.
- [ ] After the grace period ends, the app drops to Free at the next launch or foreground.

## Broken Site Reports

Reports are sent from the user's own mail app to `BrokenSiteReport.recipient`. Before submitting:

- **Address:** set `BrokenSiteReport.recipient` to a forwarding alias on the product's domain, such as `reports@<brand-domain>`, not a personal mailbox. It ships in the app and will be scraped. An archive fails until it's set (`Scripts/check-report-recipient.sh`).
- **Privacy policy:** say that reports arrive by email and contain only the domain, app version, enabled groups and issue category, along with the sender's address, which the mail app adds. The repository has no privacy policy yet.
- **App Privacy label:** keeping a report for longer than it takes to answer it counts as "collect" under [Apple's definition](https://developer.apple.com/app-store/app-privacy-details/). Optional feedback can be left undeclared only if every listed criterion holds, including that the user's name or account name is prominently displayed in the submission form. Ours doesn't show one, so declare **Customer Support** and **Email Address**, linked to the user, with purpose App Functionality. Check the page again when filling in the label.

## Release Checklist

Before the first TestFlight upload:

- [x] **Signed manifest live on the site** (2026-11-21: `manifestVersion` `2026-11-21T17:20:57Z`, SHA-256 `8017d15e…`, signed with K1), with both public keys (K1 and K2) pinned in the build. Every build requires a signature, with no unsigned transition, so a build reading an unsigned site can never update. `publisher verify` checks the committed files; then fetch the deployed `manifest.json` and confirm its SHA-256 names a file under `signatures/` on the site. See `docs/Security/ManifestTrust.md`.
- [x] **Recompile on compiler change** (built 2026-11-07): the installed compiled rules record the compiler version, and launch recompiles every group from its stored lists when it differs. Bump `CompiledSources.currentCompilerVersion` with every compiler change (`CompilerSourceFingerprintTests` fails when the compiler changes and the stored fingerprint doesn't). A recompile that keeps failing stops after three tries until the next build. Testers update across compiler fixes, and without this they keep rules from the old compiler until a list update happens to recompile them (`docs/gotchas.md`, "Compiler: dropping an unsupported domain must never widen a rule").

Every archive also fails, without CI, if the app has DNS Protection in it, an extension's version
differs from the app's, a background mode or task identifier is missing, or the DEBUG timing spike
is in the binary (the "Check Release Build" phase, `Scripts/check-archive-release.sh`).

Before each App Store submission:

- [ ] **Report recipient** set to the product-domain alias (see Broken Site Reports). An archive fails until it is.
- [ ] **Privacy policy URL** live on the product's domain and entered in App Store Connect, which requires one. It needs the brand domain, so it waits on the name decision with the recipient. The policy text needs the Broken Site Reports line above.
- [ ] **App Privacy label**: Customer Support and Email Address, linked to the user, not used for tracking.
- [ ] **Performance, on a device:** the tests print timings but don't assert them, because simulator timing on a shared machine says nothing about the targets. On an A14-class iPhone with a Release build, profile with Instruments (Time Profiler plus the `os_signpost` instrument, subsystem `com.ADBLX`, category `FilterPipeline`):
  - NFR-01: the `Pipeline.compile` intervals for a 100K-rule group total under 10 s, with memory under 200 MB during compile.
  - NFR-05: cold start under 1.5 s.
  Record the results in the Operational Status Log.

## Operational Status Log

| Date | Environment | Action | Performed By | Result | Notes |
|---|---|---|---|---|---|
