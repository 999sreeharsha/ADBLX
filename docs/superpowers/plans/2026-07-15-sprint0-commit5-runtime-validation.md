# Sprint 0 — Commit 5: Runtime Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the Commits 1–4 foundation works at runtime — App Group round-trip, Content Blocker reload, minimal observability — by migrating exactly one Content Blocker (`ADBLXAdsBlocker`) to read from the App Group with a bundle fallback, wiring an idempotent bootstrap-and-reload path, adding a minimal MetricKit receiver, and capturing a performance baseline.

**Architecture:** A new `ContentBlockerBootstrap` enum (app target) owns the "copy bundled rules into the App Group (idempotent, once), then request a reload (every launch, Sprint-0-only)" sequence, kept separate from `ADBLXApp` so startup doesn't accumulate logic. `ContentBlockerRequestHandler` (extension target) tries the App Group file first, falls back to its own bundled copy. Both targets get their own tiny `AppGroup` identifier constant (no shared package yet — still gated on unwritten ADR-0003). A new `os.Logger`-based logging convention (subsystem `com.ADBLX.ADBLX`, categories `Bootstrap`/`AppGroup`/`MetricKit`) is established fresh, since none exists in the codebase yet.

**Tech Stack:** Swift 5.0, `SafariServices` (`SFContentBlockerManager`), `MetricKit` (`MXMetricManagerSubscriber`), `os.Logger`, Swift Testing (`@Test`/`#expect`/`#require`).

## Global Constraints

- Only `ADBLXAdsBlocker` is migrated to read from the App Group. `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker` are untouched — still bundle `[]`.
- Bundled rules are 50–100 hand-authored, original synthetic rules (e.g. `adsN.example.com` / `trackerN.example.net` patterns) — never content copied from EasyList, AdGuard, OISD, HaGeZi, or any other real filter list, per `agent.md`'s licensing constraint.
- `ContentBlockerBootstrap.ensureInitialRulesInstalled()` is idempotent — checks whether `Rules/Ads.json` already exists in the App Group; only copies if absent. No manifest/version-comparison logic, no checksum comparison — both explicitly deferred to Sprint 1 per the design spec.
- `reloadIfNeeded()` calls `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)` on **every launch**, independent of whether the copy just happened — this is Sprint-0-only behavior (documented via a code comment), fixing a sequencing bug found in ABORT review: the original "only on first install" design guaranteed the one reload attempt fired before Safari had ever registered the extension, with no second trigger for when the user later enabled it. Sprint 1's manifest/version-comparison logic replaces this with "reload only when the manifest version changed."
- The App Group fallback in `ContentBlockerRequestHandler` (App Group first, bundle resource if missing) is permanent production behavior, not a Sprint-0-only shim.
- No new UI screens (no Settings screen). The bootstrap/reload sequence runs automatically on every launch, dispatched off the main actor.
- Logging uses `os.Logger`, subsystem `Bundle.main.bundleIdentifier` (`com.ADBLX.ADBLX`), categories `Bootstrap`, `AppGroup`, `MetricKit`. Every log line states what happened (e.g. "copied Ads.json to App Group", "reload succeeded", "reload failed: <error>") — errors are never swallowed.
- MetricKit: `MetricsSubscriber` only logs that a payload arrived (count, timestamp) — no parsing, no persistence, no upload.
- `AppGroup.swift` is duplicated into exactly 2 places (`ADBLX/`, `Extensions/ADBLXAdsBlocker/`) — still no `Packages/ADBLXShared` linkage, still no ADR-0003.
- No RuleCompiler, no manifest/CDN downloads, no background tasks, no StoreKit, no DNS filtering, no `ADBLXPacketTunnel` work.
- Manual Safari verification is a documented checklist, not an automated UI test — consistent with Commit 4's CI policy.

---

### Task 1: Bundled synthetic rules (app + extension copies)

**Files:**
- Modify: `Extensions/ADBLXAdsBlocker/Resources/blockerList.json`
- Create: `ADBLX/Resources/blockerList.json`

**Interfaces:**
- Consumes: nothing.
- Produces: an identical 70-rule Safari Content Blocker JSON array in two locations — the extension's own bundle (its permanent fallback copy) and the app's bundle (the source `ContentBlockerBootstrap` copies from). Both are needed because an app and its extension have separate bundles on disk; there is no way for the app to read a resource out of the extension's `.appex` bundle directly.

