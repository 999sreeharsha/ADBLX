# Security findings

Open findings from the 2026-10-30 to 2026-11-04 security audit, with fixes corrected by a later review. Nothing here has been implemented or tested unless its status says so. Findings come from reading the code; nothing was exploited.

Write the failing test first when fixing an item.

**Status values:** Open, Blocked, Fixed, Accepted.

**Source tags:** Panel (confirmed by a Claude Security three-voter panel), Manual (manual audit only), Overruled (the panel rejected it, and the review keeps it as a real issue).

Scan reports are in the gitignored `CLAUDE-SECURITY-*` folders at the repo root.

## Summary

| ID | Finding | Severity | Source | Status |
|---|---|---|---|---|
| **Fix now** | | | | |
| SEC-01 | `syncAllowlist` race restores premium rules | LOW | Panel | Fixed |
| SEC-02 | Content-blocker handlers parse the whole rules file | HIGH | Manual | Open |
| SEC-03 | Broken-site report silently allowlists the domain | MEDIUM | Manual | Open |
| SEC-04 | Paywall advertises "Encrypted DNS" | MEDIUM | Manual | Open |
| SEC-05 | `deploy-pages.yml` publishes the dispatching branch | LOW | Overruled | Open |
| SEC-06 | JS tests don't run in CI; `DIAG_VERBOSE` is on | LOW | Manual | Open |
| SEC-07 | Benchmark spike files are in the tunnel folder | LOW | Manual | Open |
| SEC-08 | Each ad skip sends two clicks | LOW | Manual | Open |
| **Pre-launch blockers** | | | | |
| SEC-09 | Manifest isn't authenticated or validated | HIGH | Overruled | Open |
| SEC-10 | `PublicSuffixList` widens allowlisted domains | MEDIUM | Overruled | Open |
| SEC-11 | Web-extension rule payload needs an audit | To confirm | Review | Open |
| **With the DNS track** | | | | |
| SEC-12 | No DNS over TCP; responses over 4096 bytes truncated | MEDIUM | Manual | Open |
| SEC-13 | Tunnel start check allows `.free` | LOW | Panel | Open |
| SEC-14 | Upstream DNS responses are easy to spoof | LOW | Panel | Open |
| SEC-15 | Tunnel thread-safety gaps | LOW | Manual | Open |
| **Decide and record** | | | | |
| SEC-16 | Clock set forward extends the trial | LOW | Panel | Blocked on the PD-01 trial decision |
| SEC-17 | macOS `entitlement.json` is user-editable | LOW | Panel | Accepted |
| SEC-18 | Web-extension rule checksum is never verified | LOW | Manual | Open |

## Fix now

### SEC-01: `syncAllowlist` race restores premium rules

`FilterPipeline.syncAllowlist` (`ADBLX/Filtering/Pipeline/FilterPipeline.swift:132`) takes no `FilterTransactionGate`. `SettingsService.swift:68` and `:84` call it directly. A downgrade can finish while it is suspended in the compile, and it then writes the stale premium rules back. The result lasts, because the reconciler only compares `installed_filters.json` with entitlement.

`ICloudSyncCoordinator.swift:161` is also ungated, but nothing calls its `startObserving()` today.

**Fixed:**
- `syncAllowlist` now holds the gate (`AllowlistSyncGateTests`), which also covers the iCloud path. No caller holds the gate when calling it, so no ungated variant was needed. An allowlist edit made during an update now waits for that update to finish.
- Each compile writes `Compiled/<Group>.sources.json` holding `{sourceIDs, compiledSHA256, ruleCount}`, right after the compiled JSON. A reconcile recompiles a group whose sidecar is missing or whose source IDs differ from `installed_filters.json` (`CompiledSourcesDriftTests`).

**Limits:**
- A reconcile compares source IDs only. Hashing the compiled files on every launch and foreground would exceed the performance budget, so `compiledSHA256` is written but not yet checked.
- An install from before this change has no sidecar, so its first reconcile recompiles every group once. A group with no sidecar and nothing installed is skipped, so a premium file left that way by the old bug isn't repaired.

### SEC-02: Content-blocker handlers parse the whole rules file

`ruleCount(at:)` (`Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift`, the same in all 4 extensions) loads the file and runs `JSONSerialization` on it just to log a count. Decoding up to about 150K rules would exceed the extension's roughly 6 MB memory budget, and iOS would kill the extension.

