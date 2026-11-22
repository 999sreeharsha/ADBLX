<!--
DRAFT, not final. For the owner's review. The text under "Notes for App Review" is what goes into
App Store Connect > App Review Information > Notes; everything else is for us.

Placeholders:
  {{BRAND_NAME}}, {{BRAND_DOMAIN}}, {{SUPPORT_URL}}, {{PRIVACY_URL}}, {{CONTACT_NAME}},
  {{CONTACT_EMAIL}}, {{CONTACT_PHONE}}
  {{ADS_EXTENSION_NAME}}, {{PRIVACY_EXTENSION_NAME}}, {{ANNOYANCES_EXTENSION_NAME}},
  {{REGIONAL_EXTENSION_NAME}}, {{WEB_EXTENSION_NAME}}: the names Safari shows. Today they are the
  target names (ADBLXAdsBlocker, ADBLXPrivacyBlocker, ADBLXAnnoyancesBlocker,
  ADBLXRegionalBlocker) and "ADBLX Safari Web Extension", because project.yml sets no display
  names. Give them user-facing names before submission.
  {{ANNUAL_PRICE}}, {{LIFETIME_PRICE}}: prices are still undecided (AppStoreSetup.md vs the PRD).

BLOCKERS to resolve before this can be submitted (remove this block when done):
  1. Background modes. Release declares UIBackgroundModes fetch and processing and the two task
     identifiers (ADR-0014), but in Release nothing registers or schedules a background task:
     only the DEBUG timing spike does, until task 6 of the background-updates plan lands. A
     declared mode the app doesn't use is a common rejection (Guideline 2.5.4). Either ship
     task 6 before submitting, or take the modes out of Release. The section below is written
     for the case where task 6 has shipped; rewrite it if the modes are removed instead.
  2. The paywall lists "Background Updates" as a Premium feature, while the background-updates
     plan decided both plans get them, and today neither does. Make the paywall match what ships.
  3. The paywall's YouTube text promises "background play, and PiP support". Confirm both work
     in Safari with the extension before submission, or change the text: an unmet feature claim
     is a 2.3.1 rejection.
  4. No regional list is published (the live manifest has easylist, easyprivacy,
     fanboy-annoyances and shield-fixes), so the regional content blocker is empty. The notes
     don't promise regional filters; say why the extension exists if a reviewer asks, or publish
     a list first.
  5. The trial (15 days, Keychain, no StoreKit record) is the accepted Guideline 3.1.1 risk in
     docs/gotchas.md and PD-01. If PD-01 switches to an App Store free trial, rewrite
     "How to test Premium".
-->

# App Review notes: draft

## Notes for App Review

{{BRAND_NAME}} blocks ads, trackers and page clutter in Safari, and skips video ads on YouTube in
Safari. It needs no account or sign-in, so no demo account is required.

**Turning on the Safari extensions**

The app installs five Safari extensions. Turn them on in Settings > Apps > Safari > Extensions:

- {{ADS_EXTENSION_NAME}}, {{PRIVACY_EXTENSION_NAME}}, {{ANNOYANCES_EXTENSION_NAME}} and
  {{REGIONAL_EXTENSION_NAME}} are content blockers. Each holds one group of blocking rules,
  because Safari limits the number of rules per content blocker. Safari applies the rules itself;
  the app never sees the pages visited.
- {{WEB_EXTENSION_NAME}} is a Safari web extension for YouTube. It runs only on youtube.com
  (its only host permission) and skips and hides video ads there. Allow it for youtube.com when
  Safari asks. It talks to the app on the device only, to check whether Premium is active and to
  read its rules. It sends nothing off the device.

The Protection tab shows each group and whether its Safari extension is on.

**Background modes (fetch and processing)**

The app uses a background app refresh task to check for new filter lists and download them,
and a background processing task to compile the downloaded lists into Safari's rule format and
reload the content blockers. Compiling a full list takes too long for an app refresh task, which
is why the second task exists. Neither runs on a schedule we promise; iOS decides when. The app
also checks for updates when it is opened.

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

1. Turn on {{ANNOYANCES_EXTENSION_NAME}} and visit a site with a cookie banner: the banner is
   hidden.
2. Turn on {{WEB_EXTENSION_NAME}} and play a YouTube video in Safari: its ads are skipped.

When Premium ends (trial over, subscription lapsed, refund), the app removes the premium filters
the next time it is opened or brought to the foreground, and the YouTube extension stops
skipping ads.

**Privacy**

No analytics, advertising or third-party SDKs. Filter lists download from our server and carry
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

- Fill in every placeholder; check the extension names against what Settings shows.
- Clear every blocker in the comment at the top.
- Check the Premium list against the paywall and `BundledPremiumCatalog` at the time.
- If DNS Protection ships in this version, add a section explaining the VPN configuration
  (on-device DNS filtering, no traffic other than DNS routed) and the Network Extension.
