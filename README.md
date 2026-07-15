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

## Sprint 0 status — complete (`v0.1.0-sprint0`)

- ✅ XcodeGen project (`project.yml` is the source of truth)
- ✅ 7-target architecture (app + 4 Content Blockers + Packet Tunnel + Safari Web Extension)
- ✅ App Group integration (`group.com.ADBLX.shared`)
- ✅ `ADBLXAdsBlocker` Content Blocker extension, embedded and Safari-registered
- ✅ Rule reload (`SFContentBlockerManager.reloadContentBlocker`)
- ✅ App Group rule loading, with permanent bundled-resource fallback
- ✅ End-to-end ad blocking verified manually in Safari (both the App Group and fallback paths)
- ✅ CI (generate/drift-check/build/unit-test on push to `dev`/`main`)

See [`docs/Architecture/TargetTopology.md`](docs/Architecture/TargetTopology.md) for how it's built, and [`docs/Architecture/ManualVerification.md`](docs/Architecture/ManualVerification.md) for the verification record. Next milestone: Sprint 1, the rule pipeline (fetch/validate/compile real filter lists).
