# Sprint 5B: Feature-by-Feature Live Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Sprint 5's mock-to-real swap for Protection (Safari Protection + Advanced Filter Lists), Update Progress, Settings, and About — the four remaining features left on `Mock*Service` data after Sprint 5A wired Home.

**Architecture:** Two new small JSON-backed actor stores (`FilterPreferencesStore`, `AllowlistStore`) follow the exact pattern Sprint 5A established with `RealHomeService`/`FilterStore` — atomic writes, actor isolation, real data or an honest empty/failure state, never fabricated values. `UpdateCoordinator.run()` gains an additive (default-no-op) progress callback so `UpdateProgressModel` can show real phases instead of canned sleeps. Settings and About get small, explicitly-approved UI additions (a new "General" section; a full About restyle) layered on top of otherwise-identical backend-wiring work.

**Tech Stack:** Xcode 26.6 project (Swift 5.0 language mode), scheme `ADBLX`, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), XcodeGen with `syncedFolder` (no manual `project.yml` edits needed for new files in existing directories).

## Global Constraints

- No fabricated/heuristic values: every real-service field must trace to real backend state. Empty/not-yet-available states are shown honestly (e.g. "Filter lists will appear after the first successful synchronization"), never invented.
- `docs/gotchas.md`'s group-level `ruleCount` constraint applies: `InstalledFilter.ruleCount` is the whole group's aggregate, not a per-source count — sum once per unique `FilterGroup`, never per `InstalledFilter` entry.
- All new persisted stores use `FilterStore.writeMetadata`'s existing atomic-write mechanism (temp-file-then-rename), matching `installed_filters.json`'s pattern from Sprint 5A. No new store invents its own write path.
- All new/changed backend types are constructed exclusively through `AppCompositionRoot` factory methods — no service or store is constructed inside a View or ViewModel.
- `UpdateCoordinator.run()`'s new parameter must be additive (default value) — existing callers (`UpdateCoordinatorTests`) must not need changes.
- Categories (`FilterCategoryID`) are a fixed, always-present taxonomy (4 cases); filter lists (`FilterListEntry`) are dynamic and only shown if genuinely installed — no blending with the Sprint 1 bundled test fixture manifest.
- Settings' new "General" section is additive, positioned above existing content — the existing iCloud Sync / Allowlist / About-navigation rows are not reorganized, relabeled, or removed.
- About's redesign uses `DesignColors`/`DesignSpacing`/`DesignTypography`/`DesignShape` tokens exclusively — no raw hex colors or magic-number spacing. Acknowledgements/contributor bios and the GitHub Repository link are explicitly excluded from the shipped screen.
- SwiftLint's `no_hardcoded_ui_string` rule (error severity, added Sprint 4C) applies to every new/changed view — all user-facing text goes through `Localizable.xcstrings`.

---

## File Structure

**Modify:**
- `ADBLX/AppCompositionRoot.swift` — add `makeFilterPreferencesStore()`, `makeAllowlistStore()`, extend `makeUIDependencies` to construct `RealProtectionService`/`RealSettingsService`, add `updateCoordinator` to `UIDependencies`.
- `ADBLX/ADBLXApp.swift` — no changes expected beyond what Sprint 5A already did (verify `updateCoordinator` local var is available to pass into `makeUIDependencies`).
- `ADBLX/Features/Protection/ProtectionService.swift` — `FilterCategoryID` gains `String` raw value + `CaseIterable`; add `RealProtectionService`.
- `ADBLX/Features/Protection/AdvancedFilterListsView.swift` — remove private `allCasesForDisplay`, use `FilterCategoryID.allCases`; add empty-state message.
- `ADBLX/Features/Protection/SafariProtectionView.swift` — thread `updateCoordinator` into `UpdateProgressModel`/`.sheet`.
- `ADBLX/Features/Home/HomeView.swift` — thread `updateCoordinator` into `UpdateProgressModel`/`.sheet`.
- `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift` — `start()` becomes `start(coordinator:)`, real phase-driven implementation.
- `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift` — `.task` passes the model's already-injected coordinator through (see Task 6).
- `ADBLX/Filtering/Updates/UpdateCoordinator.swift` — `run()` gains `onPhaseChange:` parameter.
- `ADBLX/Features/Settings/SettingsService.swift` — add `RealSettingsService`.
- `ADBLX/Features/Settings/SettingsView.swift` — add "General" section.
- `ADBLX/Features/Settings/AboutView.swift` — full restyle per approved mockup subset.
- `ADBLX/Navigation/RootTabView.swift` — pass `dependencies.updateCoordinator` into `HomeView`/`SafariProtectionView`.
- `ADBLX/Resources/Localizable.xcstrings` — new keys for General section, About redesign, empty-state messages.

**Create:**
- `ADBLX/Filtering/Storage/FilterPreferencesStore.swift` — new actor, persists category/filter-list enable state.
- `ADBLX/Filtering/Storage/AllowlistStore.swift` — new actor, persists allowlist domains.
- `ADBLX/Features/Settings/AppearancePreferenceStore.swift` — new small store for the Appearance setting (`.system`/`.light`/`.dark`).
- `ADBLX/Features/Settings/AboutViewModel.swift` — sources app version/build from `Bundle.main`.
- `ADBLXTests/Filtering/Storage/FilterPreferencesStoreTests.swift`
- `ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift`
- `ADBLXTests/Features/Protection/RealProtectionServiceTests.swift`
- `ADBLXTests/Features/UpdateProgress/UpdateCoordinatorProgressTests.swift`
- `ADBLXTests/Features/Settings/RealSettingsServiceTests.swift`
- `ADBLXTests/Features/Settings/AppearancePreferenceStoreTests.swift`

---

## Task 1: `FilterPreferencesStore`

**Files:**
- Create: `ADBLX/Filtering/Storage/FilterPreferencesStore.swift`
- Modify: `ADBLX/Features/Protection/ProtectionService.swift:7-12` (`FilterCategoryID` gains a `String` raw value and `CaseIterable`)
- Test: `ADBLXTests/Filtering/Storage/FilterPreferencesStoreTests.swift` (new)

**Interfaces:**
- Consumes: `FilterStore.read(_:in:)`/`writeMetadata(_:filename:)` (existing, `ADBLX/Filtering/Storage/FilterStore.swift:61,69`), `FilterCategoryID` (modified this task).
- Produces: `FilterCategoryID: String, CaseIterable, Equatable, Codable`, `FilterPreferences` struct, `FilterPreferencesStore` actor with `func load() async -> FilterPreferences` and `func setCategory(_ id: FilterCategoryID, enabled: Bool) async` / `func setFilterList(_ id: String, enabled: Bool) async`, consumed by Task 2 (`RealProtectionService`) and `AdvancedFilterListsView` (Task 3).

