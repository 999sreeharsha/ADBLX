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
