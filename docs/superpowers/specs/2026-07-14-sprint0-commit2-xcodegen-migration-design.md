# Sprint 0 — Commit 2: XcodeGen Migration Design

**Project:** ADBLX (SHIELD) — iOS Ad Blocker
**Status:** Approved (Revision 1)
**Parent spec:** `docs/superpowers/specs/2026-07-14-sprint0-bootstrap-design.md`

## Goal

Replace the hand-authored `ADBLX.xcodeproj` with one generated from `project.yml`, functionally identical in every measurable way. This is the highest-risk commit in Sprint 0 — everything after it (adding 6 extension targets) depends on the project being correctly declarative from this point forward.

## Success criterion (narrow, by design)

> Functionally identical app. Only new artifacts are `project.yml` and the regenerated `ADBLX.xcodeproj`.

Explicitly out of scope for this commit: new targets, App Groups, extensions, bundle ID changes, build setting changes beyond what XcodeGen strictly requires, folder reorganization.

## Inventory (extracted from the current `project.pbxproj`)

| Aspect | Current value |
|---|---|
| Targets | `ADBLX` (app), `ADBLXTests` (unit test), `ADBLXUITests` (UI test) |
| Platforms | `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx xros xrsimulator`, `SDKROOT = auto` — genuinely multiplatform (iOS + native macOS + visionOS), not Mac Catalyst |
| Deployment targets | `IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET` / `XROS_DEPLOYMENT_TARGET` = `26.5` |
| Swift version | `5.0` |
| Bundle IDs | `com.ADBLX.ADBLX`, `com.ADBLX.ADBLXTests`, `com.ADBLX.ADBLXUITests` |
| Source layout | All three targets use `PBXFileSystemSynchronizedRootGroup` (Xcode 16 synced folders), no explicit file-reference lists |
| Capabilities (no `.entitlements` file exists) | `ENABLE_APP_SANDBOX = YES`, `ENABLE_USER_SELECTED_FILES = readonly`, `REGISTER_APP_GROUPS = YES` are already present as plain build settings, auto-managed by Xcode's capability system with no physical entitlements file |
| Versioning | `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1` |
| Test wiring | `ADBLXTests`/`ADBLXUITests` depend on `ADBLX` via `TestTargetID`, `TEST_HOST`, `BUNDLE_LOADER` (unit tests only), `TEST_TARGET_NAME` (UI tests) |
| Info.plist | Fully generated (`GENERATE_INFOPLIST_FILE = YES`), no physical `Info.plist` file — all keys come from `INFOPLIST_KEY_*` build settings |
| Code signing | `CODE_SIGN_STYLE = Automatic`; no `DEVELOPMENT_TEAM` key present in any configuration |

**Bundle ID note:** `com.ADBLX.*` does not match the Sprint 0 naming convention (`com.sreeharsha.adblx`) established in the parent spec. This commit preserves the bundle IDs verbatim — bundle ID normalization to `com.sreeharsha.adblx` is deferred to a dedicated ADR/commit after the XcodeGen migration, not folded into this "no functional change" migration.

## `project.yml` structure decision

The current project already has a natural two-level settings split — project-level Debug/Release configs (compiler warnings, `CLANG_*`/`GCC_*`, `ENABLE_TESTABILITY`, etc.) and target-level Debug/Release configs (bundle ID, deployment targets, `INFOPLIST_KEY_*`, capabilities). `project.yml` mirrors that exactly rather than inventing a new structure:

- **`Config/Base.xcconfig`, `Debug.xcconfig`, `Release.xcconfig`** (created inert in Commit 1) are expanded with the real project-level settings from the two project-scope `XCBuildConfiguration` blocks, wired in via `project.yml`'s `configFiles:`. Plain xcconfig inheritance (`#include "Base.xcconfig"`), not a template/anchor trick — this fulfills the header comment already present in those files from Commit 1.
- **Each target** (`ADBLX`, `ADBLXTests`, `ADBLXUITests`) gets its own `settings:` block in `project.yml` with its target-specific values (bundle ID, `INFOPLIST_KEY_*`, `TARGETED_DEVICE_FAMILY`, capabilities, test wiring). XcodeGen layers these on top of the xcconfig — the same layering Xcode already does today.
- **Sources** use XcodeGen's `type: syncedFolder` (confirmed supported in the installed XcodeGen 2.45.4, added specifically for Xcode 16's `PBXFileSystemSynchronizedRootGroup`) so the generated project uses the same synced-folder model as today — no explicit file lists, no reorganization.
- No `targetTemplates`, no YAML anchors, no `settingGroups` beyond the plain project/target split that already exists in the current project.

## Verification (Commit 2 acceptance criteria — all must pass)

1. `xcodegen generate` completes without error.
2. Running `xcodegen generate` a second time produces no `git diff` — deterministic generation.
3. **Build settings comparison** — `xcodebuild -showBuildSettings` for the `ADBLX` target, old project vs. regenerated project, must match on exactly these keys:
   - `PRODUCT_BUNDLE_IDENTIFIER`
   - `PRODUCT_NAME`
   - `SDKROOT`
   - `SUPPORTED_PLATFORMS`
   - `TARGETED_DEVICE_FAMILY`
   - `IPHONEOS_DEPLOYMENT_TARGET`
   - `MACOSX_DEPLOYMENT_TARGET`
   - `XROS_DEPLOYMENT_TARGET`
   - `GENERATE_INFOPLIST_FILE`
   - `SWIFT_VERSION`
   - `MARKETING_VERSION`
   - `CURRENT_PROJECT_VERSION`
   - `CODE_SIGN_STYLE`
   - `DEVELOPMENT_TEAM` (passing condition: absent/empty in both — no team is currently configured)

   Matching on this list is treated as sufficient proof of equivalence; everything else is nice-to-have, not a gate.
4. `xcodebuild build` succeeds for the `ADBLX` scheme.
5. Xcode ⌘B succeeds and ⌘R launches the simulator (manual).
6. `xcodebuild test` (or Xcode ⌘U) runs `ADBLXTests`/`ADBLXUITests` and they still pass/launch.
7. **Diff scope check** — `git diff`/`git status` after generation contains changes only within `project.yml`, `ADBLX.xcodeproj/`, and `README.md` (the XcodeGen quickstart added in this commit). No source file changes anywhere else. This catches accidental rewrites of generated assets or unexpected project modifications.
8. **Xcode project usability (manual)** — `open ADBLX.xcodeproj` and confirm: all three schemes appear correctly, no missing file references, no yellow/orange folders, no build-setting warnings in the project navigator, and the project opens without any "upgrade to recommended settings" migration prompt.
9. `git status` is clean after generation and review.

## Rollback

Git only — if any acceptance criterion fails, stop, do not hand-edit the generated `.xcodeproj`, fix `project.yml`, regenerate. If unresolvable in-session, `git revert`/reset the commit; the prior hand-authored project is fully intact in history.

## CI

None added in this commit. The idempotency check (criterion 2) is manual here; it becomes an automated `xcodegen generate && git diff --exit-code` step in Commit 4 as originally scoped in the parent spec.

## Commit contents

- `project.yml` (new)
- `ADBLX.xcodeproj/` (regenerated, committed)
- `README.md` (new) — XcodeGen quickstart:
  ```bash
  brew install xcodegen
  xcodegen generate
  open ADBLX.xcodeproj
  ```
- Commit message: `feat: migrate project to xcodegen`