`FilterCategoryID` currently has no raw value, which blocks JSON-encoding it as a dictionary key (`Codable`'s `Dictionary<K,V>` requires `K: LosslessStringConvertible` or `K == String`/`Int` for a keyed JSON representation). Giving it a `String` raw value fixes this and lets `FilterPreferencesStore` encode `[FilterCategoryID: Bool]` directly.

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/Filtering/Storage/FilterPreferencesStoreTests.swift`:

```swift
// ADBLXTests/Filtering/Storage/FilterPreferencesStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterPreferencesStore", .serialized)
struct FilterPreferencesStoreTests {
    private func makeStore() async throws -> FilterStore {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("filter_preferences.json"))
        return store
    }

    @Test("first load with no existing file writes and returns explicit defaults for all four categories")
    func firstLoadWritesExplicitDefaults() async throws {
        let filterStore = try await makeStore()
        let preferencesStore = FilterPreferencesStore(store: filterStore)

        let preferences = await preferencesStore.load()

        #expect(preferences.categories[.ads] == true)
        #expect(preferences.categories[.privacy] == true)
        #expect(preferences.categories[.annoyances] == true)
        #expect(preferences.categories[.regional] == true)
        #expect(preferences.filterLists.isEmpty)

        // Defaults must actually be persisted, not just returned in-memory —
        // a second store instance reading the same file should see the same values.
        let data = try await filterStore.read("filter_preferences.json", in: .metadata)
        let decoded = try JSONDecoder().decode(FilterPreferences.self, from: data)
        #expect(decoded.categories[.ads] == true)
    }

    @Test("setCategory persists across a fresh store instance")
    func setCategoryPersists() async throws {
        let filterStore = try await makeStore()
        let preferencesStore = FilterPreferencesStore(store: filterStore)
        _ = await preferencesStore.load()

        await preferencesStore.setCategory(.annoyances, enabled: false)

        let freshInstance = FilterPreferencesStore(store: filterStore)
        let preferences = await freshInstance.load()
        #expect(preferences.categories[.annoyances] == false)
        #expect(preferences.categories[.ads] == true)
    }

    @Test("setFilterList adds or updates an entry and persists it")
    func setFilterListPersists() async throws {
        let filterStore = try await makeStore()
        let preferencesStore = FilterPreferencesStore(store: filterStore)
        _ = await preferencesStore.load()

        await preferencesStore.setFilterList("easylist", enabled: false)

        let freshInstance = FilterPreferencesStore(store: filterStore)
        let preferences = await freshInstance.load()
        #expect(preferences.filterLists["easylist"] == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/FilterPreferencesStoreTests`
Expected: FAIL — `FilterPreferencesStore`/`FilterPreferences` don't exist, `FilterCategoryID` isn't `Codable`/doesn't have a raw value yet.

- [ ] **Step 3: Give `FilterCategoryID` a raw value and `CaseIterable`**

Edit `ADBLX/Features/Protection/ProtectionService.swift`, replacing:

```swift
/// UI-facing mirror of the backend's FilterGroup (Filtering/Models/FilterManifest.swift).
/// Deliberately a separate type — the UI layer never imports FilterGroup directly
/// (Sprint 4 spec §5).
enum FilterCategoryID: Equatable {
    case ads
    case privacy
    case annoyances
    case regional
}
```

with:

```swift
/// UI-facing mirror of the backend's FilterGroup (Filtering/Models/FilterManifest.swift).
/// Deliberately a separate type — the UI layer never imports FilterGroup directly
/// (Sprint 4 spec §5). String raw value + CaseIterable: the canonical, single source
/// of the four-category list — FilterPreferencesStore, RealProtectionService, and
/// AdvancedFilterListsView all iterate FilterCategoryID.allCases rather than each
/// keeping their own hardcoded array (Sprint 5B design doc).
enum FilterCategoryID: String, CaseIterable, Equatable, Codable {
    case ads
    case privacy
    case annoyances
    case regional
}
```

- [ ] **Step 4: Implement `FilterPreferencesStore`**

Create `ADBLX/Filtering/Storage/FilterPreferencesStore.swift`:

```swift
// ADBLX/Filtering/Storage/FilterPreferencesStore.swift
import Foundation

/// Persisted enable/disable state for both protection categories and individual
/// filter lists — one file because both express the same underlying concept
/// ("is this thing on or off"), not two near-identical persistence mechanisms
/// (Sprint 5B design doc).
struct FilterPreferences: Codable, Equatable {
    var categories: [FilterCategoryID: Bool]
    var filterLists: [String: Bool]

    static let defaults = FilterPreferences(
        categories: Dictionary(uniqueKeysWithValues: FilterCategoryID.allCases.map { ($0, true) }),
        filterLists: [:]
    )
}

/// Persists `filter_preferences.json` (FilterStore/Metadata) via the same atomic-write
/// mechanism as `installed_filters.json`. On first load with no existing file, writes
/// and returns explicit defaults rather than treating "missing key" as an implicit
/// default scattered across call sites.
actor FilterPreferencesStore {
    private let store: FilterStore
    private static let filename = "filter_preferences.json"

    init(store: FilterStore) {
        self.store = store
    }

    func load() async -> FilterPreferences {
        guard let data = try? await store.read(Self.filename, in: .metadata),
              let decoded = try? JSONDecoder().decode(FilterPreferences.self, from: data) else {
            let defaults = FilterPreferences.defaults
            try? await save(defaults)
            return defaults
        }
        return decoded
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        var preferences = await load()
        preferences.categories[id] = enabled
        try? await save(preferences)
    }

    func setFilterList(_ id: String, enabled: Bool) async {
        var preferences = await load()
        preferences.filterLists[id] = enabled
        try? await save(preferences)
    }

    private func save(_ preferences: FilterPreferences) async throws {
        let data = try JSONEncoder().encode(preferences)
        try await store.writeMetadata(data, filename: Self.filename)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/FilterPreferencesStoreTests`
Expected: PASS.

- [ ] **Step 6: Build and run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass. `AdvancedFilterListsView.swift`'s private `allCasesForDisplay` extension is untouched by this task (Task 3 removes it) and still compiles since `FilterCategoryID` gaining a raw value doesn't break existing `switch`/equality usage.

- [ ] **Step 7: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Filtering/Storage/FilterPreferencesStore.swift ADBLX/Features/Protection/ProtectionService.swift ADBLXTests/Filtering/Storage/FilterPreferencesStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(protection): add FilterPreferencesStore for category/filter-list toggles

Neither category-level nor filter-list-level enable/disable state
was persisted anywhere. One JSON-backed actor store covers both,
using the same atomic-write mechanism as installed_filters.json.
FilterCategoryID gains a String raw value + CaseIterable so it can
be a JSON dictionary key and so the four-category list has one
canonical source instead of being duplicated across call sites.
EOF
)"
```

---

## Task 2: `RealProtectionService`

**Files:**
- Modify: `ADBLX/Features/Protection/ProtectionService.swift` (add `RealProtectionService`)
- Test: `ADBLXTests/Features/Protection/RealProtectionServiceTests.swift` (new)

**Interfaces:**
- Consumes: `FilterPreferencesStore` (Task 1), `FilterStore.read(_:in:)` (existing), `InstalledFilter` (existing, `ADBLX/Filtering/Models/InstalledFilter.swift`), `FilterGroup` (existing, `ADBLX/Filtering/Models/FilterManifest.swift:24`).
- Produces: `RealProtectionService: ProtectionService`, an `actor`, consumed by `AppCompositionRoot` in Task 4.

Categories are always all four (fixed taxonomy), sourced from `FilterPreferencesStore` for `isEnabled` and `installed_filters.json` for `ruleCount` (summed once per unique group, `0` if nothing installed). Filter lists are built only from genuinely-installed `InstalledFilter` entries — no manifest-fixture blending. `name`/`description` per category stay as static, localized display text (matching how `MockProtectionService` already hardcodes them — these are UI copy, not backend data, so they don't move to `FilterPreferencesStore`).

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/Features/Protection/RealProtectionServiceTests.swift`:

```swift
// ADBLXTests/Features/Protection/RealProtectionServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealProtectionService", .serialized)
struct RealProtectionServiceTests {
    private func makeStores() async throws -> (FilterStore, FilterPreferencesStore) {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("filter_preferences.json"))
        return (filterStore, FilterPreferencesStore(store: filterStore))
    }

    @Test("always returns all four categories, even with nothing installed")
    func alwaysReturnsAllFourCategories() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)

        let status = await service.fetchStatus()

        #expect(status.categories.count == 4)
        #expect(Set(status.categories.map(\.id)) == Set(FilterCategoryID.allCases))
        for category in status.categories {
            #expect(category.ruleCount == 0)
            #expect(category.isEnabled == true)  // FilterPreferences.defaults
        }
        #expect(status.filterLists.isEmpty)
    }

    @Test("category ruleCount sums once per unique group, not per InstalledFilter entry")
    func ruleCountSumsOncePerGroup() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: Date(), ruleCount: 62_000
            ),
            InstalledFilter(
                id: "easylist-extra", group: .ads, installedVersion: "1", checksumSHA256: "b",
                lastUpdated: Date(), ruleCount: 62_000
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        try await filterStore.writeMetadata(data, filename: "installed_filters.json")

        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        let status = await service.fetchStatus()

        let adsCategory = status.categories.first { $0.id == .ads }
        #expect(adsCategory?.ruleCount == 62_000)
        #expect(status.filterLists.count == 2)
    }

    @Test("setCategory writes through to FilterPreferencesStore and is reflected on next fetch")
    func setCategoryWritesThrough() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        _ = await service.fetchStatus()

        await service.setCategory(.privacy, enabled: false)

        let status = await service.fetchStatus()
        let privacyCategory = status.categories.first { $0.id == .privacy }
        #expect(privacyCategory?.isEnabled == false)
    }

    @Test("setFilterList writes through to FilterPreferencesStore and is reflected on next fetch")
    func setFilterListWritesThrough() async throws {
        let (filterStore, preferencesStore) = try await makeStores()
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: Date(), ruleCount: 62_000
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        try await filterStore.writeMetadata(data, filename: "installed_filters.json")
        let service = RealProtectionService(store: filterStore, preferencesStore: preferencesStore)
        _ = await service.fetchStatus()

        await service.setFilterList("easylist", enabled: false)

        let status = await service.fetchStatus()
        #expect(status.filterLists.first?.isEnabled == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/RealProtectionServiceTests`
Expected: FAIL — `RealProtectionService` does not exist.

- [ ] **Step 3: Implement `RealProtectionService`**

Add to the end of `ADBLX/Features/Protection/ProtectionService.swift`:

```swift
/// Real ProtectionService, backing both Safari Protection and Advanced Filter Lists
/// (they share this one service/ViewModel — Sprint 5B design doc). Categories are
/// always all four (fixed application taxonomy matching GroupExtensionIdentifiers'
/// four content blocker extensions), regardless of install state. Filter lists are
/// built only from genuinely-installed InstalledFilter entries — no blending with
/// the Sprint 1 bundled test fixture manifest.
actor RealProtectionService: ProtectionService {
    private let store: FilterStore
    private let preferencesStore: FilterPreferencesStore

    init(store: FilterStore, preferencesStore: FilterPreferencesStore) {
        self.store = store
        self.preferencesStore = preferencesStore
    }

    func fetchStatus() async -> ProtectionStatus {
        let preferences = await preferencesStore.load()
        let filters = (try? await loadInstalledFilters()) ?? []
        let filtersByGroup = Dictionary(grouping: filters, by: \.group)

        let categories = FilterCategoryID.allCases.map { categoryID in
            let group = filterGroup(for: categoryID)
            let groupFilters = filtersByGroup[group] ?? []
            let uniqueRuleCount = Dictionary(grouping: groupFilters, by: \.group)
                .compactMapValues { entries in entries.first?.ruleCount }
                .values.reduce(0, +)
            return ProtectionCategory(
                id: categoryID,
                name: categoryDisplayName(categoryID),
                description: categoryDescription(categoryID),
                isEnabled: preferences.categories[categoryID] ?? true,
                ruleCount: uniqueRuleCount
            )
        }

        let filterLists = filters.map { filter in
            FilterListEntry(
                id: filter.id,
                name: filter.id,
                category: categoryID(for: filter.group),
                version: filter.installedVersion,
                isEnabled: preferences.filterLists[filter.id] ?? true,
                isPremium: false
            )
        }

        return ProtectionStatus(
            isSafariExtensionEnabled: true,
            categories: categories,
            filterLists: filterLists
        )
    }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        await preferencesStore.setCategory(id, enabled: enabled)
    }

    func setFilterList(_ id: String, enabled: Bool) async {
        await preferencesStore.setFilterList(id, enabled: enabled)
    }

    private func loadInstalledFilters() async throws -> [InstalledFilter] {
        let data = try await store.read("installed_filters.json", in: .metadata)
        return try JSONDecoder().decode([InstalledFilter].self, from: data)
    }

    private func filterGroup(for categoryID: FilterCategoryID) -> FilterGroup {
        switch categoryID {
        case .ads: return .ads
        case .privacy: return .privacy
        case .annoyances: return .annoyances
        case .regional: return .regional
        }
    }

    private func categoryID(for group: FilterGroup) -> FilterCategoryID {
        switch group {
        case .ads: return .ads
        case .privacy: return .privacy
        case .annoyances: return .annoyances
        case .regional: return .regional
        }
    }

    private func categoryDisplayName(_ id: FilterCategoryID) -> String {
        switch id {
        case .ads: return String(localized: "protection.category.ads")
        case .privacy: return String(localized: "protection.category.privacy")
        case .annoyances: return String(localized: "protection.category.annoyances")
        case .regional: return String(localized: "protection.category.regional")
        }
    }

    private func categoryDescription(_ id: FilterCategoryID) -> String {
        switch id {
        case .ads: return String(localized: "protection.category.ads.description")
        case .privacy: return String(localized: "protection.category.privacy.description")
        case .annoyances: return String(localized: "protection.category.annoyances.description")
        case .regional: return String(localized: "protection.category.regional.description")
        }
    }
}
```

(`uniqueRuleCount`'s inner `Dictionary(grouping:by:)` looks redundant against the outer `filtersByGroup` grouping — it's there because `groupFilters` for a single category can still contain 2+ `InstalledFilter` entries sharing one group-level `ruleCount` per `docs/gotchas.md`, and `.compactMapValues { $0.first?.ruleCount }.values.reduce(0, +)` collapses that to "take the (identical) group-level count once." Since `groupFilters` is already filtered to one group, this simplifies to `groupFilters.first?.ruleCount ?? 0` — use that simpler form instead: replace the `uniqueRuleCount` line with `let uniqueRuleCount = groupFilters.first?.ruleCount ?? 0`.)

- [ ] **Step 4: Simplify the ruleCount calculation per the note above**

Edit the `fetchStatus()` method just written, replacing:

```swift
            let groupFilters = filtersByGroup[group] ?? []
            let uniqueRuleCount = Dictionary(grouping: groupFilters, by: \.group)
                .compactMapValues { entries in entries.first?.ruleCount }
                .values.reduce(0, +)
```

with:

```swift
            let groupFilters = filtersByGroup[group] ?? []
            let uniqueRuleCount = groupFilters.first?.ruleCount ?? 0
```

- [ ] **Step 5: Add the four new localization keys `categoryDescription` references**

Edit `ADBLX/Resources/Localizable.xcstrings`, adding after the existing `"protection.category.regional"` entry (currently followed by `"protection.action.applyChanges"`):

```json
    "protection.category.ads.description" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Blocks display and video ads" } } }
    },
    "protection.category.privacy.description" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Blocks trackers and analytics scripts" } } }
    },
    "protection.category.annoyances.description" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Hides cookie banners and popups" } } }
    },
    "protection.category.regional.description" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Extra rules for regional ad networks" } } }
    },
```

(Values copied verbatim from `MockProtectionService`'s existing hardcoded descriptions, now properly localized instead of literal Swift strings.)

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/RealProtectionServiceTests`
Expected: PASS.

- [ ] **Step 7: Build and run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Protection/ProtectionService.swift ADBLX/Resources/Localizable.xcstrings ADBLXTests/Features/Protection/RealProtectionServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(protection): implement RealProtectionService

Categories are always all four (fixed taxonomy), sourcing isEnabled
from FilterPreferencesStore and ruleCount from installed_filters.json
(0 if nothing installed for that category, summed once per group per
docs/gotchas.md). Filter lists are built only from genuinely-installed
InstalledFilter entries, no blending with the Sprint 1 bundled test
fixture manifest — sparse until Sprint 5A's UpdateCoordinator wiring
and a real CDN manifest exist, which is honest rather than a bug.
EOF
)"
```

---

## Task 3: Wire `RealProtectionService` into `AppCompositionRoot`, update `AdvancedFilterListsView`

**Files:**
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/Features/Protection/AdvancedFilterListsView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `RealProtectionService` (Task 2), `FilterPreferencesStore` (Task 1), `AppCompositionRoot.makeFilterStore()` (existing, Sprint 5A).
- Produces: `AppCompositionRoot.makeFilterPreferencesStore(store:) -> FilterPreferencesStore`, `UIDependencies.protectionService` now returns `RealProtectionService`.

- [ ] **Step 1: Add the factory method and wire it into `makeUIDependencies`**

Edit `ADBLX/AppCompositionRoot.swift`, adding after `makeFilterStore()`:

```swift
    /// The single `FilterPreferencesStore` instance — same "one instance per backend
    /// type" principle as makeFilterStore(). No factory or service constructs its own.
    static func makeFilterPreferencesStore(store: FilterStore) -> FilterPreferencesStore {
        FilterPreferencesStore(store: store)
    }
```

Then replace the `.mock` case body inside `makeUIDependencies`:

```swift
    static func makeUIDependencies(configuration: UIDependenciesConfiguration, store: FilterStore) -> UIDependencies {
        switch configuration {
        case .mock:
            let preferencesStore = makeFilterPreferencesStore(store: store)
            return UIDependencies(
                homeService: RealHomeService(store: store),
                protectionService: RealProtectionService(store: store, preferencesStore: preferencesStore),
                subscriptionService: MockSubscriptionService(),
                settingsService: MockSettingsService()
            )
        }
    }
```

- [ ] **Step 2: Update `AdvancedFilterListsView` to use `FilterCategoryID.allCases` and add an empty-state message**

Edit `ADBLX/Features/Protection/AdvancedFilterListsView.swift`, replacing the `body`'s `ForEach`:

```swift
                if let lists = viewModel.status?.filterLists {
                    ForEach(FilterCategoryID.allCasesForDisplay, id: \.self) { category in
                        let listsInCategory = lists.filter { $0.category == category }
                        if !listsInCategory.isEmpty {
                            categorySection(titleKey: category.displayNameKey, lists: listsInCategory)
                        }
                    }
                }
```

with:

```swift
                if let lists = viewModel.status?.filterLists {
                    if lists.isEmpty {
                        emptyState
                    } else {
                        ForEach(FilterCategoryID.allCases, id: \.self) { category in
                            let listsInCategory = lists.filter { $0.category == category }
                            if !listsInCategory.isEmpty {
                                categorySection(titleKey: category.displayNameKey, lists: listsInCategory)
                            }
                        }
                    }
                }
```

Add a new `emptyState` computed property right after `header`:

```swift
    private var emptyState: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Text("protection.filterLists.empty")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSpacing.sectionGap)
    }
```

Remove the private extension at the bottom of the file that's now dead code:

```swift
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
```

Replace it with just the `displayNameKey` computed property (the `allCasesForDisplay` array is gone, replaced by `FilterCategoryID.allCases`, but `displayNameKey` is still used by `categorySection(titleKey:lists:)` and has no equivalent elsewhere):

```swift
private extension FilterCategoryID {
    var displayNameKey: LocalizedStringKey {
        switch self {
        case .ads: return "protection.category.ads"
        case .privacy: return "protection.category.privacy"
        case .annoyances: return "protection.category.annoyances"
        case .regional: return "protection.category.regional"
        }
    }
}
```

- [ ] **Step 3: Add the new localization key**

Edit `ADBLX/Resources/Localizable.xcstrings`, adding after `"protection.filterLists.subtitle"`:

```json
    "protection.filterLists.empty" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Filter lists will appear here after the first successful synchronization." } } }
    },
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the SwiftLint check**

Run: `swiftlint lint --path ADBLX/Features/Protection/AdvancedFilterListsView.swift`
Expected: no violations.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 7: Manual simulator check**

Open `ADBLX.xcodeproj` in Xcode, run on an iOS Simulator, navigate to Protection → Advanced Filter Lists.
Expected: after a fresh install (only the bootstrap ads snapshot installed), the Ads category section shows one real filter list entry; Privacy/Annoyances/Regional show nothing (or the whole screen shows the empty-state message if literally nothing is installed yet — check timing against `ContentBlockerBootstrap`). Navigate to Safari Protection: all four category tiles are visible with real toggle state that persists across app relaunch.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/AppCompositionRoot.swift ADBLX/Features/Protection/AdvancedFilterListsView.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
feat(protection): wire RealProtectionService into the composition root

Safari Protection and Advanced Filter Lists both go live in one
commit since they share ProtectionViewModel/ProtectionService.
AdvancedFilterListsView now iterates FilterCategoryID.allCases
instead of a duplicated private array, and shows an honest empty
state instead of nothing when no filter lists are installed yet.
EOF
)"
```

---

## Task 4: `UpdateCoordinator.run(onPhaseChange:)`

**Files:**
- Modify: `ADBLX/Filtering/Updates/UpdateCoordinator.swift`
- Test: `ADBLXTests/Features/UpdateProgress/UpdateCoordinatorProgressTests.swift` (new)

**Interfaces:**
- Consumes: `UpdatePhase` (existing, `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift:5-12`).
- Produces: `UpdateCoordinator.run(onPhaseChange: (UpdatePhase) -> Void = { _ in }) async throws -> UpdateRunResult`, consumed by `UpdateProgressModel` in Task 5.

`UpdatePhase` is currently defined in `UpdateProgressModel.swift` (a `Features/` file); `UpdateCoordinator.swift` lives in `Filtering/Updates/`. Since `UpdatePhase` becomes a shared vocabulary between both layers, this task does not move the type — Swift files in the same module (`ADBLX`) can reference each other regardless of directory, so `UpdateCoordinator.swift` can reference `UpdatePhase` without an import change. (If this feels backwards architecturally, note it for a future cleanup — not blocking for this task.)

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/Features/UpdateProgress/UpdateCoordinatorProgressTests.swift`:

```swift
// ADBLXTests/Features/UpdateProgress/UpdateCoordinatorProgressTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("UpdateCoordinator onPhaseChange", .serialized)
struct UpdateCoordinatorProgressTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let filterSourceURL = URL(string: "https://example.com/easylist.txt")!
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    @Test("run() with no callback behaves exactly as before (default no-op)")
    func defaultParameterIsBackwardCompatible() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(
            url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )!
        let session = MockHTTPSession(responses: [manifestEndpoint: .success((manifestData, manifestResponse))])
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )

        // No onPhaseChange argument — must compile and behave identically to
        // pre-Sprint-5B callers (UpdateCoordinatorTests never passes one).
        let result = try await coordinator.run()

        guard case .upToDate = result else {
            Issue.record("expected .upToDate (empty manifest, no install actions), got \(result)")
            return
        }
    }

    @Test("run() reports .checking then .complete for an up-to-date result")
    func reportsCheckingThenComplete() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(
            url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )!
        let session = MockHTTPSession(responses: [manifestEndpoint: .success((manifestData, manifestResponse))])
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )

        var observedPhases: [UpdatePhase] = []
        _ = try await coordinator.run { phase in observedPhases.append(phase) }

        #expect(observedPhases.first == .checking)
        #expect(observedPhases.last == .complete)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/UpdateCoordinatorProgressTests`