- [ ] **Step 1: Generate the synthetic rules file**

```bash
cd /Users/sreeharshag/Work/ADBLX
python3 -c "
import json
rules = []
for i in range(1, 41):
    rules.append({
        'trigger': {'url-filter': f'ads{i}\\\\.example\\\\.com'},
        'action': {'type': 'block'}
    })
for i in range(1, 31):
    rules.append({
        'trigger': {'url-filter': f'tracker{i}\\\\.example\\\\.net'},
        'action': {'type': 'block'}
    })
with open('/tmp/blockerList-synthetic.json', 'w') as f:
    json.dump(rules, f, indent=2)
print(len(rules), 'rules generated')
"
```

Expected: `70 rules generated`.

- [ ] **Step 2: Copy the generated file into both locations**

```bash
cd /Users/sreeharshag/Work/ADBLX
mkdir -p ADBLX/Resources
cp /tmp/blockerList-synthetic.json Extensions/ADBLXAdsBlocker/Resources/blockerList.json
cp /tmp/blockerList-synthetic.json ADBLX/Resources/blockerList.json
```

- [ ] **Step 3: Verify both files are valid JSON and identical**

```bash
plutil -lint Extensions/ADBLXAdsBlocker/Resources/blockerList.json
plutil -lint ADBLX/Resources/blockerList.json
diff Extensions/ADBLXAdsBlocker/Resources/blockerList.json ADBLX/Resources/blockerList.json
echo "diff exit=$?"
python3 -c "import json; print(len(json.load(open('ADBLX/Resources/blockerList.json'))), 'rules')"
```

Expected: both `OK`, `diff exit=0`, `70 rules`.

---

### Task 2: `AppGroup` identifier for the `ADBLXAdsBlocker` extension target

**Files:**
- Create: `Extensions/ADBLXAdsBlocker/AppGroup.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum AppGroup { static let identifier: String }` inside the `ADBLXAdsBlocker` module — a second copy of the same constant already in `ADBLX/AppGroup.swift` (different module, so it can't be imported across targets without `Packages/ADBLXShared`, which stays deferred).

- [ ] **Step 1: Write the file**

```swift
enum AppGroup {
    static let identifier = "group.com.ADBLX.shared"
}
```

Write this exact content to `Extensions/ADBLXAdsBlocker/AppGroup.swift`.

- [ ] **Step 2: Confirm it's picked up by the synced folder (no `project.yml` change needed)**

```bash
cd /Users/sreeharshag/Work/ADBLX
/usr/bin/find Extensions/ADBLXAdsBlocker -name "AppGroup.swift"
```

Expected: `Extensions/ADBLXAdsBlocker/AppGroup.swift` listed.

---

### Task 3: Migrate `ContentBlockerRequestHandler` to read from the App Group with bundle fallback

**Files:**
- Modify: `Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift`

**Interfaces:**
- Consumes: `AppGroup.identifier` from Task 2, `Rules/Ads.json` (written by `ContentBlockerBootstrap` in Task 4), the bundled `blockerList.json` from Task 1.
- Produces: `ContentBlockerRequestHandler.beginRequest(with:)` now resolves its rules URL from the App Group first, falling back to the bundle — this is the actual behavior Commit 5 exists to prove.

- [ ] **Step 1: Replace the file's contents**

```swift
import Foundation

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let url = Self.rulesURL() else {
            context.cancelRequest(withError: CocoaError(.fileNoSuchFile))
            return
        }

        guard let itemProvider = NSItemProvider(contentsOf: url) else {
            context.cancelRequest(withError: CocoaError(.fileReadCorruptFile))
            return
        }

        let item = NSExtensionItem()
        item.attachments = [itemProvider]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    private static func rulesURL() -> URL? {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            let appGroupURL = containerURL.appendingPathComponent("Rules/Ads.json")
            if FileManager.default.fileExists(atPath: appGroupURL.path) {
                return appGroupURL
            }
        }
        return Bundle.main.url(forResource: "blockerList", withExtension: "json")
    }
}
```

- [ ] **Step 2: Build the `ADBLXAdsBlocker` target to confirm it compiles**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -target ADBLXAdsBlocker -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 4: `ContentBlockerBootstrap.ensureInitialRulesInstalled()` (TDD)

**Files:**
- Create: `ADBLX/ContentBlockerBootstrap.swift`
- Test: `ADBLXTests/ContentBlockerBootstrapTests.swift`

**Interfaces:**
- Consumes: `AppGroup.identifier` (`ADBLX/AppGroup.swift`, from Commit 4), the bundled `blockerList.json` from Task 1.
- Produces: `ContentBlockerBootstrap.ensureInitialRulesInstalled() -> Bool` — `true` if it just installed the rules, `false` if they already existed (or installation failed). Consumed by Task 5's `reloadIfNeeded()`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("first call installs rules, second call is a no-op")
    func idempotentInstall() throws {
        let containerURL = try #require(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
        )
        let rulesURL = containerURL.appendingPathComponent("Rules/Ads.json")
        try? FileManager.default.removeItem(at: rulesURL)

        let firstResult = ContentBlockerBootstrap.ensureInitialRulesInstalled()
        #expect(firstResult == true)
        #expect(FileManager.default.fileExists(atPath: rulesURL.path))

        let secondResult = ContentBlockerBootstrap.ensureInitialRulesInstalled()
        #expect(secondResult == false)

        try? FileManager.default.removeItem(at: rulesURL)
    }
}
```

Write this to `ADBLXTests/ContentBlockerBootstrapTests.swift`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ContentBlockerBootstrapTests test 2>&1 | tail -15
```

