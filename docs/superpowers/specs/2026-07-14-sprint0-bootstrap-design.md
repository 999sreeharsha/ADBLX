# Sprint 0 — Repository Bootstrap Design

**Project:** ADBLX (SHIELD) — iOS Ad Blocker
**Duration target:** 1 week
**Status:** Approved

## Goal

Bootstrap ADBLX from a fresh Xcode scaffold (`ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`, hand-authored `.xcodeproj`) into a declarative, XcodeGen-managed multi-target repo: main app + 4 Content Blocker extensions + 2 placeholder extensions (PacketTunnel, Safari Web Extension), backed by ADRs for the two architecturally load-bearing decisions, CI, and a functional-verification pass proving the App Group → Content Blocker pipeline works end to end.

## Naming conventions (locked)

| Element | Convention | Example |
|---|---|---|
| Target names | PascalCase | `ADBLXAdsBlocker` |
| Bundle ID suffixes | lowercase | `com.sreeharsha.adblx.ads` |
| Folders | PascalCase | `ADBLXAdsBlocker/` |
| Swift modules | PascalCase | `import ADBLXShared` |

**Target list:**

```
ADBLX                    (main app)          com.sreeharsha.adblx
ADBLXAdsBlocker          (CB extension)      com.sreeharsha.adblx.ads
ADBLXPrivacyBlocker      (CB extension)      com.sreeharsha.adblx.privacy
ADBLXAnnoyancesBlocker   (CB extension)      com.sreeharsha.adblx.annoyances
ADBLXRegionalBlocker     (CB extension)      com.sreeharsha.adblx.regional
ADBLXPacketTunnel        (NE extension, placeholder)  com.sreeharsha.adblx.tunnel
ADBLXSafariWebExtension  (Safari Web Ext, placeholder) com.sreeharsha.adblx.webextension
```

App Group ID: `group.com.sreeharsha.adblx` (all 7 targets).

## Critical-path items (start day 1, run in parallel with everything else)

These have external lead time and are the actual schedule risk for Sprint 0 — everything else is internal effort. Neither blocks Sprint 0 itself.

1. **ADR-0001 draft → sent to counsel.** Draft the three-option licensing framework (ship+comply / clean-room converter / server-side conversion) and send to legal before writing ADR-0002/0003. Counsel turnaround, not authoring time, is the bottleneck. RuleCompiler code does not start until this returns.
2. **Network Extension entitlement request submitted** via developer portal. Approval can take days–weeks; this blocks S5 (PacketTunnel) if delayed, not Sprint 0.

## Branching

Stay on the existing `dev` branch. No new branch/PR ceremony introduced this sprint.

## Repository structure (final state after Sprint 0)

```
ADBLX/
├── project.yml
├── ADBLX.xcodeproj              (generated via XcodeGen, committed)
├── README.md                    (xcodegen quickstart)
├── .gitignore
├── .editorconfig
├── .swift-format
├── .swiftlint.yml
│
├── App/
├── Extensions/
│   ├── ADBLXAdsBlocker/
│   ├── ADBLXPrivacyBlocker/
│   ├── ADBLXAnnoyancesBlocker/
│   ├── ADBLXRegionalBlocker/
│   ├── ADBLXPacketTunnel/
│   └── ADBLXSafariWebExtension/
│
├── Packages/
│   └── ADBLXShared/              (empty skeleton in Sprint 0)
│
├── Config/
│   ├── Base.xcconfig
│   ├── Debug.xcconfig
│   └── Release.xcconfig
│
├── Docs/
│   ├── ADR/
│   │   ├── ADR-0001-SafariConverterLib-Licensing.md
│   │   ├── ADR-0002-Architecture-Extension-Boundaries.md
│   │   └── ADR-0003-Shared-Package-Boundaries.md
│   └── Architecture/
│       ├── TargetTopology.md
│       ├── AppGroup.md
│       ├── RulePipeline.md
│       └── UpdatePipeline.md
│
├── Performance/
│   └── Baselines.md
│
├── Scripts/
│
└── .github/
    └── workflows/
        └── ci.yml
```

Note: `Extensions/` subfolders are created by XcodeGen in Commit 3, together with the targets that own them — not pre-created empty in Commit 1. Creating target folders before the targets exist would create a filesystem/`project.yml` mismatch.

`Docs/Architecture/Logging.md` is explicitly **not** part of this structure — see "Deferred" below.

**ADR vs. Architecture docs:** ADRs are immutable decision records ("why," dated, not edited after acceptance — superseded by a new ADR if reversed). `Docs/Architecture/` is living documentation ("how it currently works") updated as the system evolves.

## Document authoring order

1. `project.yml` — defines physical structure everything else references
2. **ADR-0001 draft → sent to counsel** (parallel track, not blocking the rest)
3. ADR-0002 — architecture & extension boundaries (3-diagram version, see below)
4. ADR-0003 — shared package boundaries
5. GitHub Actions CI
6. `Performance/Baselines.md`

## ADR-0002 content notes (extension-communication model)

Three separate diagrams, not one generalized pattern — the three extension types communicate differently:

```
Content Blockers (read-only):
Main App → App Group Storage → Content Blocker Extensions

Packet Tunnel (bidirectional):
Main App → App Group Storage → Packet Tunnel
Main App ← App Group Storage ← Packet Tunnel  (status/diagnostics)

Safari Web Extension (App Group + internal native messaging):
Main App → App Group Storage → Web Extension native handler
Web Extension native handler ↔ Web Extension JS (native messaging,
    internal to the extension target — NOT a channel to the main app)
```

Also include two separate dependency diagrams, not one combined chain:

- Intra-app-target: `Features → Services → Repositories → Storage` (no feature-to-feature imports)
- Extension boundary: extensions are sibling processes connected to the main app only via App Group I/O, never via direct Swift-layer imports of Services/Repositories.

## ADR-0003 content notes (shared package)

`Packages/ADBLXShared` contains only: Models, Constants, Logging, Utilities, AppGroup helpers, Manifest models.

**Forbidden:** UI, Networking, StoreKit, SwiftUI, RuleCompiler, FilterUpdateManager.

**Linked into:** Main App, PacketTunnel, SafariWebExtension.
**Not linked into:** the 4 Content Blocker extensions (keep them lean against the ~6MB budget).

**Note:** PacketTunnel has its own OS-enforced memory ceiling (higher than CB extensions' ~6MB, but not unlimited like the main app) — flag this explicitly so nothing gets added to the shared package on the assumption that "not a CB extension" means "no constraint."

Creation vs. adoption, tracked separately:

| Task | Gated by |
|---|---|
| Create empty `Packages/ADBLXShared` | Nothing |
| Add first source files | ADR-0003 approved |
| Link into App/Tunnel/WebExt | ADR-0003 approved |

## Execution steps (small, independently reviewable commits)

### Commit 1 — Repository bootstrap

- `.gitignore`, `.editorconfig`, `.swift-format`, `.swiftlint.yml`
- `App/`, `Packages/ADBLXShared/` (empty skeleton, no source files), `Config/`, `Docs/` (ADR + Architecture folders with placeholder content), `Performance/`, `Scripts/`, `.github/`
- No `Extensions/` folder yet — those are created in Commit 3 together with their targets.
- No `project.yml` yet, no XcodeGen.
- Commit: `feat: bootstrap repository`

### Commit 2 — Migrate to XcodeGen

- Author `project.yml` describing the existing app target only.
- Generate `ADBLX.xcodeproj` from it; confirm the app builds and runs identically to before.
- Add `README.md` with the XcodeGen quickstart:
  ```bash
  brew install xcodegen
  xcodegen generate
  open ADBLX.xcodeproj
  ```
- Isolated as its own commit since it's the highest-risk step (touching the only thing that currently exists and builds).
- Commit: `feat: migrate project to xcodegen`

### Commit 3 — Extension targets

- All 6 extension targets added via `project.yml` (CB×4, PacketTunnel placeholder, WebExtension placeholder). XcodeGen creates the matching `Extensions/*` folders together with the targets. No business logic; must compile.
- Commit: `feat: add extension targets`

### Commit 4 — Capabilities & CI

- App Groups entitlement wired to all 7 targets.
- Bundle IDs, schemes, deployment targets set in `project.yml`.
- GitHub Actions: build all targets, run tests, lint/format check, warnings-as-errors, XcodeGen drift check (`xcodegen generate` must produce no diff), no-op rule-budget check (trivially passes on empty rule arrays).
- Commit: `feat: configure app groups and target capabilities`

### Commit 5 — Functional verification

- App Group round-trip test: main app writes → CB extension reads.
- `SFContentBlockerManager.reloadContentBlocker()` succeeds with a bundled snapshot (1–3K real compiled rules, not `[]`) on at least one CB extension.
- Instruments baseline pass: Time Profiler on cold launch, Allocations on the empty CB extension process (validates methodology — the number itself is expected to be small and uninteresting at this stage).
- MetricKit stub integrated (first-party only, per G5).
- `Performance/Baselines.md` populated with the tracked-metrics table below.
- CI green across all of the above.
- Commit: `feat: functional verification — app group, cb reload, bundled snapshot`

**Cadence for each commit:** finish the commit, build in Xcode, run the simulator, commit, push, then move to the next commit. Don't batch multiple commits' worth of changes before verifying in Xcode.

## Performance/Baselines.md — tracked metrics table

| Metric | Tool | Budget | PRD ref |
|---|---|---|---|
| App cold launch | Time Profiler | < 1.5 s | NFR-05 |
| Rule compile (once RuleCompiler exists) | Time Profiler + Allocations | < 10 s / < 200 MB | NFR-01 |
| Content blocker reload | Signposts + logging | No failures | FR-06 |
| Tunnel idle energy (S5+) | Energy Log | < 3% battery/day | NFR-02 |
| Rule counts per extension | CI | < 150K each | FR-01 |

Capture before every sprint merge from Sprint 1 onward.

## Explicit non-scope for Sprint 0

- No RuleCompiler implementation (blocked on ADR-0001)
- No manifest/CDN/FilterUpdateManager logic (S2)
- No onboarding UI (S3)
- No rule-budget CI enforcement beyond a trivial no-op check (nothing to enforce yet)
- No Keychain Sharing or Associated Domains entitlements (no concrete design need yet — add on-demand when a feature requires them)

## Deferred (explicitly not Sprint 0 deliverables)

- **`Docs/Architecture/Logging.md`** — not written in Sprint 0. There is no logging code yet, so the document would go stale before anything references it. Write it in the same commit that introduces the first `import OSLog` / `Logger(...)` usage, whenever that lands (likely Sprint 1+). At that point it should cover: `os.Logger`, subsystem `com.sreeharsha.adblx`, categories (App, RuleCompiler, FilterUpdate, ContentBlocker, PacketTunnel, SafariWebExtension), and an explicit forbidden-data list (URLs, DNS queries, hostnames, browsing history, request contents, user-identifiable data).
- **PRD amendment** — insert a formal Sprint 0 section into `adblock-prd-v1.1.md` (→ v1.2) ahead of the existing §12 milestone table. Done once Sprint 0 is complete and the ADRs are accepted, so the PRD reflects what was actually decided rather than what was proposed.