Expected: FAIL — `run()` doesn't accept an `onPhaseChange` argument yet.

- [ ] **Step 3: Add the callback parameter and call it at the four checkpoints**

Edit `ADBLX/Filtering/Updates/UpdateCoordinator.swift`, replacing the `run()` method:

```swift
    func run() async throws -> UpdateRunResult {
        let cached = try await manifestStore.load()
        let fetchResult = try await manifestClient.fetch(previousETag: cached?.etag)

        let manifest: FilterManifest
        let etag: String?
        switch fetchResult {
        case .notModified:
            return .upToDate
        case .updated(let fetchedManifest, let fetchedETag):
            manifest = fetchedManifest
            etag = fetchedETag
        }

        let installedFilters = try await currentInstalledFilters()
        let plan = UpdatePlanner.plan(manifest: manifest, installed: installedFilters)
        let installGroups: [(group: FilterGroup, entries: [FilterManifest.Entry])] = plan.actions.compactMap {
            if case .install(let group, let entries) = $0 { return (group, entries) }
            return nil
        }

        guard !installGroups.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            return .upToDate
        }

        // Download and verify every group up front, before any write — a checksum
        // failure in one group must not leave another group's files half-written.
        var downloadedByGroup: [FilterGroup: [DownloadedFilter]] = [:]
        for (group, entries) in installGroups {
            var downloaded: [DownloadedFilter] = []
            for entry in entries {
                downloaded.append(try await downloadClient.download(entry))
            }
            for filter in downloaded {
                try Checksum.verify(fileURL: filter.tempFileURL, against: filter.expectedChecksum)
            }
            downloadedByGroup[group] = downloaded
        }

        let snapshot = try await store.snapshotForRollback()
        let affectedExtensionIDs = installGroups.map { extensionIdentifiers[$0.group] }
        var installedFilterIDs: [String] = []

        do {
            // One group composed and installed at a time — keeps at most one group's
            // decoded sources resident in memory (Sprint 3A design doc's <200MB target).
            for (group, _) in installGroups {
                let downloaded = downloadedByGroup[group] ?? []
                var sources: [FilterSource] = []
                for filter in downloaded {
                    // Bridge because FilterPipeline.install is Data-based. If a future
                    // overload accepts a URL directly, this read disappears.
                    let data = try Data(contentsOf: filter.tempFileURL)
                    sources.append(FilterSource(
                        filterID: filter.filterID,
                        version: filter.version,
                        checksumSHA256: filter.expectedChecksum,
                        data: data
                    ))
                }
                let composition = GroupComposition(group: group, sources: sources)
                _ = try await pipeline.install(composition, reloadStrategy: .deferred)
                installedFilterIDs.append(contentsOf: downloaded.map(\.filterID))
            }
            try await manifestStore.save(manifest, etag: etag)
            let reloadResults = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .updated(installedFilterIDs: installedFilterIDs, reloadResults: reloadResults)
        } catch {
            do {
                try await store.restore(snapshot)
            } catch let restoreError {
                // `store.restore` only deletes `Previous/` after both directory
                // replacements succeed, so a thrown restoreError here means the
                // snapshot is still on disk — do not attempt a second automatic
                // retry; surface both failures distinctly instead of losing the
                // original install failure or crashing the caller with a raw throw.
                return .rollbackFailed(originalReason: error, restoreError: restoreError)
            }
            _ = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .rolledBack(reason: error)
        }
    }
```