The call sits inside a `logger.info` interpolation, but info messages are normally kept in memory on iOS, so it most likely runs, and it certainly runs when logs are streamed. The fix costs less than measuring that.

**Fix:** read the count from the SEC-01 sidecar, and log "unknown" if the sidecar is missing. Never fall back to parsing the rules.

**Verify:** measure the extension with `memgraph` or the Allocations template while Safari reloads it. Peak memory should drop well below the limit of about 6 MB.

### SEC-03: Broken-site report silently allowlists the domain

`BrokenSiteReporter.swift:48` defaults `autoAllowlist` to `true`, and `:53` allowlists before sending. FR-14 specifies an auto-allowlist *prompt*. The report also POSTs to static GitHub Pages (`:29`), which can't accept it, and it sends a domain off the device.

**Fix:**
- Default to `false`, and allowlist only after the user confirms.
- Get explicit consent and show the payload before anything is sent.
- **Transport (decided): a `mailto:` URL, not `MFMailComposeViewController`.** `canSendMail()` is false unless Apple Mail is set up, and a `mailto:` URL opens the user's default mail app. If it can't open, copy the report to the clipboard and say so.
- The report holds only the registrable domain, the app version and the enabled groups, with no full URL, path or query.
- "Report" and "Allow this site" are separate buttons.
- Add a line to PRD FR-14: mail until a backend exists.

### SEC-04: Paywall advertises "Encrypted DNS"

`ADBLX/Features/Premium/Trial/TrialExpiredDecisionView.swift:68` claims encrypted DNS, but the upstream is plaintext UDP/53. `DNSProtectionView` says "encrypted upstream" too (`docs/TECHNICAL_OVERVIEW.md` §6.3). DNS Protection also can't ship until its connectivity bug is closed.

**Fix:** remove the DNS line from the paywall while DNS isn't in the release, and don't just reword it. Advertising an absent feature risks a Guideline 2.3 rejection. Correct the `DNSProtectionView` copy, and restore the claim only if DoH or DoT ships.

### SEC-05: `deploy-pages.yml` publishes the dispatching branch

`.github/workflows/deploy-pages.yml` checks out with no `ref` and uploads `.`, so a manual `workflow_dispatch` from another branch publishes that branch as the live manifest site. Only people with write access can trigger it.

**Fix:** set `ref: gh-pages` on the checkout step.

### SEC-06: JS tests don't run in CI; `DIAG_VERBOSE` is on

`content.test.js:1112` asserts `DIAG_VERBOSE` is false, but `ci.yml` only runs `-only-testing:ADBLXTests`, so nothing enforces it. The working tree currently has it set to `true` (`content.js:20`). Its own comment says verbose mode can echo page markup, and `docs/Architecture/Logging.md` allows no exception for debug builds.

**Fix:** add the extension's JS tests to CI, and set the flag back to `false` before committing. Check whether the verbose dumps can include URLs or domains.

### SEC-07: Benchmark spike files are in the tunnel folder

`Extensions/ADBLXPacketTunnel/` holds `DNSBenchmarkSpike.swift`, `DNSBenchmarkSpike.swift.patch` and `dns_artifact.bin`. The class has no callers, but it does unchecked raw `UInt32` loads.

**Fix:** add them to the target's `excludes` in `project.yml`, or move them out of the folder.

### SEC-08: Each ad skip sends two clicks

`content.js:337-338` calls `targetBtn.click()` and also dispatches its own click event.

**Fix:** keep only `click()`, and add a test asserting one click per skip.

## Pre-launch blockers

### SEC-09: Manifest isn't authenticated or validated

The panel rejected these items because it treats the HTTPS manifest as trusted. That trust is one personal GitHub account feeding rules to every user, so all of it is one work item.

