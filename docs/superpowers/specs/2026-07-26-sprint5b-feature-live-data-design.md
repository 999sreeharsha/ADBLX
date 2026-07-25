# Sprint 5B — Feature-by-Feature Live Data

## Goal

Finish Sprint 5's mock-to-real swap: Protection (Safari Protection + Advanced
Filter Lists), Update Progress, Settings, and About all read/write real backend
state instead of `Mock*Service` data. Continues Sprint 5A's pattern —
`AppCompositionRoot` is the sole construction point, no protocol changes unless
justified and documented, every value traces to real backend state or is
honestly labeled as not-yet-available.

Two deliberate, approved exceptions to Sprint 5's "no redesigns" rule are
scoped explicitly below (Settings' new "General" section, About's restyle) —
everything else is copy-only or pure backend wiring, same pattern as Sprint 5A.

Sprint 5B collapses the Sprint 5A spec's original 5-commit sketch (Commits 3-7)
into **4 commits**: Safari Protection and Advanced Filter Lists share one real
service (`ProtectionViewModel`/`ProtectionService`), so wiring one wires both.

## Out of scope (carried from Sprint 5A)

StoreKit, DNS Packet Tunnel, VPN management, Safari Web Extension, background
refresh, push-triggered updates. Also out of scope for Sprint 5B specifically:
real allowlist *enforcement* (persistence only — see Commit 3), a real Open
Source Licenses list (placeholder row — see Commit 4), real Notifications/
Safari Help screens (placeholder navigation — see Commit 3).

## Commit 1 — Real ProtectionService (Safari Protection + Advanced Filter Lists)

### New backend surface: `FilterPreferencesStore`

Neither category-level nor filter-list-level enable/disable state is persisted
anywhere today. One new actor, `FilterPreferencesStore`, persists both under a
single JSON file (`filter_preferences.json`, `FilterStore`'s `Metadata/`
directory, same atomic-write mechanism as `installed_filters.json`) — both are
the same underlying concept ("is this thing on or off"), so one file avoids
duplicate persistence infrastructure for near-identical data.

```swift
struct FilterPreferences: Codable, Equatable {
    var categories: [FilterCategoryID: Bool]
    var filterLists: [String: Bool]  // keyed by FilterListEntry.id / filterID
}
```

On first creation (no existing file), `FilterPreferencesStore` writes explicit
defaults for all four categories (`true` for every category, matching today's
`MockProtectionService` defaults for Ads/Privacy, and existing `enabledByDefault`
semantics from `FilterManifest.Entry` for the rest) rather than treating
"missing key" as an implicit default scattered across call sites.

### `FilterCategoryID` becomes `CaseIterable`

`AdvancedFilterListsView.swift` currently hardcodes a private
`allCasesForDisplay: [FilterCategoryID]` array duplicating the four-category
list. Making `FilterCategoryID: CaseIterable` and switching that view (plus
`FilterPreferencesStore` and `RealProtectionService`) to `FilterCategoryID
.allCases` removes the duplication — one canonical list, not two that can
drift.

### `RealProtectionService`

- **Categories: always all four**, regardless of install state. Categories are
  fixed application taxonomy (they map 1:1 to `GroupExtensionIdentifiers`'
  four content blocker extensions), not dynamic data — a category with nothing
  installed yet should still be visible and toggleable, matching today's mock
  behavior. `isEnabled` comes from `FilterPreferencesStore`; `ruleCount` sums
  `InstalledFilter.ruleCount` for that group from `installed_filters.json`
  (per `docs/gotchas.md`'s group-level constraint — sum once per unique group,
  not per entry, same pattern `RealHomeService` already established in Sprint
  5A), defaulting to `0` if nothing is installed for that category.
