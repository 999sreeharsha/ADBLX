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