**Fix:**
- **Signature:** Ed25519 over the exact bytes `ManifestJSONWriter` emits, published as `manifest.json.sig`, with two pinned public keys for rotation. Fetch the signature only on a 200 response, never on a 304.
- **Rollback:** reject a `manifestVersion` lower than the cached one, since a signature alone still allows replaying an old manifest. The field is a date string (`backend/docs/ManifestSpecification.md`), so confirm the comparison and how same-day republishes behave.
- **Filter IDs:** `entry.id` reaches file paths unchecked (`FilterStore.swift:89`, `:105`; `FilterDownloadClient.swift`). Validate against `^[a-z0-9][a-z0-9-]{0,63}$`.
- **Duplicate IDs:** `UpdatePlan.swift:35` and `UpdateCoordinator.swift:170` use `Dictionary(uniqueKeysWithValues:)`, which traps. Reject the whole manifest rather than keeping the first entry. First-wins hides publisher bugs and makes behaviour depend on entry order. This also closes the `filterLists` dedup gotcha.
- **Allowed hosts:** `FilterDownloadClient` fetches `entry.sourceURL` with no host check. Restrict it to the publishing host.
- **Size cap (most urgent pipeline item after SEC-01 and SEC-02):** `FilterDownloadClient` reads the whole response into memory with `session.data(for:)`, before any size check. Move the `HTTPSession` seam to a download task so the body streams to disk, and change `MockHTTPSession` with it. Cancel when `expectedContentLength` exceeds the cap, and also in the delegate's progress callback, because servers can omit or lie about the length. Verify with an Allocations trace during a 150K-rule update: peak memory should be about the same with or without the download in flight.

### SEC-10: `PublicSuffixList` widens allowlisted domains

`ADBLX/Filtering/Validation/PublicSuffixList.swift` uses a hand-curated suffix set, and anything missing falls back to the last two labels. `shop.example.co.kr` becomes `co.kr`, so one broken-site report can turn off blocking for every `.co.kr` site. The main Indian suffixes (`co.in`, `org.in`, `gov.in`, `ac.in` and others) are in the set, so India isn't the exposed market. Other common ones, such as `co.kr`, `co.id`, `com.cn` and `com.mx`, are not.

**Fix:** keep the full host when the registrable domain is uncertain. That closes the over-allowlisting in a few lines, at no memory cost.

**Nice-to-have, not a launch blocker:** bundle the full Public Suffix List in the main app only, parsed lazily once. It's about 250 KB on disk and 1–2 MB as a `Set` (review's estimate). The list is MPL-2.0, so credit it in `ADBLX/Features/Settings/FilterAttributionView.swift`.

### SEC-11: Web-extension rule payload needs an audit

If the extension could evaluate strings arriving from the network, a compromised manifest would mean code injection on every page for premium users, and a Guideline 2.5.2 problem.

**Checked so far (grep only):** `background.js` and `content.js` contain no `eval`, `new Function`, `executeScript` or script-element creation. Rules reach the page as CSS through `textContent` (`content.js:273`), and `WebExtensionRulePublisher` describes its input as "inert rule data".

**Still to confirm:** read `WebExtensionSchemaValidator` and the rules' source end to end, and check whether manifest data can reach these rules at all. Hostile CSS can still hide or restyle page content without running code.

Check the scriptlet path specifically, because a grep for `eval` won't catch it:
- Can a manifest rule name a scriptlet that isn't bundled?
- Can scriptlet arguments reach `innerHTML`, `setAttribute('on…')` or `style` in a way that executes?

## With the DNS track

These can't be reached in a release while DNS Protection stays off (see the open connectivity entry in `docs/gotchas.md`).

### SEC-12: No DNS over TCP; responses over 4096 bytes truncated

`DNSPacketParser` accepts only UDP (protocol 17), and the tunnel silently drops anything else. So a TC-bit retry over TCP to the tunnel's DNS address goes unanswered until the client times out. `DNSUpstreamSocket.swift:98` also cuts responses off at 4096 bytes with no TC handling.

**Check this first in the connectivity investigation,** alongside the pass-through test. It is a strong candidate for "DNS breaks apps and payments". The IPv4 `includedRoutes` is only the tunnel's DNS address, so the "routes capture everything" suspect looks unlikely for IPv4.

**Fix:** receive into a 65,535-byte buffer, and deliver the response whenever it fits the size the client advertised. Set TC only if it doesn't, and only once TCP is handled. DoH would remove the UDP size problem.

### SEC-13: Tunnel start check allows `.free`

`TunnelEntitlementGuard.swift:26` only calls `isExpired(at:)`, which is false when `validUntil` is nil, and non-entitled users are published as `{state: free, validUntil: nil}`. `handleEntitlementLoss` leaves the VPN configuration installed, so a lapsed user can connect it from Settings > VPN.

