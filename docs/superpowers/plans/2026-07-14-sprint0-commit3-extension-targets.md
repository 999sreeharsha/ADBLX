# Sprint 0 — Commit 3: Extension Targets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add all 6 placeholder extension targets to `project.yml` — 4 Content Blockers, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension` — building successfully with zero business logic beyond the real content-blocker request lifecycle, and zero capabilities/entitlements.

**Architecture:** Each extension target is `type: app-extension`, differentiated only by its `NSExtension` Info.plist dictionary, generated via XcodeGen's `info.properties` (no physical Info.plist hand-authored — confirmed XcodeGen writes it to `info.path` at generation time and auto-excludes it from synced-folder membership). Sources use `type: syncedFolder`, matching Commit 2's pattern for `ADBLX`/`ADBLXTests`/`ADBLXUITests`.

**Tech Stack:** XcodeGen 2.45.4, Xcode 26.6, Swift 5.0. `NSExtensionRequestHandling` (Content Blockers, Safari Web Extension), `NEPacketTunnelProvider` (PacketTunnel).

## Global Constraints

- No App Groups, no Network Extension entitlement, no Web Extension capabilities, no CI changes — Commit 4 scope entirely (per `docs/superpowers/specs/2026-07-14-sprint0-commit3-extension-targets-design.md`).
- No `SFContentBlockerManager.reloadContentBlocker()` calls, no tunnel start logic, no real bundled rule data — Commit 5 scope entirely.
- Content Blocker `beginRequest(with:)` must follow the real production request lifecycle (load `Resources/blockerList.json` from the extension bundle, wrap in `NSItemProvider`, `completeRequest`) — not a stub that returns no items.
- PacketTunnel implements only the SDK-required overrides, each completing immediately with no other work: no timers, no observers, no networking, no file I/O.
- Bundle IDs follow the existing pattern already established in `project.yml` by Commit 2: `com.ADBLX.<TargetName>` (e.g. `com.ADBLX.ADBLXAdsBlocker`) — not the future `com.sreeharsha.adblx.*` convention, which is a deferred future ADR.
- All 6 targets: `CODE_SIGN_STYLE: Automatic`, `supportedDestinations: [iOS, macOS, visionOS]` and deployment targets `"26.5"` matching the main app (platform narrowing is deferred to a future Platform Strategy ADR, not decided in this commit).
- No physical `Info.plist` files are hand-authored — only XcodeGen-generated ones via `info.properties`.

---

### Task 1: Content Blocker source files (all 4 targets)

**Files:**
- Create: `Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift`
- Create: `Extensions/ADBLXAdsBlocker/Resources/blockerList.json`
- Create: `Extensions/ADBLXPrivacyBlocker/ContentBlockerRequestHandler.swift`
- Create: `Extensions/ADBLXPrivacyBlocker/Resources/blockerList.json`
- Create: `Extensions/ADBLXAnnoyancesBlocker/ContentBlockerRequestHandler.swift`
- Create: `Extensions/ADBLXAnnoyancesBlocker/Resources/blockerList.json`
- Create: `Extensions/ADBLXRegionalBlocker/ContentBlockerRequestHandler.swift`
- Create: `Extensions/ADBLXRegionalBlocker/Resources/blockerList.json`

**Interfaces:**
- Consumes: nothing.
- Produces: `ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling` in each of the 4 targets — identical implementation, each compiled into its own target's module. Consumed by Task 2's `project.yml` target definitions via `NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler`.

- [ ] **Step 1: Write the identical `ContentBlockerRequestHandler.swift` into all 4 folders**

```swift
import Foundation

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let url = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
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
}
```

Write this exact content to:
- `Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift`
- `Extensions/ADBLXPrivacyBlocker/ContentBlockerRequestHandler.swift`
- `Extensions/ADBLXAnnoyancesBlocker/ContentBlockerRequestHandler.swift`
- `Extensions/ADBLXRegionalBlocker/ContentBlockerRequestHandler.swift`

- [ ] **Step 2: Write `[]` to all 4 `Resources/blockerList.json` files**