with (adding the parameter and four `onPhaseChange` calls at the checkpoints identified in the design doc):

```swift
    /// `onPhaseChange` is additive — defaults to a no-op so existing callers (and
    /// UpdateCoordinatorTests) are unaffected. Called at four checkpoints matching
    /// UpdatePhase's in-flight cases: before the manifest fetch (.checking), before
    /// the download+verify loop (.downloading), before the per-group install loop
    /// (.installing), and on completion (.complete/.failed via the caller's catch,
    /// since run() throws rather than returning a .failed case itself — see
    /// UpdateProgressModel.start(coordinator:) in Sprint 5B Commit 2).
    func run(onPhaseChange: (UpdatePhase) -> Void = { _ in }) async throws -> UpdateRunResult {
        onPhaseChange(.checking)
        let cached = try await manifestStore.load()
        let fetchResult = try await manifestClient.fetch(previousETag: cached?.etag)

        let manifest: FilterManifest
        let etag: String?
        switch fetchResult {
        case .notModified:
            onPhaseChange(.complete)
            return .upToDate
        case .updated(let fetchedManifest, let fetchedETag):
            manifest = fetchedManifest
            etag = fetchedETag
        }

        let installedFilters = try await currentInstalledFilters()
        let plan = UpdatePlanner.plan(manifest: manifest, installed: installedFilters)
        let installGroups: [(group: FilterGroup, entries: [FilterManifest.Entry])] = plan.actions.compactMap {
            if case .install(let group, let entries) = $0 { return (group, entries) }
            return nil
        }

        guard !installGroups.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            onPhaseChange(.complete)
            return .upToDate
        }

        onPhaseChange(.downloading)
        // Download and verify every group up front, before any write — a checksum
        // failure in one group must not leave another group's files half-written.
        var downloadedByGroup: [FilterGroup: [DownloadedFilter]] = [:]
        for (group, entries) in installGroups {
            var downloaded: [DownloadedFilter] = []
            for entry in entries {
                downloaded.append(try await downloadClient.download(entry))
            }
            for filter in downloaded {
                try Checksum.verify(fileURL: filter.tempFileURL, against: filter.expectedChecksum)
            }
            downloadedByGroup[group] = downloaded
        }

        let snapshot = try await store.snapshotForRollback()
        let affectedExtensionIDs = installGroups.map { extensionIdentifiers[$0.group] }
        var installedFilterIDs: [String] = []

        onPhaseChange(.installing)
        do {
            // One group composed and installed at a time — keeps at most one group's
            // decoded sources resident in memory (Sprint 3A design doc's <200MB target).
            for (group, _) in installGroups {
                let downloaded = downloadedByGroup[group] ?? []
                var sources: [FilterSource] = []
                for filter in downloaded {
                    // Bridge because FilterPipeline.install is Data-based. If a future
                    // overload accepts a URL directly, this read disappears.
                    let data = try Data(contentsOf: filter.tempFileURL)
                    sources.append(FilterSource(
                        filterID: filter.filterID,
                        version: filter.version,
                        checksumSHA256: filter.expectedChecksum,
                        data: data
                    ))
                }
                let composition = GroupComposition(group: group, sources: sources)
                _ = try await pipeline.install(composition, reloadStrategy: .deferred)
                installedFilterIDs.append(contentsOf: downloaded.map(\.filterID))
            }
            try await manifestStore.save(manifest, etag: etag)
            let reloadResults = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            onPhaseChange(.complete)
            return .updated(installedFilterIDs: installedFilterIDs, reloadResults: reloadResults)
        } catch {
            do {
                try await store.restore(snapshot)
            } catch let restoreError {
                // `store.restore` only deletes `Previous/` after both directory
                // replacements succeed, so a thrown restoreError here means the
                // snapshot is still on disk — do not attempt a second automatic
                // retry; surface both failures distinctly instead of losing the
                // original install failure or crashing the caller with a raw throw.
                return .rollbackFailed(originalReason: error, restoreError: restoreError)
            }
            _ = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .rolledBack(reason: error)
        }
    }
```

Note: the `.rolledBack`/`.rollbackFailed` return paths intentionally do NOT call `onPhaseChange(.failed(...))` — `run()` still returns a value (not `throws`) for those cases, and `UpdatePhase.failed` takes a `String` message that `UpdateRunResult`'s cases don't carry directly. `UpdateProgressModel.start(coordinator:)` (Task 5) is responsible for translating a non-`.updated`/`.upToDate` result or a thrown error into `.failed`, not `run()` itself — keeping `onPhaseChange` a pure "what stage am I in" signal, not a result-translation layer.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/UpdateCoordinatorProgressTests`
Expected: PASS.

- [ ] **Step 5: Build and run the full test suite, including the pre-existing `UpdateCoordinatorTests`**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/UpdateCoordinatorTests`
Expected: PASS — every existing test calls `coordinator.run()` with no arguments and must be unaffected by the new default parameter.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Filtering/Updates/UpdateCoordinator.swift ADBLXTests/Features/UpdateProgress/UpdateCoordinatorProgressTests.swift
git commit -m "$(cat <<'EOF'
feat(updates): add optional onPhaseChange callback to UpdateCoordinator.run()

Additive, default-no-op parameter called at the four checkpoints
that map onto UpdatePhase's in-flight cases (.checking before the
manifest fetch, .downloading before the download+verify loop,
.installing before the per-group pipeline.install loop, .complete
on any successful return). Existing callers (UpdateCoordinatorTests)
are unaffected. Rollback paths intentionally don't call onPhaseChange
with .failed — that translation belongs to the caller (Sprint 5B
Commit 2's UpdateProgressModel), keeping this a pure stage signal.
EOF
)"
```

---

## Task 5: `UpdateProgressModel.start(coordinator:)` and threading `UpdateCoordinator` to the views

**Files:**
- Modify: `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift`
- Modify: `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift`
- Modify: `ADBLX/AppCompositionRoot.swift` (`UIDependencies` gains `updateCoordinator`)
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Modify: `ADBLX/Features/Home/HomeView.swift`
- Modify: `ADBLX/Features/Protection/SafariProtectionView.swift`
- Modify: `ADBLX/ADBLXApp.swift` (verify `updateCoordinator` passed through)
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `UpdateCoordinator.run(onPhaseChange:)` (Task 4), `UpdateCoordinator` (existing, `AppCompositionRoot.makeUpdateCoordinator`, Sprint 5A).
- Produces: `UpdateProgressModel.start(coordinator: UpdateCoordinator) async`, `UIDependencies.updateCoordinator: UpdateCoordinator`, consumed by `HomeView`/`SafariProtectionView`'s `.sheet`.

Neither `HomeView` nor `SafariProtectionView` has access to `UpdateCoordinator` today — `UIDependencies` doesn't carry it, and both views construct `UpdateProgressModel()` with no arguments. This task adds `updateCoordinator` to `UIDependencies` and threads it down, which the Sprint 5B design doc's "the sheet itself does not change" claim undersells slightly — the sheet's *body* doesn't change, but its construction call site does, in both views that present it.

- [ ] **Step 1: Write the failing test**

Create/extend `ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift` if it doesn't exist, or add to the existing one:

```bash
cat /Users/sreeharshag/Work/ADBLX/ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift
```

Add this test to that file (create the file with this content if the `cat` above shows nothing / the file doesn't exist yet):

```swift
// ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("UpdateProgressModel", .serialized)
struct UpdateProgressModelTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    @Test("start(coordinator:) reaches .complete for a real up-to-date result")
    func startReachesComplete() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(
            url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )!
        let session = MockHTTPSession(responses: [manifestEndpoint: .success((manifestData, manifestResponse))])
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )
        let model = UpdateProgressModel()

        await model.start(coordinator: coordinator)

        #expect(model.phase == .complete)
    }

    @Test("start(coordinator:) reaches .failed when the coordinator throws")
    func startReachesFailedOnThrow() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let session = MockHTTPSession(responses: [:])  // no registered response — throws UnregisteredURL
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline, store: store, reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )
        let model = UpdateProgressModel()

        await model.start(coordinator: coordinator)

        guard case .failed = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/UpdateProgressModelTests`
Expected: FAIL — `start(coordinator:)` doesn't exist yet (only parameterless `start()` does).

- [ ] **Step 3: Implement `start(coordinator:)`**

Edit `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift`, replacing the whole file:

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

/// Drives the shared Update Progress sheet, presentable from Home or Protection.
/// Sprint 5B: start(coordinator:) replaces the earlier canned local sequence with
/// real UpdateCoordinator.run(onPhaseChange:) calls — the sheet itself is unchanged,
/// only its construction call sites (HomeView/SafariProtectionView) now pass a
/// coordinator through.
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

    func start(coordinator: UpdateCoordinator) async {
        do {
            let result = try await coordinator.run { [weak self] newPhase in
                self?.phase = newPhase
            }
            switch result {
            case .upToDate, .updated:
                phase = .complete
            case .rolledBack, .rollbackFailed:
                phase = .failed(String(localized: "updateprogress.status.failed"))
            }
        } catch {
            phase = .failed(String(localized: "updateprogress.status.failed"))
        }
    }
}
```

