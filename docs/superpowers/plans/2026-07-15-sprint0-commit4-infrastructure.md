# Sprint 0 — Commit 4: Infrastructure (App Groups + CI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `group.com.ADBLX.shared` App Group entitlement to the 6 supported targets, document the shared container contract, add a single-file `AppGroup` Swift constant to the app target, and stand up a GitHub Actions CI workflow that generates/builds/tests the project on every push to `dev`/`main`.

**Architecture:** App Group entitlements are declared per-target in `project.yml` via XcodeGen's `entitlements:` key (same generated-artifact pattern Commit 3 established for `info:`/Info.plist — no hand-authored `.entitlements` files). CI is a single-job GitHub Actions workflow that mirrors the local verification loop: install XcodeGen, regenerate, diff-check for drift, build, test.

**Tech Stack:** XcodeGen 2.45.4, Xcode 26.6 (local) / Xcode 26.3 via `maxim-lobanov/setup-xcode@v1` (CI), Swift 5.0, GitHub Actions (`macos-15` runner).

## Global Constraints

- App Group identifier: `group.com.ADBLX.shared` — matches the `com.ADBLX.*` bundle ID namespace, not `com.sreeharsha.adblx` (per `docs/superpowers/specs/2026-07-15-sprint0-commit4-infrastructure-design.md`).
- App Group entitlement goes on exactly 6 targets: `ADBLX`, `ADBLXAdsBlocker`, `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker`, `ADBLXSafariWebExtension`. **Never** `ADBLXPacketTunnel`, `ADBLXTests`, or `ADBLXUITests`.
- `ADBLXPacketTunnel` must remain byte-for-byte unmodified in `project.yml` and get no entitlements file — Personal Team cannot provision the Network Extension entitlement it would eventually need, and a partial App Group would misrepresent its provisioning state.
- No App Group read/write code — the `AppGroup` enum only exposes the identifier string. No file I/O, no `FileManager` container lookups implemented yet (Commit 5 scope).
- `AppGroup.swift` lives only in `ADBLX/` (the app target's synced source folder) — no `Packages/ADBLXShared` linkage, no duplication into extension targets.
- No physical `.entitlements` files are hand-authored — only XcodeGen-generated ones via `entitlements.properties`, mirroring Commit 3's `Info.plist` rule.
- CI: triggers on `push`/`pull_request` to `dev`+`main` plus `workflow_dispatch`, with a `concurrency` cancel-in-progress group. Runner `macos-15`, Xcode selected via `xcode-version: latest-stable` (no hardcoded Xcode path). Steps gate sequentially — generate must succeed before the drift check, drift check is a hard failure before build, build must succeed before tests. Only `ADBLXTests` runs in CI; `ADBLXUITests` is explicitly skipped (documented reason: no UI worth testing yet, not flakiness).
- No CI caching, no build artifacts, no release automation.

---

### Task 1: Add App Group entitlements to `project.yml`

**Files:**
- Modify: `project.yml:8-52` (`ADBLX` target)
- Modify: `project.yml:112-138` (`ADBLXAdsBlocker` target)
- Modify: `project.yml:139-165` (`ADBLXPrivacyBlocker` target)
- Modify: `project.yml:166-192` (`ADBLXAnnoyancesBlocker` target)
- Modify: `project.yml:193-219` (`ADBLXRegionalBlocker` target)
- Modify: `project.yml:247-274` (`ADBLXSafariWebExtension` target)

**Interfaces:**
- Consumes: nothing.
- Produces: 6 `entitlements:` blocks in `project.yml` that, on `xcodegen generate` (Task 2), each write a `.entitlements` file to disk and wire `CODE_SIGN_ENTITLEMENTS` for that target.

Line numbers below are from the `project.yml` as it stood after Commit 3 (`da17133`). If the file has drifted, locate each target by its `PRODUCT_BUNDLE_IDENTIFIER` instead.

- [ ] **Step 1: Replace the `ADBLX` target block (lines 8-52)**

Old block starts with `  ADBLX:` and ends with `        XROS_DEPLOYMENT_TARGET: "26.5"` (the line right before `  ADBLXTests:`). Insert an `entitlements:` key between `sources:` and `settings:`:

```yaml
  ADBLX:
    type: application
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: ADBLX
        type: syncedFolder
    entitlements:
      path: ADBLX/ADBLX.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.ADBLX.shared
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        ENABLE_APP_SANDBOX: YES
        ENABLE_PREVIEWS: YES
        ENABLE_USER_SELECTED_FILES: readonly
        GENERATE_INFOPLIST_FILE: YES
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphoneos*]": YES
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphonesimulator*]": YES
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphoneos*]": YES
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphonesimulator*]": YES
        "INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphoneos*]": YES
        "INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]": YES
        "INFOPLIST_KEY_UIStatusBarStyle[sdk=iphoneos*]": UIStatusBarStyleDefault
        "INFOPLIST_KEY_UIStatusBarStyle[sdk=iphonesimulator*]": UIStatusBarStyleDefault
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/Frameworks"
        "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": "@executable_path/../Frameworks"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLX
        PRODUCT_NAME: "$(TARGET_NAME)"
        REGISTER_APP_GROUPS: YES
        SDKROOT: auto
        STRING_CATALOG_GENERATE_SYMBOLS: YES
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
        SWIFT_EMIT_LOC_STRINGS: YES
        SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY: YES
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

(`REGISTER_APP_GROUPS: YES` was already present — unchanged. Only the `entitlements:` block is new.)

- [ ] **Step 2: Replace the `ADBLXAdsBlocker` target block (lines 112-138)**

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
    entitlements:
      path: Extensions/ADBLXAdsBlocker/ADBLXAdsBlocker.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.ADBLX.shared
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXAdsBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        REGISTER_APP_GROUPS: YES
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 3: Replace the `ADBLXPrivacyBlocker` target block (lines 139-165)**

```yaml
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
    entitlements:
      path: Extensions/ADBLXPrivacyBlocker/ADBLXPrivacyBlocker.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.ADBLX.shared
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXPrivacyBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        REGISTER_APP_GROUPS: YES
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 4: Replace the `ADBLXAnnoyancesBlocker` target block (lines 166-192)**

```yaml
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
    entitlements:
      path: Extensions/ADBLXAnnoyancesBlocker/ADBLXAnnoyancesBlocker.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.ADBLX.shared
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXAnnoyancesBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        REGISTER_APP_GROUPS: YES
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 5: Replace the `ADBLXRegionalBlocker` target block (lines 193-219)**

```yaml
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
    entitlements:
      path: Extensions/ADBLXRegionalBlocker/ADBLXRegionalBlocker.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.ADBLX.shared
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: "1"
        IPHONEOS_DEPLOYMENT_TARGET: "26.5"
        MACOSX_DEPLOYMENT_TARGET: "26.5"
        MARKETING_VERSION: "1.0"
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXRegionalBlocker
        PRODUCT_NAME: "$(TARGET_NAME)"
        REGISTER_APP_GROUPS: YES
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 6: Replace the `ADBLXSafariWebExtension` target block (lines 247-274)**

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
    entitlements:
      path: Extensions/ADBLXSafariWebExtension/ADBLXSafariWebExtension.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.ADBLX.shared
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
        REGISTER_APP_GROUPS: YES
        SDKROOT: auto
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_VERSION: "5.0"
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: "26.5"
```

- [ ] **Step 7: Confirm `ADBLXPacketTunnel` (lines 220-246) is untouched and the YAML parses**

```bash
cd /Users/sreeharshag/Work/ADBLX
grep -A5 "^  ADBLXPacketTunnel:" project.yml | grep -c entitlements
xcodegen dump --spec project.yml > /tmp/adblx-c4-dump-1.txt && echo "YAML valid"
```

Expected: `0` (no `entitlements` key anywhere near `ADBLXPacketTunnel`), then `YAML valid`.

---

### Task 2: Generate the project and verify entitlements + determinism

**Files:**
- Modify (generated): `ADBLX.xcodeproj/`
- Create (generated): `ADBLX/ADBLX.entitlements`
- Create (generated): `Extensions/ADBLXAdsBlocker/ADBLXAdsBlocker.entitlements`
- Create (generated): `Extensions/ADBLXPrivacyBlocker/ADBLXPrivacyBlocker.entitlements`
- Create (generated): `Extensions/ADBLXAnnoyancesBlocker/ADBLXAnnoyancesBlocker.entitlements`
- Create (generated): `Extensions/ADBLXRegionalBlocker/ADBLXRegionalBlocker.entitlements`
- Create (generated): `Extensions/ADBLXSafariWebExtension/ADBLXSafariWebExtension.entitlements`

**Interfaces:**
- Consumes: `project.yml` from Task 1.
- Produces: the regenerated `ADBLX.xcodeproj` and 6 `.entitlements` files, verified idempotent.

Note: the working tree may already show `ADBLX.xcodeproj/project.pbxproj` as locally modified (from opening the project in Xcode, which adds a machine-local `DEVELOPMENT_TEAM` and reformats some fields). That drift is expected to be fully superseded by this task's regeneration — `DEVELOPMENT_TEAM` is deliberately not set in `project.yml` (it's personal-account-specific, not shared state), so it will not reappear after `xcodegen generate`.

- [ ] **Step 1: Generate the project**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodegen generate
```

Expected: `Created project at /Users/sreeharshag/Work/ADBLX/ADBLX.xcodeproj`, exit code 0.

- [ ] **Step 2: Confirm all 6 `.entitlements` files were generated**

```bash
/usr/bin/find . -iname "*.entitlements" | sort
```

Expected:
```
./ADBLX/ADBLX.entitlements
./Extensions/ADBLXAdsBlocker/ADBLXAdsBlocker.entitlements
./Extensions/ADBLXAnnoyancesBlocker/ADBLXAnnoyancesBlocker.entitlements
./Extensions/ADBLXPrivacyBlocker/ADBLXPrivacyBlocker.entitlements
./Extensions/ADBLXRegionalBlocker/ADBLXRegionalBlocker.entitlements
./Extensions/ADBLXSafariWebExtension/ADBLXSafariWebExtension.entitlements
```

Confirm `ADBLXPacketTunnel` has none:

```bash
/usr/bin/find Extensions/ADBLXPacketTunnel -iname "*.entitlements"
```

Expected: no output.

- [ ] **Step 3: Verify each entitlements file's App Group content**

```bash
for f in ADBLX/ADBLX.entitlements Extensions/ADBLXAdsBlocker/ADBLXAdsBlocker.entitlements Extensions/ADBLXPrivacyBlocker/ADBLXPrivacyBlocker.entitlements Extensions/ADBLXAnnoyancesBlocker/ADBLXAnnoyancesBlocker.entitlements Extensions/ADBLXRegionalBlocker/ADBLXRegionalBlocker.entitlements Extensions/ADBLXSafariWebExtension/ADBLXSafariWebExtension.entitlements; do
  echo "=== $f ==="
  plutil -lint "$f"
  plutil -extract "com.apple.security.application-groups.0" raw "$f"
done
```

Expected, for each file: `<path>: OK` then `group.com.ADBLX.shared`.

- [ ] **Step 4: Record state, generate a second time, confirm no further changes**

```bash
git status --porcelain=v1 --untracked-files=all > /tmp/adblx-c4-gen1-status.txt
xcodegen generate
git status --porcelain=v1 --untracked-files=all > /tmp/adblx-c4-gen2-status.txt
diff /tmp/adblx-c4-gen1-status.txt /tmp/adblx-c4-gen2-status.txt
echo "diff exit=$?"
```

Expected: `diff exit=0` — deterministic generation.

---

### Task 3: Add the `AppGroup` helper to the app target

**Files:**
- Create: `ADBLX/AppGroup.swift`
- Test: `ADBLXTests/AppGroupTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum AppGroup { static let identifier: String }`, referenced by future App Group I/O code (Commit 5).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import ADBLX

@Suite("AppGroup")
struct AppGroupTests {
    @Test("identifier matches the entitlement configured in project.yml")
    func identifierMatchesEntitlement() {
        #expect(AppGroup.identifier == "group.com.ADBLX.shared")
    }
}
```

Write this to `ADBLXTests/AppGroupTests.swift`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/AppGroupTests test 2>&1 | tail -20
```

Expected: build failure — `cannot find 'AppGroup' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Write `ADBLX/AppGroup.swift`**

```swift
enum AppGroup {
    static let identifier = "group.com.ADBLX.shared"
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/AppGroupTests test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

---

### Task 4: Document the App Group, shared container contract, and CI in `TargetTopology.md`

**Files:**
- Modify: `docs/Architecture/TargetTopology.md`

**Interfaces:**
- Consumes: decisions from `docs/superpowers/specs/2026-07-15-sprint0-commit4-infrastructure-design.md`.
- Produces: updated living documentation reflecting Commit 4's state.

- [ ] **Step 1: Update the status line**

Change:
```markdown
**Status:** current as of Sprint 0 Commit 3 (`da17133`). Living document — update in place as targets, build settings, or capabilities change. For the "why" behind these decisions, see the linked specs; this document covers only the "how it currently works."
```
to:
```markdown
**Status:** current as of Sprint 0 Commit 4. Living document — update in place as targets, build settings, or capabilities change. For the "why" behind these decisions, see the linked specs; this document covers only the "how it currently works."
```

- [ ] **Step 2: Replace the "What's deliberately not here yet" bullet about capabilities**

Find this bullet in the "## What's deliberately not here yet" section:
```markdown
- **App Groups, Network Extension entitlement, Safari Web Extension capabilities** — no target has any capability configured. All 7 targets use `CODE_SIGN_STYLE: Automatic` and nothing else security/capability-related.
```
Replace with:
```markdown
- **Network Extension entitlement** — `ADBLXPacketTunnel` has no capability configured; blocked on the Personal Team limitation (see "Development environment limitations" below).
```

Also update the CI bullet in the same section:
```markdown
- **CI** — `.github/workflows/` has no `ci.yml` yet, only a placeholder `README.md`.
```
Replace with:
```markdown
- **CI caching, build artifacts, release automation** — `.github/workflows/ci.yml` (added Commit 4) runs generate/drift-check/build/unit-test only.
```

- [ ] **Step 3: Insert a new "App Groups" section after the "Content Blocker request lifecycle" section**

Find the section that ends with:
```markdown
## What's deliberately not here yet
```
Insert this new section immediately before it:

```markdown
## App Groups

Identifier: `group.com.ADBLX.shared` — follows the `com.ADBLX.*` bundle ID namespace, not the earlier-proposed-but-superseded `com.sreeharsha.adblx` convention (see bundle ID note above).

| Target | App Group |
|---|---|
| `ADBLX` | ✅ |
| `ADBLXAdsBlocker` | ✅ |
| `ADBLXPrivacyBlocker` | ✅ |
| `ADBLXAnnoyancesBlocker` | ✅ |
| `ADBLXRegionalBlocker` | ✅ |
| `ADBLXSafariWebExtension` | ✅ |
| `ADBLXPacketTunnel` | ⏸ Deferred — see "Development environment limitations" |
| `ADBLXTests` / `ADBLXUITests` | ❌ Not needed |

Configured via `entitlements:` in `project.yml` per target, generating a `.entitlements` file at build time (same generated-artifact pattern as `Info.plist` — never hand-authored). `REGISTER_APP_GROUPS: YES` is set alongside on each entitled target so Automatic signing registers the capability with the App ID.

`AppGroup.swift` (`ADBLX/AppGroup.swift`) exposes the identifier as `AppGroup.identifier`. It lives only in the app target — no `Packages/ADBLXShared` linkage yet (still gated on unwritten ADR-0003); revisit when a real cross-target need arises.

### Shared container contract

Directory structure inside the App Group container (contract only — not yet exercised with real I/O; that's Commit 5):

```
group.com.ADBLX.shared/
├── Rules/
│   ├── Ads.json
│   ├── Privacy.json
│   ├── Annoyances.json
│   └── Regional.json
├── Manifest/
│   └── manifest.json
├── Metadata/
│   ├── installed-versions.json
│   └── manifest-state.json
└── Diagnostics/
```

`Rules/` holds active rule JSON regardless of provenance (bundled/compiled/imported) — Content Blockers will eventually read from here instead of their bundled `Resources/blockerList.json`. Files are written atomically by the main app (`.tmp` → rename) so extensions never observe partially-written rule files.

## Development environment limitations

Current development uses an Apple Personal Team (free, non-paid). Therefore:

- The Network Extension entitlement (`com.apple.developer.networking.networkextension`) is unavailable — Personal Teams cannot provision it.
- `ADBLXPacketTunnel`'s capability and App Group are intentionally deferred as a result.
- This is an Apple provisioning limitation, not a project or architecture limitation. Revisit once the account upgrades to a paid Apple Developer Program membership.

## Continuous Integration

`.github/workflows/ci.yml` runs on push/PR to `dev`/`main` plus manual dispatch: checkout → select latest-stable Xcode → install XcodeGen → `xcodegen generate` → drift check (`git diff --exit-code`) → build the `ADBLX` scheme → run `ADBLXTests` only. `ADBLXUITests` is intentionally excluded — there is no UI worth testing yet, not because of flakiness; it joins CI once onboarding/settings screens exist.
```

- [ ] **Step 4: Review the diff**

```bash
cd /Users/sreeharshag/Work/ADBLX
git diff docs/Architecture/TargetTopology.md
```

Expected: status line, two bullet replacements, and the new "App Groups" / "Development environment limitations" / "Continuous Integration" sections all present; nothing else changed.

---

### Task 5: Write the GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `.github/workflows/README.md`

**Interfaces:**
- Consumes: `project.yml`, the `ADBLX` scheme, `ADBLXTests`.
- Produces: a working CI pipeline triggered on push/PR to `dev`/`main`.

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [dev, main]
  pull_request:
    branches: [dev, main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-and-test:
    runs-on: macos-15
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Verify no project drift
        run: git diff --exit-code ADBLX.xcodeproj

      - name: Find an available iOS Simulator
        id: simulator
        run: |
          UDID=$(xcrun simctl list devices available -j | python3 -c '
          import json, sys
          data = json.load(sys.stdin)
          for runtime, devices in data["devices"].items():
              if "iOS" not in runtime:
                  continue
              for d in devices:
                  if d["name"].startswith("iPhone"):
                      print(d["udid"])
                      sys.exit(0)
          ')
          if [ -z "$UDID" ]; then
            echo "No iOS Simulator found" >&2
            exit 1
          fi
          echo "udid=$UDID" >> "$GITHUB_OUTPUT"

      - name: Build
        run: |
          xcodebuild -project ADBLX.xcodeproj -scheme ADBLX \
            -destination "id=${{ steps.simulator.outputs.udid }}" build

      - name: Run unit tests (ADBLXTests only)
        run: |
          xcodebuild -project ADBLX.xcodeproj -scheme ADBLX \
            -destination "id=${{ steps.simulator.outputs.udid }}" \
            -only-testing:ADBLXTests test
```

- [ ] **Step 2: Update `.github/workflows/README.md`**

Replace:
```markdown
# GitHub Actions Workflows

CI workflow definitions for ADBLX. `ci.yml` (build all targets, test, lint/format check, XcodeGen drift check, no-op rule-budget check) is added in Sprint 0 Commit 4, once there are multiple targets and a `project.yml` to check for drift.
```
with:
```markdown
# GitHub Actions Workflows

CI workflow definitions for ADBLX.

`ci.yml` (Sprint 0 Commit 4) runs on push/PR to `dev`/`main` and on manual dispatch: generates the Xcode project via XcodeGen, fails on drift between `project.yml` and the checked-in `ADBLX.xcodeproj`, builds the `ADBLX` scheme, and runs `ADBLXTests`. `ADBLXUITests` is intentionally excluded (no UI worth testing yet). No caching, no artifacts, no release automation — see `docs/superpowers/specs/2026-07-15-sprint0-commit4-infrastructure-design.md`.
```

- [ ] **Step 3: Validate the workflow YAML parses**

```bash
cd /Users/sreeharshag/Work/ADBLX
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML valid')"
```

Expected: `YAML valid`.

---

### Task 6: Locally dry-run the CI steps

**Files:**
- None created or modified — verification only.

**Interfaces:**
- Consumes: everything from Tasks 1–5.
- Produces: confidence that the CI workflow's commands actually work, before pushing and burning a real Actions run.

- [ ] **Step 1: Simulate the drift check step**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodegen generate
git diff --exit-code ADBLX.xcodeproj
echo "drift check exit=$?"
```

Expected: `drift check exit=0` (assuming Task 2 already generated and nothing changed since).

- [ ] **Step 2: Simulate the simulator-discovery step**

```bash
python3 -c '
import json, subprocess, sys
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"].startswith("iPhone"):
            print(d["udid"])
            sys.exit(0)
'
```

Expected: a UDID printed (a 36-character GUID), confirming the same script CI will run resolves correctly on this machine's simulator set.

- [ ] **Step 3: Run the same build command CI will run**

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
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$UDID" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the same test command CI will run**

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
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$UDID" -only-testing:ADBLXTests test 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

---

### Task 7: Manual Xcode verification for provisioning warnings

**Files:**
- None created or modified — manual verification only.

**Interfaces:**
- Consumes: the regenerated project from Task 2.
- Produces: confirmation of acceptance criterion "no provisioning/entitlement warnings" from the design spec.

- [ ] **Step 1: Open the project in Xcode**

```bash
open /Users/sreeharshag/Work/ADBLX/ADBLX.xcodeproj
```

- [ ] **Step 2: Check Signing & Capabilities for each of the 6 entitled targets**

For `ADBLX`, `ADBLXAdsBlocker`, `ADBLXPrivacyBlocker`, `ADBLXAnnoyancesBlocker`, `ADBLXRegionalBlocker`, `ADBLXSafariWebExtension`: select the target → Signing & Capabilities tab. Confirm:
- "App Groups" capability is listed with `group.com.ADBLX.shared` checked.
- No red/yellow provisioning warning banners.
- No "missing entitlement" or "failed to register" errors (Personal Team can provision App Groups — only Network Extension is blocked).

- [ ] **Step 3: Check `ADBLXPacketTunnel` has no capabilities configured**

Select `ADBLXPacketTunnel` → Signing & Capabilities. Confirm: no App Groups capability, no Network Extension capability, `CODE_SIGN_STYLE: Automatic` with no warnings (since nothing is being provisioned for it).

---

### Task 8: Update `agent.md`, review scope, and commit

**Files:**
- Modify: `agent.md`

**Interfaces:**
- Consumes: all changes from Tasks 1–7.
- Produces: the `feat: add app groups and CI workflow` commit on `dev`.

- [ ] **Step 1: Update the "Current repo state" section of `agent.md`**

Replace:
```markdown
## Current repo state
Sprint 0 (repository bootstrap) is in progress on `dev`, Commits 1–3 of 5 complete:
- **Commit 1** — repo scaffolding (`Config/`, `docs/ADR/`, `docs/Architecture/`, lint/format config).
- **Commit 2** — migrated the hand-authored `ADBLX.xcodeproj` to XcodeGen (`project.yml` is now the source of truth; see [`README.md`](README.md)).
- **Commit 3** — added all 6 extension targets (4 Content Blockers, `ADBLXPacketTunnel`, `ADBLXSafariWebExtension`) as placeholders — they build, but have no capabilities and no runtime behavior yet.

Full current target topology, folder layout, and what's deliberately not implemented yet: [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md).

Remaining Sprint 0 work: Commit 4 (App Groups entitlement, CI) and Commit 5 (functional verification — real bundled rule snapshot, `reloadContentBlocker()`, performance baselines).
```
with:
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

- [ ] **Step 2: Review the full diff scope**

```bash
cd /Users/sreeharshag/Work/ADBLX
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
```

Expected: changes limited to `project.yml` (modified), `ADBLX.xcodeproj/` (modified/regenerated), `agent.md` (modified), `docs/Architecture/TargetTopology.md` (modified), `.github/workflows/README.md` (modified), `.github/workflows/ci.yml` (new), `ADBLX/AppGroup.swift` (new), `ADBLXTests/AppGroupTests.swift` (new), and the 6 new `.entitlements` files under `ADBLX/` and `Extensions/*/`. No changes under `ADBLXUITests/`, `Config/`, `Performance/`, `Scripts/`, `Packages/`, `README.md`, or `Extensions/ADBLXPacketTunnel/`.

- [ ] **Step 3: Stage and commit**

```bash
git add project.yml ADBLX.xcodeproj ADBLX/AppGroup.swift ADBLX/ADBLX.entitlements ADBLXTests/AppGroupTests.swift Extensions/ADBLXAdsBlocker/ADBLXAdsBlocker.entitlements Extensions/ADBLXPrivacyBlocker/ADBLXPrivacyBlocker.entitlements Extensions/ADBLXAnnoyancesBlocker/ADBLXAnnoyancesBlocker.entitlements Extensions/ADBLXRegionalBlocker/ADBLXRegionalBlocker.entitlements Extensions/ADBLXSafariWebExtension/ADBLXSafariWebExtension.entitlements .github/workflows/ci.yml .github/workflows/README.md docs/Architecture/TargetTopology.md agent.md
git commit -m "feat: add app groups and CI workflow"
```

- [ ] **Step 4: Confirm the commit landed cleanly**

```bash
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
git log -1 --stat
```

Expected: clean working tree (aside from pre-existing untracked `.claude/`); the log shows the `feat: add app groups and CI workflow` commit with exactly the files from Step 3.

- [ ] **Step 5: Push and confirm the CI workflow runs**

```bash
git push origin dev
```

Then check the Actions tab on GitHub (or `gh run watch` if the `gh` CLI is authenticated) to confirm the `CI` workflow triggers and passes.

- [ ] **Step 6: Clean up temporary verification files**

```bash
rm -f /tmp/adblx-c4-dump-1.txt /tmp/adblx-c4-gen1-status.txt /tmp/adblx-c4-gen2-status.txt
```

---

## After This Plan

Sprint 0 has one remaining commit: **Commit 5** — functional verification. App Group read/write round-trip (exercising the `Rules/`/`Manifest/`/`Metadata/`/`Diagnostics/` contract documented in this commit), a real bundled 1–3K rule snapshot replacing the `[]` placeholder, `SFContentBlockerManager.reloadContentBlocker()` wiring, MetricKit integration, and an informal performance baseline in `Performance/Baselines.md`. Per the parent Sprint 0 spec, this is a separate planning pass once Commit 4 is verified and merged.