Expected: build failure — `cannot find 'ContentBlockerBootstrap' in scope`.

- [ ] **Step 3: Write `ADBLX/ContentBlockerBootstrap.swift`**

```swift
import Foundation
import SafariServices
import OSLog

enum ContentBlockerBootstrap {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "Bootstrap"
    )

    private static let contentBlockerIdentifier = "com.ADBLX.ADBLXAdsBlocker"

    @discardableResult
    static func ensureInitialRulesInstalled() -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else {
            logger.error("Could not resolve App Group container")
            return false
        }

        let rulesDirectory = containerURL.appendingPathComponent("Rules", isDirectory: true)
        let destinationURL = rulesDirectory.appendingPathComponent("Ads.json")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return false
        }

        guard let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
            logger.error("Bundled blockerList.json not found")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: bundledURL)
            let temporaryURL = rulesDirectory.appendingPathComponent("Ads.json.tmp")
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            logger.info("Copied Ads.json to App Group")
            return true
        } catch {
            logger.error("Failed to copy Ads.json to App Group: \(error, privacy: .public)")
            return false
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ContentBlockerBootstrapTests test 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`.

---

### Task 5: `ContentBlockerBootstrap.reloadIfNeeded()` and `SFContentBlockerManager` wiring

**Files:**
- Modify: `ADBLX/ContentBlockerBootstrap.swift`
- Modify: `project.yml` (add `OTHER_LDFLAGS` to the `ADBLX` target, matching the precedent already set for `ADBLXSafariWebExtension` in Commit 3)

**Interfaces:**
- Consumes: `ensureInitialRulesInstalled()` from Task 4.
- Produces: `ContentBlockerBootstrap.reloadIfNeeded()` — consumed by Task 7's `ADBLXApp` wiring.

- [ ] **Step 1: Add `reloadIfNeeded()` to `ADBLX/ContentBlockerBootstrap.swift`**

Add this function inside the `ContentBlockerBootstrap` enum, after `ensureInitialRulesInstalled()`:

```swift
    // Sprint-0-only behavior: reload is requested on every launch, not just first install.
    // Apple exposes no "extension was just enabled in Safari" callback, and the one
    // guaranteed first-install reload fires before the user has ever enabled the
    // extension — so it's guaranteed to be a no-op/failure on a fresh install with no
    // second trigger. Launch is the only observable event available before Sprint 1's
    // manifest/version-comparison logic exists; that logic replaces this with
    // "reload only when the manifest version changed."
    static func reloadIfNeeded() {
        ensureInitialRulesInstalled()

        SFContentBlockerManager.reloadContentBlocker(withIdentifier: contentBlockerIdentifier) { error in
            if let error {
                logger.error("Reload failed: \(error, privacy: .public)")
            } else {
                logger.info("Reload succeeded")
            }
        }
    }
```

- [ ] **Step 2: Add `OTHER_LDFLAGS` to the `ADBLX` target in `project.yml`**

