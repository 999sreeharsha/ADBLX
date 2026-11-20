# 0014 — App target Info.plist: background task keys through a merged XcodeGen plist

**Date:** 2026-11-08
**Status:** Proposed (applied in task 6 of `docs/superpowers/plans/2026-11-07-background-updates.md`)

---

## 1. Context

Background filter updates need four Info.plist entries in the `ADBLX` app target:

| Key | Value |
|---|---|
| `UIBackgroundModes` | `fetch` (for the `BGAppRefreshTask`) and `processing` (for the `BGProcessingTask`) |
| `BGTaskSchedulerPermittedIdentifiers` | `com.ADBLX.ADBLX.filter-refresh`, `com.ADBLX.ADBLX.filter-install` |

Without the identifiers, `BGTaskScheduler.register` and `submit` fail for them.

The app target has no Info.plist file today. `project.yml` sets `GENERATE_INFOPLIST_FILE: YES`, and
Xcode builds the plist from `INFOPLIST_KEY_*` build settings. Xcode offers those settings only
for a fixed list of keys. On this toolchain (Xcode 26.6, 17F113) its build specifications define no
`INFOPLIST_KEY_` setting for either `UIBackgroundModes` or `BGTaskSchedulerPermittedIdentifiers`
(searched across every `.xcspec` in the Xcode bundle; the only background-related key is
`LSBackgroundOnly`). Neither key can be set through build settings.

`TargetTopology.md` allows Info.plist content outside the generated path only when XcodeGen can't
express a key, and requires an ADR for each exception.

## 2. Decision

Give the app target a partial plist written by XcodeGen's `info:` key, and let Xcode merge it with
the keys it already generates:

```yaml
  ADBLX:
    info:
      path: Config/ADBLX-Info.plist
      properties:
        UIBackgroundModes: [fetch, processing]
        BGTaskSchedulerPermittedIdentifiers:
          - com.ADBLX.ADBLX.filter-refresh
          - com.ADBLX.ADBLX.filter-install
```

- **Still not hand-authored.** XcodeGen writes the file from `project.yml` on every `xcodegen
  generate`, as it does for the six extensions. Nobody edits the file, and `project.yml` stays the
  only source.
- **What's new is the merge.** With `INFOPLIST_FILE` set and `GENERATE_INFOPLIST_FILE: YES` kept,
  Xcode starts from the file and adds the `INFOPLIST_KEY_*` keys. Only these two keys live in the
  file; every key Xcode can generate stays a build setting.
- **Outside `ADBLX/`.** The app's sources are a synced folder, which would also copy a plist inside it
  into the bundle as a resource. `Config/` isn't a source folder.
- **Both configurations.** `info:` sets `INFOPLIST_FILE` at the target level, so Debug and Release
  read the same file. Nothing here may be configuration-specific; the DNS tunnel's per-configuration
  settings are unaffected.

### Why this is the smallest exception

- Moving the whole app plist into the file would put the keys Xcode generates today back under hand
  control, for no gain.
- A build phase that edits the built plist with `PlistBuddy` would put configuration in a script,
  out of `project.yml`, where a reordered build phase could silently drop it.
- Waiting for Xcode to add the settings isn't an option: the feature needs them now.

## 3. Keeping the Release build honest

- **Release:** `Scripts/check-background-modes.sh <path to .app>` reads the built app's
  `Info.plist` and fails unless both modes and both identifiers are present. Every archive runs it
  on the app being archived (the "Check Release Build" phase, `Scripts/check-archive-release.sh`),
  so an archive fails without CI. CI runs it on the Release build it already makes for
  `Scripts/check-release-no-dns.sh` (`.github/workflows/ci.yml`).
  The script has its own test cases, as `check-release-no-dns.sh` does.
- **Debug:** a unit test reads `Bundle.main.infoDictionary` in the test host and checks the same
  four entries against the identifiers `BackgroundUpdates` registers, so the plist and the code
  can't drift apart.

## 4. Consequences

- A new background mode or task identifier goes into `project.yml`'s `info.properties` and into
  the script's expected list.
- If a later Xcode adds `INFOPLIST_KEY_` settings for these keys, this ADR can be superseded and
  the file dropped.
- App Store review sees a Background Modes capability (fetch, processing); the review note says it's
  for on-device blocklist updates.