(`onPhaseChange`'s own `.complete` call inside `UpdateCoordinator.run()` (Task 4) already sets `phase = .complete` for the `.updated`/`.upToDate` success paths via the closure — the explicit `switch result` here exists specifically to catch `.rolledBack`/`.rollbackFailed`, which `run()` returns as values rather than throwing, and which `onPhaseChange` deliberately does not translate into `.failed` itself per Task 4's design note.)

- [ ] **Step 4: Add the new localization key**

Edit `ADBLX/Resources/Localizable.xcstrings`, adding after `"updateprogress.status.complete"`:

```json
    "updateprogress.status.failed" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Unable to check for updates. Please try again later." } } }
    },
```

- [ ] **Step 5: Update `UpdateProgressSheet` to accept and pass through the coordinator**

Edit `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift`, replacing:

```swift
struct UpdateProgressSheet: View {
    @State var model: UpdateProgressModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
```

with:

```swift
struct UpdateProgressSheet: View {
    @State var model: UpdateProgressModel
    let coordinator: UpdateCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
```

and replacing:

```swift
        .task { await model.start() }
```

with:

```swift
        .task { await model.start(coordinator: coordinator) }
```

And the `#Preview` at the bottom needs a coordinator — since previews don't have `AppCompositionRoot`'s app-lifetime instance available, construct a throwaway one inline:

```swift
#Preview {
    UpdateProgressSheet(
        model: UpdateProgressModel(),
        coordinator: AppCompositionRoot.makeUpdateCoordinator(
            pipeline: AppCompositionRoot.makeFilterPipeline(store: AppCompositionRoot.makeFilterStore()),
            store: AppCompositionRoot.makeFilterStore()
        )
    )
}
```

- [ ] **Step 6: Add `updateCoordinator` to `UIDependencies` and thread it through**

Edit `ADBLX/AppCompositionRoot.swift`, adding `updateCoordinator` to the `UIDependencies` struct:

```swift
    struct UIDependencies {
        let homeService: HomeService
        let protectionService: ProtectionService
        let subscriptionService: SubscriptionService
        let settingsService: SettingsService
        let updateCoordinator: UpdateCoordinator
    }
```

Update `makeUIDependencies` to accept and store it:

```swift
    static func makeUIDependencies(
        configuration: UIDependenciesConfiguration,
        store: FilterStore,
        updateCoordinator: UpdateCoordinator
    ) -> UIDependencies {
        switch configuration {
        case .mock:
            let preferencesStore = makeFilterPreferencesStore(store: store)
            return UIDependencies(
                homeService: RealHomeService(store: store),
                protectionService: RealProtectionService(store: store, preferencesStore: preferencesStore),
                subscriptionService: MockSubscriptionService(),
                settingsService: MockSettingsService(),
                updateCoordinator: updateCoordinator
            )
        }
    }
```

- [ ] **Step 7: Update `ADBLXApp.swift`'s call site**

Edit `ADBLX/ADBLXApp.swift`, changing:

```swift
        uiDependencies = AppCompositionRoot.makeUIDependencies(configuration: .mock, store: store)
```

to:

```swift
        uiDependencies = AppCompositionRoot.makeUIDependencies(
            configuration: .mock, store: store, updateCoordinator: updateCoordinator
        )
```

- [ ] **Step 8: Update `RootTabView`'s `#Preview` call site**

Edit `ADBLX/Navigation/RootTabView.swift`, changing:

```swift
#Preview {
    RootTabView(dependencies: AppCompositionRoot.makeUIDependencies(configuration: .mock, store: AppCompositionRoot.makeFilterStore()))
}
```

to:

```swift
#Preview {
    let store = AppCompositionRoot.makeFilterStore()
    let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
    RootTabView(dependencies: AppCompositionRoot.makeUIDependencies(
        configuration: .mock,
        store: store,
        updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
    ))
}
```

- [ ] **Step 9: Update `HomeView`'s `.sheet` to pass the coordinator**

Edit `ADBLX/Features/Home/HomeView.swift`. This view currently has no access to `UIDependencies` — it only receives `HomeViewModel`. Add a new stored property:

```swift
struct HomeView: View {
    @State var viewModel: HomeViewModel
    let updateCoordinator: UpdateCoordinator
    @State private var isShowingUpdateProgress = false
```

Change the `.sheet`:

```swift
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel())
        }
```

to:

```swift
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel(), coordinator: updateCoordinator)
        }
```

Update the `#Preview` at the bottom:

```swift
#Preview {
    let store = AppCompositionRoot.makeFilterStore()
    HomeView(
        viewModel: HomeViewModel(service: MockHomeService()),
        updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(
            pipeline: AppCompositionRoot.makeFilterPipeline(store: store), store: store
        )
    )
}
```

- [ ] **Step 10: Update `SafariProtectionView`'s `.sheet` to pass the coordinator**

Edit `ADBLX/Features/Protection/SafariProtectionView.swift`, applying the identical pattern:

```swift
struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel
    let updateCoordinator: UpdateCoordinator
    @State private var isShowingUpdateProgress = false
```

```swift
        .sheet(isPresented: $isShowingUpdateProgress) {
            UpdateProgressSheet(model: UpdateProgressModel(), coordinator: updateCoordinator)
        }
```

Update the `#Preview`:

```swift
#Preview {
    let store = AppCompositionRoot.makeFilterStore()
    NavigationStack {
        SafariProtectionView(
            viewModel: ProtectionViewModel(service: MockProtectionService()),
            updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(
                pipeline: AppCompositionRoot.makeFilterPipeline(store: store), store: store
            )
        )
    }
}
```

- [ ] **Step 11: Update `RootTabView`'s construction of both views**

Edit `ADBLX/Navigation/RootTabView.swift`'s `placeholder(for:)`:

```swift
        case .home:
            HomeView(viewModel: HomeViewModel(service: dependencies.homeService))
```

to:

```swift
        case .home:
            HomeView(viewModel: HomeViewModel(service: dependencies.homeService), updateCoordinator: dependencies.updateCoordinator)
```

and:

```swift
        case .protection:
            NavigationStack {
                SafariProtectionView(viewModel: ProtectionViewModel(service: dependencies.protectionService))
            }
```

to:

```swift
        case .protection:
            NavigationStack {
                SafariProtectionView(
                    viewModel: ProtectionViewModel(service: dependencies.protectionService),
                    updateCoordinator: dependencies.updateCoordinator
                )
            }
```

- [ ] **Step 12: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/UpdateProgressModelTests`
Expected: PASS.

- [ ] **Step 13: Build and run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 14: Manual simulator check**

Open `ADBLX.xcodeproj` in Xcode, run on an iOS Simulator. From Home, tap "Update Filters" — expect the sheet to show a spinner with "Checking for updates…", then transition to a failure state with "Unable to check for updates. Please try again later." (since `AppManifestEndpointProvider`'s placeholder `https://example.invalid` genuinely can't be reached). Repeat from Safari Protection's equivalent entry point if one exists in the current UI, or confirm `UpdateProgressSheet` is reachable from both screens per the design doc's "presentable from Home or Protection" note.

- [ ] **Step 15: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/UpdateProgress/UpdateProgressModel.swift ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift ADBLX/AppCompositionRoot.swift ADBLX/ADBLXApp.swift ADBLX/Navigation/RootTabView.swift ADBLX/Features/Home/HomeView.swift ADBLX/Features/Protection/SafariProtectionView.swift ADBLX/Resources/Localizable.xcstrings ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift
git commit -m "$(cat <<'EOF'
feat(update-progress): wire UpdateProgressModel to real UpdateCoordinator

