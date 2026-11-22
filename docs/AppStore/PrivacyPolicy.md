<!--
DRAFT, not final. For the owner's review; nothing here is published.

Placeholders to fill before publishing:
  {{BRAND_NAME}}        the app's public name
  {{DEVELOPER_NAME}}    the legal name shown on the App Store (person or company)
  {{BRAND_DOMAIN}}      the product's domain
  {{PRIVACY_URL}}       where this page will live, e.g. https://{{BRAND_DOMAIN}}/privacy
  {{CONTACT_EMAIL}}     a privacy contact on the product's domain
  {{REPORT_EMAIL}}      the broken-site report alias (BrokenSiteReport.recipient)
  {{REPORT_RETENTION}}  how long broken-site report emails are kept, e.g. "12 months"
  {{EFFECTIVE_DATE}}

Open points for the owner (remove this block before publishing):
  1. DNS Protection is not in this version (Release builds don't embed the tunnel). When it
     ships, add a section: which resolver receives the queries, that the app keeps only counts,
     and the VPN configuration it installs.
  2. Retention of report emails ({{REPORT_RETENTION}}) is a decision, not a fact from the code.
  3. Check the "Your rights" wording with someone who knows the law where you're based; it is
     deliberately general.
  4. If filter lists move off GitHub Pages (to the brand domain, say), rewrite "Filter list
     updates" for the new host.
-->

# {{BRAND_NAME}} Privacy Policy

Effective {{EFFECTIVE_DATE}}

{{BRAND_NAME}} blocks ads, trackers and page clutter in Safari. It is built so that what you
browse stays on your device. This policy explains what the app handles, where it goes, and
what you can do about it.

## The short version

- No account and no sign-in.
- No analytics, no advertising, and no third-party tracking or crash-reporting code.
- We never see the websites you visit.
- If you send us a broken-site report, it comes to us by email, and we keep it to fix the
  filters.

## Safari content blockers

{{BRAND_NAME}} gives Safari lists of blocking rules. Safari applies them itself. The app
doesn't see the pages you visit, and it isn't told when a rule blocks something.

## YouTube enhancements in Safari (Premium)

The {{BRAND_NAME}} Safari extension runs only on youtube.com pages. There it reads the page to
skip and hide video ads. It does this on your device and sends nothing about the videos you
watch to us or anyone else. It stores its own settings in Safari's extension storage, and it
asks the {{BRAND_NAME}} app, on your device, whether Premium is active and which rules to use.

## Filter list updates

To keep its block lists current, the app downloads them over HTTPS from GitHub Pages, a web
hosting service run by GitHub. These downloads contain nothing about you or your browsing, but
GitHub sees the IP address each request comes from, as any web server does, and may keep it in
its logs. GitHub's privacy statement explains how it handles that:
https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement. We don't
receive those logs.

## Purchases and the free trial

Purchases go through Apple. We never receive your payment details. The app reads your
purchase from Apple on your device to know whether Premium is active.

The free trial's start date is stored in your device's keychain, so the trial can't be started
again. It is not sent anywhere.

## Your allowlist

Sites you allow are stored on your device only.

## Notifications

If you allow notifications, the app schedules reminders about your trial on your device. No
server sends them.

## Broken-site reports

If a site doesn't work and you choose to report it, the app opens your mail app with a message
to {{REPORT_EMAIL}}. Before you send it, you can see everything in it:

- the site's domain (not the full address of the page)
- the app's version
- which filter groups you have turned on
- the kind of problem you picked

Your mail app adds your email address, and the message includes anything you type. We use
reports only to fix our filters and to reply to you. We keep them for {{REPORT_RETENTION}},
then delete them. Ask us at {{CONTACT_EMAIL}} and we'll delete yours sooner.

## Diagnostics

The app contains no crash-reporting or analytics code. If you have chosen to share analytics
with app developers in your device's settings, Apple may give us crash reports and usage
statistics that don't identify you. You can change this in Settings > Privacy & Security >
Analytics & Improvements.

## Children

{{BRAND_NAME}} isn't directed at children and doesn't knowingly collect anyone's personal
information beyond the broken-site reports described above.

## Your rights

Depending on where you live, you may have the right to ask what personal information we hold
about you, to correct it, or to delete it. The only personal information we hold is in
broken-site report emails. Write to {{CONTACT_EMAIL}} and we'll answer within 30 days.

## Changes

If this policy changes, we'll update the date at the top and post the new version at
{{PRIVACY_URL}}. If a change affects what we handle, we'll also say so in the app's release
notes.

## Contact

{{DEVELOPER_NAME}}
{{CONTACT_EMAIL}}
