# Sprint 0 — Commit 2: XcodeGen Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-authored `ADBLX.xcodeproj` with one generated from `project.yml` via XcodeGen, functionally identical to today's project in every measurable way.

**Architecture:** Author `project.yml` as a faithful transcription of the current `project.pbxproj` — three targets (`ADBLX` app, `ADBLXTests`, `ADBLXUITests`), project-level Debug/Release settings pulled out into `Config/*.xcconfig` (mirroring the project's existing project-vs-target settings split), target-level settings declared inline per target, sources using XcodeGen's `type: syncedFolder` to preserve the existing `PBXFileSystemSynchronizedRootGroup` model. Generate, then verify equivalence against a captured baseline before committing.

**Tech Stack:** XcodeGen 2.45.4 (installed at `/opt/homebrew/bin/xcodegen`, confirms `syncedFolder` and `supportedDestinations`/`platform: auto` support per its CHANGELOG), Xcode 26.6, Swift 5.0.

## Global Constraints

- No new targets, App Groups, extensions, bundle ID changes, or folder reorganization (per `docs/superpowers/specs/2026-07-14-sprint0-commit2-xcodegen-migration-design.md`).
- Bundle IDs stay exactly `com.ADBLX.ADBLX` / `com.ADBLX.ADBLXTests` / `com.ADBLX.ADBLXUITests` — normalization to `com.sreeharsha.adblx` is a future ADR, not this commit.
- No CI changes — deferred to Commit 4.
- Never hand-edit the generated `ADBLX.xcodeproj` to "make it work." If verification fails, fix `project.yml` and regenerate.
- All 9 acceptance criteria from the design spec must pass before committing.

---

### Task 1: Capture baseline build settings before touching anything

**Files:**
- Create (untracked, not committed): `/tmp/adblx-baseline-settings.txt`

**Interfaces:**
- Consumes: the current hand-authored `ADBLX.xcodeproj` (still in its pre-migration state).
- Produces: `/tmp/adblx-baseline-settings.txt`, the reference file Task 7 diffs the regenerated project's settings against. Must be captured now — once `xcodegen generate` runs in Task 5, the old `.xcodeproj` content is gone.

- [ ] **Step 1: Dump full build settings for the ADBLX target to a baseline file**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -target ADBLX -showBuildSettings -destination 'generic/platform=iOS Simulator' > /tmp/adblx-baseline-settings.txt
```

- [ ] **Step 2: Verify the baseline file contains the mandatory comparison keys**

```bash
grep -E "PRODUCT_BUNDLE_IDENTIFIER|PRODUCT_NAME|SDKROOT|SUPPORTED_PLATFORMS|TARGETED_DEVICE_FAMILY|IPHONEOS_DEPLOYMENT_TARGET|MACOSX_DEPLOYMENT_TARGET|XROS_DEPLOYMENT_TARGET|GENERATE_INFOPLIST_FILE|SWIFT_VERSION|MARKETING_VERSION|CURRENT_PROJECT_VERSION|CODE_SIGN_STYLE|DEVELOPMENT_TEAM" /tmp/adblx-baseline-settings.txt
```

Expected: 13 lines of output (one per key; `DEVELOPMENT_TEAM` may print as empty or be absent — note whichever it is, since Task 7 must match this exact absence/emptiness).

---

### Task 2: Expand `Config/Base.xcconfig`, `Debug.xcconfig`, `Release.xcconfig` with real project-level settings

**Files:**
- Modify: `Config/Base.xcconfig`
- Modify: `Config/Debug.xcconfig`
- Modify: `Config/Release.xcconfig`

**Interfaces:**
- Consumes: the project-level `XCBuildConfiguration` blocks in the current `ADBLX.xcodeproj/project.pbxproj` (the two blocks with `CLANG_*`/`GCC_*` warnings, not the per-target blocks with `PRODUCT_BUNDLE_IDENTIFIER`).
- Produces: xcconfig files that Task 4's `project.yml` references via `configFiles:`. Note: `SWIFT_VERSION` and the three `*_DEPLOYMENT_TARGET` keys are **not** project-level settings in the current project (they only appear per-target) — the placeholder versions of these files from Commit 1 incorrectly implied otherwise; this task removes them from here and Task 4 sets them per-target instead, matching the real project structure.

- [ ] **Step 1: Replace `Config/Base.xcconfig` with the real shared project-level settings**

```text
// Base build settings shared across all ADBLX targets and configurations.
// Transcribed from the project-level XCBuildConfiguration blocks in
// ADBLX.xcodeproj/project.pbxproj as of the Sprint 0 Commit 2 migration.
// SWIFT_VERSION and platform deployment targets are NOT project-level in
// the source project — they are set per-target in project.yml instead.
ALWAYS_SEARCH_USER_PATHS = NO
ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES
CLANG_ANALYZER_NONNULL = YES
CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE
CLANG_CXX_LANGUAGE_STANDARD = gnu++20
CLANG_ENABLE_MODULES = YES
CLANG_ENABLE_OBJC_ARC = YES
CLANG_ENABLE_OBJC_WEAK = YES
CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES
CLANG_WARN_BOOL_CONVERSION = YES
CLANG_WARN_COMMA = YES
CLANG_WARN_CONSTANT_CONVERSION = YES
CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES
CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR
CLANG_WARN_DOCUMENTATION_COMMENTS = YES
CLANG_WARN_EMPTY_BODY = YES
CLANG_WARN_ENUM_CONVERSION = YES
CLANG_WARN_INFINITE_RECURSION = YES
CLANG_WARN_INT_CONVERSION = YES
CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES
CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES
CLANG_WARN_OBJC_LITERAL_CONVERSION = YES
CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR
CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES
CLANG_WARN_RANGE_LOOP_ANALYSIS = YES
CLANG_WARN_STRICT_PROTOTYPES = YES
CLANG_WARN_SUSPICIOUS_MOVE = YES
CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE
CLANG_WARN_UNREACHABLE_CODE = YES
CLANG_WARN__DUPLICATE_METHOD_MATCH = YES
COPY_PHASE_STRIP = NO
ENABLE_STRICT_OBJC_MSGSEND = YES
ENABLE_USER_SCRIPT_SANDBOXING = YES
GCC_C_LANGUAGE_STANDARD = gnu17
GCC_NO_COMMON_BLOCKS = YES
GCC_WARN_64_TO_32_BIT_CONVERSION = YES
GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR
GCC_WARN_UNDECLARED_SELECTOR = YES
GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE
GCC_WARN_UNUSED_FUNCTION = YES
GCC_WARN_UNUSED_VARIABLE = YES
LOCALIZATION_PREFERS_STRING_CATALOGS = YES
MTL_FAST_MATH = YES
```

- [ ] **Step 2: Replace `Config/Debug.xcconfig` with the real Debug-only project-level settings**

```text
#include "Base.xcconfig"

DEBUG_INFORMATION_FORMAT = dwarf
ENABLE_TESTABILITY = YES
GCC_DYNAMIC_NO_PIC = NO
GCC_OPTIMIZATION_LEVEL = 0
GCC_PREPROCESSOR_DEFINITIONS = DEBUG=1 $(inherited)
MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE
ONLY_ACTIVE_ARCH = YES
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG $(inherited)
SWIFT_OPTIMIZATION_LEVEL = -Onone
```

- [ ] **Step 3: Replace `Config/Release.xcconfig` with the real Release-only project-level settings**

```text
#include "Base.xcconfig"

DEBUG_INFORMATION_FORMAT = dwarf-with-dsym
ENABLE_NS_ASSERTIONS = NO
MTL_ENABLE_DEBUG_INFO = NO
SWIFT_COMPILATION_MODE = wholemodule
```

- [ ] **Step 4: Verify the three files exist with the expected content**

```bash
cat Config/Base.xcconfig Config/Debug.xcconfig Config/Release.xcconfig
```

Expected: no `SWIFT_VERSION` or `*_DEPLOYMENT_TARGET` keys anywhere in the three files (confirms Step 1's note was followed).

---

### Task 3: Author `project.yml`

**Files:**
- Create: `project.yml`

**Interfaces:**
- Consumes: `Config/Debug.xcconfig`/`Config/Release.xcconfig` from Task 2 (referenced via `configFiles:`); the full target-level settings inventory from `docs/superpowers/specs/2026-07-14-sprint0-commit2-xcodegen-migration-design.md`.
- Produces: `project.yml`, consumed by `xcodegen generate` in Task 4. Defines three targets: `ADBLX` (application), `ADBLXTests` (bundle.unit-test, depends on `ADBLX`), `ADBLXUITests` (bundle.ui-testing, depends on `ADBLX`).

- [ ] **Step 1: Write `project.yml`**

```yaml
name: ADBLX
configFiles:
  Debug: Config/Debug.xcconfig
  Release: Config/Release.xcconfig
targets:
  ADBLX:
    type: application
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: ADBLX
        type: syncedFolder
    settings:
      base:
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: 1
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
        IPHONEOS_DEPLOYMENT_TARGET: 26.5
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/Frameworks"
        "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": "@executable_path/../Frameworks"
        MACOSX_DEPLOYMENT_TARGET: 26.5
        MARKETING_VERSION: 1.0
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
        SWIFT_VERSION: 5.0
        TARGETED_DEVICE_FAMILY: "1,2,7"
        XROS_DEPLOYMENT_TARGET: 26.5
  ADBLXTests:
    type: bundle.unit-test
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: ADBLXTests
        type: syncedFolder
    dependencies:
      - target: ADBLX
    settings:
      base:
        BUNDLE_LOADER: "$(TEST_HOST)"
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: 1
        GENERATE_INFOPLIST_FILE: YES
        IPHONEOS_DEPLOYMENT_TARGET: 26.5
        MACOSX_DEPLOYMENT_TARGET: 26.5
        MARKETING_VERSION: 1.0
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXTests
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        STRING_CATALOG_GENERATE_SYMBOLS: NO
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_EMIT_LOC_STRINGS: NO
        SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY: YES
        SWIFT_VERSION: 5.0
        TARGETED_DEVICE_FAMILY: "1,2,7"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/ADBLX.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/ADBLX"
        XROS_DEPLOYMENT_TARGET: 26.5
  ADBLXUITests:
    type: bundle.ui-testing
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: ADBLXUITests
        type: syncedFolder
    dependencies:
      - target: ADBLX
    settings:
      base:
        CODE_SIGN_STYLE: Automatic
        CURRENT_PROJECT_VERSION: 1
        GENERATE_INFOPLIST_FILE: YES
        IPHONEOS_DEPLOYMENT_TARGET: 26.5
        MACOSX_DEPLOYMENT_TARGET: 26.5
        MARKETING_VERSION: 1.0
        PRODUCT_BUNDLE_IDENTIFIER: com.ADBLX.ADBLXUITests
        PRODUCT_NAME: "$(TARGET_NAME)"
        SDKROOT: auto
        STRING_CATALOG_GENERATE_SYMBOLS: NO
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator macosx xros xrsimulator"
        SWIFT_APPROACHABLE_CONCURRENCY: YES
        SWIFT_EMIT_LOC_STRINGS: NO
        SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY: YES
        SWIFT_VERSION: 5.0
        TARGETED_DEVICE_FAMILY: "1,2,7"
        TEST_TARGET_NAME: ADBLX
        XROS_DEPLOYMENT_TARGET: 26.5
```

- [ ] **Step 2: Validate the YAML parses**

```bash
xcodegen dump --spec project.yml > /tmp/adblx-project-yml-dump.txt && echo "YAML valid"
```

Expected: `YAML valid` printed, no parse errors.

---

### Task 4: Add `README.md` with the XcodeGen quickstart

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: root-level documentation for future contributors on how to regenerate the project.

- [ ] **Step 1: Write `README.md`**

```markdown
# ADBLX

iOS/iPadOS/macOS/visionOS ad blocker. See [agent.md](agent.md) and [docs/adblock-prd-v1.1.md](docs/adblock-prd-v1.1.md) for full context.

## Getting started

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate `ADBLX.xcodeproj` from `project.yml`. The generated project is committed to git, but if you change `project.yml`, regenerate before opening Xcode:

```bash
brew install xcodegen
xcodegen generate
open ADBLX.xcodeproj
```

Never hand-edit `ADBLX.xcodeproj` directly — edit `project.yml` and regenerate instead.
```

- [ ] **Step 2: Verify the file exists**

```bash
cat README.md
```

---

### Task 5: Generate the project and verify deterministic generation

**Files:**
- Modify (generated): `ADBLX.xcodeproj/`

**Interfaces:**
- Consumes: `project.yml` (Task 3), `Config/*.xcconfig` (Task 2).
- Produces: the regenerated `ADBLX.xcodeproj`, verified idempotent — the input to Task 6's build-settings comparison.

- [ ] **Step 1: Generate the project**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodegen generate
```

Expected: `Generated project at ADBLX.xcodeproj` (or equivalent success message), exit code 0.

- [ ] **Step 2: Record the state after first generation**

```bash
git status --porcelain=v1 --untracked-files=all > /tmp/adblx-gen1-status.txt
cat /tmp/adblx-gen1-status.txt
```

- [ ] **Step 3: Generate a second time and confirm no further changes**

```bash
xcodegen generate
git status --porcelain=v1 --untracked-files=all > /tmp/adblx-gen2-status.txt
diff /tmp/adblx-gen1-status.txt /tmp/adblx-gen2-status.txt
```

Expected: `diff` produces no output — the second `xcodegen generate` changed nothing beyond the first. This satisfies acceptance criterion 2 (deterministic generation).

---

### Task 6: Build-settings comparison against the baseline

**Files:**
- None created or modified — read-only verification against Task 1's baseline and Task 5's generated project.

**Interfaces:**
- Consumes: `/tmp/adblx-baseline-settings.txt` (Task 1), the regenerated `ADBLX.xcodeproj` (Task 5).
- Produces: pass/fail confirmation of acceptance criterion 3.

- [ ] **Step 1: Dump build settings for the regenerated ADBLX target**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -target ADBLX -showBuildSettings -destination 'generic/platform=iOS Simulator' > /tmp/adblx-generated-settings.txt
```

- [ ] **Step 2: Extract the 13 mandatory keys from both files and diff them**

```bash
for f in /tmp/adblx-baseline-settings.txt /tmp/adblx-generated-settings.txt; do
  grep -E "PRODUCT_BUNDLE_IDENTIFIER|PRODUCT_NAME|SDKROOT|SUPPORTED_PLATFORMS|TARGETED_DEVICE_FAMILY|IPHONEOS_DEPLOYMENT_TARGET|MACOSX_DEPLOYMENT_TARGET|XROS_DEPLOYMENT_TARGET|GENERATE_INFOPLIST_FILE|SWIFT_VERSION|MARKETING_VERSION|CURRENT_PROJECT_VERSION|CODE_SIGN_STYLE|DEVELOPMENT_TEAM" "$f" | sort > "$f.keys"
done
diff /tmp/adblx-baseline-settings.txt.keys /tmp/adblx-generated-settings.txt.keys
```

Expected: no output. If `DEVELOPMENT_TEAM` was absent from the baseline (per Task 1 Step 2's note), it must also be absent (or equally empty) from the generated settings — both files' `.keys` extracts should agree exactly.

If this diff is non-empty: stop, do not proceed to Task 7. Fix the mismatched setting in `project.yml` (Task 3) or `Config/*.xcconfig` (Task 2), then repeat Task 5 and this task from scratch.

---

### Task 7: Build, launch, and usability verification

**Files:**
- None created or modified — verification only.

**Interfaces:**
- Consumes: the regenerated, settings-verified `ADBLX.xcodeproj` from Tasks 5–6.
- Produces: pass/fail confirmation of acceptance criteria 4, 5, 6, and 8.

- [ ] **Step 1: CLI build**

```bash
cd /Users/sreeharshag/Work/ADBLX
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: CLI test run**

```bash
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: test run completes; `ADBLXTests` and `ADBLXUITests` both execute (adjust the simulator name to whatever's available locally via `xcrun simctl list devices available` if `iPhone 17` isn't present).

- [ ] **Step 3: Xcode build and simulator launch (manual)**

Open `ADBLX.xcodeproj` in Xcode, select an iOS Simulator destination, press ⌘B then ⌘R.
Expected: build succeeds, app launches in the simulator with no crash — same behavior as the pre-migration app.

- [ ] **Step 4: Xcode project usability check (manual)**

While `ADBLX.xcodeproj` is open in Xcode:
- Confirm the `ADBLX` scheme appears in the scheme selector (and no unexpected extra schemes were auto-generated).
- Confirm no missing file references (red filenames) or yellow/orange folder icons in the project navigator.
- Confirm no build-setting warnings badge on the project/target in the navigator.
- Confirm the project opened without an "Update to recommended settings" migration prompt.

Expected: all four conditions hold. If XcodeGen auto-generated extra per-target schemes beyond `ADBLX`, note this as a finding — it means an explicit `schemes:` block needs to be added to `project.yml` to match the original single-scheme project, which would require repeating Task 5 and Task 6.

- [ ] **Step 5: Run unit and UI tests from Xcode (manual)**

In Xcode, press ⌘U.
Expected: `ADBLXTests` and `ADBLXUITests` both run and pass (the current tests are the default Xcode-generated scaffold tests, which pass trivially).

---

### Task 8: Diff scope check and commit

**Files:**
- None created — final verification and commit of everything from Tasks 2–5.

**Interfaces:**
- Consumes: all changes from Tasks 2–5.
- Produces: the `feat: migrate project to xcodegen` commit on `dev`.

- [ ] **Step 1: Review the full diff scope**

```bash
cd /Users/sreeharshag/Work/ADBLX
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
```

Expected: changes limited to `project.yml` (new), `README.md` (new), `Config/Base.xcconfig`, `Config/Debug.xcconfig`, `Config/Release.xcconfig` (modified), and `ADBLX.xcodeproj/` (modified/regenerated). No changes under `ADBLX/`, `ADBLXTests/`, `ADBLXUITests/` (source files themselves — only the project file referencing them changes), no changes to `docs/`, `Performance/`, `Scripts/`, `.github/`, `Packages/`, `.editorconfig`, `.swift-format`, `.swiftlint.yml`, `.gitignore`.

- [ ] **Step 2: Stage and commit**

```bash
git add project.yml README.md Config/Base.xcconfig Config/Debug.xcconfig Config/Release.xcconfig ADBLX.xcodeproj
git commit -m "feat: migrate project to xcodegen"
```

- [ ] **Step 3: Confirm the commit landed cleanly**

```bash
git status --porcelain=v1 --untracked-files=all | grep -v '^?? \.claude/'
git log -1 --stat
```

Expected: clean working tree (aside from pre-existing untracked `.claude/`); the log shows the `feat: migrate project to xcodegen` commit with exactly the files from Step 2.

- [ ] **Step 4: Clean up temporary verification files**

```bash
rm -f /tmp/adblx-baseline-settings.txt /tmp/adblx-baseline-settings.txt.keys /tmp/adblx-generated-settings.txt /tmp/adblx-generated-settings.txt.keys /tmp/adblx-gen1-status.txt /tmp/adblx-gen2-status.txt /tmp/adblx-project-yml-dump.txt
```

---

## After This Plan

Commit 3 (`feat: add extension targets`) is next: add the 4 Content Blocker targets, PacketTunnel placeholder, and Safari Web Extension placeholder via `project.yml`, with XcodeGen creating the matching `Extensions/*` folders together with the targets. Per the parent Sprint 0 spec, this is a separate planning pass once Commit 2 is verified and merged.
