# Sprint 0 — Commit 1: Repository Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold ADBLX's repository infrastructure (folders, lint/format config, xcconfig placeholders, CI folder) as a single reviewable commit, without touching the existing Xcode project or introducing XcodeGen yet.

**Architecture:** Pure filesystem/config scaffolding — no Swift code, no `project.yml`, no target changes. Every otherwise-empty directory gets a one-line `README.md` so git tracks it and the repo is self-documenting from the first commit. The existing `ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`, `ADBLX.xcodeproj/` are left untouched; the project must still build and run in the simulator exactly as before after this commit.

**Tech Stack:** Xcode 26.6 project (Swift 5.0 language mode, `IPHONEOS_DEPLOYMENT_TARGET = 26.5`, scheme `ADBLX`), swift-format, SwiftLint, EditorConfig. XcodeGen is *not* installed/used in this commit — it lands in Commit 2.

## Global Constraints

- Do not create, modify, or delete: `project.yml`, `Extensions/`, App Group entitlements, or anything XcodeGen-related. Those are Commit 2+ per `docs/superpowers/specs/2026-07-14-sprint0-bootstrap-design.md`.
- Do not move or reorganize `ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`, or `ADBLX.xcodeproj/`. Leave them exactly where Xcode created them.
- Do not replace the existing root `.gitignore` — only extend it if a gap is found.
- Naming/bundle-ID/target conventions from the spec apply to later commits, not this one (no targets are touched here).
- Final verification for this commit is an Xcode build (⌘B) + simulator launch + `git status` check — not `pytest`/unit tests, since this commit contains no executable code.

---

### Task 1: Documentation and support directories with README placeholders

**Files:**
- Create: `docs/ADR/README.md`
- Create: `docs/Architecture/README.md`
- Create: `Performance/README.md`
- Create: `Scripts/README.md`
- Create: `.github/workflows/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: five tracked, otherwise-empty directories that later commits populate — `docs/ADR/` (ADR-0001/2/3 in later work), `docs/Architecture/` (TargetTopology/AppGroup/RulePipeline/UpdatePipeline/Logging docs later), `Performance/` (`Baselines.md` in Commit 5), `Scripts/` (future build/lint helper scripts), `.github/workflows/` (`ci.yml` in Commit 4).

Note: the design spec's directory tree shows `Docs/ADR` and `Docs/Architecture` (capital `Docs`), but the repo's existing docs live in lowercase `docs/` (`docs/adblock-prd-v1.1.md`, `docs/superpowers/`). Use the existing lowercase `docs/` root and add `ADR/` and `Architecture/` under it, so there is one docs root instead of two case-variant ones.

- [ ] **Step 1: Create the five directories with a placeholder file in each**

```bash
mkdir -p docs/ADR docs/Architecture Performance Scripts .github/workflows
```

- [ ] **Step 2: Write `docs/ADR/README.md`**

```markdown
# Architecture Decision Records

Immutable decision records for ADBLX. Each ADR is dated and not edited after acceptance — a reversed decision gets a new ADR that supersedes the old one, not an edit.
```

- [ ] **Step 3: Write `docs/Architecture/README.md`**

```markdown
# Architecture Documentation

Living documentation describing how ADBLX currently works. Updated as the system evolves, unlike the immutable ADRs in `docs/ADR/`.
```

- [ ] **Step 4: Write `Performance/README.md`**

```markdown
# Performance

Tracked performance baselines and budgets for ADBLX (cold launch, rule compile time, content blocker reload, tunnel energy use). See `Baselines.md` once populated in Sprint 0 Commit 5.
```

- [ ] **Step 5: Write `Scripts/README.md`**

```markdown
# Scripts

Build, lint, and automation helper scripts for ADBLX. Empty as of Sprint 0 Commit 1 — populated as tooling needs arise.
```

- [ ] **Step 6: Write `.github/workflows/README.md`**

```markdown
# GitHub Actions Workflows