```json
[]
```

Write this exact content to:
- `Extensions/ADBLXAdsBlocker/Resources/blockerList.json`
- `Extensions/ADBLXPrivacyBlocker/Resources/blockerList.json`
- `Extensions/ADBLXAnnoyancesBlocker/Resources/blockerList.json`
- `Extensions/ADBLXRegionalBlocker/Resources/blockerList.json`

- [ ] **Step 3: Verify all 8 files exist**

```bash
/usr/bin/find Extensions/ADBLXAdsBlocker Extensions/ADBLXPrivacyBlocker Extensions/ADBLXAnnoyancesBlocker Extensions/ADBLXRegionalBlocker -type f | sort
```

Expected: 8 files listed, 2 per target (`ContentBlockerRequestHandler.swift`, `Resources/blockerList.json`).

---

### Task 2: Add the 4 Content Blocker targets to `project.yml`

**Files:**
- Modify: `project.yml`

**Interfaces:**
- Consumes: `Extensions/ADBLXAdsBlocker/`, `Extensions/ADBLXPrivacyBlocker/`, `Extensions/ADBLXAnnoyancesBlocker/`, `Extensions/ADBLXRegionalBlocker/` from Task 1.
- Produces: 4 new target definitions in `project.yml`, each generating `Extensions/<Name>/Info.plist` when `xcodegen generate` runs (Task 5).

- [ ] **Step 1: Append the 4 Content Blocker target definitions**

Add these 4 entries under the existing `targets:` key in `project.yml`, after `ADBLXUITests` (matching the existing file's 2-space indentation):

```yaml
  ADBLXAdsBlocker:
    type: app-extension
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: Extensions/ADBLXAdsBlocker
        type: syncedFolder
    info:
      path: Extensions/ADBLXAdsBlocker/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.Safari.content-blocker
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXAdsBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
  ADBLXPrivacyBlocker:
    type: app-extension
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: Extensions/ADBLXPrivacyBlocker
        type: syncedFolder
    info:
      path: Extensions/ADBLXPrivacyBlocker/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.Safari.content-blocker
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXPrivacyBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
  ADBLXAnnoyancesBlocker:
    type: app-extension
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: Extensions/ADBLXAnnoyancesBlocker
        type: syncedFolder
    info:
      path: Extensions/ADBLXAnnoyancesBlocker/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.Safari.content-blocker
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXAnnoyancesBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
  ADBLXRegionalBlocker:
    type: app-extension
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: Extensions/ADBLXRegionalBlocker
        type: syncedFolder
    info:
      path: Extensions/ADBLXRegionalBlocker/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.Safari.content-blocker
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXRegionalBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 2: Validate the YAML parses**

```bash
xcodegen dump --spec project.yml > /tmp/adblx-c3-dump-1.txt && echo "YAML valid"
```

Expected: `YAML valid` printed.

---

### Task 3: PacketTunnel source file and `project.yml` target

**Files:**
- Create: `Extensions/ADBLXPacketTunnel/PacketTunnelProvider.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PacketTunnelProvider: NEPacketTunnelProvider` and its `project.yml` target definition, generating `Extensions/ADBLXPacketTunnel/Info.plist` at generation time.

- [ ] **Step 1: Write `Extensions/ADBLXPacketTunnel/PacketTunnelProvider.swift`**

```swift
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(nil)
    }
}
```

- [ ] **Step 2: Append the `ADBLXPacketTunnel` target definition to `project.yml`**

Add after `ADBLXRegionalBlocker`:

```yaml
  ADBLXPacketTunnel:
    type: app-extension
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: Extensions/ADBLXPacketTunnel
        type: syncedFolder
    info:
      path: Extensions/ADBLXPacketTunnel/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.networkextension.packet-tunnel
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).PacketTunnelProvider
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXPacketTunnel
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 3: Verify the file exists and the YAML still parses**

```bash
cat Extensions/ADBLXPacketTunnel/PacketTunnelProvider.swift
xcodegen dump --spec project.yml > /tmp/adblx-c3-dump-2.txt && echo "YAML valid"
```