start(coordinator:) replaces the canned sleep sequence with a real
UpdateCoordinator.run(onPhaseChange:) call. UIDependencies gains
updateCoordinator, threaded through RootTabView into HomeView and
SafariProtectionView (neither had access to it before), which both
now pass it into UpdateProgressSheet. Since no real CDN manifest
endpoint exists yet (Sprint 5A), a live check genuinely fails and
surfaces as an honest "Unable to check for updates" state rather
than simulated progress.
EOF
)"
```

---

## Task 6: `AllowlistStore` and `RealSettingsService`

**Files:**
- Create: `ADBLX/Filtering/Storage/AllowlistStore.swift`
- Modify: `ADBLX/Features/Settings/SettingsService.swift` (add `RealSettingsService`)
- Test: `ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift` (new)
- Test: `ADBLXTests/Features/Settings/RealSettingsServiceTests.swift` (new)

**Interfaces:**
- Consumes: `FilterStore.read(_:in:)`/`writeMetadata(_:filename:)` (existing), `AllowlistEntry`/`SettingsSnapshot` (existing, `ADBLX/Features/Settings/SettingsService.swift:4-12`).
- Produces: `AllowlistStore` actor with `func load() async -> [AllowlistEntry]`, `func add(domain:) async`, `func remove(id:) async`; `RealSettingsService: SettingsService`, consumed by `AppCompositionRoot` in Task 8.

`RealSettingsService.iCloudSyncEnabled` stays hardcoded `false` — no iCloud sync backend exists, this is explicitly unchanged scope per the design doc (not a regression, just not built).

- [ ] **Step 1: Write the failing tests**

Create `ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift`:

```swift
// ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("AllowlistStore", .serialized)
struct AllowlistStoreTests {
    private func makeStore() async throws -> FilterStore {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("allowlist.json"))
        return store
    }

    @Test("no existing file returns an empty list")
    func emptyByDefault() async throws {
        let filterStore = try await makeStore()
        let allowlistStore = AllowlistStore(store: filterStore)

        let entries = await allowlistStore.load()

        #expect(entries.isEmpty)
    }

    @Test("add persists a new entry across a fresh store instance")
    func addPersists() async throws {
        let filterStore = try await makeStore()
        let allowlistStore = AllowlistStore(store: filterStore)

        await allowlistStore.add(domain: "example.com")

        let freshInstance = AllowlistStore(store: filterStore)
        let entries = await freshInstance.load()
        #expect(entries.count == 1)
        #expect(entries.first?.domain == "example.com")
    }

    @Test("remove deletes the matching entry and persists the removal")
    func removePersists() async throws {
        let filterStore = try await makeStore()
        let allowlistStore = AllowlistStore(store: filterStore)
        await allowlistStore.add(domain: "example.com")
        let entries = await allowlistStore.load()
        let entryID = entries[0].id

        await allowlistStore.remove(id: entryID)

        let freshInstance = AllowlistStore(store: filterStore)
        let remaining = await freshInstance.load()
        #expect(remaining.isEmpty)
    }
}
```

Create `ADBLXTests/Features/Settings/RealSettingsServiceTests.swift`:

```swift
// ADBLXTests/Features/Settings/RealSettingsServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealSettingsService", .serialized)
struct RealSettingsServiceTests {
    private func makeService() async throws -> RealSettingsService {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("allowlist.json"))
        return RealSettingsService(allowlistStore: AllowlistStore(store: filterStore))
    }

    @Test("fetchSnapshot reflects real allowlist state and a hardcoded false iCloudSyncEnabled")
    func fetchSnapshotReflectsRealState() async throws {
        let service = try await makeService()

        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.iCloudSyncEnabled == false)
        #expect(snapshot.allowlist.isEmpty)
    }

    @Test("addAllowlistEntry then fetchSnapshot shows the new entry")
    func addThenFetchShowsEntry() async throws {
        let service = try await makeService()

        await service.addAllowlistEntry(domain: "news.example.com")
        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.allowlist.count == 1)
        #expect(snapshot.allowlist.first?.domain == "news.example.com")
    }

    @Test("removeAllowlistEntry then fetchSnapshot no longer shows the entry")
    func removeThenFetchOmitsEntry() async throws {
        let service = try await makeService()
        await service.addAllowlistEntry(domain: "news.example.com")
        let firstSnapshot = await service.fetchSnapshot()
        let entryID = firstSnapshot.allowlist[0].id

        await service.removeAllowlistEntry(id: entryID)
        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.allowlist.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AllowlistStoreTests -only-testing:ADBLXTests/RealSettingsServiceTests`
Expected: FAIL — `AllowlistStore`/`RealSettingsService` don't exist.

- [ ] **Step 3: Implement `AllowlistStore`**

Create `ADBLX/Filtering/Storage/AllowlistStore.swift`:

```swift
// ADBLX/Filtering/Storage/AllowlistStore.swift
import Foundation

/// Persists `allowlist.json` (FilterStore/Metadata) via the same atomic-write
/// mechanism as `installed_filters.json`/`filter_preferences.json`. Storage only —
/// this does not exempt any domain from blocking. Real enforcement (touching
/// FilterPipeline/CompositionService/RuleCompiler) is separate, larger, deferred
/// work (Sprint 5B design doc).
actor AllowlistStore {
    private let store: FilterStore
    private static let filename = "allowlist.json"

    init(store: FilterStore) {
        self.store = store
    }

    func load() async -> [AllowlistEntry] {
        guard let data = try? await store.read(Self.filename, in: .metadata),
              let decoded = try? JSONDecoder().decode([AllowlistEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    func add(domain: String) async {
        var entries = await load()
        entries.append(AllowlistEntry(id: UUID().uuidString, domain: domain))
        try? await save(entries)
    }

    func remove(id: String) async {
        var entries = await load()
        entries.removeAll { $0.id == id }
        try? await save(entries)
    }

    private func save(_ entries: [AllowlistEntry]) async throws {
        let data = try JSONEncoder().encode(entries)
        try await store.writeMetadata(data, filename: Self.filename)
    }
}
```

`AllowlistEntry` needs `Codable` conformance — it currently only has `Equatable, Identifiable`.

- [ ] **Step 4: Give `AllowlistEntry` `Codable` conformance**

Edit `ADBLX/Features/Settings/SettingsService.swift`, replacing:

```swift
struct AllowlistEntry: Equatable, Identifiable {
    let id: String
    let domain: String
}
```

with:

```swift
struct AllowlistEntry: Codable, Equatable, Identifiable {
    let id: String
    let domain: String
}
```

- [ ] **Step 5: Implement `RealSettingsService`**

Add to the end of `ADBLX/Features/Settings/SettingsService.swift`:

```swift
/// Real SettingsService. iCloudSyncEnabled stays hardcoded false — no iCloud sync
/// backend exists yet, unchanged scope for Sprint 5B (Sprint 5B design doc).
/// Allowlist is real and persisted via AllowlistStore, but storage-only: it does
/// not yet exempt anything from blocking.
actor RealSettingsService: SettingsService {
    private let allowlistStore: AllowlistStore

    init(allowlistStore: AllowlistStore) {
        self.allowlistStore = allowlistStore
    }

    func fetchSnapshot() async -> SettingsSnapshot {
        let allowlist = await allowlistStore.load()
        return SettingsSnapshot(iCloudSyncEnabled: false, allowlist: allowlist)
    }

    func addAllowlistEntry(domain: String) async {
        await allowlistStore.add(domain: domain)
    }

    func removeAllowlistEntry(id: String) async {
        await allowlistStore.remove(id: id)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AllowlistStoreTests -only-testing:ADBLXTests/RealSettingsServiceTests`
Expected: PASS.

- [ ] **Step 7: Build and run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Filtering/Storage/AllowlistStore.swift ADBLX/Features/Settings/SettingsService.swift ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift ADBLXTests/Features/Settings/RealSettingsServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): add AllowlistStore and RealSettingsService

Allowlist entries now persist across launches via a JSON-backed
actor store using the same atomic-write pattern as
installed_filters.json/filter_preferences.json. Storage only — no
enforcement wired into FilterPipeline yet, that's separate, larger,
deferred work. iCloudSyncEnabled stays hardcoded false, matching
existing scope (no iCloud sync backend exists).
EOF
)"
```

---

## Task 7: `AppearancePreferenceStore` and live theme switching

**Files:**
- Create: `ADBLX/Features/Settings/AppearancePreferenceStore.swift`
- Modify: `ADBLX/ADBLXApp.swift` (apply `.preferredColorScheme` at the root)
- Test: `ADBLXTests/Features/Settings/AppearancePreferenceStoreTests.swift` (new)

**Interfaces:**
- Consumes: `UserDefaults` (standard library — Appearance is a lightweight local preference, not App Group metadata, since it's device-local UI state rather than filtering data; this deliberately does NOT go through `FilterStore`).
- Produces: `enum AppearancePreference: String, CaseIterable, Codable { case system, light, dark }`, `AppearancePreferenceStore` with `var current: AppearancePreference { get set }` (synchronous — `UserDefaults` reads/writes don't need actor isolation the way App Group file I/O does), consumed by `SettingsView`'s new General section (Task 8) and `ADBLXApp` (this task).

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/Features/Settings/AppearancePreferenceStoreTests.swift`:

```swift
// ADBLXTests/Features/Settings/AppearancePreferenceStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("AppearancePreferenceStore")
struct AppearancePreferenceStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppearancePreferenceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("defaults to .system when nothing has been set")
    func defaultsToSystem() {
        let store = AppearancePreferenceStore(defaults: makeDefaults())

        #expect(store.current == .system)
    }

    @Test("setting current persists across a fresh store instance backed by the same UserDefaults")
    func settingPersists() {
        let defaults = makeDefaults()
        var store = AppearancePreferenceStore(defaults: defaults)

        store.current = .dark

        let freshInstance = AppearancePreferenceStore(defaults: defaults)
        #expect(freshInstance.current == .dark)
    }

    @Test("colorScheme maps .system to nil, .light to .light, .dark to .dark")
    func colorSchemeMapping() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AppearancePreferenceStoreTests`
Expected: FAIL — `AppearancePreferenceStore`/`AppearancePreference` don't exist.

- [ ] **Step 3: Implement `AppearancePreferenceStore`**

Create `ADBLX/Features/Settings/AppearancePreferenceStore.swift`:

```swift
// ADBLX/Features/Settings/AppearancePreferenceStore.swift
import SwiftUI

/// Device-local UI preference, deliberately backed by UserDefaults rather than
/// FilterStore/App Group metadata — this is app-chrome state, not filtering data,
/// so it doesn't belong alongside installed_filters.json/filter_preferences.json
/// (Sprint 5B design doc).
enum AppearancePreference: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var displayNameKey: LocalizedStringKey {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
}

struct AppearancePreferenceStore {
    private static let key = "appearancePreference"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var current: AppearancePreference {
        get {
            guard let rawValue = defaults.string(forKey: Self.key),
                  let preference = AppearancePreference(rawValue: rawValue) else {
                return .system
            }
            return preference
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}
```

- [ ] **Step 4: Add the three new localization keys**

Edit `ADBLX/Resources/Localizable.xcstrings`, adding after `"settings.title"` (or anywhere in the `settings.*` block — exact position doesn't matter for `.xcstrings`, but grouping near other `settings.*` keys keeps the file navigable):

```json
    "settings.appearance.system" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "System" } } }
    },
    "settings.appearance.light" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Light" } } }
    },
    "settings.appearance.dark" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Dark" } } }
    },
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AppearancePreferenceStoreTests`
Expected: PASS.

- [ ] **Step 6: Apply the preference at the app root**

Edit `ADBLX/ADBLXApp.swift`, adding a `@State` property and applying `.preferredColorScheme`:

```swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterStore: FilterStore
    private let filterPipeline: FilterPipeline
    private let updateCoordinator: UpdateCoordinator
    private let uiDependencies: AppCompositionRoot.UIDependencies
    private let appearanceStore = AppearancePreferenceStore()
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool
    @State private var appearance: AppearancePreference

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        filterStore = store
        filterPipeline = pipeline
        updateCoordinator = AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        uiDependencies = AppCompositionRoot.makeUIDependencies(
            configuration: .mock, store: store, updateCoordinator: updateCoordinator
        )
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
        _appearance = State(initialValue: AppearancePreferenceStore().current)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies, appearance: $appearance)
                } else {
                    OnboardingView {
                        onboardingStore.hasCompletedOnboarding = true
                        hasCompletedOnboarding = true
                    }
                }
            }
            .preferredColorScheme(appearance.colorScheme)
            .task {
                let pipeline = filterPipeline
                Task.detached(priority: .utility) {
                    await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
                }
            }
        }
    }
}
```

Note: `RootTabView` now needs an `appearance: Binding<AppearancePreference>` parameter so `SettingsView`'s new Appearance row (Task 8) can change it and have the change immediately reflected at the root. This binding threads through `RootTabView` → `SettingsView` → `SettingsViewModel` is NOT the right layer (that ViewModel is about `SettingsSnapshot`/backend data, not app-chrome state) — thread the binding directly as a View parameter instead, bypassing the ViewModel. Task 8 completes this wiring; this task only establishes the root-level `.preferredColorScheme` and the initial `@State`.

- [ ] **Step 7: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD FAILED **` — `RootTabView`'s initializer doesn't accept `appearance:` yet. This is expected; Task 8 fixes it. Confirm the failure is confined to the `RootTabView(dependencies:appearance:)` call site in `ADBLXApp.swift`.

