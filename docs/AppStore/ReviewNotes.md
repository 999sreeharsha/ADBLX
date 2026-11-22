<!--
DRAFT, not final. For the owner's review. The text under "Notes for App Review" is what goes into
App Store Connect > App Review Information > Notes; everything else is for us.

Placeholders:
  {{BRAND_NAME}}: the BRAND_NAME build setting in project.yml (ADBLX today). The extensions are
    named from it: "{{BRAND_NAME}} Ads", "{{BRAND_NAME}} Privacy", "{{BRAND_NAME}} Annoyances",
    "{{BRAND_NAME}} Regional" and "{{BRAND_NAME}} YouTube" (ExtensionDisplayNameTests). When the
    brand is chosen, change BRAND_NAME and the "name" in the web extension's manifest.json.
  {{SUPPORT_URL}}, {{PRIVACY_URL}}, {{CONTACT_NAME}}, {{CONTACT_EMAIL}}, {{CONTACT_PHONE}}
  {{ANNUAL_PRICE}}, {{LIFETIME_PRICE}}: prices are still undecided (AppStoreSetup.md vs the PRD).

Still open before submission (remove this block when done):
  1. Regional blocker: no regional list is published, so "{{BRAND_NAME}} Regional" is an empty
     content blocker. The owner is deciding what to do with it. The notes below describe it only
     as one of the content blockers; revise them once that's decided.
  2. The trial (15 days, Keychain, no StoreKit record) is the accepted Guideline 3.1.1 risk in
     docs/gotchas.md and PD-01. If PD-01 switches to an App Store free trial, rewrite
     "How to test Premium".
  3. The paywall's comparison table still marks "Auto Updates" as Premium only, though free users
     get updates when they open the app and neither plan gets background updates. Decide whether
     that row stays before submission.

Settled for this build, so not mentioned to App Review: no background modes (off in Release
behind BACKGROUND_UPDATES_ENABLED, ADR-0014 section 5), no iCloud sync or iCloud entitlement, no
DNS Protection or Network Extension. If any of them ships, add a section for it here.
-->

# App Review notes: draft

## Notes for App Review

{{BRAND_NAME}} blocks ads, trackers and page clutter in Safari, and skips video ads on YouTube in
Safari. It needs no account or sign-in, so no demo account is required.

**Turning on the Safari extensions**

The app installs five Safari extensions. Turn them on in Settings > Apps > Safari > Extensions:

- {{BRAND_NAME}} Ads, {{BRAND_NAME}} Privacy, {{BRAND_NAME}} Annoyances and
  {{BRAND_NAME}} Regional are content blockers. Each holds one group of blocking rules, because
  Safari limits the number of rules per content blocker. Safari applies the rules itself; the app
  never sees the pages visited.
- {{BRAND_NAME}} YouTube is a Safari web extension. It runs only on youtube.com (its only host
  permission) and skips and hides video ads there. Allow it for youtube.com when Safari asks. It
  talks to the app on the device only, to check whether Premium is active and to read its rules.
  It sends nothing off the device.

The Protection tab shows each group and whether its Safari extension is on.

Filter lists update when the app is opened. The app runs no background tasks.

**How to test Premium**

- **Free:** the ads and privacy filter groups.
- **Premium:** the annoyances filters (cookie banners, pop-ups) and the YouTube extension.

There are two ways to get Premium:

1. **Free trial.** The first launch offers a 15-day trial, which starts with no purchase or
   payment method. The Premium tab then shows when the trial ends.
2. **Purchase** with a sandbox account, from the Premium tab: an annual subscription
   ({{ANNUAL_PRICE}}) or a lifetime purchase ({{LIFETIME_PRICE}}). **Restore** on the same tab
   restores earlier purchases.

To check what Premium unlocks:

1. Turn on {{BRAND_NAME}} Annoyances and visit a site with a cookie banner: the banner is hidden.
2. Turn on {{BRAND_NAME}} YouTube and play a YouTube video in Safari: its ads are skipped.

When Premium ends (trial over, subscription lapsed, refund), the app removes the premium filters
the next time it is opened or brought to the foreground, and the YouTube extension stops
skipping ads.

**Privacy**

No analytics, advertising or third-party SDKs. Filter lists download from GitHub Pages and carry
nothing about the user. Broken-site reports are optional and sent from the user's own mail app.
The privacy policy is at {{PRIVACY_URL}}.

## App Review Information fields

| Field | Value |
|---|---|
| Sign-in required | No |
| Contact | {{CONTACT_NAME}}, {{CONTACT_EMAIL}}, {{CONTACT_PHONE}} |
| Support URL | {{SUPPORT_URL}} |
| Privacy policy URL | {{PRIVACY_URL}} |

## Before pasting

- Fill in every placeholder, and check the extension names against what Settings shows on a
  Release build.
- Clear the open points in the comment at the top.
- Check the Premium list against the paywall and `BundledPremiumCatalog` at the time.