---

### Task 4: Safari Web Extension source files and `project.yml` target

**Files:**
- Create: `Extensions/ADBLXSafariWebExtension/SafariWebExtensionHandler.swift`
- Create: `Extensions/ADBLXSafariWebExtension/Resources/manifest.json`
- Create: `Extensions/ADBLXSafariWebExtension/Resources/background.js`
- Create: `Extensions/ADBLXSafariWebExtension/Resources/_locales/en/messages.json`
- Modify: `project.yml`

**Interfaces:**
- Consumes: nothing new.
- Produces: `SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling` and its `project.yml` target definition, generating `Extensions/ADBLXSafariWebExtension/Info.plist` at generation time.

- [ ] **Step 1: Write `Extensions/ADBLXSafariWebExtension/SafariWebExtensionHandler.swift`**

```swift
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["echo": message as Any]]

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
```

- [ ] **Step 2: Write `Extensions/ADBLXSafariWebExtension/Resources/manifest.json`**

```json
{
    "manifest_version": 2,
    "default_locale": "en",
    "name": "__MSG_extension_name__",
    "description": "__MSG_extension_description__",
    "version": "1.0",
    "background": {
        "scripts": ["background.js"],
        "persistent": false
    },
    "permissions": []
}
```

- [ ] **Step 3: Write `Extensions/ADBLXSafariWebExtension/Resources/background.js`**

```javascript
// Placeholder background script — no behavior implemented in Sprint 0 Commit 3.
// Real message handling lands in a later sprint once ADR-0003 (shared package) is approved.
```

- [ ] **Step 4: Write `Extensions/ADBLXSafariWebExtension/Resources/_locales/en/messages.json`**

```json
{
    "extension_name": {
        "message": "ADBLX Safari Web Extension",
        "description": "Display name shown in Safari's extension list."
    },
    "extension_description": {
        "message": "Placeholder description — functional implementation lands in a later sprint.",
        "description": "Description shown in Safari's extension list."
    }
}
```

- [ ] **Step 5: Append the `ADBLXSafariWebExtension` target definition to `project.yml`**

Add after `ADBLXPacketTunnel`:

```yaml
  ADBLXSafariWebExtension:
    type: app-extension
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: Extensions/ADBLXSafariWebExtension
        type: syncedFolder
    info:
      path: Extensions/ADBLXSafariWebExtension/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.Safari.web-extension
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).SafariWebExtensionHandler
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        OTHER_LDFLAGS: "-framework SafariServices"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXSafariWebExtension
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 6: Verify all 4 files exist and the YAML still parses**

```bash
/usr/bin/find Extensions/ADBLXSafariWebExtension -type f | sort
xcodegen dump --spec project.yml > /tmp/adblx-c3-dump-3.txt && echo "YAML valid"
```

Expected: 4 files listed (`SafariWebExtensionHandler.swift`, `Resources/manifest.json`, `Resources/background.js`, `Resources/_locales/en/messages.json`).

---

### Task 5: Generate the project and verify determinism

**Files:**
- Modify (generated): `ADBLX.xcodeproj/`
- Modify (generated): `Extensions/*/Info.plist` (6 new files, one per extension target)

**Interfaces:**
- Consumes: `project.yml` (Tasks 2–4), all extension source files (Tasks 1, 3, 4).
- Produces: the regenerated `ADBLX.xcodeproj` with all 7 targets, verified idempotent.

- [ ] **Step 1: Generate the project**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodegen generate
```

Expected: `Created project at /Users/sreeharshag/Work/ADBLX/ADBLX.xcodeproj`, exit code 0.

- [ ] **Step 2: Confirm the 6 Info.plist files were generated in the expected locations**

```bash
/usr/bin/find Extensions -iname "Info.plist" | sort
```

Expected:
```
Extensions/ADBLXAdsBlocker/Info.plist
Extensions/ADBLXAnnoyancesBlocker/Info.plist
Extensions/ADBLXPacketTunnel/Info.plist
Extensions/ADBLXPrivacyBlocker/Info.plist
Extensions/ADBLXRegionalBlocker/Info.plist
Extensions/ADBLXSafariWebExtension/Info.plist
```

- [ ] **Step 3: Record state, generate a second time, confirm no further changes**

```bash
git status --porcelain=v1 --untracked-files=all > /tmp/adblx-c3-gen1-status.txt
xcodegen generate
git status --porcelain=v1 --untracked-files=all > /tmp/adblx-c3-gen2-status.txt
diff /tmp/adblx-c3-gen1-status.txt /tmp/adblx-c3-gen2-status.txt
echo "diff exit=$?"
```

Expected: `diff exit=0` — deterministic generation.

---

### Task 6: Build verification for all 7 targets

**Files:**
- None created or modified — verification only.

**Interfaces:**
- Consumes: the regenerated `ADBLX.xcodeproj` from Task 5.
- Produces: pass/fail confirmation that every target compiles.

- [ ] **Step 1: Build each of the 6 new extension targets from the CLI**

```bash
cd /Users/sreeharshag/Work/ADBLX
for target in ADBLXAdsBlocker ADBLXPrivacyBlocker ADBLXAnnoyancesBlocker ADBLXRegionalBlocker ADBLXPacketTunnel ADBLXSafariWebExtension; do
  echo "=== Building $target ==="
  xcodebuild -project ADBLX.xcodeproj -target "$target" -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
done
```

Expected: `** BUILD SUCCEEDED **` for all 6 targets.

- [ ] **Step 2: Confirm the main `ADBLX` scheme still builds (regression check)**

```bash
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

---

### Task 7: Info.plist validation for all 6 extensions

**Files:**
- None created or modified — verification only.

**Interfaces:**
- Consumes: `Extensions/*/Info.plist` from Task 5.
- Produces: pass/fail confirmation of acceptance criterion 4 from the design spec.

- [ ] **Step 1: Lint every generated Info.plist**

```bash
cd /Users/sreeharshag/Work/ADBLX
for f in Extensions/ADBLXAdsBlocker/Info.plist Extensions/ADBLXPrivacyBlocker/Info.plist Extensions/ADBLXAnnoyancesBlocker/Info.plist Extensions/ADBLXRegionalBlocker/Info.plist Extensions/ADBLXPacketTunnel/Info.plist Extensions/ADBLXSafariWebExtension/Info.plist; do
  echo "=== $f ==="
  plutil -lint "$f"
done
```

Expected: `<path>: OK` for all 6 files.

- [ ] **Step 2: Verify the 4 Content Blockers' `NSExtension` contents**

```bash
for f in Extensions/ADBLXAdsBlocker/Info.plist Extensions/ADBLXPrivacyBlocker/Info.plist Extensions/ADBLXAnnoyancesBlocker/Info.plist Extensions/ADBLXRegionalBlocker/Info.plist; do
  echo "=== $f ==="
  plutil -extract NSExtension.NSExtensionPointIdentifier raw "$f"
  plutil -extract NSExtension.NSExtensionPrincipalClass raw "$f"
done
```

Expected, for each of the 4 files: `com.apple.Safari.content-blocker` then `$(PRODUCT_MODULE_NAME).ContentBlockerRequestHandler`.

- [ ] **Step 3: Verify `ADBLXPacketTunnel`'s `NSExtension` contents**

```bash
plutil -extract NSExtension.NSExtensionPointIdentifier raw Extensions/ADBLXPacketTunnel/Info.plist
plutil -extract NSExtension.NSExtensionPrincipalClass raw Extensions/ADBLXPacketTunnel/Info.plist
```

Expected: `com.apple.networkextension.packet-tunnel` then `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`.

- [ ] **Step 4: Verify `ADBLXSafariWebExtension`'s `NSExtension` contents**

```bash
plutil -extract NSExtension.NSExtensionPointIdentifier raw Extensions/ADBLXSafariWebExtension/Info.plist
plutil -extract NSExtension.NSExtensionPrincipalClass raw Extensions/ADBLXSafariWebExtension/Info.plist
```

Expected: `com.apple.Safari.web-extension` then `$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler`.

- [ ] **Step 5: Confirm no unexpected top-level keys beyond the standard generated set**

```bash
for f in Extensions/ADBLXAdsBlocker/Info.plist Extensions/ADBLXPrivacyBlocker/Info.plist Extensions/ADBLXAnnoyancesBlocker/Info.plist Extensions/ADBLXRegionalBlocker/Info.plist Extensions/ADBLXPacketTunnel/Info.plist Extensions/ADBLXSafariWebExtension/Info.plist; do
  echo "=== $f ==="
  plutil -p "$f" | grep -E '^\s*"[A-Za-z]+' | sed 's/=.*//' | sort
