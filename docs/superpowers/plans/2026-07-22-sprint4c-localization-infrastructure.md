# Sprint 4C — Localization Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all hardcoded English UI strings with a `Localizable.xcstrings` String Catalog and a frozen `<feature>.<component>.<purpose>` key convention, then lock the convention in place with a SwiftLint rule — so Sprint 5+ never reintroduces hardcoded UI strings.

**Architecture:** Three commits. Commit 1 adds the String Catalog and documents the convention with zero call-site changes (build stays green). Commit 2 migrates all 11 shared-component/screen files to catalog keys, file by file, then — only once the tree is fully clean — introduces a fresh SwiftLint rule at `error` severity as the closing gate. Commit 3 is a verification-only audit of accessibility strings, alerts, and confirmation dialogs that Commit 2 deliberately skipped.

**Tech Stack:** Swift 6, SwiftUI, Xcode String Catalogs (`.xcstrings`), XcodeGen (`project.yml`, `syncedFolder`), SwiftLint (new dependency), Swift Testing (existing test suite convention — this project does not use XCTest for unit tests).

## Global Constraints

- Every commit must leave `dev` buildable and green — never commit a build-breaking change, even temporarily (spec: Commit 1 §"Every commit... must leave dev buildable and green").
- Key naming convention is frozen: `<feature>.<component>.<purpose>` (e.g. `home.action.update`, `settings.row.about`, `onboarding.button.continue`). Never use the English phrase itself as a key.
- Shared components (`Card`, `PrimaryButton`, `ComingSoonState`, `SettingsRow`, `ToggleRow`, `PremiumBadge`) take `LocalizedStringKey`-typed parameters. Screen call sites use bare `Text("key")` / `Label("key", ...)` — SwiftUI's native `LocalizedStringKey` resolves against the catalog directly. `String(localized:)` is reserved for ViewModels, services, and non-SwiftUI-native contexts (e.g. `AppTab.title`, which is a plain `Foundation` enum, not a View).
- Any user-visible numeric, date, time, currency, measurement, or byte-count value touched during migration must use a Swift `FormatStyle` API (`Text(_:format:)`, `.formatted(_:)`) instead of raw string interpolation, even though English is the only shipped locale. Applies to exactly one call site in this plan: `OnboardingView.swift`'s `Text("\(number)")` step-indicator.
- Commit 2 scope per file is: visible `Text`, `Button`, `Label`, navigation titles, empty-state copy. Accessibility labels/hints and `Alert`/`confirmationDialog` strings are explicitly deferred to Commit 3 — do not migrate them in Commit 2 even when they appear in a file already being edited.
- Service-layer mock/seed data (`ProtectionService.swift`, `HomeService.swift`, `SubscriptionService.swift` — filter category names, subscription plan names, activity feed text) is out of scope for this entire sprint. Sprint 5 replaces these with live backend data.
- Developer/debug strings, log messages, test descriptions (`@Suite(...)`), internal identifiers, analytics events, bundle identifiers, filter IDs, and manifest IDs are never localized — they are not user-visible.
- No SwiftLint rule exists until the end of Commit 2. Introducing the rule while any file is still unmigrated would break the build, which the first constraint above forbids.

---

## File Manifest

**Create:**
- `ADBLX/Resources/Localizable.xcstrings` (Commit 1)
- `docs/coding-standards.md` (Commit 1)
- `.swiftlint.yml` (Commit 2, end-of-commit gate)

**Modify (Commit 2, one task per file, in dependency order):**
1. `ADBLX/DesignSystem/Components/Card.swift`
2. `ADBLX/DesignSystem/Components/ComingSoonState.swift`
3. `ADBLX/DesignSystem/Components/PrimaryButton.swift`
4. `ADBLX/DesignSystem/Components/SettingsRow.swift`
5. `ADBLX/DesignSystem/Components/ToggleRow.swift`
6. `ADBLX/DesignSystem/Components/PremiumBadge.swift`
7. `ADBLX/Navigation/AppTab.swift`
8. `ADBLX/Navigation/RootTabView.swift` (no literal changes needed — verify only)
9. `ADBLX/Features/Onboarding/OnboardingView.swift`
10. `ADBLX/Features/Home/HomeView.swift`
11. `ADBLX/Features/Protection/SafariProtectionView.swift`
12. `ADBLX/Features/Protection/DNSProtectionView.swift`
13. `ADBLX/Features/Protection/AdvancedFilterListsView.swift`
14. `ADBLX/Features/Premium/PremiumView.swift`
15. `ADBLX/Features/Settings/SettingsView.swift`
16. `ADBLX/Features/Settings/AboutView.swift`
17. `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift`
18. `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift`
19. `project.yml` (add SwiftLint build phase, end of Commit 2)

Also touched throughout Commit 2: `ADBLX/Resources/Localizable.xcstrings` (every task adds its keys).

---

## Commit 1: Localization Foundation

### Task 1: Create Localizable.xcstrings and document the convention

**Files:**
- Create: `ADBLX/Resources/Localizable.xcstrings`
- Create: `docs/coding-standards.md`

**Interfaces:**
- Produces: `Localizable.xcstrings` — an empty String Catalog (no keys yet; keys are added per-file in Commit 2) that Xcode/XcodeGen resolves automatically from `ADBLX/Resources/` via the existing `syncedFolder` wiring (confirmed: `project.yml` has no explicit `resources:` key today, and `ADBLX/Resources/blockerList.json` already resolves through the same mechanism).

- [ ] **Step 1: Create the String Catalog file**

A `.xcstrings` file is JSON. Create it with the minimal valid empty-catalog structure, English as the source language:

```json
{
  "sourceLanguage" : "en",
  "strings" : {

  },
  "version" : "1.0"
}
```

- [ ] **Step 2: Verify Xcode recognizes the catalog**

Run:
```bash
xcodegen generate
```
Expected: regenerates `ADBLX.xcodeproj` with no errors. Then build:
```bash
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
```
Expected: `** BUILD SUCCEEDED **`. If the catalog is not picked up (e.g. it doesn't appear in the built app bundle's `Contents`), add an explicit resource entry to the `ADBLX` target's `sources` list in `project.yml` pointing at `ADBLX/Resources/Localizable.xcstrings` and regenerate again. (Expected not to be necessary — `syncedFolder` already wires `ADBLX/Resources/blockerList.json` with no explicit entry.)

- [ ] **Step 3: Write the coding standards doc**

Create `docs/coding-standards.md`:

```markdown
# Coding Standards

Prescriptive conventions for this codebase. For pitfalls discovered during
implementation review, see `docs/gotchas.md` instead — this file is for
standards to follow going forward, not lessons already learned.

## Localization

All user-visible strings in SwiftUI views must come from
`ADBLX/Resources/Localizable.xcstrings`, never hardcoded.

### Key naming convention (frozen)

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

### API convention

- Shared DesignSystem components take `LocalizedStringKey`-typed parameters
  (e.g. `PrimaryButton(titleKey: "onboarding.button.continue")`) so call
  sites pass keys, not raw strings.
- Screen call sites use bare `Text("key")` / `Label("key", ...)` — SwiftUI's
  native `LocalizedStringKey` resolves these against the catalog directly.
- `String(localized:)` is reserved for ViewModels, services, and any
  user-facing string built outside a native SwiftUI view context (e.g. a
  plain `enum`/`struct` computed property consumed by a view, like
  `AppTab.title`).

### Value formatting

Any user-visible numeric, date, time, currency, measurement, or byte-count
value must use a Swift `FormatStyle` API (`Text(_:format:)`,
`.formatted(_:)`) instead of raw string interpolation — even though
English/`en_US` is the only shipped locale today.

```swift
// Preferred
Text(number, format: .number)
Text(date, format: .dateTime.month().day().year())
Text(price, format: .currency(code: currencyCode))