- **Filter lists: only what's genuinely installed.** No blending with the
  bundled Sprint 1 test fixture manifest — that fixture exists to exercise the
  pipeline before networking exists, not to represent a production catalog.
  `filterLists` is built from `installed_filters.json` entries only. Today
  that's realistically just the bootstrap-installed ads snapshot, so Advanced
  Filter Lists will look sparse until Sprint 5A's `UpdateCoordinator` wiring
  and a real CDN manifest exist — that sparseness is honest, not a bug. Add an
  empty-state message ("Filter lists will appear after the first successful
  synchronization" or similar) rather than an empty section.
- `setCategory(_:enabled:)` / `setFilterList(_:enabled:)` write through
  `FilterPreferencesStore`.

**Acceptance criteria:**
- Toggling a category or filter list in either screen persists across app
  relaunch (backed by `filter_preferences.json`, not in-memory state).
- `AdvancedFilterListsView`'s private `allCasesForDisplay` extension is
  removed in favor of `FilterCategoryID.allCases`.
- No fabricated filter-list entries — every row traces to a real
  `InstalledFilter`.

## Commit 2 — Update Progress

### `UpdateCoordinator.run(onPhaseChange:)` — additive signature change

`UpdateCoordinator.run()` is one atomic call with four natural checkpoints
that map directly onto `UpdatePhase`'s in-flight cases:

| Checkpoint (existing code) | `UpdatePhase` |
|---|---|
| Before `manifestClient.fetch(...)` | `.checking` |
| Start of the download+verify loop (`downloadClient.download`/`Checksum.verify`) | `.downloading` |
| Start of the per-group `pipeline.install(...)` loop | `.installing` |
| `.updated`/`.upToDate` return, or the catch block's rollback path | `.complete` / `.failed` |

```swift
func run(onPhaseChange: (UpdatePhase) -> Void = { _ in }) async throws -> UpdateRunResult
```

Default no-op parameter — existing callers (`UpdateCoordinatorTests`) are
unaffected, this is additive, not a breaking protocol change. Only
`UpdateProgressModel` passes a real closure.

### `UpdateProgressModel.start()`

Replaces the canned `Task.sleep` sequence with a real call:

```swift
func start(coordinator: UpdateCoordinator) async {
    do {
        _ = try await coordinator.run { [weak self] newPhase in
            self?.phase = newPhase
        }
        if phase != .failed { phase = .complete }
    } catch {
        phase = .failed(String(localized: "updateprogress.status.failed"))
    }
}
```

Given no real CDN manifest endpoint exists yet (Sprint 5A's
`AppManifestEndpointProvider` is a placeholder `https://example.invalid`), a
live check will genuinely fail during `manifestClient.fetch`. This surfaces
honestly as `.failed` — no special-casing needed, it's simply what a real
network failure against an unreachable host produces. This was the Sprint 5A
spec's stated intent ("show an honest 'Unable to check for updates' error
state rather than simulating progress") and Commit 2 fulfills it via the real
call path rather than a hardcoded failure branch.

**Acceptance criteria:**
- `UpdateProgressSheet` (the view) is unchanged — only `UpdateProgressModel`'s
  internals and `UpdateCoordinator`'s signature change, per the type's own
  existing doc comment anticipating exactly this swap.
- `UpdateCoordinatorTests` continues to pass unmodified (default parameter).
- A live update attempt against the placeholder endpoint shows `.failed` with
  a real, honest error message — not a silently-hanging or fake-progress UI.

## Commit 3 — Settings

### New "General" section (additive, above existing content — approved UI addition)

Per user-provided reference screenshot: four rows — Appearance, Language,
Notifications, Safari Help — added as a new `Card`-wrapped section above the
existing iCloud Sync / Allowlist / About-navigation content, which is **not**
reorganized or relabeled (stays exactly as-is below the new section).

- **Appearance** — real, new persisted preference (`.system`/`.light`/`.dark`),
  small addition alongside `FilterPreferencesStore`'s pattern (or folded into
  a general `AppPreferencesStore` if that reads cleaner at implementation
  time — decide during planning). Row shows the current value's display name
  and navigates to a picker.
- **Language** — real, read-only: displays the current system locale's
  display name (e.g. `Locale.current.localizedString(forIdentifier:)`). No
  in-app language override picker — that's a larger localization-
  infrastructure task, out of scope here.
- **Notifications** and **Safari Help** — navigate to `ComingSoonState`
  (existing shared component, `ADBLX/DesignSystem/Components/ComingSoonState.swift`)
  rather than fabricated functional screens. Notifications needs real
  permission-status wiring (`UNUserNotificationCenter`) and Safari Help is
  informational content — both are scoped-out follow-ups, not backend
  integration work.

### Allowlist persistence

New small JSON-backed store, same pattern as `FilterPreferencesStore`
(`allowlist.json` in `FilterStore`'s `Metadata/` directory, atomic writes).
`RealSettingsService.addAllowlistEntry`/`removeAllowlistEntry` write through
it; `fetchSnapshot()` reads it. **Storage only** — no enforcement wired into
`FilterPipeline`/`CompositionService`/`RuleCompiler`. The allowlist is real
and durable across launches but does not yet exempt anything from blocking;
that's a separate, larger feature (touches the compilation pipeline, not just
persistence) explicitly deferred.