done
```

Expected, for every file: exactly `CFBundleDevelopmentRegion`, `CFBundleDisplayName` (only if set — otherwise absent, that's fine), `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleInfoDictionaryVersion`, `CFBundleName`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion`, `NSExtension`. No App Group, entitlement, or capability-related keys anywhere.

---

### Task 8: Manual Xcode verification, baseline timing, and commit

**Files:**
- None created — final verification and commit of everything from Tasks 1–5.

**Interfaces:**
- Consumes: all changes from Tasks 1–5.
- Produces: the `feat: add extension targets` commit on `dev`.

- [ ] **Step 1: Open the project in Xcode and verify manually**

```bash
open /Users/sreeharshag/Work/ADBLX/ADBLX.xcodeproj
```

In Xcode's project navigator, confirm: all 7 targets (`ADBLX` + 6 extensions) appear under the project; no red/missing file references; no yellow/orange folder icons; no build-setting warning badges on any target; no "Update to recommended settings" migration prompt; no capability/entitlement warning badges on any of the 6 new targets (there should be none configured yet, matching this commit's scope).

- [ ] **Step 2: Record an informal build-time baseline**

```bash
cd /Users/sreeharshag/Work/ADBLX
rm -rf ~/Library/Developer/Xcode/DerivedData/ADBLX-*
time xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5
```

Note the `real` time reported — this is an informal 7-target baseline (not a gate), for later comparison once `Performance/Baselines.md` is populated in Commit 5.

- [ ] **Step 3: Review the full diff scope**

```bash
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
```

Expected: changes limited to `project.yml` (modified), `ADBLX.xcodeproj/` (modified/regenerated), and new files under `Extensions/ADBLXAdsBlocker/`, `Extensions/ADBLXPrivacyBlocker/`, `Extensions/ADBLXAnnoyancesBlocker/`, `Extensions/ADBLXRegionalBlocker/`, `Extensions/ADBLXPacketTunnel/`, `Extensions/ADBLXSafariWebExtension/` (source files and generated `Info.plist` each). No changes under `ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`, `Config/`, `docs/`, `Performance/`, `Scripts/`, `.github/`, `Packages/`, `README.md`, or any dotfile.

- [ ] **Step 4: Stage and commit**

```bash
git add project.yml ADBLX.xcodeproj Extensions
git commit -m "feat: add extension targets"
```

- [ ] **Step 5: Confirm the commit landed cleanly**

```bash
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
git log -1 --stat
```

Expected: clean working tree (aside from pre-existing untracked `.claude/`); the log shows the `feat: add extension targets` commit with exactly the files from Step 4.

- [ ] **Step 6: Clean up temporary verification files**

```bash
rm -f /tmp/adblx-c3-dump-1.txt /tmp/adblx-c3-dump-2.txt /tmp/adblx-c3-dump-3.txt /tmp/adblx-c3-gen1-status.txt /tmp/adblx-c3-gen2-status.txt
```

---

## After This Plan

Commit 4 (`feat: configure app groups and target capabilities`) is next: App Groups entitlement wired to all 7 targets, bundle IDs/schemes/deployment targets finalized in `project.yml`, and GitHub Actions CI (build, test, lint/format, XcodeGen drift check, no-op rule-budget check). Per the parent Sprint 0 spec, this is a separate planning pass once Commit 3 is verified and merged.
