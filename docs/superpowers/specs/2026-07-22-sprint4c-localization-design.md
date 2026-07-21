# Sprint 4C — Localization Infrastructure

**Status:** Approved
**Roadmap position:** Sprint 4A (UI Foundation) ✅ → Sprint 4B (UI Screens) ✅ → **Sprint 4C (this)** → Sprint 5 (Backend Integration & Live Data)

## Goal

Replace the current hardcoded English UI with a localization-ready architecture,
while keeping English as the only shipped language initially. This is
infrastructure work, done once, so future screens never reintroduce hardcoded
strings.

## Why now

Sprint 4A and 4B left 9 files with hardcoded user-visible string literals
(`Home`, `SafariProtectionView`, `AdvancedFilterListsView`, `Premium`,
`Settings`, `AboutView`, `Onboarding`, `DesignSystem/Card`,
`DesignSystem/ComingSoonState`) — roughly 46 `Text(...)` call sites, more once
buttons, labels, and alerts are counted. This is the last point before Sprint 5
(backend integration) where the surface area is still small enough to migrate
in one sprint. Deferring it lets the hardcoded-string pattern spread to
however many screens Sprint 5 and beyond add.

## Out of scope

This sprint is infrastructure and migration only. Explicitly excluded:

- Additional languages (only English ships)
- Runtime language switching
- Locale-aware formatting (`DateFormatter`, `NumberFormatter`, currency, etc.)
- RTL layout verification
- Pluralization rules (`stringsdict`-style plural variants)

These belong to a later internationalization sprint, once real demand for a
second language exists.

**Note:** Although locale-aware formatting infrastructure is out of scope,
touched code must adopt `FormatStyle` APIs where applicable so future
localization work does not require revisiting the same call sites. See
"Value formatting" under Commit 2.

## Key naming convention (frozen)

```
<feature>.<component>.<purpose>
```

Examples:

```
home.title
home.status.enabled
home.action.update

protection.category.ads
protection.category.privacy

premium.action.subscribe

settings.row.about
settings.section.general

about.version.label

onboarding.button.continue
```

Never use the English phrase itself as the key (`"Continue"`, `"Upgrade"`,
`"Home"`). Keys are hierarchical and stable across copy changes.

## Commit 1 — Localization Foundation

Every commit in this sprint must leave `dev` buildable and green — no commit
knowingly breaks the build.

- Add `ADBLX/Resources/Localizable.xcstrings` (String Catalog), English locale.
- Verify XcodeGen `syncedFolder` resource wiring picks up the catalog
  automatically; add an explicit resource entry to `project.yml` only if it
  doesn't.
- Add a **Localization** section to `docs/coding-standards.md` (new file,
  sibling to `docs/gotchas.md`) documenting the frozen key convention above and
  the SwiftUI-native-key convention from Commit 2. `docs/gotchas.md` stays
  reserved for pitfalls discovered during implementation review, not standards
  — this is a new file for prescriptive conventions.
- No SwiftLint rule yet, no call-site changes.

**Acceptance criteria:**
- `Localizable.xcstrings` exists with English locale.
- Project builds via XcodeGen regen.
- `docs/coding-standards.md` exists with the Localization section.
- No visible UI changes.

## Commit 2 — UI String Migration

Per-screen tasks, each following the TDD rhythm used in Sprint 4A/4B. Order is
dependency-driven: shared components first, since screens depend on them.

1. Shared DesignSystem (`Card`, `ComingSoonState`, `PrimaryButton`)
2. Shared Navigation chrome (if any string-bearing nav exists)
3. Onboarding
4. Home
5. Safari Protection
6. Advanced Filter Lists
7. Premium
8. Settings
9. About

**API convention:**
- Shared components take `LocalizedStringKey`-typed parameters, e.g.
  `PrimaryButton(titleKey: "onboarding.button.continue")`, so call sites pass
  keys, not raw strings.
- Screen call sites use bare `Text("key")` / `Label("key", ...)` — SwiftUI's
  native `LocalizedStringKey` resolves these against the catalog directly.
- `String(localized:)` is reserved for ViewModels, services, and any
  user-facing string built outside a native SwiftUI view context.