CI workflow definitions for ADBLX. `ci.yml` (build all targets, test, lint/format check, XcodeGen drift check, no-op rule-budget check) is added in Sprint 0 Commit 4, once there are multiple targets and a `project.yml` to check for drift.
```

- [ ] **Step 7: Verify the directories and files exist**

Run: `find docs/ADR docs/Architecture Performance Scripts .github/workflows -type f`
Expected output (order may vary):
```
docs/ADR/README.md
docs/Architecture/README.md
Performance/README.md
Scripts/README.md
.github/workflows/README.md
```

---

### Task 2: `Packages/ADBLXShared` empty skeleton

**Files:**
- Create: `Packages/ADBLXShared/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: an empty, tracked package directory. Per ADR-0003 (written in a later commit), source files and Swift Package Manager linkage into App/PacketTunnel/SafariWebExtension are gated on that ADR being approved — this task creates the directory only, no `Package.swift`, no source.

- [ ] **Step 1: Create the directory**

```bash
mkdir -p Packages/ADBLXShared
```

- [ ] **Step 2: Write `Packages/ADBLXShared/README.md`**

```markdown
# ADBLXShared

Shared Swift package for ADBLX: Models, Constants, Logging, Utilities, AppGroup helpers, Manifest models.

Empty skeleton as of Sprint 0 Commit 1. Source files and linkage into the main app, PacketTunnel, and Safari Web Extension are gated on ADR-0003 (shared package boundaries) being approved. Never add UI, Networking, StoreKit, SwiftUI, RuleCompiler, or FilterUpdateManager code here — see ADR-0003 once written.
```

- [ ] **Step 3: Verify**

Run: `find Packages -type f`
Expected output: `Packages/ADBLXShared/README.md`

---

### Task 3: `Config/` xcconfig files

**Files:**
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`

**Interfaces:**
- Consumes: current project build settings (`SWIFT_VERSION = 5.0`, `IPHONEOS_DEPLOYMENT_TARGET = 26.5`) read from `ADBLX.xcodeproj/project.pbxproj` so the values match today's project.
- Produces: xcconfig files that are inert in this commit (not referenced by any target — `ADBLX.xcodeproj` is untouched). Commit 2's `project.yml` wires these in via `configFiles:` when the project is migrated to XcodeGen.

- [ ] **Step 1: Write `Config/Base.xcconfig`**

```text
// Base build settings shared across all ADBLX targets and configurations.
// Wired into project.yml starting in Sprint 0 Commit 2 (XcodeGen migration).
SWIFT_VERSION = 5.0
IPHONEOS_DEPLOYMENT_TARGET = 26.5
```

- [ ] **Step 2: Write `Config/Debug.xcconfig`**

```text
#include "Base.xcconfig"

ONLY_ACTIVE_ARCH = YES
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
SWIFT_OPTIMIZATION_LEVEL = -Onone
```

- [ ] **Step 3: Write `Config/Release.xcconfig`**

```text
#include "Base.xcconfig"

SWIFT_COMPILATION_MODE = wholemodule
SWIFT_OPTIMIZATION_LEVEL = -O
```

- [ ] **Step 4: Verify**

Run: `ls Config/`
Expected output:
```
Base.xcconfig
Debug.xcconfig
Release.xcconfig
```

---

### Task 4: Lint, format, and editor config at repo root

**Files:**
- Create: `.editorconfig`
- Create: `.swift-format`
- Create: `.swiftlint.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: root-level tool config that Commit 4's CI workflow will invoke (`swift-format lint`, `swiftlint`). Not wired into CI in this commit — CI itself doesn't exist until Commit 4.

- [ ] **Step 1: Write `.editorconfig`**

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 4

[*.{yml,yaml}]
indent_size = 2

[*.md]
trim_trailing_whitespace = false
```

- [ ] **Step 2: Write `.swift-format`**

```json
{
  "version": 1,
  "lineLength": 120,
  "indentation": {
    "spaces": 4
  },
  "tabWidth": 4,
  "respectsExistingLineBreaks": true,
  "lineBreakBeforeControlFlowKeywords": false,
  "lineBreakBeforeEachArgument": false
}
```

- [ ] **Step 3: Write `.swiftlint.yml`**

```yaml
excluded:
  - Pods
  - DerivedData
  - .build