`iCloudSyncEnabled` stays as today — no iCloud sync backend exists, this
remains a `PremiumBadge`-gated, non-functional row (unchanged from the
existing mock behavior; not a regression, just not in this sprint's scope).

**Acceptance criteria:**
- Existing iCloud Sync / Allowlist / About rows are visually and
  positionally unchanged, just with the new General section above them.
- Allowlist add/remove persists across app relaunch.
- Appearance preference persists across relaunch and actually changes the
  app's color scheme (`.preferredColorScheme` applied at the root).
- Language row never claims to change the app's language — it only displays
  the system's current language.

## Commit 4 — About (approved redesign, restyled from user-provided mockup)

`AboutView` currently has no service/ViewModel — it's fully static text
(`about.title.app`, a static `about.version.label` string). This commit both
restyles the screen and wires it to real data; there's no mock to swap since
none exists.

### Kept from the mockup, restyled using existing `DesignSystem` tokens (not the mockup's raw Tailwind/hex values)

- **App identity section**: icon badge, app name, tagline, and a version chip.
  Version chip shows real `Bundle.main` data:
  `"v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))"`,
  no filter/rule stats on this screen — Home already owns that, per the
  mockup's own scope (app identity + legal, not diagnostics).
- **Connect section**: Official Website link only (existing
  `about.link.privacyPolicy`-style `Link` pattern). GitHub Repository row
  dropped per explicit instruction.
- **Legal & Open Source section**: three rows — Open Source Licenses, Privacy
  Policy, Terms of Service — using the existing `SettingsRow`/`Card`
  components. Privacy Policy and Terms of Service keep their existing real
  `Link(destination:)` URLs (`https://adblx.app/privacy`,
  `https://adblx.app/terms`, unchanged from current `AboutView.swift`). **Open
  Source Licenses stays a placeholder** — row renders, navigation target is a
  `ComingSoonState` (or simply non-interactive for now) — building a real
  dependency/license list is separate content work, not backend integration.
- **Footer**: copyright line, updated to a real current year rather than a
  static hardcoded one if easily derived (`Calendar.current.component(.year,
  from: Date())`), otherwise a static string is acceptable — minor detail, not
  a blocking design decision.

### Dropped from the mockup (explicit instruction)

Acknowledgements/contributor bios section (photos, names, roles) and the
GitHub Repository link. Neither is added.

**Acceptance criteria:**
- New `AboutViewModel` (or a minimal inline computed property, decided at
  planning time given how little state this is) sources version/build from
  `Bundle.main`, not hardcoded strings.
- Visual restyling uses `DesignColors`/`DesignSpacing`/`DesignTypography`/
  `DesignShape` tokens exclusively — no raw hex colors or magic-number
  spacing copied from the mockup's Tailwind config.
- Acknowledgements and GitHub Repository do not appear anywhere in the
  shipped screen.

## Performance & battery

Consistent with Sprint 5A's established constraints:

- **Main thread:** all new store reads (`FilterPreferencesStore`, allowlist
  store) stay off the main actor, same actor-isolated pattern as
  `FilterStore`/`RealHomeService`.
- **Memory:** one instance each of any new store, threaded through
  `AppCompositionRoot` — no duplicates.
- **Disk I/O:** new JSON files are small, read on demand, written only on
  explicit user toggle/edit actions (not polled).
- **Network:** `UpdateCoordinator.run()` is only invoked from Update
  Progress's explicit user-triggered action, unchanged from Sprint 5A's "zero
  network at launch" constraint.
- **Background execution:** no changes.

## Testing

Same convention as Sprint 5A: tests construct dependencies inline (real
`FilterStore`/new stores pointed at the test App Group, or mocks) rather than
through `AppCompositionRoot`. New stores (`FilterPreferencesStore`, allowlist
store) get direct unit tests for persistence round-trip and default-value
behavior on first creation, following `RealHomeServiceTests`' pattern from
Sprint 5A (including its atomic-write-race test where applicable — any new
store using `FilterStore.writeMetadata` inherits the same atomicity
guarantee, worth a similar regression test if the store sees concurrent
read/write in practice).