Find this line inside the `ADBLX:` target's `settings.base` block:
```yaml
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLX
```
Replace with:
```yaml
        MARKETING_VERSION: "1.0"
        OTHER_LDFLAGS: "-framework SafariServices"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLX
```

- [ ] **Step 3: Regenerate and build**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodegen generate
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 6: `MetricsSubscriber`

**Files:**
- Create: `ADBLX/MetricsSubscriber.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber` — instantiated and registered by Task 7's `ADBLXApp`.

- [ ] **Step 1: Write the file**

```swift
import Foundation
import MetricKit
import OSLog

final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "MetricKit"
    )

    func didReceive(_ payloads: [MXMetricPayload]) {
        logger.info("Received \(payloads.count) MetricKit payload(s)")
    }
}
```

Write this to `ADBLX/MetricsSubscriber.swift`.

- [ ] **Step 2: Build to confirm it compiles**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 7: Wire `ADBLXApp` — register `MetricsSubscriber`, trigger `reloadIfNeeded()` off the main actor

**Files:**
- Modify: `ADBLX/ADBLXApp.swift`

**Interfaces:**
- Consumes: `MetricsSubscriber` (Task 6), `ContentBlockerBootstrap.reloadIfNeeded()` (Task 5).
- Produces: the app's launch sequence — registers the MetricKit subscriber and kicks off the bootstrap/reload sequence exactly once per launch, off the main actor.

- [ ] **Step 1: Replace `ADBLX/ADBLXApp.swift`**

```swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    Task.detached(priority: .utility) {
                        ContentBlockerBootstrap.reloadIfNeeded()
                    }
                }
        }
    }
}
```

- [ ] **Step 2: Build and run in the simulator**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Boot the simulator, install, and launch the app to exercise the real bootstrap path**

```bash
cd /Users/sreeharshag/Work/ADBLX
UDID=$(python3 -c '
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"].startswith("iPhone"):
            print(d["udid"])
            sys.exit(0)
')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$UDID" -derivedDataPath /tmp/adblx-c5-build build 2>&1 | tail -5
xcrun simctl install "$UDID" /tmp/adblx-c5-build/Build/Products/Debug-iphonesimulator/ADBLX.app
xcrun simctl launch "$UDID" com.ADBLX.ADBLX
sleep 3
xcrun simctl get_app_container "$UDID" com.ADBLX.ADBLX groups 2>/dev/null
```

Note the printed App Group container path for the next step.

- [ ] **Step 4: Confirm `Rules/Ads.json` was written into the App Group container**

```bash
UDID=$(python3 -c '
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"].startswith("iPhone"):
            print(d["udid"])
            sys.exit(0)
')
GROUP_CONTAINER=$(xcrun simctl get_app_container "$UDID" com.ADBLX.ADBLX groups)
plutil -lint "$GROUP_CONTAINER/Rules/Ads.json"
python3 -c "import json; print(len(json.load(open('$GROUP_CONTAINER/Rules/Ads.json'))), 'rules in App Group')"
diff "$GROUP_CONTAINER/Rules/Ads.json" ADBLX/Resources/blockerList.json
echo "diff exit=$?"
```

Expected: `OK`, `70 rules in App Group`, `diff exit=0` (the App Group copy matches the bundled source exactly).

---

### Task 8: Performance baseline

**Files:**
- Create: `Performance/Baselines.md`

**Interfaces:**
- Consumes: manual Instruments captures, the build-time measurement from this task.
- Produces: a dated baseline document.

- [ ] **Step 1: Capture the 7-target build-time baseline**

```bash
cd /Users/sreeharshag/Work/ADBLX
rm -rf ~/Library/Developer/Xcode/DerivedData/ADBLX-*
time xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Note the `real` time reported.

- [ ] **Step 2: Capture cold launch time using Instruments (manual)**

In Xcode: Product → Profile (⌘I) → Time Profiler → select the `ADBLX` scheme and an iOS Simulator destination → Record → note the time from process launch to first frame rendered in the trace. Stop recording.

- [ ] **Step 3: Capture `ADBLXAdsBlocker` memory footprint using Instruments (manual)**

In Xcode: Product → Profile (⌘I) → Allocations → attach to the running `ADBLXAdsBlocker` extension process (trigger it via Safari, per Task 9's checklist) → note peak "All Heap & Anonymous VM" memory.

- [ ] **Step 4: Write `Performance/Baselines.md`**

```markdown
# Performance Baselines