// Discouraged
Text("\(number)")
Text("\(date)")
```

### Enforcement

`.swiftlint.yml` (repo root) defines a `no_hardcoded_ui_string` custom rule
at `error` severity, run as a `preBuildScripts` phase in `project.yml`. It
scans all of `ADBLX/` (excluding `Tests/`, `Preview Content/`, `Generated/`)
for string literals passed to `Text(`, `Label(`, `Button(`. Requires
`brew install swiftlint` on dev machines and CI.

No new user-visible string may be hardcoded in SwiftUI. Every user-facing
string must come from `Localizable.xcstrings`.
```

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Resources/Localizable.xcstrings docs/coding-standards.md
git commit -m "docs+feat: add Localizable.xcstrings foundation and localization coding standard"
```

---

## Commit 2: UI String Migration

Each task below: add the file's keys to `Localizable.xcstrings`, replace every in-scope literal with its key, verify the existing test suite still passes (none of these files have View-layer tests that assert on literal copy — confirmed by audit: `ADBLXTests/Features/*ViewModelTests.swift` only match on `@Suite(...)` names and mock service data, never on UI copy), then commit.

`Localizable.xcstrings` entries are shown as `"key" : "value"` JSON fragments to merge into the `strings` object — exact indentation doesn't matter, valid JSON does.

### Task 2: Migrate Card.swift

**Files:**
- Modify: `ADBLX/DesignSystem/Components/Card.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none (leaf shared component)
- Produces: `Card<Content: View>` unchanged signature — `Card { ... }` trailing-closure API is untouched; only the `#Preview` block's literal content strings change.

- [ ] **Step 1: Add catalog keys**

`Card.swift`'s only literals are in its `#Preview` block (`"Safari Protection"`, `"Enabled"`) — preview-only content is not shipped UI, but per the spec's closing acceptance criterion ("zero hardcoded strings... except preview/demo content explicitly annotated with `// swiftlint:disable` and justified inline"), previews must either use catalog keys too or carry an explicit disable comment. Since these two strings already have real keys elsewhere in this migration (`protection.safari.title` from Task 11, `protection.status.enabled` — not yet defined), define a preview-local pair instead of forward-referencing a later task's key:

```json
"card.preview.title" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Safari Protection"
      }
    }
  }
},
"card.preview.status" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Enabled"
      }
    }
  }
}
```

- [ ] **Step 2: Replace the literals**

```swift
#Preview {
    Card {
        Text("card.preview.title")
        Text("card.preview.status")
    }
    .padding()
}
```

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all existing tests pass (this file has no dedicated test target — `Card` is exercised indirectly through screen views).

- [ ] **Step 4: Commit**

```bash
git add ADBLX/DesignSystem/Components/Card.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate Card.swift preview strings to Localizable.xcstrings"
```

### Task 3: Migrate ComingSoonState.swift

**Files:**
- Modify: `ADBLX/DesignSystem/Components/ComingSoonState.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: `ComingSoonState(title: LocalizedStringKey, message: LocalizedStringKey)` — **signature changes** from `(title: String, message: String)`. `DNSProtectionView.swift` (Task 12) is the only caller and is updated in that task; until Task 12 runs, `DNSProtectionView.swift` will not build. Both tasks must land together in the same session before the branch is otherwise touched, or this task's commit temporarily breaks the build — see Note below.

> **Sequencing note:** `ComingSoonState`'s only real call site (`DNSProtectionView.swift`) is migrated later in file order (Task 12), because Task 12 is grouped with the other screens for dependency-cleanliness. To honor the "never break the build" constraint, do this task and Task 12's `ComingSoonState(...)` call-site update **as one combined commit** instead of two — see Step 4.

- [ ] **Step 1: Add catalog keys**

```json
"comingsoon.label.badge" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Coming Soon"
      }
    }
  }
},
"protection.dns.title" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "DNS Protection"
      }
    }
  }
},
"protection.dns.message" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "System-wide DNS filtering blocks ads and trackers across every app on your device — entirely on-device, with nothing sent to a server. Available with Premium in a future update."
      }
    }
  }
}
```

- [ ] **Step 2: Change the component's parameter types and replace literals**

```swift
// ADBLX/DesignSystem/Components/ComingSoonState.swift
import SwiftUI

/// Static placeholder for P1 screens with no backend yet (Sprint 4 spec §3/§9).
/// No ViewModel — there is nothing to load or mutate.
struct ComingSoonState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(DesignColors.primary)
            Text(title)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
            Text(message)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Text("comingsoon.label.badge")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onPrimaryContainer)
                .padding(.horizontal, DesignSpacing.gutter)
                .padding(.vertical, DesignSpacing.base / 2)
                .background(DesignColors.primaryContainer)
                .clipShape(Capsule())
        }
        .padding(DesignSpacing.containerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ComingSoonState(
        title: "protection.dns.title",
        message: "protection.dns.message"
    )
}
```

- [ ] **Step 3: Update the only caller — DNSProtectionView.swift**

```swift
// ADBLX/Features/Protection/DNSProtectionView.swift
import SwiftUI

struct DNSProtectionView: View {
    var body: some View {
        ComingSoonState(
            title: "protection.dns.title",
            message: "protection.dns.message"
        )
        .background(DesignColors.background)
    }
}

#Preview {
    DNSProtectionView()
}
```

This is `DNSProtectionView.swift`'s entire migration — it has no other literals, so Task 12 in the file list above is satisfied by this step and needs no separate task.

- [ ] **Step 4: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass.

- [ ] **Step 5: Commit (both files together)**

```bash
git add ADBLX/DesignSystem/Components/ComingSoonState.swift ADBLX/Features/Protection/DNSProtectionView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate ComingSoonState and DNSProtectionView to Localizable.xcstrings"
```

### Task 4: Migrate PrimaryButton.swift

**Files:**
- Modify: `ADBLX/DesignSystem/Components/PrimaryButton.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: `PrimaryButton(titleKey: LocalizedStringKey, action: () -> Void)` — **signature and parameter name change** from `PrimaryButton(title: String, action: () -> Void)`. Callers: `OnboardingView.swift` (Task 9) and `UpdateProgressSheet.swift` (Task 18) both pass a literal today and must be updated to use `titleKey:` with a key argument in their own tasks.

- [ ] **Step 1: Add catalog key (preview only — real callers get their own keys in their own tasks)**

```json
"primarybutton.preview.title" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Reload Safari Blockers"
      }
    }
  }
}
```

- [ ] **Step 2: Rename the parameter and change its type**

```swift
// ADBLX/DesignSystem/Components/PrimaryButton.swift
import SwiftUI

/// The solid Privacy-Purple action button used throughout the app (Stitch
/// theme: "Primary buttons use a solid Privacy Purple fill with white text").
struct PrimaryButton: View {
    let titleKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSpacing.base * 1.5)
        }
        .background(DesignColors.primary)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.buttonCornerRadius))
    }
}

#Preview {
    PrimaryButton(titleKey: "primarybutton.preview.title") {}
        .padding()
}
```

> **Note:** this task's commit temporarily breaks compilation of `OnboardingView.swift` and `UpdateProgressSheet.swift` (both call `PrimaryButton(title:...)`, which no longer exists). Per the "never break the build" constraint, do **not** commit this task alone. Continue immediately to Steps 3–4 below, which fix both callers, and commit everything together.

- [ ] **Step 3: Fix the two existing callers' parameter label (keys land properly in Tasks 9 and 18 — this step only renames the label so the build succeeds now)**

In `ADBLX/Features/Onboarding/OnboardingView.swift`, line 64, change:
```swift
PrimaryButton(title: "Get Started", action: onFinish)
```
to:
```swift
PrimaryButton(titleKey: "Get Started", action: onFinish)
```

In `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift`, line 30, change:
```swift
PrimaryButton(title: "Done") { dismiss() }
```
to:
```swift
PrimaryButton(titleKey: "Done") { dismiss() }
```

These are placeholder literal-as-key values (SwiftUI's `LocalizedStringKey` is `ExpressibleByStringLiteral`, so `"Get Started"` compiles as a key whose value happens to equal itself via the catalog's automatic fallback). Task 9 and Task 18 replace these with real keys (`onboarding.button.getstarted`, `updateprogress.button.done`) and add matching catalog entries — this step exists only to keep the build green between now and then.

- [ ] **Step 4: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds (with the placeholder key labels from Step 3), all tests pass.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/DesignSystem/Components/PrimaryButton.swift ADBLX/Features/Onboarding/OnboardingView.swift ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate PrimaryButton to LocalizedStringKey API"
```

### Task 5: Migrate SettingsRow.swift

**Files:**
- Modify: `ADBLX/DesignSystem/Components/SettingsRow.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: `SettingsRow(titleKey: LocalizedStringKey, systemImage: String)` — **signature change** from `(title: String, systemImage: String)`. Caller: `SettingsView.swift` (Task 15) passes `title: "About"` today.

**Scope note:** `SettingsRow` has no accessibility-specific string of its own beyond `.accessibilityElement(children: .combine)` (which combines child accessibility text, not a literal) — nothing here is deferred to Commit 3.

- [ ] **Step 1: Add catalog key**

```json
"settings.row.about" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "About"
      }
    }
  }
}
```

- [ ] **Step 2: Rename the parameter and change its type**

```swift
// ADBLX/DesignSystem/Components/SettingsRow.swift
import SwiftUI

/// A navigation-style settings list row: icon, title, disclosure chevron.
struct SettingsRow: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    SettingsRow(titleKey: "settings.row.about", systemImage: "info.circle.fill")
        .padding()
}
```

- [ ] **Step 3: Fix the caller (SettingsView.swift line 64)**

Change:
```swift
SettingsRow(title: "About", systemImage: "info.circle.fill")
```
to:
```swift
SettingsRow(titleKey: "settings.row.about", systemImage: "info.circle.fill")
```

This is `SettingsView.swift`'s `SettingsRow(...)` call site only — the rest of `SettingsView.swift`'s literals are migrated in Task 15.

- [ ] **Step 4: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/DesignSystem/Components/SettingsRow.swift ADBLX/Features/Settings/SettingsView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate SettingsRow to LocalizedStringKey API"
```

### Task 6: Migrate ToggleRow.swift

**Files:**
- Modify: `ADBLX/DesignSystem/Components/ToggleRow.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: `ToggleRow(titleKey: LocalizedStringKey, subtitleKey: LocalizedStringKey, isOn: Binding<Bool>)` — **signature change**. No real callers exist in shipped screens today (grep found only the `#Preview` block uses it directly; `AdvancedFilterListsView.swift` and `SafariProtectionView.swift` use inline `Toggle("", isOn:...)`, not `ToggleRow`) — this task only touches `ToggleRow.swift` itself.

**Scope note:** `ToggleRow`'s `.accessibilityValue(isOn ? "On" : "Off")` (line 29) is accessibility scope — **do not migrate it in this task**; it is Commit 3's responsibility. Only `title`/`subtitle` (visible `Text`) are in scope here.

- [ ] **Step 1: Add catalog key (preview only, since there's no shipped caller yet)**

```json
"togglerow.preview.title" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Ads"
      }
    }
  }
},
"togglerow.preview.subtitle" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Blocks display and video ads"
      }
    }
  }
}
```

- [ ] **Step 2: Rename parameters, change types — leave the accessibilityValue line untouched**

```swift
// ADBLX/DesignSystem/Components/ToggleRow.swift
import SwiftUI

/// A titled, subtitled row ending in a Toggle. Stitch theme: switches use full
/// pill-shaping and the Privacy Purple "on" tint with a spring-animated transition.
struct ToggleRow: View {
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(titleKey)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(subtitleKey)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(DesignColors.primary)
                .animation(.spring, value: isOn)
        }
        .accessibilityElement(children: .combine)
        // Deferred to Commit 3 (accessibility audit): accessibilityLabel(title)
        // used to read `title: String` directly; now `titleKey` is a
        // LocalizedStringKey with no String value to hand to
        // accessibilityLabel(_:). Commit 3 resolves this alongside the
        // accessibilityValue below — do not fix ad hoc here.
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

#Preview {
    ToggleRow(titleKey: "togglerow.preview.title", subtitleKey: "togglerow.preview.subtitle", isOn: .constant(true))
        .padding()
}
```

> **Correctness note:** the original code had `.accessibilityLabel(title)` (line 28) using the now-removed `String` parameter — this line does not compile as-is once `title` becomes `titleKey: LocalizedStringKey`. Since accessibility strings are Commit 3's scope, **remove the `.accessibilityLabel(title)` line entirely in this task** (not replace it) — `.accessibilityElement(children: .combine)` already combines the row's visible text into the accessibility tree without it, so removing it does not regress accessibility; Commit 3 decides whether an explicit label is still needed.

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/DesignSystem/Components/ToggleRow.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate ToggleRow to LocalizedStringKey API"
```

### Task 7: Migrate PremiumBadge.swift

**Files:**
- Modify: `ADBLX/DesignSystem/Components/PremiumBadge.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: `PremiumBadge(textKey: LocalizedStringKey = "premium.badge.label")` — **signature change** from `(text: String = "Premium")`. No callers pass an explicit argument anywhere in the codebase (grep confirms only `PremiumBadge()` with the default is used, in `SettingsView.swift`), so no caller needs updating.

- [ ] **Step 1: Add catalog key**

```json
"premium.badge.label" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Premium"
      }
    }
  }
}
```

- [ ] **Step 2: Change the parameter type and default**

```swift
// ADBLX/DesignSystem/Components/PremiumBadge.swift
import SwiftUI

struct PremiumBadge: View {
    var textKey: LocalizedStringKey = "premium.badge.label"

    var body: some View {
        Text(textKey)
            .font(DesignTypography.labelCaps)
            .foregroundStyle(DesignColors.onTertiary)
            .padding(.horizontal, DesignSpacing.gutter)
            .padding(.vertical, DesignSpacing.base / 2)
            .background(DesignColors.tertiary)
            .clipShape(Capsule())
    }
}

#Preview {
    PremiumBadge()
}
```

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/DesignSystem/Components/PremiumBadge.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate PremiumBadge to LocalizedStringKey API"
```

### Task 8: Migrate AppTab.swift (Shared Navigation)

**Files:**
- Modify: `ADBLX/Navigation/AppTab.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: `AppTab.title: String` — type is **unchanged** (still `String`, not `LocalizedStringKey`). `AppTab` is a plain `Foundation` enum, not a SwiftUI View, and `RootTabView.swift` passes `tab.title` into `Label(tab.title, systemImage:...)`, whose first parameter is `LocalizedStringKey` — but `String` still bridges into `LocalizedStringKey` via `ExpressibleByStringLiteral`'s counterpart only for literals, not runtime values, so this must use `String(localized:)` per the global constraint ("reserved for ViewModels, services, and non-SwiftUI-native contexts").

- [ ] **Step 1: Add catalog keys**

```json
"navigation.tab.home" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Home"
      }
    }
  }
},
"navigation.tab.protection" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Protection"
      }
    }
  }
},
"navigation.tab.premium" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Premium"
      }
    }
  }
},
"navigation.tab.settings" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Settings"
      }
    }
  }
}
```

- [ ] **Step 2: Replace the literals with String(localized:)**

```swift
// ADBLX/Navigation/AppTab.swift
import Foundation

/// The four frozen top-level destinations (Sprint 4 spec §3). Adding a fifth tab
/// requires a product decision, not just a code change — see the spec's
/// "explicitly excluded" list before adding anything here.
enum AppTab: CaseIterable {
    case home
    case protection
    case premium
    case settings

    var title: String {
        switch self {
        case .home: return String(localized: "navigation.tab.home")
        case .protection: return String(localized: "navigation.tab.protection")
        case .premium: return String(localized: "navigation.tab.premium")
        case .settings: return String(localized: "navigation.tab.settings")
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .protection: return "shield.fill"
        case .premium: return "star.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
```

`RootTabView.swift` needs no change — `Label(tab.title, systemImage: tab.systemImage)` already receives a `String`, and `Label`'s initializer accepts `String` directly (it does not require `LocalizedStringKey` when given a runtime `String`); the string itself is now sourced from the catalog rather than hardcoded.

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. Manually verify (or add a quick Swift Testing check) that `AppTab.home.title == "Home"` still holds so no test silently regresses on tab labels — search first:
```bash
grep -rn "AppTab" ADBLXTests/
```
Expected: no matches (confirmed no existing test references `AppTab` today) — no test to update.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Navigation/AppTab.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate AppTab.title to Localizable.xcstrings"
```

### Task 9: Migrate OnboardingView.swift

**Files:**
- Modify: `ADBLX/Features/Onboarding/OnboardingView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PrimaryButton(titleKey: LocalizedStringKey, action: () -> Void)` from Task 4.
- Produces: no public API change — `OnboardingView` itself has no parameters that change type.

**Scope note:** this file's `stepRow(number: Int, text: String)` interpolates a plain integer (`Text("\(number)")`, line 93) — per the Global Constraints' value-formatting rule, this becomes `Text(number, format: .number)`. The `text:` parameter stays `String` (it's a private helper, not called with anything but static English literals that are themselves migrated) — but see Step 2: it's simpler and more consistent to make `stepRow`'s `text` parameter `LocalizedStringKey` too, matching `featureRow`.

- [ ] **Step 1: Add catalog keys**

```json
"onboarding.title.app" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "ADBLX"
      }
    }
  }
},
"onboarding.subtitle.tagline" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Browse the web in total peace."
      }
    }
  }
},
"onboarding.feature.privacy.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Privacy First" } } }
},
"onboarding.feature.privacy.body" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Blocks trackers before they ever load — nothing about your browsing leaves your device." } } }
},
"onboarding.feature.speed.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Pure Speed" } } }
},
"onboarding.feature.speed.body" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Pages load faster with ads and trackers stripped out before rendering." } } }
},
"onboarding.feature.simplicity.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Simplicity" } } }
},
"onboarding.feature.simplicity.body" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "One toggle. No configuration required." } } }
},
"onboarding.section.activation" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Activation" } } }
},
"onboarding.instruction.enable" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "To start blocking, please enable ADBLX in your Safari settings." } } }
},
"onboarding.step.openSettings" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Open Settings and tap Safari." } } }
},
"onboarding.step.tapExtensions" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Tap Extensions or Content Blockers." } } }
},
"onboarding.step.turnOn" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Turn on all ADBLX switches." } } }
},
"onboarding.section.staySecure.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Stay Secure" } } }
},
"onboarding.section.staySecure.body" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "We'll let you know when filter updates are ready, with a weekly security report." } } }
},
"onboarding.button.getStarted" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Get Started" } } }
},
"onboarding.button.skip" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Skip for now" } } }
}
```

- [ ] **Step 2: Replace every literal, including the numeric FormatStyle fix and stepRow's text→textKey rename**

```swift
// ADBLX/Features/Onboarding/OnboardingView.swift
import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                VStack(spacing: DesignSpacing.stackGap) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 56))
                        .foregroundStyle(DesignColors.primary)
                    Text("onboarding.title.app")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("onboarding.subtitle.tagline")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Card {
                    featureRow(icon: "lock.shield.fill", titleKey: "onboarding.feature.privacy.title", bodyKey: "onboarding.feature.privacy.body")
                    Divider()
                    featureRow(icon: "bolt.fill", titleKey: "onboarding.feature.speed.title", bodyKey: "onboarding.feature.speed.body")
                    Divider()
                    featureRow(icon: "checkmark.seal.fill", titleKey: "onboarding.feature.simplicity.title", bodyKey: "onboarding.feature.simplicity.body")
                }

                VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
                    Text("onboarding.section.activation")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("onboarding.instruction.enable")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                    Card {
                        stepRow(number: 1, textKey: "onboarding.step.openSettings")
                        Divider()
                        stepRow(number: 2, textKey: "onboarding.step.tapExtensions")
                        Divider()
                        stepRow(number: 3, textKey: "onboarding.step.turnOn")
                    }
                }

                Card {
                    HStack(alignment: .top, spacing: DesignSpacing.gutter) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(DesignColors.secondary)
                        VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                            Text("onboarding.section.staySecure.title")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Text("onboarding.section.staySecure.body")
                                .font(DesignTypography.bodySmall)
                                .foregroundStyle(DesignColors.onSurfaceVariant)
                        }
                    }
                }

                VStack(spacing: DesignSpacing.stackGap) {
                    PrimaryButton(titleKey: "onboarding.button.getStarted", action: onFinish)
                    Button("onboarding.button.skip", action: onFinish)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private func featureRow(icon: String, titleKey: LocalizedStringKey, bodyKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Image(systemName: icon)
                .foregroundStyle(DesignColors.primary)
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(titleKey)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(bodyKey)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(number: Int, textKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Text(number, format: .number)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onPrimary)
                .frame(width: 24, height: 24)
                .background(DesignColors.primary)
                .clipShape(Circle())
            Text(textKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
```

Note this replaces the placeholder `PrimaryButton(titleKey: "Get Started", ...)` from Task 4 Step 3 with the real key `onboarding.button.getStarted` — the placeholder and the real key resolve to the same displayed text (`"Get Started"`) either way, since `LocalizedStringKey` falls back to its literal value when no catalog entry matches, so there is no user-visible change at any point in this sequence.

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass.
```bash
grep -rn "OnboardingView\b" ADBLXTests/
```
Expected: no matches — confirmed no test targets `OnboardingView` directly (only `OnboardingCompletionStoreTests.swift`, a different type).

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Onboarding/OnboardingView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate OnboardingView to Localizable.xcstrings"
```

### Task 10: Migrate HomeView.swift

**Files:**
- Modify: `ADBLX/Features/Home/HomeView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none (no shared-component signature changes affect this file — it does not call `PrimaryButton`, `Card`, `SettingsRow`, `ToggleRow`, or `PremiumBadge`).
- Produces: no public API change.

**Scope note:** line 121's `"\(String(format: "%.1f", status.blockedPercentage))% Blocked"` mixes a formatted percentage with static English (`"% Blocked"`). Per the value-formatting rule, the percentage itself should use `.formatted()`; the surrounding `"% Blocked"` text is a genuine UI string needing a catalog key. Because these are combined into one interpolated string passed to `statTile(detail:)` (a `String` parameter, not `Text`), the cleanest fix within this task's scope is to build the detail string from a localized format key with an interpolated formatted number — see Step 2.

- [ ] **Step 1: Add catalog keys**

```json
"home.title.app" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "ADBLX" } } }
},
"home.status.active" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Active" } } }
},
"home.status.inactive" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Inactive" } } }
},
"home.status.enabledDetail" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "System-wide protection is enabled" } } }
},
"home.status.disabledDetail" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Protection is off" } } }
},
"home.badge.secure" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "SECURE" } } }
},
"home.section.monitoring" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "System Monitoring" } } }
},
"home.stat.safari.label" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Safari" } } }
},
"home.stat.safari.value" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Enabled" } } }
},
"home.stat.safari.detail" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "%@%% Blocked" } } }
},
"home.stat.dns.label" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "DNS" } } }
},
"home.stat.dns.detail" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Encrypted" } } }
},
"home.stat.lastUpdate.label" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Last Update" } } }
},
"home.stat.rules.label" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Rules" } } }
},
"home.section.quickControl" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Quick Control" } } }
},
"home.action.updateFilters" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Update Filters" } } }
},
"home.action.reloadSafari" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Reload Safari Blockers" } } }
},
"home.section.recentActivity" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Recent Activity" } } }
}
```

- [ ] **Step 2: Replace every literal**

```swift
// ADBLX/Features/Home/HomeView.swift
import SwiftUI

struct HomeView: View {
    @State var viewModel: HomeViewModel
    @State private var isShowingUpdateProgress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                if let status = viewModel.status {
                    heroCard(for: status)
                    monitoringGrid(for: status)
                    quickControls
                    activityFeed(for: status.recentActivity)
                }
            }
            .padding(.horizontal, DesignSpacing.containerPadding)
            .padding(.top, DesignSpacing.sectionGap)
        }
        .background(DesignColors.background)
        .safeAreaInset(edge: .top) { topBar }
        .task { await viewModel.load() }
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            HStack(spacing: DesignSpacing.gutter / 2) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(DesignColors.primary)
                Text("home.title.app")
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(DesignColors.primary)
            }
            Spacer()
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .padding(.trailing, DesignSpacing.containerPadding)
        }
        .padding(.vertical, DesignSpacing.gutter)
        .background(.ultraThinMaterial)
    }

    private func heroCard(for status: HomeStatus) -> some View {
        VStack(spacing: DesignSpacing.sectionGap / 1.5) {
            ZStack {
                Circle()
                    .fill(DesignColors.secondary.opacity(0.1))
                    .strokeBorder(DesignColors.secondary.opacity(0.2), lineWidth: 1)
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(DesignColors.secondary)
            }

            VStack(spacing: DesignSpacing.base) {
                Text(status.isProtectionEnabled ? "home.status.active" : "home.status.inactive")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(status.isProtectionEnabled
                     ? "home.status.enabledDetail"
                     : "home.status.disabledDetail")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: DesignSpacing.gutter) {
                pillBadge {
                    Circle()
                        .fill(DesignColors.secondary)
                        .frame(width: 8, height: 8)
                    Text("home.badge.secure")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(DesignColors.secondary)
                }
                pillBadge {
                    Text("v4.2.0")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
        }
        .padding(DesignSpacing.sectionGap)
        .frame(maxWidth: .infinity)
        .background(DesignColors.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .overlay(
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private func pillBadge(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: DesignSpacing.base) {
            content()
        }
        .padding(.horizontal, DesignSpacing.gutter)
        .padding(.vertical, DesignSpacing.base * 2)
        .background(Color.white.opacity(0.05))
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func monitoringGrid(for status: HomeStatus) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("home.section.monitoring")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.gutter) {
                statTile(icon: "safari", labelKey: "home.stat.safari.label", value: String(localized: "home.stat.safari.value"), detail: String(format: String(localized: "home.stat.safari.detail"), status.blockedPercentage.formatted(.number.precision(.fractionLength(1)))), detailColor: DesignColors.secondary, iconColor: DesignColors.primary)
                statTile(icon: "network", labelKey: "home.stat.dns.label", value: status.dnsProviderName, detail: String(localized: "home.stat.dns.detail"), detailColor: DesignColors.onSurfaceVariant, iconColor: DesignColors.tertiary)
                statTile(icon: "arrow.triangle.2.circlepath", labelKey: "home.stat.lastUpdate.label", value: status.lastUpdateDescription, detail: nil, detailColor: DesignColors.onSurfaceVariant, iconColor: .orange)
                statTile(icon: "list.bullet.rectangle", labelKey: "home.stat.rules.label", value: status.ruleCount.formatted(), detail: nil, detailColor: DesignColors.onSurfaceVariant, iconColor: DesignColors.secondary)
            }
        }
    }

    private func statTile(icon: String, labelKey: LocalizedStringKey, value: String, detail: String?, detailColor: Color, iconColor: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            HStack(spacing: DesignSpacing.base) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(labelKey)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.outlineVariant)
            }
            Text(value)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onSurface)
            if let detail {
                Text(detail)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(detailColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .overlay(
            RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("home.section.quickControl")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)

            Button {
                isShowingUpdateProgress = true
            } label: {
                HStack {
                    Label("home.action.updateFilters", systemImage: "arrow.triangle.2.circlepath")
                        .font(DesignTypography.bodyLarge)
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .opacity(0.5)
                }
                .foregroundStyle(DesignColors.onPrimary)
                .padding(DesignSpacing.containerPadding)
                .background(DesignColors.primaryContainer)
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            }

            Button {
                Task { await viewModel.load() }
            } label: {
                HStack {
                    Label("home.action.reloadSafari", systemImage: "arrow.clockwise")
                        .font(DesignTypography.bodyLarge)
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .opacity(0.3)
                }
                .foregroundStyle(DesignColors.onSurface)
                .padding(DesignSpacing.containerPadding)
                .background(DesignColors.surfaceContainerLowest)
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }

    private func activityFeed(for entries: [HomeActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("home.section.recentActivity")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.outlineVariant)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    activityRow(entry)
                    if index < entries.count - 1 {
                        Divider().overlay(Color.white.opacity(0.05))
                    }
                }
            }
            .background(DesignColors.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
    }

    private func activityRow(_ entry: HomeActivityEntry) -> some View {
        HStack(spacing: DesignSpacing.containerPadding) {
            ZStack {
                Circle()
                    .fill(activityColor(for: entry.kind).opacity(0.1))
                    .frame(width: 40, height: 40)
                Image(systemName: activityIcon(for: entry.kind))
                    .font(.caption)
                    .foregroundStyle(activityColor(for: entry.kind))
            }
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(entry.title)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurface)
                Text(entry.subtitle)
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.outlineVariant)
            }
            Spacer()
            Text(entry.timestamp)
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outlineVariant)
        }
        .padding(DesignSpacing.containerPadding)
        .accessibilityElement(children: .combine)
    }

    private func activityIcon(for kind: HomeActivityEntry.Kind) -> String {
        switch kind {
        case .trackerBlocked: return "hand.raised.slash.fill"
        case .filtersSynchronized: return "checkmark.circle.fill"
        case .protectionToggled: return "lock.shield.fill"
        }
    }

    private func activityColor(for kind: HomeActivityEntry.Kind) -> Color {
        switch kind {
        case .trackerBlocked: return DesignColors.error
        case .filtersSynchronized: return DesignColors.secondary
        case .protectionToggled: return DesignColors.primary
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(service: MockHomeService()))
}
```

`entry.title`, `entry.subtitle`, `entry.timestamp` (lines 239, 242, 247 originally) are **not** migrated here — they come from `HomeActivityEntry`, populated by `HomeService.swift`'s mock data, which is explicitly out of scope per the Global Constraints (service-layer mock/seed data).

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. `HomeViewModelTests.swift` tests the ViewModel/mock data layer, not view copy — confirmed no assertion on any string migrated in this task.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Home/HomeView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate HomeView to Localizable.xcstrings"
```

### Task 11: Migrate SafariProtectionView.swift

**Files:**
- Modify: `ADBLX/Features/Protection/SafariProtectionView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none (no shared-component signature changes used here directly, though `NavigationLink("Upgrade") { ... }` uses `NavigationLink`'s `String`/`LocalizedStringKey` init the same way `Text` does).
- Produces: no public API change.

**Scope note:** `"4,281 Threats Blocked"` (line 51) is mock/demo data hardcoded directly in the view (not sourced from `ProtectionService`), so it is in scope here (not the service-layer exclusion, which only covers strings actually returned by service methods). Since it mixes a formatted count with static text, split it the same way as Task 10's percentage: a localized format string with a formatted number substituted in.

- [ ] **Step 1: Add catalog keys**

```json
"protection.safari.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Safari Protection" } } }
},
"protection.safari.subtitle" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Highly optimized content blocking for a faster, cleaner browsing experience on iOS." } } }
},
"protection.safari.badge.active" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "ACTIVE PROTECTION" } } }
},
"protection.safari.stat.threatsBlocked" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "%@ Threats Blocked" } } }
},
"protection.safari.stat.period" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Last 24 hours on Safari" } } }
},
"protection.section.configuration" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Configuration" } } }
},
"protection.row.advancedFilterLists" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Advanced Filter Lists" } } }
},
"protection.row.dnsProtection" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "DNS Protection" } } }
},
"protection.row.speedOptimization" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Speed Optimization" } } }
},
"premium.badge.upsellLabel" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "ADBLX PREMIUM" } } }
},
"premium.upsell.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Unlock AI Blocking" } } }
},
"premium.upsell.body" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Zero-day threat detection and custom domain firewalling." } } }
},
"premium.action.upgrade" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Upgrade" } } }
}
```

- [ ] **Step 2: Replace every literal**

```swift
// ADBLX/Features/Protection/SafariProtectionView.swift
import SwiftUI

struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel
    @State private var isShowingUpdateProgress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                header

                if let status = viewModel.status {
                    heroCard
                    categoryGrid(for: status)
                    configurationList
                    premiumUpsell
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("protection.safari.title")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onSurface)
            Text("protection.safari.subtitle")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Spacer()
            HStack(spacing: DesignSpacing.base) {
                Circle()
                    .fill(DesignColors.secondary)
                    .frame(width: 8, height: 8)
                Text("protection.safari.badge.active")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.secondary)
            }
            Text(String(format: String(localized: "protection.safari.stat.threatsBlocked"), 4281.formatted()))
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(.white)
            Text("protection.safari.stat.period")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.containerPadding)
        .frame(height: 176)
        .background(DesignColors.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius))
    }

    private func categoryGrid(for status: ProtectionStatus) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSpacing.stackGap) {
            ForEach(Array(status.categories.enumerated()), id: \.element.id) { index, category in
                categoryTile(category, index: index)
            }
        }
    }

    private func categoryTile(_ category: ProtectionCategory, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(categoryIconColor(category.id).opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: categoryIcon(category.id))
                        .foregroundStyle(categoryIconColor(category.id))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.status?.categories[index].isEnabled ?? false },
                    set: { _ in Task { await viewModel.toggleCategory(category.id) } }
                ))
                .labelsHidden()
                .tint(DesignColors.primary)
            }
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(category.name)
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(DesignColors.onSurface)
                Text(category.description)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
                    .lineLimit(2)
            }
        }
        .padding(DesignSpacing.containerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColors.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .accessibilityElement(children: .combine)
    }

    private func categoryIcon(_ id: FilterCategoryID) -> String {
        switch id {
        case .ads: return "hand.raised.slash.fill"
        case .privacy: return "eye.slash.fill"
        case .annoyances: return "hand.tap.fill"
        case .regional: return "globe"
        }
    }

    private func categoryIconColor(_ id: FilterCategoryID) -> Color {
        switch id {
        case .ads: return DesignColors.primary
        case .privacy: return DesignColors.tertiary
        case .annoyances: return DesignColors.onSurface
        case .regional: return DesignColors.primary
        }
    }

    private var configurationList: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("protection.section.configuration")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)

            VStack(spacing: 0) {
                NavigationLink {
                    AdvancedFilterListsView(viewModel: viewModel)
                } label: {
                    configurationRow(icon: "line.3.horizontal.decrease.circle.fill", iconColor: DesignColors.primary, titleKey: "protection.row.advancedFilterLists", detail: "4 Enabled")
                }
                Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                NavigationLink {
                    DNSProtectionView()
                } label: {
                    configurationRow(icon: "lock.shield.fill", iconColor: DesignColors.tertiary, titleKey: "protection.row.dnsProtection", detail: "Cloudflare")
                }
                Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                configurationRow(icon: "bolt.fill", iconColor: DesignColors.primary, titleKey: "protection.row.speedOptimization", detail: nil)
            }
            .background(DesignColors.surfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        }
    }

    private func configurationRow(icon: String, iconColor: Color, titleKey: LocalizedStringKey, detail: String?) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            if let detail {
                Text(detail)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .padding(DesignSpacing.containerPadding)
        .contentShape(Rectangle())
    }

    private var premiumUpsell: some View {
        HStack(spacing: DesignSpacing.containerPadding) {
            VStack(alignment: .leading, spacing: DesignSpacing.base) {
                Text("premium.badge.upsellLabel")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, DesignSpacing.gutter)
                    .padding(.vertical, DesignSpacing.base / 2)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())
                Text("premium.upsell.title")
                    .font(DesignTypography.headlineMedium)
                    .foregroundStyle(.white)
                Text("premium.upsell.body")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            NavigationLink("premium.action.upgrade") {
                PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
            }
            .font(DesignTypography.bodyLarge)
            .fontWeight(.bold)
            .foregroundStyle(DesignColors.primaryContainer)
            .padding(.horizontal, DesignSpacing.containerPadding)
            .padding(.vertical, DesignSpacing.base * 2)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
        .padding(DesignSpacing.sectionGap)
        .background(
            LinearGradient(colors: [DesignColors.primaryContainer, DesignColors.tertiaryContainer], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

#Preview {
    NavigationStack {
        SafariProtectionView(viewModel: ProtectionViewModel(service: MockProtectionService()))
    }
}
```

`"4 Enabled"` and `"Cloudflare"` (the `detail:` arguments) are left as-is — they are dynamic-looking but are themselves still hardcoded demo values in this view (not from a service); they are plain `String`, not `Text`, so they don't hit the SwiftLint rule's `Text(`/`Label(`/`Button(` pattern, and migrating them is a judgment call outside this task's enumerated scope (the spec's per-file scope is `Text`, `Button`, `Label`, nav titles, empty-state copy — `configurationRow`'s `detail: String?` parameter renders through `Text(detail)`, which **is** in scope). Correction: since `detail` does render through `Text(detail)` inside `configurationRow`, add keys for these two values as well:

```json
"protection.row.advancedFilterLists.detail" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "4 Enabled" } } }
},
"protection.row.dnsProtection.detail" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Cloudflare" } } }
}
```

and change the two call sites to pass `LocalizedStringKey?` instead of `String?`:

```swift
configurationRow(icon: "line.3.horizontal.decrease.circle.fill", iconColor: DesignColors.primary, titleKey: "protection.row.advancedFilterLists", detailKey: "protection.row.advancedFilterLists.detail")
...
configurationRow(icon: "lock.shield.fill", iconColor: DesignColors.tertiary, titleKey: "protection.row.dnsProtection", detailKey: "protection.row.dnsProtection.detail")
...
configurationRow(icon: "bolt.fill", iconColor: DesignColors.primary, titleKey: "protection.row.speedOptimization", detailKey: nil)
```

and update `configurationRow`'s signature to `detailKey: LocalizedStringKey?` with `if let detailKey { Text(detailKey) ... }`.

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. Confirmed no test targets `SafariProtectionView` (`ProtectionViewModelTests.swift` tests the ViewModel, not view copy).

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Protection/SafariProtectionView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate SafariProtectionView to Localizable.xcstrings"
```

### Task 12: Migrate AdvancedFilterListsView.swift

**Files:**
- Modify: `ADBLX/Features/Protection/AdvancedFilterListsView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: no public API change.

**Scope note:** `.accessibilityValue(list.isEnabled ? "On" : "Off")` (line 90) and `.accessibilityLabel(list.isPremium ? "\(list.name), premium" : list.name)` (line 89) are accessibility strings — **deferred to Commit 3**, do not touch in this task. `FilterCategoryID.displayName` (lines 126-133, `"Ads"`/`"Privacy"`/`"Annoyances"`/`"Regional"`) renders through `Text(title)` at line 43 (`categorySection(title:...)`), so it is in scope — but it's a computed property on a type, not a View, so it uses `String(localized:)` per the same pattern as `AppTab.title` (Task 8).

- [ ] **Step 1: Add catalog keys**

```json
"protection.filterLists.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Filter Lists" } } }
},
"protection.filterLists.subtitle" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Customize your blocking experience by enabling specialized community-maintained lists." } } }
},
"protection.category.ads" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Ads" } } }
},
"protection.category.privacy" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Privacy" } } }
},
"protection.category.annoyances" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Annoyances" } } }
},
"protection.category.regional" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Regional" } } }
},
"protection.action.applyChanges" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Apply Changes" } } }
}
```

- [ ] **Step 2: Replace literals — leave both accessibility lines untouched**

```swift
// ADBLX/Features/Protection/AdvancedFilterListsView.swift
import SwiftUI

struct AdvancedFilterListsView: View {
    @State var viewModel: ProtectionViewModel
    @State private var isApplying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                header

                if let lists = viewModel.status?.filterLists {
                    ForEach(FilterCategoryID.allCasesForDisplay, id: \.self) { category in
                        let listsInCategory = lists.filter { $0.category == category }
                        if !listsInCategory.isEmpty {
                            categorySection(titleKey: category.displayNameKey, lists: listsInCategory)
                        }
                    }
                }
            }
            .padding(DesignSpacing.containerPadding)
            .padding(.bottom, 96)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .safeAreaInset(edge: .bottom) { applyChangesButton }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("protection.filterLists.title")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onSurface)
            Text("protection.filterLists.subtitle")
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
        }
    }

    private func categorySection(titleKey: LocalizedStringKey, lists: [FilterListEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text(titleKey)
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(lists.enumerated()), id: \.element.id) { index, list in
                    filterListRow(list)
                    if index < lists.count - 1 {
                        Divider().overlay(Color.white.opacity(0.05))
                    }
                }
            }
            .background(DesignColors.surfaceContainerLow)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
    }

    private func filterListRow(_ list: FilterListEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                HStack(spacing: DesignSpacing.base) {
                    Text(list.name)
                        .font(DesignTypography.bodyLarge)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignColors.onSurface)
                    if list.isPremium {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(DesignColors.tertiary)
                    }
                }
                Text("v\(list.version)")
                    .font(DesignTypography.labelCaps)
                    .foregroundStyle(DesignColors.primary.opacity(0.6))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { _ in Task { await viewModel.toggleFilterList(list.id) } }
            ))
            .labelsHidden()
            .tint(DesignColors.primaryContainer)
        }
        .padding(DesignSpacing.containerPadding)
        .accessibilityElement(children: .combine)
        // Deferred to Commit 3 (accessibility audit) — do not migrate these two lines here.
        .accessibilityLabel(list.isPremium ? "\(list.name), premium" : list.name)
        .accessibilityValue(list.isEnabled ? "On" : "Off")
    }

    private var applyChangesButton: some View {
        Button {
            isApplying = true
            Task {
                await viewModel.load()
                isApplying = false
            }
        } label: {
            HStack {
                if isApplying {
                    ProgressView().tint(.white)
                } else {
                    Text("protection.action.applyChanges")
                        .font(DesignTypography.bodyLarge)
                        .fontWeight(.semibold)
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSpacing.gutter)
            .background(DesignColors.primaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius))
        }
        .disabled(isApplying)
        .padding(DesignSpacing.containerPadding)
        .background(.ultraThinMaterial)
    }
}

private extension FilterCategoryID {
    static let allCasesForDisplay: [FilterCategoryID] = [.ads, .privacy, .annoyances, .regional]

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .ads: return "protection.category.ads"
        case .privacy: return "protection.category.privacy"
        case .annoyances: return "protection.category.annoyances"
        case .regional: return "protection.category.regional"
        }
    }
}

#Preview {
    AdvancedFilterListsView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
```

Note: `displayName: String` becomes `displayNameKey: LocalizedStringKey` (not `String(localized:)`) because this property only ever feeds directly into `Text(titleKey:)` inside the same file — unlike `AppTab.title`, it's never read as a plain `String` elsewhere, so there's no need to resolve it eagerly.

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. `ProtectionViewModelTests.swift` (checked in Global Constraints audit) asserts on `ProtectionCategory(name: "Ads", ...)` mock data, not on `FilterCategoryID.displayName` — no test breakage expected, but re-run to confirm.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Protection/AdvancedFilterListsView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate AdvancedFilterListsView to Localizable.xcstrings"
```

### Task 13: Migrate PremiumView.swift

**Files:**
- Modify: `ADBLX/Features/Premium/PremiumView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: no public API change.

**Scope note:** `plan.name`, `plan.billingPeriodDescription`, `plan.priceDescription` (lines 85, 88, 94) come from `SubscriptionService.swift`'s mock `SubscriptionPlan` data — out of scope (service-layer mock data). `comparisonRow(feature: String, ...)`'s `feature:` argument strings (`"Safari Blocking"`, `"DNS Protection"`, `"Auto Updates"`, `"Premium Themes"`, lines 176-179) are hardcoded directly in this view (not from a service) and render through `Text(feature)` at line 211 — in scope.

- [ ] **Step 1: Add catalog keys**

```json
"premium.hero.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Unlock Ultimate Privacy" } } }
},
"premium.hero.subtitle" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Experience a faster, cleaner, and safer web without limits." } } }
},
"premium.section.selectPlan" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Select a Plan" } } }
},
"premium.badge.bestValue" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Best Value" } } }
},
"premium.section.power" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Premium Power" } } }
},
"premium.feature.dns.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "DNS Protection" } } }
},
"premium.feature.dns.description" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "System-wide ad blocking via encrypted DNS queries. Blocks trackers in apps beyond the browser." } } }
},
"premium.feature.backgroundUpdates.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Background Updates" } } }
},
"premium.feature.backgroundUpdates.description" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Blocklists stay fresh automatically. You never have to manually check for new tracker signatures." } } }
},
"premium.feature.youtube.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "YouTube Safari Enhancements" } } }
},
"premium.feature.youtube.description" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Native-like experience in Safari with no video ads, background play, and PiP support." } } }
},
"premium.section.comparison" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Comparison" } } }
},
"premium.comparison.feature" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Feature" } } }
},
"premium.comparison.free" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Free" } } }
},
"premium.comparison.premium" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Premium" } } }
},
"premium.comparison.safariBlocking" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Safari Blocking" } } }
},
"premium.comparison.dnsProtection" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "DNS Protection" } } }
},
"premium.comparison.autoUpdates" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Auto Updates" } } }
},
"premium.comparison.premiumThemes" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Premium Themes" } } }
},
"premium.action.upgradeToPremium" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Upgrade to Premium" } } }
},
"premium.action.restore" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Restore" } } }
},
"premium.action.manage" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Manage" } } }
},
"premium.legal.subscriptionTerms" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "By subscribing, you agree to our Terms of Use and Privacy Policy. Subscriptions automatically renew unless canceled 24 hours before the end of the current period." } } }
}
```

- [ ] **Step 2: Replace every in-scope literal**

```swift
// ADBLX/Features/Premium/PremiumView.swift
import SwiftUI

struct PremiumView: View {
    @State var viewModel: PremiumViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                hero

                if let plans = viewModel.status?.plans {
                    pricingSection(plans: plans)
                }

                featuresSection
                comparisonSection

                if let error = viewModel.purchaseError {
                    Text(error.localizedDescription)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.error)
                }

                actionButtons
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    private var hero: some View {
        VStack(spacing: DesignSpacing.gutter) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius)
                    .fill(DesignColors.tertiary.opacity(0.1))
                    .strokeBorder(DesignColors.tertiary.opacity(0.3), lineWidth: 1)
                    .frame(width: 80, height: 80)
                Image(systemName: "crown.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(DesignColors.tertiary)
            }
            Text("premium.hero.title")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.tertiary)
                .multilineTextAlignment(.center)
            Text("premium.hero.subtitle")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSpacing.sectionGap)
    }

    private func pricingSection(plans: [SubscriptionPlan]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("premium.section.selectPlan")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            ForEach(plans) { plan in
                planCard(plan, isBestValue: plan.id == "annual")
            }
        }
    }

    private func planCard(_ plan: SubscriptionPlan, isBestValue: Bool) -> some View {
        Button {
            Task { await viewModel.purchase(planID: plan.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: DesignSpacing.containerPadding) {
                    ZStack {
                        Circle()
                            .fill((isBestValue ? DesignColors.tertiary : DesignColors.surfaceContainer).opacity(isBestValue ? 0.2 : 0.5))
                            .frame(width: 48, height: 48)
                        Image(systemName: isBestValue ? "calendar" : "infinity")
                            .foregroundStyle(isBestValue ? DesignColors.tertiary : DesignColors.outline)
                    }
                    VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                        Text(plan.name)
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(DesignColors.primary)
                        Text(plan.billingPeriodDescription)
                            .font(DesignTypography.bodySmall)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: DesignSpacing.base / 2) {
                        Text(plan.priceDescription)
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(isBestValue ? DesignColors.tertiary : DesignColors.onSurfaceVariant)
                        Text(isBestValue ? "per year" : "one-time")
                            .font(DesignTypography.labelCaps)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }
                }
                .padding(DesignSpacing.containerPadding)
                .background(.ultraThinMaterial)
                .background(isBestValue ? DesignColors.tertiary.opacity(0.05) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                        .strokeBorder(isBestValue ? DesignColors.tertiary.opacity(0.5) : DesignColors.outlineVariant.opacity(0.3), lineWidth: isBestValue ? 2 : 1)
                )

                if isBestValue {
                    Text("premium.badge.bestValue")
                        .font(DesignTypography.labelCaps)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSpacing.gutter)
                        .padding(.vertical, DesignSpacing.base / 2)
                        .background(DesignColors.tertiary)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: DesignShape.smallCornerRadius, topTrailingRadius: DesignShape.defaultCornerRadius * 2))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("premium.section.power")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            featureCard(icon: "network", iconColor: DesignColors.primary, titleKey: "premium.feature.dns.title", descriptionKey: "premium.feature.dns.description")
            featureCard(icon: "arrow.triangle.2.circlepath", iconColor: DesignColors.tertiary, titleKey: "premium.feature.backgroundUpdates.title", descriptionKey: "premium.feature.backgroundUpdates.description")
            featureCard(icon: "play.tv.fill", iconColor: DesignColors.secondary, titleKey: "premium.feature.youtube.title", descriptionKey: "premium.feature.youtube.description")
        }
    }

    private func featureCard(icon: String, iconColor: Color, titleKey: LocalizedStringKey, descriptionKey: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.containerPadding) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .padding(DesignSpacing.gutter / 1.5)
                .background(iconColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: DesignShape.smallCornerRadius * 2))
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(titleKey)
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignColors.primary)
                Text(descriptionKey)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .padding(DesignSpacing.containerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
        .overlay(
            RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("premium.section.comparison")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                comparisonHeaderRow
                comparisonRow(featureKey: "premium.comparison.safariBlocking", freeIncluded: true, premiumIncluded: true)
                comparisonRow(featureKey: "premium.comparison.dnsProtection", freeIncluded: false, premiumIncluded: true)
                comparisonRow(featureKey: "premium.comparison.autoUpdates", freeIncluded: false, premiumIncluded: true)
                comparisonRow(featureKey: "premium.comparison.premiumThemes", freeIncluded: false, premiumIncluded: true)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var comparisonHeaderRow: some View {
        HStack {
            Text("premium.comparison.feature")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
            Spacer()
            Text("premium.comparison.free")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.outline)
                .frame(width: 60)
            Text("premium.comparison.premium")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.tertiary)
                .frame(width: 60)
        }
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerHigh.opacity(0.3))
    }

    private func comparisonRow(featureKey: LocalizedStringKey, freeIncluded: Bool, premiumIncluded: Bool) -> some View {
        HStack {
            Text(featureKey)
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.primary)
            Spacer()
            comparisonMark(included: freeIncluded, color: DesignColors.outline)
                .frame(width: 60)
            comparisonMark(included: premiumIncluded, color: DesignColors.tertiary)
                .frame(width: 60)
        }
        .padding(DesignSpacing.containerPadding)
        .overlay(alignment: .bottom) {
            Divider().overlay(DesignColors.outlineVariant.opacity(0.1))
        }
    }

    private func comparisonMark(included: Bool, color: Color) -> some View {
        Image(systemName: included ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption)
            .foregroundStyle(included ? color : DesignColors.outline)
    }

    private var actionButtons: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            Button {
                if let plan = viewModel.status?.plans.first(where: { $0.id == "annual" }) {
                    Task { await viewModel.purchase(planID: plan.id) }
                }
            } label: {
                Text("premium.action.upgradeToPremium")
                    .font(DesignTypography.bodyLarge)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSpacing.containerPadding)
                    .background(DesignColors.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2))
            }

            HStack(spacing: DesignSpacing.stackGap) {
                Button("premium.action.restore") {}
                    .frame(maxWidth: .infinity)
                Button("premium.action.manage") {}
                    .frame(maxWidth: .infinity)
            }
            .font(DesignTypography.bodyLarge)
            .fontWeight(.semibold)
            .foregroundStyle(DesignColors.onSurface)
            .padding(.vertical, DesignSpacing.containerPadding)
            .overlay(
                RoundedRectangle(cornerRadius: DesignShape.defaultCornerRadius * 2)
                    .strokeBorder(DesignColors.outline.opacity(0.3), lineWidth: 1)
            )

            Text("premium.legal.subscriptionTerms")
                .font(.system(size: 11))
                .foregroundStyle(DesignColors.outline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSpacing.sectionGap)
                .padding(.top, DesignSpacing.base)
        }
        .padding(.top, DesignSpacing.gutter)
    }
}

#Preview {
    PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
}
```

Note: `"per year"` / `"one-time"` (line 97 originally, inside `planCard`) render `Text(isBestValue ? "per year" : "one-time")` — this is genuinely in scope but was missed above; add it now:

```json
"premium.plan.periodYearly" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "per year" } } }
},
"premium.plan.periodOneTime" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "one-time" } } }
}
```

and in `planCard`, replace:
```swift
Text(isBestValue ? "per year" : "one-time")
```
with:
```swift
Text(isBestValue ? "premium.plan.periodYearly" : "premium.plan.periodOneTime")
```

`.accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")` (line 124) is left untouched — it's an accessibility string (Commit 3 scope) built from service-layer mock data (also out of scope), a double exclusion.

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. `PremiumViewModelTests.swift` tests mock `SubscriptionPlan` data, not this view's static copy.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Premium/PremiumView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate PremiumView to Localizable.xcstrings"
```

### Task 14: Migrate SettingsView.swift

**Files:**
- Modify: `ADBLX/Features/Settings/SettingsView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `SettingsRow(titleKey: LocalizedStringKey, systemImage: String)` from Task 5 (already updated at its call site in Task 5 Step 3 — no further change needed here).
- Produces: no public API change.

**Scope note:** `snapshot.iCloudSyncEnabled ? "On" : "Off"` (line 24) renders through `Text(...)` and is genuinely user-visible status text — in scope (not an `.accessibilityValue`, so not a Commit 3 exclusion). `entry.domain` (line 35) is user-entered data (the allowlist), not static UI copy — out of scope, it's not a hardcoded string at all. `TextField("Add a domain", text: $newDomain)` (line 48) is a placeholder string, in scope. `Button("Add")` (line 50) is in scope.

- [ ] **Step 1: Add catalog keys**

```json
"settings.title" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Settings" } } }
},
"settings.row.iCloudSync" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "iCloud Sync" } } }
},
"settings.status.on" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "On" } } }
},
"settings.status.off" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Off" } } }
},
"settings.section.allowlist" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Allowlist" } } }
},
"settings.placeholder.addDomain" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Add a domain" } } }
},
"settings.action.add" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Add" } } }
}
```

- [ ] **Step 2: Replace every literal**

```swift
// ADBLX/Features/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var newDomain = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("settings.title")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                if let snapshot = viewModel.snapshot {
                    Card {
                        HStack {
                            Text("settings.row.iCloudSync")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Spacer()
                            PremiumBadge()
                        }
                        Text(snapshot.iCloudSyncEnabled ? "settings.status.on" : "settings.status.off")
                            .font(DesignTypography.bodySmall)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }

                    Card {
                        Text("settings.section.allowlist")
                            .font(DesignTypography.headlineMedium)
                            .foregroundStyle(DesignColors.onBackground)
                        ForEach(snapshot.allowlist) { entry in
                            HStack {
                                Text(entry.domain)
                                    .font(DesignTypography.bodyLarge)
                                    .foregroundStyle(DesignColors.onSurface)
                                Spacer()
                                Button {
                                    Task { await viewModel.removeAllowlistEntry(id: entry.id) }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(DesignColors.error)
                                }
                            }
                        }
                        HStack {
                            TextField("settings.placeholder.addDomain", text: $newDomain)
                                .font(DesignTypography.bodyLarge)
                            Button("settings.action.add") {
                                Task {
                                    await viewModel.addAllowlistEntry(domain: newDomain)
                                    newDomain = ""
                                }
                            }
                            .disabled(newDomain.isEmpty)
                        }
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Card {
                            SettingsRow(titleKey: "settings.row.about", systemImage: "info.circle.fill")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel(service: MockSettingsService()))
}
```

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. `SettingsViewModelTests.swift` tests the ViewModel/mock snapshot data, not this view's static copy.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Settings/SettingsView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate SettingsView to Localizable.xcstrings"
```

### Task 15: Migrate AboutView.swift

**Files:**
- Modify: `ADBLX/Features/Settings/AboutView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: none
- Produces: no public API change.

**Scope note:** `Link("Privacy Policy", destination: ...)` and `Link("Terms of Service", destination: ...)` (lines 28, 31) — `Link`'s title parameter is `LocalizedStringKey`, same treatment as `Text`/`Button`.

- [ ] **Step 1: Add catalog keys**

```json
"about.title.app" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "ADBLX" } } }
},
"about.version.label" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Version 1.0" } } }
},
"about.privacy.statement" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Zero data collection. Nothing about your browsing ever leaves your device." } } }
},
"about.link.privacyPolicy" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Privacy Policy" } } }
},
"about.link.termsOfService" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Terms of Service" } } }
}
```

- [ ] **Step 2: Replace every literal**

```swift
// ADBLX/Features/Settings/AboutView.swift
import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                VStack(spacing: DesignSpacing.stackGap) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 48))
                        .foregroundStyle(DesignColors.primary)
                    Text("about.title.app")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("about.version.label")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)

                Card {
                    Text("about.privacy.statement")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                }

                Card {
                    Link("about.link.privacyPolicy", destination: URL(string: "https://adblx.app/privacy")!)
                        .font(DesignTypography.bodyLarge)
                    Divider()
                    Link("about.link.termsOfService", destination: URL(string: "https://adblx.app/terms")!)
                        .font(DesignTypography.bodyLarge)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }
}

#Preview {
    AboutView()
}
```

- [ ] **Step 3: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass. No test targets `AboutView`.

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Settings/AboutView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate AboutView to Localizable.xcstrings"
```

### Task 16: Migrate UpdateProgressModel.swift and UpdateProgressSheet.swift

**Files:**
- Modify: `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift`
- Modify: `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `PrimaryButton(titleKey: LocalizedStringKey, action: () -> Void)` from Task 4.
- Produces: `UpdateProgressModel.progressDescription: String` — type unchanged (still `String`, consumed by `Text(model.progressDescription)` at `UpdateProgressSheet.swift:24`, where `model.progressDescription` is a runtime `String`, not a literal, so it needs `String(localized:)` inside the model, same pattern as `AppTab.title`).

**Scope note:** `case failed(let message): return message` (line 29 of `UpdateProgressModel.swift`) — `message` is an already-resolved runtime string associated with the `.failed` case, not a static literal to migrate; leave as-is.

- [ ] **Step 1: Add catalog keys**

```json
"updateprogress.status.ready" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Ready to update" } } }
},
"updateprogress.status.checking" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Checking for updates…" } } }
},
"updateprogress.status.downloading" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Downloading filter updates…" } } }
},
"updateprogress.status.installing" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Installing filters…" } } }
},
"updateprogress.status.complete" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Filters updated" } } }
},
"updateprogress.button.done" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Done" } } }
}
```

- [ ] **Step 2: Update UpdateProgressModel.swift**

```swift
// ADBLX/Features/UpdateProgress/UpdateProgressModel.swift
import Observation
import Foundation

enum UpdatePhase: Equatable {
    case idle
    case checking
    case downloading
    case installing
    case complete
    case failed(String)
}

/// Drives the shared Update Progress sheet, presentable from Home or Protection
/// (Sprint 4 spec §7). This sprint walks a canned local sequence; a later sprint
/// replaces start()'s body with real UpdateCoordinator callbacks — the sheet
/// itself does not change.
@Observable
final class UpdateProgressModel {
    var phase: UpdatePhase = .idle

    var progressDescription: String {
        switch phase {
        case .idle: return String(localized: "updateprogress.status.ready")
        case .checking: return String(localized: "updateprogress.status.checking")
        case .downloading: return String(localized: "updateprogress.status.downloading")
        case .installing: return String(localized: "updateprogress.status.installing")
        case .complete: return String(localized: "updateprogress.status.complete")
        case .failed(let message): return message
        }
    }

    func start() async {
        phase = .checking
        try? await Task.sleep(for: .milliseconds(300))
        phase = .downloading
        try? await Task.sleep(for: .milliseconds(300))
        phase = .installing
        try? await Task.sleep(for: .milliseconds(300))
        phase = .complete
    }
}
```

- [ ] **Step 3: Update UpdateProgressSheet.swift (replace the placeholder key from Task 4 Step 3 with the real one)**

```swift
// ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift
import SwiftUI

struct UpdateProgressSheet: View {
    @State var model: UpdateProgressModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: DesignSpacing.sectionGap) {
            if model.phase == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignColors.primary)
            } else if case .failed = model.phase {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(DesignColors.error)
            } else {
                ProgressView()
                    .tint(DesignColors.primary)
                    .scaleEffect(1.5)
            }

            Text(model.progressDescription)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
                .multilineTextAlignment(.center)

            if model.phase == .complete {
                PrimaryButton(titleKey: "updateprogress.button.done") { dismiss() }
            }
        }
        .padding(DesignSpacing.containerPadding)
        .task { await model.start() }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    UpdateProgressSheet(model: UpdateProgressModel())
}
```

- [ ] **Step 4: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds, all tests pass.
```bash
grep -rn "UpdateProgressModel\|progressDescription" ADBLXTests/
```
Expected: no matches — confirmed no test targets this model's string output today.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Features/UpdateProgress/UpdateProgressModel.swift ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate UpdateProgressModel and UpdateProgressSheet to Localizable.xcstrings"
```

### Task 17: SwiftLint Gate — introduce the enforcement rule

**Files:**
- Create: `.swiftlint.yml`
- Modify: `project.yml`

**Interfaces:**
- Consumes: a fully-migrated tree (Tasks 2–16 complete — this task is the closing gate and must run last).
- Produces: a `preBuildScripts` phase in the generated Xcode project that fails the build on any new hardcoded `Text(`/`Label(`/`Button(` string literal under `ADBLX/`.

- [ ] **Step 1: Verify the tree is actually clean before adding the rule**

```bash
grep -rnE 'Text\("[A-Z][a-zA-Z ]|Label\("[A-Z][a-zA-Z ]|Button\("[A-Z][a-zA-Z ]' ADBLX/Features ADBLX/DesignSystem ADBLX/Navigation --include="*.swift" | grep -v "Preview"
```
Expected: no matches (all real call sites now use lowercase dotted keys like `"home.title"`; remaining preview-only literals were already converted to keys in Tasks 2–16, so there should be zero matches, not merely zero matches outside previews).

- [ ] **Step 2: Write .swiftlint.yml at repo root**

```yaml
included:
  - ADBLX

excluded:
  - ADBLXTests
  - ADBLXUITests
  - Extensions
  - "**/Preview Content"
  - "**/*.generated.swift"

custom_rules:
  no_hardcoded_ui_string:
    included: ".*\\.swift"
    regex: '(Text|Label|Button)\(\s*"[A-Z][^"]*"'
    match_kinds:
      - string
    message: "User-visible strings must use a Localizable.xcstrings key (e.g. \"home.title\"), not a hardcoded literal. See docs/coding-standards.md."
    severity: error
```

- [ ] **Step 3: Add the SwiftLint build phase to project.yml**

Find the `ADBLX` target's settings block in `project.yml` (the one with `ASSETCATALOG_COMPILER_APPICON_NAME`, etc.) and add a sibling `preBuildScripts` key at the target level:

```yaml
targets:
  ADBLX:
    type: application
    platform: auto
    supportedDestinations: [iOS, macOS, visionOS]
    sources:
      - path: ADBLX
        type: syncedFolder
    preBuildScripts:
      - name: "SwiftLint"
        script: |
          if which swiftlint > /dev/null; then
            swiftlint
          else
            echo "warning: SwiftLint not installed. Run: brew install swiftlint"
          fi
        basedOnDependencyAnalysis: false
```

(Insert `preBuildScripts` after `sources:` and before `entitlements:`, matching the existing key ordering in the file.)

- [ ] **Step 4: Regenerate, install SwiftLint locally, and verify the gate is live**

```bash
brew install swiftlint
xcodegen generate
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
```
Expected: `** BUILD SUCCEEDED **` with the SwiftLint phase running and reporting 0 violations.

- [ ] **Step 5: Prove the gate actually catches violations**

Temporarily add `Text("Test Violation")` to any Feature view (e.g. append a throwaway line to `HomeView.swift`'s body), regenerate, and build:
```bash
xcodegen generate
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
```
Expected: build fails with a SwiftLint `error` on the `no_hardcoded_ui_string` rule. Then revert the throwaway line:
```bash
git checkout ADBLX/Features/Home/HomeView.swift
xcodegen generate
xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
```
Expected: `** BUILD SUCCEEDED **` again.

- [ ] **Step 6: Run the full test suite one final time**

```bash
swift test
```
Expected: all tests pass — this is Commit 2's closing acceptance gate per the spec ("Full build and `swift test` pass green with the SwiftLint rule active at `error` severity").

- [ ] **Step 7: Commit**

```bash
git add .swiftlint.yml project.yml
git commit -m "feat(i18n): add SwiftLint no_hardcoded_ui_string rule at error severity

Closing gate for Sprint 4C Commit 2 — the UI tree is now fully migrated
to Localizable.xcstrings, so this rule is introduced only once nothing
in ADBLX/ can trip it."
```

---

## Commit 3: Localization Audit

This commit is verification-only — it closes the accessibility/alert/dialog gaps Commit 2 deliberately deferred. No new catalog infrastructure; keys are added to the same `Localizable.xcstrings`.

### Task 18: Audit and migrate accessibility strings

**Files:**
- Modify: `ADBLX/DesignSystem/Components/ToggleRow.swift`
- Modify: `ADBLX/Features/Protection/AdvancedFilterListsView.swift`
- Modify: `ADBLX/Features/Premium/PremiumView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: the fully-migrated Commit 2 tree.
- Produces: no signature changes — accessibility modifiers don't affect a view's public parameters.

- [ ] **Step 1: Grep for every remaining accessibility string across the app**

```bash
grep -rn "accessibilityLabel\|accessibilityValue\|accessibilityHint" ADBLX/Features ADBLX/DesignSystem --include="*.swift"
```
Expected output identifies exactly three sites needing attention (per the Commit 2 audit trail above):
1. `ToggleRow.swift` — `.accessibilityValue(isOn ? "On" : "Off")`, and the removed `.accessibilityLabel(title)` line from Task 6 that needs a replacement now that `titleKey` is a `LocalizedStringKey`.
2. `AdvancedFilterListsView.swift` — `.accessibilityLabel(list.isPremium ? "\(list.name), premium" : list.name)` and `.accessibilityValue(list.isEnabled ? "On" : "Off")`.
3. `PremiumView.swift` — `.accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")`.

- [ ] **Step 2: Add catalog keys for the "On"/"Off" accessibility values (shared across all three uses)**

```json
"accessibility.value.on" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "On" } } }
},
"accessibility.value.off" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Off" } } }
}
```

- [ ] **Step 3: Fix ToggleRow.swift**

`accessibilityValue(_:)` takes `Text`, so `Text("accessibility.value.on")` resolves through the catalog. For the label, restore an explicit accessibility label using `Text(titleKey)` (the same key already driving the visible title):

```swift
// ADBLX/DesignSystem/Components/ToggleRow.swift — body, tail end only:
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(titleKey))
        .accessibilityValue(isOn ? Text("accessibility.value.on") : Text("accessibility.value.off"))
```

- [ ] **Step 4: Fix AdvancedFilterListsView.swift's filterListRow**

`list.name` is user-data-ish (comes from `FilterListEntry`, which is service-layer/mock, out of scope for the *name* itself) but `", premium"` is a genuine UI string. Add a key for that suffix:

```json
"protection.filterList.accessibility.premiumSuffix" : {
  "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "%@, premium" } } }
}
```

```swift
// ADBLX/Features/Protection/AdvancedFilterListsView.swift — filterListRow, tail end:
        .accessibilityElement(children: .combine)
        .accessibilityLabel(list.isPremium ? Text(String(format: String(localized: "protection.filterList.accessibility.premiumSuffix"), list.name)) : Text(list.name))
        .accessibilityValue(list.isEnabled ? Text("accessibility.value.on") : Text("accessibility.value.off"))
```

- [ ] **Step 5: Leave PremiumView.swift's accessibilityLabel as-is**

`"\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)"` is built entirely from `SubscriptionPlan` fields, which are service-layer mock data (out of scope per the Global Constraints — Sprint 5 replaces this data source). There is no static UI string here to localize; skip this site and note it in the commit message.

- [ ] **Step 6: Build and test**

```bash
xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: build succeeds (SwiftLint rule from Task 17 stays green — none of these changes touch `Text(`/`Label(`/`Button(` literals, only `accessibilityLabel`/`accessibilityValue`, which the rule doesn't scan), all tests pass.

- [ ] **Step 7: Commit**

```bash
git add ADBLX/DesignSystem/Components/ToggleRow.swift ADBLX/Features/Protection/AdvancedFilterListsView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate accessibility labels/values to Localizable.xcstrings

PremiumView's plan accessibilityLabel is left as-is — built entirely
from SubscriptionPlan mock data (service-layer, out of scope; Sprint 5
replaces this data source)."
```

### Task 19: Audit for remaining alerts, confirmation dialogs, and error/success messages

**Files:**
- None expected to change — this task is a verification pass. If it finds something, treat each finding as its own micro-task following the same pattern as Tasks 2–16 (add key, replace literal, build, test, commit).

**Interfaces:**
- Consumes: the fully-migrated Commit 2 + Task 18 tree.
- Produces: a documented confirmation that Commit 3's scope is closed.

- [ ] **Step 1: Grep for Alert and confirmationDialog usage across the entire app target**

```bash
grep -rn "Alert(\|\.alert(\|confirmationDialog(" ADBLX --include="*.swift"
```
Expected: no matches — confirmed no `Alert`/`.alert`/`confirmationDialog` exists anywhere in the codebase today (Sprint 4A/4B never introduced any; error display in `PremiumView.swift` uses a plain inline `Text(error.localizedDescription)`, not a system alert).

- [ ] **Step 2: Check PremiumView's inline error text**

`Text(error.localizedDescription)` (line 20) renders `PurchaseError`'s `localizedDescription`. Check its definition:
```bash
grep -n "localizedDescription\|enum PurchaseError\|struct PurchaseError" ADBLX/Features/Premium/*.swift
```
If `PurchaseError` is a plain `Error`-conforming type whose `localizedDescription` returns a hardcoded English string, that string is genuinely in scope (it's a user-visible error message). Read the type definition, add a catalog key for its message(s) following the same `String(localized:)` pattern as `AppTab.title` (Task 8), and replace the hardcoded return value. If it wraps a system/framework error (e.g. `URLError`) instead, its message is out of scope — the same exclusion as developer/log strings, since system-framework error text isn't authored by this codebase.

- [ ] **Step 3: Final full-repo confirmation**

```bash
grep -rnE '"[A-Z][a-zA-Z0-9 ,.!?%'"'"'-]{2,}"' ADBLX/Features ADBLX/DesignSystem ADBLX/Navigation --include="*.swift" | grep -v "Preview\|systemName\|#Preview\|Font.custom"
```
Expected: any remaining matches are either (a) service-layer mock data already ruled out of scope, (b) `list.name`/`entry.domain`-style user/mock data, not static UI copy, or (c) SF Symbol/font-name literals, which were never in scope. If a genuine new hardcoded UI string surfaces here that wasn't caught by Tasks 2–17, add it as a follow-up micro-task before closing this commit.

- [ ] **Step 4: Commit (only if Step 2 produced a change; otherwise this task has nothing to commit)**

```bash
git add -A
git commit -m "docs(i18n): confirm no remaining Alert/confirmationDialog/error-message localization gaps"
```

If Step 2 found nothing to migrate and Step 3 found nothing new, skip this commit — there's nothing to commit, and creating an empty commit would violate the "never commit without a real change" convention implicit in this codebase's history.

---

## Self-Review Notes

**Spec coverage:** Every spec section has a task — Commit 1 (Task 1), Commit 2's 11 ordered files (Tasks 2–16, with `DNSProtectionView` folded into Task 3 since `ComingSoonState`'s signature change and its only caller must land together), the SwiftLint gate (Task 17), and Commit 3's accessibility/alert audit (Tasks 18–19).

**Placeholder scan:** No TBD/TODO. Task 4's Step 3 "placeholder key" is not a plan placeholder — it's a real, explained intermediate state (a literal used as a `LocalizedStringKey` via `ExpressibleByStringLiteral`) with an exact resolution shown in the tasks that follow it (Tasks 9 and 16).

**Type consistency:** `PrimaryButton.titleKey`, `SettingsRow.titleKey`, `ToggleRow.titleKey`/`subtitleKey`, `PremiumBadge.textKey`, `ComingSoonState.title`/`message` (kept unprefixed since they were already unambiguous) are used identically at every call site across tasks. `AppTab.title: String` and `FilterCategoryID.displayNameKey: LocalizedStringKey` intentionally differ in type — documented inline in Tasks 8 and 12 with the reasoning (whether the value is read as a plain `String` elsewhere or only ever fed into a local `Text(_:)`).

**Real surface vs. spec's original 9 files:** confirmed during planning research that the true file count is larger than the spec's initial audit (missed `DNSProtectionView.swift`, `UpdateProgressSheet.swift`, `UpdateProgressModel.swift`, `SettingsRow.swift`, `ToggleRow.swift`, `PremiumBadge.swift`) — the spec itself was updated to reflect this before this plan was written, so plan and spec are consistent.