- [ ] **Step 8: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Settings/AppearancePreferenceStore.swift ADBLX/Resources/Localizable.xcstrings ADBLX/ADBLXApp.swift ADBLXTests/Features/Settings/AppearancePreferenceStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): add AppearancePreferenceStore, apply .preferredColorScheme at root

Backed by UserDefaults rather than FilterStore/App Group metadata —
this is device-local app-chrome state, not filtering data. ADBLXApp
now applies the persisted preference via .preferredColorScheme at
the root. RootTabView's call site now expects an appearance binding
parameter — wired up in the next commit (Settings General section).
EOF
)"
```

---

## Task 8: Settings — new "General" section, wire `RealSettingsService`

**Files:**
- Modify: `ADBLX/Features/Settings/SettingsView.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`
- Modify: `ADBLX/DesignSystem/Components/ComingSoonState.swift` — no changes needed, reused as-is.

**Interfaces:**
- Consumes: `AppearancePreferenceStore` (Task 7), `RealSettingsService`/`AllowlistStore` (Task 6), `ComingSoonState` (existing, `ADBLX/DesignSystem/Components/ComingSoonState.swift`).
- Produces: `SettingsView` with a new General section, `AppCompositionRoot.makeUIDependencies` returns `RealSettingsService`.

- [ ] **Step 1: No new automated test for the view itself** — SwiftUI view layout isn't unit-testable in this codebase's existing convention (no snapshot testing infrastructure present); verification is the SwiftLint check, build, and manual simulator check below. The backing stores (`AppearancePreferenceStore`, `RealSettingsService`) already have unit tests from Tasks 6-7.

- [ ] **Step 2: Wire `RealSettingsService` into `AppCompositionRoot`**

Edit `ADBLX/AppCompositionRoot.swift`, adding an `makeAllowlistStore` factory and updating `makeUIDependencies`:

```swift
    static func makeAllowlistStore(store: FilterStore) -> AllowlistStore {
        AllowlistStore(store: store)
    }
```

Update the `.mock` case body:

```swift
    static func makeUIDependencies(
        configuration: UIDependenciesConfiguration,
        store: FilterStore,
        updateCoordinator: UpdateCoordinator
    ) -> UIDependencies {
        switch configuration {
        case .mock:
            let preferencesStore = makeFilterPreferencesStore(store: store)
            let allowlistStore = makeAllowlistStore(store: store)
            return UIDependencies(
                homeService: RealHomeService(store: store),
                protectionService: RealProtectionService(store: store, preferencesStore: preferencesStore),
                subscriptionService: MockSubscriptionService(),
                settingsService: RealSettingsService(allowlistStore: allowlistStore),
                updateCoordinator: updateCoordinator
            )
        }
    }
```

- [ ] **Step 3: Add the new "General" section to `SettingsView`, and accept the appearance binding**

Edit `ADBLX/Features/Settings/SettingsView.swift`, replacing the whole file:

```swift
// ADBLX/Features/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @Binding var appearance: AppearancePreference
    @State private var newDomain = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("settings.title")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                generalSection

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

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("settings.section.general")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            Card {
                VStack(spacing: 0) {
                    NavigationLink {
                        appearancePicker
                    } label: {
                        generalRow(titleKey: "settings.row.appearance", systemImage: "circle.lefthalf.filled", detail: appearance.displayNameKey)
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    generalRow(
                        titleKey: "settings.row.language", systemImage: "character.bubble",
                        detail: Text(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier)
                    )
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    NavigationLink {
                        ComingSoonState(
                            title: "settings.row.notifications",
                            message: "settings.notifications.comingSoon.message"
                        )
                    } label: {
                        SettingsRow(titleKey: "settings.row.notifications", systemImage: "bell.fill")
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    NavigationLink {
                        ComingSoonState(
                            title: "settings.row.safariHelp",
                            message: "settings.safariHelp.comingSoon.message"
                        )
                    } label: {
                        SettingsRow(titleKey: "settings.row.safariHelp", systemImage: "safari")
                    }
                }
            }
        }
    }

    private func generalRow(titleKey: LocalizedStringKey, systemImage: String, detail: LocalizedStringKey) -> some View {
        generalRow(titleKey: titleKey, systemImage: systemImage, detail: Text(detail))
    }

    private func generalRow(titleKey: LocalizedStringKey, systemImage: String, detail: Text) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            Text(titleKey)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
            Spacer()
            detail
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignColors.outline)
        }
        .accessibilityElement(children: .combine)
    }

    private var appearancePicker: some View {
        List(AppearancePreference.allCases, id: \.self) { preference in
            Button {
                appearance = preference
            } label: {
                HStack {
                    Text(preference.displayNameKey)
                        .foregroundStyle(DesignColors.onSurface)
                    Spacer()
                    if preference == appearance {
                        Image(systemName: "checkmark")
                            .foregroundStyle(DesignColors.primary)
                    }
                }
            }
        }
        .navigationTitle(Text("settings.row.appearance"))
    }
}

#Preview {
    SettingsView(viewModel: SettingsViewModel(service: MockSettingsService()), appearance: .constant(.system))
}
```

(`generalRow`'s two overloads exist because the Appearance row's detail is a plain localized string via `AppearancePreference.displayNameKey`, while the Language row's detail is a runtime-computed `Text` from `Locale` — not a static `LocalizedStringKey`. `SettingsRow` (the existing shared component) is reused as-is for Notifications/Safari Help since those rows have no detail text, matching its existing icon+title+chevron shape exactly.)

- [ ] **Step 4: Add the new localization keys**

Edit `ADBLX/Resources/Localizable.xcstrings`, adding after `"settings.action.add"`:

```json
    "settings.section.general" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "General" } } }
    },
    "settings.row.appearance" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Appearance" } } }
    },
    "settings.row.language" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Language" } } }
    },
    "settings.row.notifications" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Notifications" } } }
    },
    "settings.notifications.comingSoon.message" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Notification settings are coming in a future update." } } }
    },
    "settings.row.safariHelp" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Safari Help" } } }
    },
    "settings.safariHelp.comingSoon.message" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Safari setup help is coming in a future update." } } }
    },
```

- [ ] **Step 5: Thread the `appearance` binding through `RootTabView`**

Edit `ADBLX/Navigation/RootTabView.swift`, replacing the whole file:

```swift
// ADBLX/Navigation/RootTabView.swift
import SwiftUI

struct RootTabView: View {
    let dependencies: AppCompositionRoot.UIDependencies
    @Binding var appearance: AppearancePreference

    var body: some View {
        TabView {
            ForEach(AppTab.allCases, id: \.self) { tab in
                placeholder(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
            }
        }
        .tint(DesignColors.primary)
    }

    @ViewBuilder
    private func placeholder(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView(viewModel: HomeViewModel(service: dependencies.homeService), updateCoordinator: dependencies.updateCoordinator)
        case .protection:
            NavigationStack {
                SafariProtectionView(
                    viewModel: ProtectionViewModel(service: dependencies.protectionService),
                    updateCoordinator: dependencies.updateCoordinator
                )
            }
        case .premium:
            NavigationStack {
                PremiumView(viewModel: PremiumViewModel(service: dependencies.subscriptionService))
            }
        case .settings:
            NavigationStack {
                SettingsView(viewModel: SettingsViewModel(service: dependencies.settingsService), appearance: $appearance)
            }
        }
    }
}

#Preview {
    let store = AppCompositionRoot.makeFilterStore()
    let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
    RootTabView(
        dependencies: AppCompositionRoot.makeUIDependencies(
            configuration: .mock,
            store: store,
            updateCoordinator: AppCompositionRoot.makeUpdateCoordinator(pipeline: pipeline, store: store)
        ),
        appearance: .constant(.system)
    )
}
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **` — this resolves Task 7 Step 7's expected failure.

- [ ] **Step 7: Run the SwiftLint check**

Run: `swiftlint lint --path ADBLX/Features/Settings/SettingsView.swift`
Expected: no violations.

- [ ] **Step 8: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass.

- [ ] **Step 9: Manual simulator check**

Open `ADBLX.xcodeproj` in Xcode, run on an iOS Simulator, navigate to Settings.
Expected: new "General" section appears above the existing iCloud Sync card, showing Appearance ("System"), Language (real system language name), Notifications, Safari Help — the existing iCloud Sync / Allowlist / About rows are unchanged below it. Tap Appearance → picker → select "Dark" → confirm the whole app switches to dark mode immediately and the setting persists after force-quitting and relaunching. Tap Notifications/Safari Help → confirm each navigates to a `ComingSoonState` screen, not a crash or blank view. Add/remove an allowlist domain → confirm it persists across relaunch.

- [ ] **Step 10: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Settings/SettingsView.swift ADBLX/Navigation/RootTabView.swift ADBLX/AppCompositionRoot.swift ADBLX/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
feat(settings): add General section, wire RealSettingsService

New General section (Appearance, Language, Notifications, Safari
Help) added above the existing, unchanged iCloud Sync/Allowlist/About
content per the approved screenshot. Appearance is a real, persisted
preference that actually changes the app's color scheme; Language is
a real read-only display of the system locale; Notifications and
Safari Help navigate to the existing shared ComingSoonState component.
SettingsView now uses RealSettingsService, so allowlist add/remove
persists across relaunch.
EOF
)"
```

---

## Task 9: About — restyle and wire `AboutViewModel`