Tracked performance baselines for ADBLX, established in Sprint 0 Commit 5. Update in place as the app grows — each entry should be dated so regressions are visible over time.

## Build time (7 targets: `ADBLX` + 6 extensions)

| Date | Real time | Notes |
|---|---|---|
| <DATE> | <REAL_TIME> | Clean build, DerivedData wiped, `generic/platform=iOS Simulator`, Xcode 26.6, Sprint 0 Commit 5 baseline. |

## Cold launch (Time Profiler)

| Date | Time to first frame | Notes |
|---|---|---|
| <DATE> | <TIME> | Simulator, Debug configuration, includes `ContentBlockerBootstrap.reloadIfNeeded()` dispatched off the main actor. |

## `ADBLXAdsBlocker` memory (Allocations)

| Date | Peak memory | Budget | Notes |
|---|---|---|---|
| <DATE> | <PEAK_MEMORY> | ~6MB (per `agent.md`'s Content Blocker hard constraint) | 70 synthetic rules loaded from the App Group container. |

## Methodology

- Build time: `time xcodebuild ... build` after wiping `~/Library/Developer/Xcode/DerivedData/ADBLX-*`.
- Cold launch / memory: Xcode → Product → Profile → Time Profiler / Allocations, manual capture — no automated performance test exists yet.
```

Fill in `<DATE>`, `<REAL_TIME>`, `<TIME>`, `<PEAK_MEMORY>` with the values captured in Steps 1–3.

---

### Task 9: Manual Safari verification checklist

**Files:**
- Create: `docs/Architecture/ManualVerification.md`

**Interfaces:**
- Consumes: the running app and `ADBLXAdsBlocker` from Tasks 1–7.
- Produces: a documented, repeatable manual checklist (not automated — consistent with Commit 4's CI policy).

- [ ] **Step 1: Write `docs/Architecture/ManualVerification.md`**

```markdown
# Manual Verification

Manual checklists for behavior that isn't automated in CI — either because it requires Safari/extension registration (not scriptable in CI) or because automating it now would cost more than it proves at this stage of the project. Update in place as new manual-only surfaces appear.

## `ADBLXAdsBlocker` Content Blocker pipeline (Sprint 0 Commit 5)

Verifies each stage of the App Group → Content Blocker → Safari pipeline independently, not just the end result.

1. Install the app (fresh install, or after clearing the App Group container — see Task 4's test for how to locate/clear `Rules/Ads.json`).
2. Launch the app — this copies rules into the App Group and requests a reload. **Expected at this point:** the reload request may fail or no-op, because Safari doesn't know about the extension yet — that's expected, not a bug (see Task 5's code comment).
3. Confirm `Rules/Ads.json` appears in the App Group container on disk (`xcrun simctl get_app_container <UDID> com.ADBLX.ADBLX groups`, then check `Rules/Ads.json` exists inside that path).
4. Enable `ADBLXAdsBlocker` in Safari → Settings → Extensions (on device or simulator).
5. Relaunch the app — the file copy is now a no-op (idempotent), but the reload request fires again, and this time Safari has the extension registered.
6. Confirm the `Bootstrap`-category log line from this second launch reports the reload succeeded (Console.app, filter by subsystem `com.ADBLX.ADBLX`, category `Bootstrap`).
7. Visit a page that issues a request matching one of the synthetic rules (e.g. a test page that loads `https://ads1.example.com/...`).
8. Confirm the matching request is blocked (Safari's Page Information → "X trackers blocked" or equivalent, or a network inspector showing the request never completing).

Every step has a deterministic cause — no step relies on hoping an earlier reload happened to land at the right time.

## Fallback verification

9. With the App Group's `Rules/Ads.json` deliberately removed (see Task 4's test for the removal command), confirm `ADBLXAdsBlocker` still produces valid output by falling back to its bundled `Resources/blockerList.json` — re-run steps 4–8 and confirm blocking still works.

## Last verified

| Date | Result | Notes |
|---|---|---|
| <DATE> | <PASS/FAIL> | <NOTES> |
```

- [ ] **Step 2: Walk through the checklist once and record the result**

Follow steps 1–8 above manually. Fill in the "Last verified" row with today's date, the result, and any notes.

---

### Task 10: Update `TargetTopology.md`, `agent.md`, review scope, and commit

**Files:**
- Modify: `docs/Architecture/TargetTopology.md`
- Modify: `agent.md`

**Interfaces:**
- Consumes: all changes from Tasks 1–9.
- Produces: the `feat: validate app group and content blocker reload pipeline` commit on `dev`, closing out Sprint 0.

- [ ] **Step 1: Update `TargetTopology.md`'s status line and App Groups section**

Change:
```markdown
**Status:** current as of Sprint 0 Commit 4. Living document — update in place as targets, build settings, or capabilities change. For the "why" behind these decisions, see the linked specs; this document covers only the "how it currently works."
```
to:
```markdown
**Status:** current as of Sprint 0 Commit 5 (Sprint 0 complete). Living document — update in place as targets, build settings, or capabilities change. For the "why" behind these decisions, see the linked specs; this document covers only the "how it currently works."
```

Then find this line in the "## App Groups" section:
```markdown
`AppGroup.swift` (`ADBLX/AppGroup.swift`) exposes the identifier as `AppGroup.identifier`. It lives only in the app target — no `Packages/ADBLXShared` linkage yet (still gated on unwritten ADR-0003); revisit when a real cross-target need arises.
```
Replace with:
```markdown
`AppGroup.swift` exposes the identifier as `AppGroup.identifier`, duplicated in exactly 2 places: `ADBLX/AppGroup.swift` (app target) and `Extensions/ADBLXAdsBlocker/AppGroup.swift` (the one extension migrated to read from the App Group in Commit 5). No `Packages/ADBLXShared` linkage yet (still gated on unwritten ADR-0003); revisit if a third target needs it.

`ADBLXAdsBlocker` is the only Content Blocker reading from the App Group (`Rules/Ads.json`, with a permanent bundle-resource fallback) — see `ContentBlockerRequestHandler.swift`. `ADBLXPrivacyBlocker`/`ADBLXAnnoyancesBlocker`/`ADBLXRegionalBlocker` still bundle `[]` and are unmigrated; replicating the pattern to them is future work.

`ContentBlockerBootstrap` (`ADBLX/ContentBlockerBootstrap.swift`) runs on every launch, dispatched off the main actor from `ADBLXApp`. Its rule copy is idempotent (checks whether `Rules/Ads.json` already exists before copying), but it calls `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)` unconditionally on every launch — a **Sprint-0-only** stand-in (documented via a code comment) for the missing "extension was just enabled in Safari" signal Apple doesn't expose; Sprint 1's manifest/version-comparison logic replaces this with reload-only-on-change. Logging uses `os.Logger`, subsystem `com.ADBLX.ADBLX`, categories `Bootstrap`/`AppGroup`/`MetricKit`.
```

- [ ] **Step 2: Update `agent.md`'s "Current repo state" section**

Replace:
```markdown
## Current repo state
Sprint 0 (repository bootstrap) is in progress on `dev`, Commits 1–4 of 5 complete:
- **Commit 1** — repo scaffolding (`Config/`, `docs/ADR/`, `docs/Architecture/`, lint/format config).
- **Commit 2** — migrated the hand-authored `ADBLX.xcodeproj` to XcodeGen (`project.yml` is now the source of truth; see [`README.md`](README.md)).
- **Commit 3** — added all 6 extension targets (4 Content Blockers, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension`) as placeholders — they build, but have no capabilities and no runtime behavior yet.
- **Commit 4** — added the `group.com.ADBLX.shared` App Group entitlement to 6 targets (`ADBLXPacketTunnel` deferred — Personal Team can't provision its Network Extension entitlement) and a GitHub Actions CI workflow (generate/drift-check/build/`ADBLXTests`).

Full current target topology, folder layout, and what's deliberately not implemented yet: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md).

Remaining Sprint 0 work: Commit 5 (functional verification — App Group round-trip, real bundled rule snapshot, `reloadContentBlocker()`, MetricKit, performance baselines).
```
with:
```markdown
## Current repo state
Sprint 0 (repository bootstrap) is **complete** on `dev`, all 5 commits landed:
- **Commit 1** — repo scaffolding (`Config/`, `docs/ADR/`, `docs/Architecture/`, lint/format config).
- **Commit 2** — migrated the hand-authored `ADBLX.xcodeproj` to XcodeGen (`project.yml` is now the source of truth; see [`README.md`](README.md)).
- **Commit 3** — added all 6 extension targets (4 Content Blockers, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension`) as placeholders — they build, but have no capabilities and no runtime behavior yet.
- **Commit 4** — added the `group.com.ADBLX.shared` App Group entitlement to 6 targets (`ADBLXPacketTunnel` deferred — Personal Team can't provision its Network Extension entitlement) and a GitHub Actions CI workflow (generate/drift-check/build/`ADBLXTests`).
- **Commit 5** — validated the runtime pipeline: `ADBLXAdsBlocker` reads 70 synthetic rules from the App Group (with permanent bundle fallback), `ContentBlockerBootstrap` installs and reloads once per install, minimal MetricKit receiver, `Performance/Baselines.md` and `docs/Architecture/ManualVerification.md` established.

Full current target topology, folder layout, and what's deliberately not implemented yet: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md).

Sprint 0 is done. The next major milestone is the RuleCompiler and filter update pipeline (Sprint 1), not further project scaffolding.
```

- [ ] **Step 3: Review the full diff scope**

```bash
cd /Users/sreeharshag/Work/ADBLX
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
```

Expected: changes limited to `Extensions/ADBLXAdsBlocker/Resources/blockerList.json` (modified), `Extensions/ADBLXAdsBlocker/AppGroup.swift` (new), `Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift` (modified), `ADBLX/Resources/blockerList.json` (new), `ADBLX/ContentBlockerBootstrap.swift` (new), `ADBLX/MetricsSubscriber.swift` (new), `ADBLX/ADBLXApp.swift` (modified), `ADBLXTests/ContentBlockerBootstrapTests.swift` (new), `project.yml` (modified), `ADBLX.xcodeproj/` (modified/regenerated), `Performance/Baselines.md` (new), `docs/Architecture/ManualVerification.md` (new), `docs/Architecture/TargetTopology.md` (modified), `agent.md` (modified). No changes under `ADBLXUITests/`, `Config/`, `Scripts/`, `Packages/`, `.github/`, `Extensions/ADBLXPacketTunnel/`, `Extensions/ADBLXPrivacyBlocker/`, `Extensions/ADBLXAnnoyancesBlocker/`, `Extensions/ADBLXRegionalBlocker/`, `Extensions/ADBLXSafariWebExtension/`, or `README.md`.

- [ ] **Step 4: Run the full unit test suite one more time**

```bash
cd /Users/sreeharshag/Work/ADBLX
UDID=$(python3 -c '
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"].startswith("iPhone"):
            print(d["udid"])
            sys.exit(0)
')
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$UDID" -only-testing:ADBLXTests test 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Stage and commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add Extensions/ADBLXAdsBlocker ADBLX/Resources/blockerList.json ADBLX/ContentBlockerBootstrap.swift ADBLX/MetricsSubscriber.swift ADBLX/ADBLXApp.swift ADBLXTests/ContentBlockerBootstrapTests.swift project.yml ADBLX.xcodeproj Performance/Baselines.md docs/Architecture/ManualVerification.md docs/Architecture/TargetTopology.md agent.md
git commit -m "feat: validate app group and content blocker reload pipeline"
```

- [ ] **Step 6: Confirm the commit landed cleanly**

```bash
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
git log -1 --stat
```

Expected: clean working tree (aside from pre-existing untracked `.claude/`); the log shows the `feat: validate app group and content blocker reload pipeline` commit with exactly the files from Step 5.

- [ ] **Step 7: Push and confirm CI passes**

```bash
git push origin dev
```

Check the Actions tab (or `gh run watch`) to confirm the `CI` workflow passes on the new commit.

- [ ] **Step 8: Clean up temporary files**

```bash
rm -f /tmp/blockerList-synthetic.json
rm -rf /tmp/adblx-c5-build
```

---

## After This Plan

Sprint 0 is complete. The next major milestone is Sprint 1: the RuleCompiler and filter update pipeline (ADR-0001), which will define how real filter lists (with their licensing/attribution requirements) are fetched, compiled, and distributed to all 4 Content Blockers — a substantially larger effort than any single Sprint 0 commit, and the first point where `Packages/ADBLXShared`/ADR-0003 is likely to become genuinely necessary.