opt_in_rules:
  - empty_count
  - closure_spacing
  - explicit_init
  - force_unwrapping
  - unused_import

line_length:
  warning: 120
  error: 150

identifier_name:
  min_length:
    warning: 2
  excluded:
    - id
```

- [ ] **Step 4: Verify**

Run: `ls -a | grep -E "^\.(editorconfig|swift-format|swiftlint\.yml)$"`
Expected output:
```
.editorconfig
.swift-format
.swiftlint.yml
```

---

### Task 5: Review `.gitignore` for gaps

**Files:**
- Modify (only if a gap is found): `.gitignore`

**Interfaces:**
- Consumes: the current `.gitignore` content (already present from the Xcode scaffold).
- Produces: confirmation that build artifacts from this commit's new tooling (SwiftPM builds under `Packages/ADBLXShared`, local xcconfig overrides) are already ignored, or an extension if not.

- [ ] **Step 1: Read the current `.gitignore` and check for SwiftPM and local-xcconfig coverage**

Run: `cat .gitignore`

Confirm it already contains (as of this plan's authoring, it does):
```
.build/
.swiftpm/
Package.resolved
*.xcconfig.local
```

If all four are present, no edit is needed — do not modify the file. If any is missing, append only the missing line(s) under the existing relevant section (Swift Package Manager section for the first three, Environment/secrets section for `*.xcconfig.local`); do not reorder or rewrite existing content.

- [ ] **Step 2: Verify no unintended changes**

Run: `git diff .gitignore`
Expected: no output (empty diff) if Step 1 found no gap; otherwise a diff showing only the appended line(s).

---

### Task 6: Build verification and commit

**Files:**
- None created or modified — this task verifies Tasks 1–5 and commits.

**Interfaces:**
- Consumes: all files from Tasks 1–5.
- Produces: the `feat: bootstrap repository` commit on the `dev` branch.

- [ ] **Step 1: Confirm the existing Xcode project still builds**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **` — this commit touched no files under `ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`, or `ADBLX.xcodeproj/`, so this is a parity check, not a new capability.

- [ ] **Step 2: Confirm the simulator still launches (manual, in Xcode)**

In Xcode: open `ADBLX.xcodeproj`, select an iOS Simulator destination, press ⌘R. Expected: app launches to the default scaffold screen with no crash.

- [ ] **Step 3: Review the full set of changes**

Run: `git status`
Expected: new/untracked files limited to `docs/ADR/`, `docs/Architecture/`, `Performance/`, `Scripts/`, `.github/workflows/`, `Packages/ADBLXShared/`, `Config/`, `.editorconfig`, `.swift-format`, `.swiftlint.yml`, and (only if Task 5 found a gap) a modified `.gitignore`. No changes under `ADBLX/`, `ADBLXTests/`, `ADBLXUITests/`, `ADBLX.xcodeproj/`, `project.yml` (must not exist), or `Extensions/` (must not exist).

- [ ] **Step 4: Stage and commit**

```bash
git add docs/ADR docs/Architecture Performance Scripts .github/workflows Packages/ADBLXShared Config .editorconfig .swift-format .swiftlint.yml
git add .gitignore
git commit -m "feat: bootstrap repository"
```

- [ ] **Step 5: Confirm the commit landed cleanly**

Run: `git status && git log -1 --stat`
Expected: `git status` reports a clean working tree; `git log -1 --stat` shows the `feat: bootstrap repository` commit with exactly the files from Step 4.

---

## After This Plan

Commit 2 (`feat: migrate project to xcodegen`) is the next unit of work: author `project.yml` for the existing `ADBLX` app target, generate `ADBLX.xcodeproj` from it, add `README.md` with the XcodeGen quickstart, and confirm the app builds/runs identically. It is deliberately **not** detailed task-by-task in this plan — per `docs/superpowers/specs/2026-07-14-sprint0-bootstrap-design.md`, it should be planned and reviewed as its own step once Commit 1 is verified and merged, since it's the highest-risk step in Sprint 0.