**Files:**
- Create: `ADBLX/Features/Settings/AboutViewModel.swift`
- Modify: `ADBLX/Features/Settings/AboutView.swift`
- Modify: `ADBLX/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `Bundle.main` (Foundation).
- Produces: `AboutViewModel` with `var versionDisplay: String { get }`, consumed by the restyled `AboutView`.

- [ ] **Step 1: Write the failing test**

Create `ADBLXTests/Features/Settings/AboutViewModelTests.swift`:

```swift
// ADBLXTests/Features/Settings/AboutViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("AboutViewModel")
struct AboutViewModelTests {
    @Test("versionDisplay formats as 'v{version} (Build {build})'")
    func versionDisplayFormats() {
        let viewModel = AboutViewModel(shortVersion: "4.2.1", buildNumber: "2024.08")

        #expect(viewModel.versionDisplay == "v4.2.1 (Build 2024.08)")
    }

    @Test("versionDisplay falls back to em dash for missing values")
    func versionDisplayFallsBackGracefully() {
        let viewModel = AboutViewModel(shortVersion: nil, buildNumber: nil)

        #expect(viewModel.versionDisplay == "v— (Build —)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AboutViewModelTests`
Expected: FAIL — `AboutViewModel` does not exist.

- [ ] **Step 3: Implement `AboutViewModel`**

Create `ADBLX/Features/Settings/AboutViewModel.swift`:

```swift
// ADBLX/Features/Settings/AboutViewModel.swift
import Foundation

/// Sources real app version/build from Bundle.main — About previously showed a
/// static "Version 1.0" string with no backend/bundle wiring at all (Sprint 5B
/// design doc). Takes shortVersion/buildNumber as init parameters (rather than
/// reading Bundle.main internally) so this is testable without depending on the
/// test target's own bundle metadata.
struct AboutViewModel {
    private let shortVersion: String?
    private let buildNumber: String?

    init(shortVersion: String?, buildNumber: String?) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
    }

    init(bundle: Bundle = .main) {
        self.init(
            shortVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String
        )
    }

    var versionDisplay: String {
        "v\(shortVersion ?? "—") (Build \(buildNumber ?? "—"))"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ADBLXTests/AboutViewModelTests`
Expected: PASS.

- [ ] **Step 5: Restyle `AboutView`**

Edit `ADBLX/Features/Settings/AboutView.swift`, replacing the whole file with the approved subset of the mockup (app identity + version chip, Connect/Official Website only, Legal & Open Source with Licenses/Privacy/Terms, footer — no Acknowledgements, no GitHub Repository):

```swift
// ADBLX/Features/Settings/AboutView.swift
import SwiftUI

struct AboutView: View {
    let viewModel = AboutViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                identitySection
                connectSection
                legalSection
                footer
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private var identitySection: some View {
        VStack(spacing: DesignSpacing.stackGap) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius)
                    .fill(
                        LinearGradient(
                            colors: [DesignColors.primary, DesignColors.secondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                Image(systemName: "shield.checkered")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            }
            Text("about.title.app")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.primary)
            Text("about.tagline")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Text(viewModel.versionDisplay)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .padding(.horizontal, DesignSpacing.gutter)
                .padding(.vertical, DesignSpacing.base)
                .background(DesignColors.surfaceContainer)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    private var connectSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("about.section.connect")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            Card {
                Link(destination: URL(string: "https://adblx.app")!) {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundStyle(DesignColors.primary)
                            .frame(width: 24)
                        Text("about.link.website")
                            .font(DesignTypography.bodyLarge)
                            .foregroundStyle(DesignColors.onSurface)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(DesignColors.outline)
                    }
                }
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.gutter) {
            Text("about.section.legal")
                .font(DesignTypography.labelCaps)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .textCase(.uppercase)

            Card {
                VStack(spacing: 0) {
                    SettingsRow(titleKey: "about.row.licenses", systemImage: "doc.text.fill")
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    Link(destination: URL(string: "https://adblx.app/privacy")!) {
                        SettingsRow(titleKey: "about.link.privacyPolicy", systemImage: "hand.raised.fill")
                    }
                    Divider().overlay(DesignColors.outlineVariant.opacity(0.2))
                    Link(destination: URL(string: "https://adblx.app/terms")!) {
                        SettingsRow(titleKey: "about.link.termsOfService", systemImage: "doc.plaintext.fill")
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("about.footer.copyright")
            .font(DesignTypography.bodySmall)
            .foregroundStyle(DesignColors.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.top, DesignSpacing.gutter)
    }
}

#Preview {
    AboutView()
}
```

(`about.row.licenses` uses bare `SettingsRow` with no `NavigationLink`/`Link` wrapper — per the design doc, Licenses stays a non-functional placeholder row for now, rendered but not interactive. `Link` is used for Website/Privacy/Terms since those already have real destination URLs, matching the pre-existing `AboutView`'s pattern for Privacy/Terms exactly.)

- [ ] **Step 6: Add the new localization keys, remove the now-unused `about.version.label`**

Edit `ADBLX/Resources/Localizable.xcstrings`. First, remove the now-unused key (replaced by `AboutViewModel.versionDisplay`, a runtime-computed string, not a localization key):

Find and delete this entry:
```json
    "about.version.label" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Version 1.0" } } }
    },
```

Then add the new keys near the existing `about.*` block (after `about.title.app`):

```json
    "about.tagline" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Secure. Swift. Seamless." } } }
    },
    "about.section.connect" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Connect" } } }
    },
    "about.link.website" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Official Website" } } }
    },
    "about.section.legal" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Legal & Open Source" } } }
    },
    "about.row.licenses" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Open Source Licenses" } } }
    },
    "about.footer.copyright" : {
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "© 2026 ADBLX. All rights reserved." } } }
    },
```

(`about.privacy.statement` — the old privacy-statement card text — is dropped since it's not part of the approved mockup subset; leave its `.xcstrings` entry in place since removing unused keys isn't required for the string catalog to build correctly, and leaving it avoids an unrelated diff. `about.link.privacyPolicy`/`about.link.termsOfService` keys already exist from before and are reused as-is.)

- [ ] **Step 7: Build**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'generic/platform=iOS Simulator' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Run the SwiftLint check**

Run: `swiftlint lint --path ADBLX/Features/Settings/AboutView.swift`
Expected: no violations — confirms no raw hex colors/hardcoded strings crept in from the mockup's Tailwind values.

- [ ] **Step 9: Run the full test suite**

Run: `xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' test`
Expected: all suites pass, including the new `AboutViewModelTests`.

- [ ] **Step 10: Manual simulator check**

Open `ADBLX.xcodeproj` in Xcode, run on an iOS Simulator, navigate to Settings → About.
Expected: restyled screen matches the approved mockup subset — icon badge, "ADBLX", tagline, a version chip showing the real build's version/build number (not "Version 1.0"), a Connect section with only "Official Website" (no GitHub Repository row), a Legal & Open Source section with Licenses/Privacy Policy/Terms of Service (Licenses does nothing when tapped, Privacy/Terms open their real URLs), and a footer copyright line. No Acknowledgements/contributor section anywhere.

- [ ] **Step 11: Commit**

```bash
cd /Users/sreeharshag/Work/ADBLX
git add ADBLX/Features/Settings/AboutViewModel.swift ADBLX/Features/Settings/AboutView.swift ADBLX/Resources/Localizable.xcstrings ADBLXTests/Features/Settings/AboutViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(about): restyle per approved mockup, wire real version/build

AboutView had no service/ViewModel at all before this — fully
static "Version 1.0" text. AboutViewModel sources real
version/build from Bundle.main. Restyled using DesignSystem tokens
to match the approved mockup subset: app identity + version chip,
Connect (website only, no GitHub Repository), Legal & Open Source
(Licenses stays a non-functional placeholder row, Privacy/Terms
keep their existing real links), footer. No Acknowledgements/
contributor section, per explicit instruction.
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:**
- Commit 1 (Real ProtectionService): `FilterPreferencesStore` ✓ Task 1, `FilterCategoryID.allCases` replacing `allCasesForDisplay` ✓ Tasks 1/3, always-4-categories + installed-only filter lists ✓ Task 2, empty-state message ✓ Task 3, composition root wiring ✓ Task 3.
- Commit 2 (Update Progress): `onPhaseChange` callback with 4 checkpoints ✓ Task 4, backward-compatible default parameter ✓ Task 4 (explicit test), honest `.failed` on real network failure ✓ Task 5, `UpdateCoordinator` threaded to both presenting views (a gap not fully specified in the design doc's "sheet doesn't change" claim, resolved here) ✓ Task 5.
- Commit 3 (Settings): new General section (Appearance/Language/Notifications/Safari Help) ✓ Task 8, existing content unchanged/unreorganized ✓ Task 8, allowlist persistence (storage only, no enforcement) ✓ Task 6, live theme switching ✓ Task 7.
- Commit 4 (About): restyle per approved mockup subset, Acknowledgements/GitHub excluded ✓ Task 9, real version/build ✓ Task 9, Licenses placeholder ✓ Task 9, DesignSystem tokens only ✓ Task 9 (SwiftLint check).

**Placeholder scan:** No TBD/TODO left unresolved. Task 4's rollback-path note ("intentionally do NOT call onPhaseChange(.failed...)") documents a deliberate design choice, not a deferred decision.

**Type consistency:** `FilterCategoryID` (String raw value, `CaseIterable`) is consistent from its Task 1 definition through `FilterPreferencesStore`, `RealProtectionService`, and `AdvancedFilterListsView`. `UpdateCoordinator.run(onPhaseChange:)`'s signature is identical across Task 4's definition, Task 5's `UpdateProgressModel.start(coordinator:)` call, and both test files. `UIDependencies`' `updateCoordinator` field is added once (Task 5) and consumed identically by `RootTabView`, `HomeView`, `SafariProtectionView` in the same task. `AppearancePreference`/`AppearancePreferenceStore` (Task 7) and their `RootTabView`/`SettingsView` binding threading (Task 8) use matching names throughout. `AboutViewModel.versionDisplay` (Task 9) is the only consumer of `Bundle.main` version data — no duplicate formatting logic elsewhere.

**Sequencing note:** Task 7 deliberately leaves the build broken (Step 7's expected `BUILD FAILED`) because `RootTabView`'s signature change is split across two tasks (Task 7 changes `ADBLXApp.swift`'s call site, Task 8 changes `RootTabView` itself). This mirrors Sprint 5A's Task 4→Task 6 pattern (also an intentional, documented broken-build checkpoint) and is not an oversight — flagging it here so a reviewer doesn't mistake it for one.