**Fix:**
- Add one `isEntitled(at:)` method to the record in `ADBLXShared`, and have the bridge and the tunnel both call it. Trial users are safe: the persisted state has only `free` and `premiumActive`, and the publisher maps `hasPremiumAccess` to `premiumActive`.
- Keep allowing a missing or unreadable file, for the first-start race.
- Call `removeFromPreferences()` on entitlement loss. Re-subscribers will see the VPN permission prompt again, which is an acceptable cost.
- Re-check in `wake()` and on each generation reload rather than on a timer, whose wakeups would count against NFR-02.

### SEC-14: Upstream DNS responses are easy to spoof

`DNSUpstreamForwarder.swift` counts transaction IDs up from 1, uses one long-lived unconnected socket, and matches replies on source IP, port and ID. It also lets an empty sender IP or port 0 through.

**Fix:**
- **Now:** random transaction IDs, and reject an empty sender IP or port 0.
- **Next:** put effort into DoH rather than a socket pool, because an on-path attacker can spoof plaintext UDP anyway. DoH also makes an encryption claim true and avoids UDP truncation.
- If question matching is added, compare names case-insensitively, or valid answers get dropped and lookups hang.

### SEC-15: Tunnel thread-safety gaps

`PacketTunnelProvider` counters change from both the packet-flow callback and the forwarder queue. `BSDUDPUpstreamSocket.close()` sets `fileDescriptor = -1` off its queue.

**Fix:** guard the counters with one lock or queue, close the socket on its own queue, and run the tunnel tests under Thread Sanitizer.

## Decide and record

### SEC-16: Clock set forward extends the trial

`TrialManager.swift:86` uses `max(date, lastObservedDate)`, so activating with a future clock keeps the trial alive for that long after the clock is set back.

**Decision:** blocked on the PD-01 trial decision. It may replace `TrialKeychainStore` entirely, so don't pick this up before then.

**Don't use the fix proposed in the first audit:**
- `AppTransaction.shared.signedDate` isn't the current time. It can be the install date, so clamping to it would hand a later legitimate user an expired trial. A fresh signature needs `AppTransaction.refresh()`, which may prompt for sign-in. Verify both against current Apple docs.
- Re-anchoring when the clock is earlier than `activatedAt` lets anyone reset a used-up trial by moving the clock back.

**If it is built:** use the TLS-protected `Date` header on the manifest response, which needs no extra request. If no trusted time is available at activation, mark the trial unverified and check it at the next successful fetch.

### SEC-17: macOS `entitlement.json` is user-editable

`SafariWebExtensionBridgeProcessor.swift:67` trusts a plain JSON file in the user's group container, so a Mac user can unlock Layer 3 on their own machine.

**Decision:** risk accepted. A user can patch the binary on their own Mac anyway. Verifying a raw JWS has no public API, so it would mean hand-validating the certificate chain. Calling `Transaction.currentEntitlements` from the extension is unverified.

**Conditions:** revisit if Mac becomes paid in its own right. The bypass does not carry over to iOS, where a non-jailbroken user can't write to the App Group.

### SEC-18: Web-extension rule checksum is never verified

`SafariWebExtensionBridgeProcessor.swift:131` passes `sha256Rules` through, and nothing checks it. Verifying it wouldn't protect anything: the rules and the checksum sit in the same App Group with the same writer, and `AtomicRuleWriter` already prevents partial writes.

**Decision:** drop the field from the bridge response and the JS together. Grep `content.js` for any use of it first, because removing it only from the Swift side breaks JS that reads it. Keep the manifest's per-filter SHA-256: downloads cross a real trust boundary, unlike the App Group read.

## Coverage

- **Scanned:** `Packages/ADBLXShared/Sources`; under `ADBLX/Filtering`, `DNS`, `WebExtension`, `Compilation`, `Validation`, `Storage`, `Deployment` (other `Filtering` folders only partly, in the first scan, which hit its usage limit); all extensions; `ADBLX/Features/Premium`, `Settings`, `BrokenSite`, `Sync`; and `backend/tools/Publisher`.
- **Never in a scan's scope:** `Features/Protection`, `Features/Home`, `Features/Onboarding`, the rest of `backend/`, and `.github/`.

## Closed or corrected

- **Temp-file leak:** the review raised this from `docs/Architecture/TargetTopology.md:228`. That note looks out of date: `UpdateCoordinator.swift:93` now calls `cleanupWorkspace()`. Confirm with a test that runs `run()` twice and asserts the workspace is empty, then update the doc.
- **Allowlist "storage-only":** no longer true. `FilterPipeline` compiles it through `SafariAllowlistCompiler`.
