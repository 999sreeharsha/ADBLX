# App Privacy label: draft answers

**DRAFT, not final.** These are the answers to enter in App Store Connect > App Privacy, with
the reason for each. Check them against [Apple's App Privacy Details page](https://developer.apple.com/app-store/app-privacy-details/)
when you fill in the form; the definitions change.

They describe the Release build at `dev` on 2026-11-22: no DNS Protection, no third-party SDKs.
Redo them when either changes.

## Summary

| Question | Answer |
|---|---|
| Do you or your third-party partners collect data from this app? | **Yes** |
| Data types collected | **Contact Info > Email Address** and **User Content > Customer Support** |
| Used for tracking? | **No**, for both |
| Linked to the user's identity? | **Yes**, for both |
| Purposes | **App Functionality**, for both |

## Why these two types

Broken-site reports arrive by email at {{REPORT_EMAIL}}. Each carries the sender's email
address and the report (the site's domain, the app version, enabled filter groups, the issue
category, and anything the user types). We keep them longer than it takes to answer them, which
is "collection" under Apple's definition.

Optional feedback can go undeclared only if every one of Apple's conditions holds. One of them
is that the user's name or account name is prominently shown in the submission form. Our report
opens in the user's mail app, and the form shows no name, so declare it
(`docs/AppStoreSetup.md`, Broken Site Reports).

- **Email Address**: the sender's address, which the mail app adds. Linked: it identifies the
  user. Purpose: App Functionality, since we use it to answer the report.
- **Customer Support**: the report's contents. Linked: it arrives with the email address.
  Purpose: App Functionality.

**Decision for you: Browsing History.** Apple defines it as content the user has viewed outside
the app, such as websites. A report names one site's domain. We read it as part of a support
request (Customer Support), not as browsing history: the user picks one site and chooses to send
it. If you'd rather be conservative, also declare **Browsing History**, linked, App Functionality.

## What is not collected, and why

| Data | Why it isn't declared |
|---|---|
| Websites visited | Safari applies the content-blocker rules itself. The app never sees pages or blocking events. |
| YouTube pages and videos | The web extension reads youtube.com pages on the device and sends nothing off it. |
| Purchases | StoreKit transactions are verified on the device. No server of ours receives them. |
| Trial start date | Stored in the device's keychain, never sent. |
| Allowlist (Premium iCloud sync) | Stored in the user's own iCloud key-value storage, which we can't access. Apple treats data the developer can't access as not collected. |
| Notifications | Local only, scheduled on the device. |
| Diagnostics | No crash or analytics SDK. MetricKit payloads are only counted on the device. Crash reports and analytics that users share through Apple's own opt-in are Apple's data, not ours; confirm this on Apple's page when you fill in the form. |
| IP address on filter downloads | The list host ({{FILTER_HOST}}) sees requests in its server logs, but we don't receive them, don't use them, and send nothing about the user. **Check this one** against Apple's page: if you decide the host counts as a partner collecting data, the type would be Identifiers or Diagnostics, not linked, not tracking. |

## Redo the label when

- DNS Protection ships (the resolver receives every DNS query; decide whether that counts as
  collection by a partner).
- Any SDK is added.
- Reports move from email to a form or a server.
- iCloud sync changes (see the open point in `PrivacyPolicy.md`).