**Scope per task:** visible `Text`, `Button`, `Label`, navigation titles, and
empty-state copy in that file. Accessibility labels/hints and
`Alert`/`confirmationDialog` strings are explicitly deferred to Commit 3.

**Value formatting:** Any user-visible numeric, date, time, currency,
measurement, or byte-count value introduced or modified during migration must
use Swift's `FormatStyle` APIs (`Text(_:format:)`, `.formatted(_:)`, or
equivalent) rather than raw string interpolation — even though English/`en_US`
is the only shipped locale today. Localization answers "what text should be
displayed?"; formatting answers "how should values be rendered?" — orthogonal
concerns, and adopting the correct formatting API costs nothing extra while a
call site is already being touched.

```swift
// Preferred
Text(number, format: .number)
Text(date, format: .dateTime.month().day().year())
Text(price, format: .currency(code: currencyCode))
Text(duration, format: .time(pattern: .minuteSecond))
Text(fileSize, format: .byteCount(style: .file))

// Discouraged
Text("\(number)")
Text("\(date)")
Text("$\(price)")
```

Confirmed by codebase audit: only one call site currently interpolates a
value into UI text — `OnboardingView.swift:93`, `Text("\(number)")` (a plain
step-indicator integer). It migrates to `Text(number, format: .number)` as
part of the Onboarding task. No dates, currencies, measurements, or
pluralized counts currently exist in the UI, so this rule does not expand
Commit 2's scope — it only forecloses a new debt trail in files already being
edited.

**Per-task acceptance criteria:**
- All in-scope strings in that file replaced with catalog keys.
- Corresponding key + English value added to `Localizable.xcstrings`.
- Existing tests still pass; no test currently asserts on literal English
  text (confirm per task — if one does, migrate the assertion to check for
  the key instead).
- No visible UI regression.

**End-of-commit gate** (once all 9 files are migrated and clean):
- Add `.swiftlint.yml` at repo root (fresh — not present anywhere in the
  project today) defining `custom_rules.no_hardcoded_ui_string`: a regex rule
  banning string literals passed to `Text(`, `Label(`, `Button(` etc.
- Scope: lint the entire `ADBLX/` source tree (app target only — not the
  content-blocker extension targets, which have no UI), excluding `Tests/`,
  `Preview Content/`, and any `Generated/` directory. Deliberately wider than
  just `Features/`/`Navigation/`/`DesignSystem/`, so `App/`, `Components/`,
  `Utilities/`, and `Shared/` can't bypass the rule by omission.
- Add a `preBuildScripts` entry in `project.yml` running `swiftlint` as a
  build phase (requires `brew install swiftlint` on dev machines and CI —
  document this in `docs/coding-standards.md`).
- Rule severity: `error` from the start (introduced only once the tree is
  already clean, so it never breaks the build).

**Commit 2 closing acceptance criterion:**
> There are zero hardcoded user-visible strings anywhere under `ADBLX/`
> (excluding `Tests/`, `Preview Content/`, `Generated/`), except preview/demo
> content explicitly annotated with `// swiftlint:disable` and justified
> inline.
>
> Full build and `swift test` pass green with the SwiftLint rule active at
> `error` severity.

## Commit 3 — Localization Audit

Verification only — no new migration infrastructure, just closing gaps
Commit 2 deliberately deferred:

- Accessibility labels
- Accessibility hints
- Alerts
- Confirmation dialogs
- Error messages
- Success messages

**Acceptance criteria:**
- No remaining hardcoded user-facing literals anywhere in the above
  categories.
- Developer/debug strings, log messages, XCTest/Swift Testing descriptions,
  internal identifiers, analytics events, bundle identifiers, filter IDs, and
  manifest IDs remain in English and are explicitly out of scope — these are
  not user-visible.

## Coding rule going forward

> No new user-visible string may be hardcoded in SwiftUI. Every user-facing
> string must come from `Localizable.xcstrings`, enforced by the SwiftLint
> `no_hardcoded_ui_string` rule at `error` severity.

This prevents the codebase from drifting back to mixed localized/hardcoded
text as Sprint 5+ adds screens.
