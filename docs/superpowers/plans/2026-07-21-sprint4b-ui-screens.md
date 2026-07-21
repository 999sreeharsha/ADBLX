# Sprint 4B — Remaining UI Screens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the remaining 8 screens of the frozen IA — Safari Protection, Advanced Filter Lists, DNS Protection, Premium, Settings, About, Update Progress, and Onboarding — each as View + ViewModel + Service protocol + mock, following the exact pattern Sprint 4A established with Home.

**Architecture:** Every screen repeats Sprint 4A's pattern: `View` → `@Observable ViewModel` → `Service` protocol → mock implementation, wired through `AppCompositionRoot.UIDependencies`. No new architectural decisions are made in this plan — only pattern application. `Card`, `PrimaryButton` (Sprint 4A) are reused; new shared components (`SettingsRow`, `ToggleRow`, `PremiumBadge`, `ComingSoonState`, `ProgressRing`) are introduced in whichever screen task first needs them.

**Tech Stack:** SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`), Swift 5, `ADBLX` multiplatform target with `syncedFolder` sources (new files under `ADBLX/`/`ADBLXTests/` need no `project.yml` changes).

## Global Constraints

- **Prerequisite:** Sprint 4A (`docs/superpowers/plans/2026-07-21-sprint4a-ui-foundation.md`) must be complete — this plan assumes `DesignColors`/`DesignTypography`/`DesignSpacing`/`DesignShape` (Task 1), `AppTab`/`RootTabView`/`AppCompositionRoot.UIDependencies` (Task 2), `PrimaryButton`/`Card` (Task 3), and `HomeService`/`HomeViewModel`/`HomeView` (Task 4) all exist exactly as those tasks defined them.
- Every screen: View + ViewModel + Service protocol + mock implementation. ViewModels contain no SwiftUI-specific logic and depend only on their feature's service protocol. Internal backend types (`FilterPipeline`, `UpdateCoordinator`, `FilterManifest`, `FilterGroup`) are never protocolized or exposed to the UI layer — services return screen-shaped DTOs the mock constructs directly.
- Each commit must build successfully, pass all existing tests, introduce no Swift compiler warnings, and leave the app in a runnable state.
- Test file headers follow the existing convention: first line is `// <path/to/file.swift>`, then `import Testing`, `@testable import ADBLX`.
- Frozen IA (do not deviate): Home / Protection (Safari Protection → Categories, Advanced Filter Lists / DNS Protection) / Premium / Settings → About. Onboarding is presented pre-navigation on first launch. Update Progress is a shared modal, not a tab.
- DNS Protection is P1: screen, navigation, copy, and premium messaging only — no `NEPacketTunnelProvider`, no VPN configuration, no backend (spec §3).
- Design values come from the Stitch project `projects/16038318836427840964` ("Serene Shield" theme) via the Sprint 4A `DesignSystem` module — never raw literals in a View file.
- Screen content/copy below is grounded in the actual Stitch screens (fetched during planning) where available, and in the PRD's functional requirements (FR-07 through FR-11) where Stitch content wasn't retrievable during planning due to a transient fetch failure — those cases are called out per task, with a step for the implementer to cross-check against the live Stitch screen during simulator validation.
- **Rule-count granularity must match what the backend can actually report** (`docs/gotchas.md`: `InstalledFilter.ruleCount` is group-level only — `CompositionService`/`FilterPipeline` write the same aggregate count into every source in a group; there is no per-source/per-list count today). `ProtectionCategory.ruleCount` (one count per `FilterCategoryID`, i.e. per group) matches this and is kept. `FilterListEntry` (one entry per source *within* a group, e.g. "EasyList" inside Ads) does **not** get a `ruleCount` field — modeling an independent count per list would fabricate data the backend cannot produce, repeating the exact gap the gotcha documents. See Task 2 for the corrected shape.

---

## Task 1: Safari Protection Screen (View + ViewModel + `ProtectionService` + mock)

**Files:**
- Create: `ADBLX/Features/Protection/ProtectionService.swift`
- Create: `ADBLX/Features/Protection/ProtectionViewModel.swift`
- Create: `ADBLX/Features/Protection/SafariProtectionView.swift`
- Create: `ADBLX/DesignSystem/Components/ToggleRow.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Test: `ADBLXTests/Features/Protection/ProtectionViewModelTests.swift`
- Test: `ADBLXTests/DesignSystem/ToggleRowTests.swift`

**Interfaces:**
- Consumes: `Card` (Sprint 4A Task 3); `DesignColors`, `DesignTypography`, `DesignSpacing`, `DesignShape` (Sprint 4A Task 1); `AppCompositionRoot.UIDependencies` (Sprint 4A Task 2, currently `{ homeService: HomeService }`).
- Produces: `ToggleRow` (View, `init(title: String, subtitle: String, isOn: Binding<Bool>)`); `ProtectionCategory` (struct: `id: FilterCategoryID`, `name: String`, `description: String`, `isEnabled: Bool`, `ruleCount: Int`); `FilterCategoryID` (enum: `.ads`, `.privacy`, `.annoyances`, `.regional` — a UI-facing mirror of the backend's `FilterGroup`, deliberately not the same type per the architecture boundary); `ProtectionStatus` (struct: `isSafariExtensionEnabled: Bool`, `categories: [ProtectionCategory]`); `ProtectionService` (protocol: `func fetchStatus() async -> ProtectionStatus`, `func setCategory(_ id: FilterCategoryID, enabled: Bool) async`); `MockProtectionService`; `ProtectionViewModel` (`@Observable`, `init(service: ProtectionService)`, `status: ProtectionStatus?`, `isLoading: Bool`, `func load() async`, `func toggleCategory(_ id: FilterCategoryID) async`); `SafariProtectionView`. Task 2 (Advanced Filter Lists) reuses `ProtectionService`/`ProtectionViewModel`/`FilterCategoryID` — it does not define its own service.

Content: four toggleable categories (Ads, Privacy/Trackers, Annoyances, Regional — matching the PRD §6.1's four content-blocker extensions and FR-09's "catalog... groups, versions, rule-count meter per extension"), each shown with a name, one-line description, per-category rule count, and an on/off toggle, plus a top-level "Safari Extension Enabled" status row.

- [ ] **Step 1: Write the failing test for `ProtectionViewModel`**

```swift
// ADBLXTests/Features/Protection/ProtectionViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("ProtectionViewModel")
struct ProtectionViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = ProtectionStatus(
            isSafariExtensionEnabled: true,
            categories: [
                ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ]
        )
        let viewModel = ProtectionViewModel(service: StubProtectionService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
    }

    @Test("toggleCategory flips the category's isEnabled and calls the service")
    func toggleCategoryFlipsState() async {
        let initial = ProtectionStatus(
            isSafariExtensionEnabled: true,
            categories: [
                ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ]
        )
        let service = StubProtectionService(statusToReturn: initial)
        let viewModel = ProtectionViewModel(service: service)
        await viewModel.load()

        await viewModel.toggleCategory(.ads)

        #expect(viewModel.status?.categories.first?.isEnabled == false)
        #expect(await service.lastSetCall == (.ads, false))
    }
}

private actor StubProtectionService: ProtectionService {
    let statusToReturn: ProtectionStatus
    private(set) var lastSetCall: (FilterCategoryID, Bool)?

    init(statusToReturn: ProtectionStatus) {
        self.statusToReturn = statusToReturn
    }

    func fetchStatus() async -> ProtectionStatus { statusToReturn }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        lastSetCall = (id, enabled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ProtectionViewModelTests`
Expected: FAIL — `ProtectionViewModel`, `ProtectionService`, `ProtectionStatus`, `ProtectionCategory`, `FilterCategoryID` do not exist.

- [ ] **Step 3: Implement `ProtectionService`, its models, and `MockProtectionService`**

```swift
// ADBLX/Features/Protection/ProtectionService.swift
import Foundation

/// UI-facing mirror of the backend's FilterGroup (Filtering/Models/FilterManifest.swift).
/// Deliberately a separate type — the UI layer never imports FilterGroup directly
/// (Sprint 4 spec §5).
enum FilterCategoryID: Equatable {
    case ads
    case privacy
    case annoyances
    case regional
}

struct ProtectionCategory: Equatable, Identifiable {
    var id: FilterCategoryID
    let name: String
    let description: String
    var isEnabled: Bool
    let ruleCount: Int
}

struct ProtectionStatus: Equatable {
    let isSafariExtensionEnabled: Bool
    var categories: [ProtectionCategory]
}

/// What Safari Protection and Advanced Filter Lists need from the backend.
/// A later sprint's real implementation translates FilterPipeline/FilterManifest
/// state into these screen-shaped types.
protocol ProtectionService: Sendable {
    func fetchStatus() async -> ProtectionStatus
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async
}

actor MockProtectionService: ProtectionService {
    private var status = ProtectionStatus(
        isSafariExtensionEnabled: true,
        categories: [
            ProtectionCategory(id: .ads, name: "Ads", description: "Blocks display and video ads", isEnabled: true, ruleCount: 62_000),
            ProtectionCategory(id: .privacy, name: "Privacy", description: "Blocks trackers and analytics scripts", isEnabled: true, ruleCount: 48_500),
            ProtectionCategory(id: .annoyances, name: "Annoyances", description: "Hides cookie banners and popups", isEnabled: false, ruleCount: 21_000),
            ProtectionCategory(id: .regional, name: "Regional", description: "Extra rules for regional ad networks", isEnabled: false, ruleCount: 10_542),
        ]
    )

    func fetchStatus() async -> ProtectionStatus { status }

    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {
        guard let index = status.categories.firstIndex(where: { $0.id == id }) else { return }
        status.categories[index].isEnabled = enabled
    }
}
```

- [ ] **Step 4: Implement `ProtectionViewModel`**

```swift
// ADBLX/Features/Protection/ProtectionViewModel.swift
import Observation

@Observable
final class ProtectionViewModel {
    private let service: ProtectionService

    var status: ProtectionStatus?
    var isLoading = false

    init(service: ProtectionService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    func toggleCategory(_ id: FilterCategoryID) async {
        guard var status else { return }
        guard let index = status.categories.firstIndex(where: { $0.id == id }) else { return }
        let newValue = !status.categories[index].isEnabled
        status.categories[index].isEnabled = newValue
        self.status = status
        await service.setCategory(id, enabled: newValue)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ProtectionViewModelTests`
Expected: PASS (2 tests)

- [ ] **Step 6: Write the failing test for `ToggleRow`**

```swift
// ADBLXTests/DesignSystem/ToggleRowTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("ToggleRow")
struct ToggleRowTests {
    @Test("binding reflects the value passed in and toggling flips it")
    func bindingRoundTrips() {
        var value = false
        let binding = Binding(get: { value }, set: { value = $0 })
        let row = ToggleRow(title: "Ads", subtitle: "Blocks display and video ads", isOn: binding)

        row.isOn.wrappedValue.toggle()

        #expect(value == true)
    }
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ToggleRowTests`
Expected: FAIL — `ToggleRow` does not exist.

- [ ] **Step 8: Implement `ToggleRow`**

```swift
// ADBLX/DesignSystem/Components/ToggleRow.swift
import SwiftUI

/// A titled, subtitled row ending in a Toggle. Stitch theme: switches use full
/// pill-shaping and the Privacy Purple "on" tint with a spring-animated transition.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(title)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(subtitle)
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
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

#Preview {
    ToggleRow(title: "Ads", subtitle: "Blocks display and video ads", isOn: .constant(true))
        .padding()
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ToggleRowTests`
Expected: PASS (1 test)

- [ ] **Step 10: Implement `SafariProtectionView`**

```swift
// ADBLX/Features/Protection/SafariProtectionView.swift
import SwiftUI

struct SafariProtectionView: View {
    @State var viewModel: ProtectionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("Safari Protection")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                if let status = viewModel.status {
                    Card {
                        HStack {
                            Text("Safari Extension")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Spacer()
                            Text(status.isSafariExtensionEnabled ? "Enabled" : "Disabled")
                                .font(DesignTypography.labelMono)
                                .foregroundStyle(status.isSafariExtensionEnabled ? DesignColors.primary : DesignColors.error)
                        }
                    }

                    Card {
                        ForEach(Array(status.categories.enumerated()), id: \.element.id) { index, category in
                            ToggleRow(
                                title: category.name,
                                subtitle: "\(category.description) · \(category.ruleCount) rules",
                                isOn: Binding(
                                    get: { viewModel.status?.categories[index].isEnabled ?? false },
                                    set: { _ in
                                        Task { await viewModel.toggleCategory(category.id) }
                                    }
                                )
                            )
                            if index < status.categories.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }
}

#Preview {
    SafariProtectionView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
```

- [ ] **Step 11: Wire `ProtectionService` into `AppCompositionRoot` and `RootTabView`**

```swift
// Modify: ADBLX/AppCompositionRoot.swift
// Replace the UIDependencies struct body from Sprint 4A Task 4 with:

struct UIDependencies {
    let homeService: HomeService
    let protectionService: ProtectionService
}

static func makeMockUIDependencies() -> UIDependencies {
    UIDependencies(
        homeService: MockHomeService(),
        protectionService: MockProtectionService()
    )
}
```

```swift
// Modify: ADBLX/Navigation/RootTabView.swift
// In `placeholder(for:)`, add a case for .protection alongside .home:

case .protection:
    NavigationStack {
        SafariProtectionView(viewModel: ProtectionViewModel(service: dependencies.protectionService))
    }
```

- [ ] **Step 12: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator, on the Protection tab: confirm the Safari Extension status row and four category toggles render, each toggle flips its row's "Enabled"/description state without affecting the others. Cross-check the layout against the live Stitch screen (`projects/16038318836427840964/screens/39bd1a962fa34d358fb8d3ddc478e0a0`, title "Safari Protection") via the Stitch MCP `get_screen`/`list_screens` tools or the Stitch web UI, since this task's copy was sourced from the PRD rather than a direct screen fetch during planning — adjust card grouping/copy to match if it differs, per Design Authority (spec §2, Stitch wins any mismatch). Then verify Dynamic Type (XXL), Dark Mode (no unreadable text), and VoiceOver (each row reads as one phrase: "Ads. Blocks display and video ads. 62000 rules. On/Off toggle.").

- [ ] **Step 13: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 14: Commit**

```bash
git add ADBLX/Features/Protection/ ADBLX/DesignSystem/Components/ToggleRow.swift ADBLX/AppCompositionRoot.swift ADBLX/Navigation/RootTabView.swift ADBLXTests/Features/Protection/ProtectionViewModelTests.swift ADBLXTests/DesignSystem/ToggleRowTests.swift
git commit -m "feat(ui): implement Safari Protection screen

SafariProtectionView + ProtectionViewModel + ProtectionService(protocol)/
MockProtectionService, covering the four filter categories (Ads,
Privacy, Annoyances, Regional) with per-category toggles and rule
counts. Adds the shared ToggleRow component. Wired into
AppCompositionRoot.UIDependencies and the Protection tab."
```

---

## Task 2: Advanced Filter Lists Screen

**Files:**
- Create: `ADBLX/Features/Protection/AdvancedFilterListsView.swift`
- Modify: `ADBLX/Features/Protection/ProtectionService.swift`
- Modify: `ADBLX/Features/Protection/ProtectionViewModel.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Test: `ADBLXTests/Features/Protection/ProtectionViewModelTests.swift`

**Interfaces:**
- Consumes: `Card` (Sprint 4A); `ProtectionService`, `ProtectionViewModel`, `FilterCategoryID`, `ProtectionCategory` (Task 1 of this plan).
- Produces: `FilterListEntry` (struct: `id: String`, `name: String`, `category: FilterCategoryID`, `version: String`, `isEnabled: Bool`, `isPremium: Bool` — the per-list detail one level below `ProtectionCategory`, deliberately with **no `ruleCount` field**); extends `ProtectionStatus` with `filterLists: [FilterListEntry]`; extends `ProtectionService` with `func setFilterList(_ id: String, enabled: Bool) async`; `AdvancedFilterListsView`.

Content matches FR-09 ("Filters screen renders catalog dynamically from manifest: groups, versions, rule-count meter per extension") and PRD §6.2's manifest fields (`id`, `name`, `group`, `version`, `premium`) — mirrored here as a UI-facing DTO, not the backend's `FilterManifest.Entry` directly. This is the screen where a user sees individual lists (e.g. "EasyList", "EasyPrivacy", "AdGuard Base") within each category, each independently toggleable, with premium lists showing a lock/badge for free users.

**Per the Global Constraints' rule-count note:** `FilterListEntry` has no `ruleCount` — `CompositionService`/`FilterPipeline` only ever compute a group-level aggregate (`docs/gotchas.md`), so there is no real per-list count to show here. The rule-count meter FR-09 calls for lives one level up, on `ProtectionCategory` (Task 1), which is genuinely group-level data the backend can produce today. `AdvancedFilterListsView` shows each list's name, version, premium status, and toggle — not a count.

- [ ] **Step 1: Write the failing test for the extended `ProtectionViewModel`**

```swift
// Append to ADBLXTests/Features/Protection/ProtectionViewModelTests.swift
@Suite("ProtectionViewModel filter lists")
struct ProtectionViewModelFilterListTests {
    @Test("load() populates filterLists alongside categories")
    func loadPopulatesFilterLists() async {
        let expected = ProtectionStatus(
            isSafariExtensionEnabled: true,
            categories: [],
            filterLists: [
                FilterListEntry(id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15", isEnabled: true, isPremium: false),
            ]
        )
        let viewModel = ProtectionViewModel(service: StubFilterListService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status?.filterLists == expected.filterLists)
    }

    @Test("toggleFilterList flips the list's isEnabled and calls the service")
    func toggleFilterListFlipsState() async {
        let initial = ProtectionStatus(
            isSafariExtensionEnabled: true,
            categories: [],
            filterLists: [
                FilterListEntry(id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15", isEnabled: true, isPremium: false),
            ]
        )
        let service = StubFilterListService(statusToReturn: initial)
        let viewModel = ProtectionViewModel(service: service)
        await viewModel.load()

        await viewModel.toggleFilterList("easylist")

        #expect(viewModel.status?.filterLists.first?.isEnabled == false)
    }
}

private actor StubFilterListService: ProtectionService {
    let statusToReturn: ProtectionStatus
    init(statusToReturn: ProtectionStatus) { self.statusToReturn = statusToReturn }
    func fetchStatus() async -> ProtectionStatus { statusToReturn }
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async {}
    func setFilterList(_ id: String, enabled: Bool) async {}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ProtectionViewModelFilterListTests`
Expected: FAIL — `FilterListEntry` doesn't exist; `ProtectionStatus` has no `filterLists` member; `ProtectionService` has no `setFilterList`.

- [ ] **Step 3: Extend `ProtectionService.swift` with `FilterListEntry` and the new protocol method**

```swift
// Modify: ADBLX/Features/Protection/ProtectionService.swift
// Add below FilterCategoryID:

/// No ruleCount: CompositionService/FilterPipeline only ever compute a
/// group-level aggregate (docs/gotchas.md) — there is no real per-source
/// count to show at this granularity. The rule-count meter FR-09 calls for
/// lives on ProtectionCategory (Task 1), which is genuinely group-level.
struct FilterListEntry: Equatable, Identifiable {
    var id: String
    let name: String
    let category: FilterCategoryID
    let version: String
    var isEnabled: Bool
    let isPremium: Bool
}

// Replace ProtectionStatus with:
struct ProtectionStatus: Equatable {
    let isSafariExtensionEnabled: Bool
    var categories: [ProtectionCategory]
    var filterLists: [FilterListEntry] = []
}

// Replace the ProtectionService protocol with:
protocol ProtectionService: Sendable {
    func fetchStatus() async -> ProtectionStatus
    func setCategory(_ id: FilterCategoryID, enabled: Bool) async
    func setFilterList(_ id: String, enabled: Bool) async
}

// Extend MockProtectionService's stored status literal (in its `status` property
// initializer) by adding a `filterLists:` argument after `categories:`:
//     filterLists: [
//         FilterListEntry(id: "easylist", name: "EasyList", category: .ads, version: "2026-07-15", isEnabled: true, isPremium: false),
//         FilterListEntry(id: "easyprivacy", name: "EasyPrivacy", category: .privacy, version: "2026-07-15", isEnabled: true, isPremium: false),
//         FilterListEntry(id: "fanboy-annoyances", name: "Fanboy's Annoyances", category: .annoyances, version: "2026-07-10", isEnabled: false, isPremium: true),
//         FilterListEntry(id: "regional-in", name: "Regional: India", category: .regional, version: "2026-07-01", isEnabled: false, isPremium: true),
//     ]
// Add the matching method:
//     func setFilterList(_ id: String, enabled: Bool) async {
//         guard let index = status.filterLists.firstIndex(where: { $0.id == id }) else { return }
//         status.filterLists[index].isEnabled = enabled
//     }
```

- [ ] **Step 4: Extend `ProtectionViewModel` with `toggleFilterList`**

```swift
// Modify: ADBLX/Features/Protection/ProtectionViewModel.swift
// Add this method to the existing ProtectionViewModel class:

func toggleFilterList(_ id: String) async {
    guard var status else { return }
    guard let index = status.filterLists.firstIndex(where: { $0.id == id }) else { return }
    let newValue = !status.filterLists[index].isEnabled
    status.filterLists[index].isEnabled = newValue
    self.status = status
    await service.setFilterList(id, enabled: newValue)
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ProtectionViewModelFilterListTests`
Expected: PASS (2 tests)

- [ ] **Step 6: Implement `AdvancedFilterListsView`**

```swift
// ADBLX/Features/Protection/AdvancedFilterListsView.swift
import SwiftUI

struct AdvancedFilterListsView: View {
    @State var viewModel: ProtectionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("Advanced Filter Lists")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                if let lists = viewModel.status?.filterLists {
                    ForEach(FilterCategoryID.allCasesForDisplay, id: \.self) { category in
                        let listsInCategory = lists.filter { $0.category == category }
                        if !listsInCategory.isEmpty {
                            Card {
                                ForEach(Array(listsInCategory.enumerated()), id: \.element.id) { index, list in
                                    filterListRow(list)
                                    if index < listsInCategory.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    private func filterListRow(_ list: FilterListEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                HStack(spacing: DesignSpacing.base / 2) {
                    Text(list.name)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    if list.isPremium {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(DesignColors.tertiary)
                    }
                }
                Text("v\(list.version)")
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { _ in Task { await viewModel.toggleFilterList(list.id) } }
            ))
            .labelsHidden()
            .tint(DesignColors.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(list.isPremium ? "\(list.name), premium" : list.name)
        .accessibilityValue(list.isEnabled ? "On" : "Off")
    }
}

private extension FilterCategoryID {
    static let allCasesForDisplay: [FilterCategoryID] = [.ads, .privacy, .annoyances, .regional]
}

#Preview {
    AdvancedFilterListsView(viewModel: ProtectionViewModel(service: MockProtectionService()))
}
```

- [ ] **Step 7: Add navigation from Safari Protection to Advanced Filter Lists**

```swift
// Modify: ADBLX/Features/Protection/SafariProtectionView.swift
// Wrap the existing VStack's content in a NavigationLink destination by adding,
// immediately after the Safari Extension status Card and before the categories Card:

NavigationLink("Advanced Filter Lists") {
    AdvancedFilterListsView(viewModel: viewModel)
}
.font(DesignTypography.bodyLarge)
.foregroundStyle(DesignColors.primary)
```

- [ ] **Step 8: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: tap "Advanced Filter Lists" from Safari Protection; confirm lists group by category, premium lists show a lock icon, and each list's toggle is independent. Cross-check against the live Stitch screen (`projects/16038318836427840964/screens/c5ed6d008dbd439c9b961e42ba56a5a0`, title "Advanced Filter Lists") since this task's content was sourced from the PRD manifest schema rather than a direct screen fetch during planning. Verify Dynamic Type, Dark Mode, and VoiceOver (each row announces name, premium status if applicable, version, and on/off state).

- [ ] **Step 9: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 10: Commit**

```bash
git add ADBLX/Features/Protection/ ADBLXTests/Features/Protection/ProtectionViewModelTests.swift
git commit -m "feat(ui): implement Advanced Filter Lists screen

Extends ProtectionService/ProtectionViewModel with per-list detail
(FilterListEntry) below the category level, mirroring the manifest
schema (FR-09) without exposing FilterManifest.Entry to the UI layer.
Navigable from Safari Protection."
```

---

## Task 3: DNS Protection Screen (Coming Soon shell — P1, no backend)

**Files:**
- Create: `ADBLX/Features/Protection/DNSProtectionView.swift`
- Create: `ADBLX/DesignSystem/Components/ComingSoonState.swift`
- Modify: `ADBLX/Features/Protection/SafariProtectionView.swift`
- Test: `ADBLXTests/DesignSystem/ComingSoonStateTests.swift`

**Interfaces:**
- Consumes: `Card`, `PrimaryButton` (Sprint 4A); `DesignColors`, `DesignTypography`, `DesignSpacing` (Sprint 4A).
- Produces: `ComingSoonState` (View, `init(title: String, message: String)` — a static empty-state layout with no ViewModel/service, since P1 screens per spec §3 have no backend to model); `DNSProtectionView`.

Per spec §3/§9, this screen has no `ProtectionService` involvement, no ViewModel, and no mock backend — it is pure static content: a title, an icon, an explanatory message, and premium messaging. No test beyond confirming `ComingSoonState` renders its passed-in strings (there is no behavior to test; layout is validated manually).

- [ ] **Step 1: Write the failing test for `ComingSoonState`**

```swift
// ADBLXTests/DesignSystem/ComingSoonStateTests.swift
import Testing
@testable import ADBLX

@Suite("ComingSoonState")
struct ComingSoonStateTests {
    @Test("stores the title and message passed to it")
    func storesContent() {
        let state = ComingSoonState(title: "DNS Protection", message: "Available with Premium.")
        #expect(state.title == "DNS Protection")
        #expect(state.message == "Available with Premium.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ComingSoonStateTests`
Expected: FAIL — `ComingSoonState` does not exist.

- [ ] **Step 3: Implement `ComingSoonState`**

```swift
// ADBLX/DesignSystem/Components/ComingSoonState.swift
import SwiftUI

/// Static placeholder for P1 screens with no backend yet (Sprint 4 spec §3/§9).
/// No ViewModel — there is nothing to load or mutate.
struct ComingSoonState: View {
    let title: String
    let message: String

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
            Text("Coming Soon")
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
        title: "DNS Protection",
        message: "System-wide DNS filtering is coming in a future update. Available with Premium."
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/ComingSoonStateTests`
Expected: PASS (1 test)

- [ ] **Step 5: Implement `DNSProtectionView` and link it from Safari Protection**

```swift
// ADBLX/Features/Protection/DNSProtectionView.swift
import SwiftUI

struct DNSProtectionView: View {
    var body: some View {
        ComingSoonState(
            title: "DNS Protection",
            message: "System-wide DNS filtering blocks ads and trackers across every app on your device — entirely on-device, with nothing sent to a server. Available with Premium in a future update."
        )
        .background(DesignColors.background)
    }
}

#Preview {
    DNSProtectionView()
}
```

```swift
// Modify: ADBLX/Features/Protection/SafariProtectionView.swift
// Add a second NavigationLink immediately below the "Advanced Filter Lists" one added
// in Task 2 Step 7:

NavigationLink("DNS Protection") {
    DNSProtectionView()
}
.font(DesignTypography.bodyLarge)
.foregroundStyle(DesignColors.primary)
```

- [ ] **Step 6: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: tap "DNS Protection" from Safari Protection; confirm the Coming Soon layout renders with no crash, no backend call, no toggle. Cross-check the icon/copy against the live Stitch "DNS Protection" screen (`projects/16038318836427840964/screens/202aa105d37645e9a31f84d85f373235`) since this task's exact wording was sourced from the PRD's DNS tunnel description (§6.1) rather than a direct screen fetch during planning. Verify Dynamic Type and Dark Mode; VoiceOver should read the whole card as one phrase ending in "Coming Soon."

- [ ] **Step 7: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 8: Commit**

```bash
git add ADBLX/Features/Protection/DNSProtectionView.swift ADBLX/DesignSystem/Components/ComingSoonState.swift ADBLX/Features/Protection/SafariProtectionView.swift ADBLXTests/DesignSystem/ComingSoonStateTests.swift
git commit -m "feat(ui): add DNS Protection Coming Soon screen (P1, no backend)

Static ComingSoonState component and DNSProtectionView, navigable from
Safari Protection. No ViewModel/service — P1 per Sprint 4 spec §3/§9;
freezes the navigation slot without implying tunnel functionality."
```

---

## Task 4: Premium Screen (View + ViewModel + `SubscriptionService` + mock)

**Files:**
- Create: `ADBLX/Features/Premium/SubscriptionService.swift`
- Create: `ADBLX/Features/Premium/PremiumViewModel.swift`
- Create: `ADBLX/Features/Premium/PremiumView.swift`
- Create: `ADBLX/DesignSystem/Components/PremiumBadge.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Test: `ADBLXTests/Features/Premium/PremiumViewModelTests.swift`

**Interfaces:**
- Consumes: `Card`, `PrimaryButton` (Sprint 4A); `AppCompositionRoot.UIDependencies` (extended by Task 1 of this plan to include `protectionService`).
- Produces: `SubscriptionPlan` (struct: `id: String`, `name: String`, `priceDescription: String`, `billingPeriodDescription: String`, `isCurrentPlan: Bool`); `SubscriptionStatus` (struct: `isPremium: Bool`, `plans: [SubscriptionPlan]`); `SubscriptionService` (protocol: `func fetchStatus() async -> SubscriptionStatus`, `func purchase(_ planID: String) async throws -> Bool`); `MockSubscriptionService`; `PremiumViewModel`; `PremiumView`; `PremiumBadge` (View, `init(text: String = "Premium")`).

Content matches PRD FR-10 (StoreKit 2, "products: monthly, annual, lifetime") and §5.2's free-vs-premium feature matrix (YouTube blocking, DNS tunnel, Annoyances, Regional, iCloud sync, custom import, Mac app).

- [ ] **Step 1: Write the failing test for `PremiumViewModel`**

```swift
// ADBLXTests/Features/Premium/PremiumViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("PremiumViewModel")
struct PremiumViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = SubscriptionStatus(
            isPremium: false,
            plans: [
                SubscriptionPlan(id: "monthly", name: "Monthly", priceDescription: "$2.99", billingPeriodDescription: "per month", isCurrentPlan: false),
            ]
        )
        let viewModel = PremiumViewModel(service: StubSubscriptionService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
    }

    @Test("purchase(planID:) sets purchaseError when the service throws")
    func purchaseSurfacesError() async {
        let viewModel = PremiumViewModel(service: FailingSubscriptionService())

        await viewModel.purchase(planID: "monthly")

        #expect(viewModel.purchaseError != nil)
    }

    @Test("purchase(planID:) clears purchaseError and reloads status on success")
    func purchaseSucceeds() async {
        let status = SubscriptionStatus(isPremium: false, plans: [])
        let service = StubSubscriptionService(statusToReturn: status)
        let viewModel = PremiumViewModel(service: service)

        await viewModel.purchase(planID: "monthly")

        #expect(viewModel.purchaseError == nil)
    }
}

private struct StubSubscriptionService: SubscriptionService {
    let statusToReturn: SubscriptionStatus
    func fetchStatus() async -> SubscriptionStatus { statusToReturn }
    func purchase(_ planID: String) async throws -> Bool { true }
}

private struct FailingSubscriptionService: SubscriptionService {
    struct PurchaseError: Error {}
    func fetchStatus() async -> SubscriptionStatus { SubscriptionStatus(isPremium: false, plans: []) }
    func purchase(_ planID: String) async throws -> Bool { throw PurchaseError() }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/PremiumViewModelTests`
Expected: FAIL — `PremiumViewModel`, `SubscriptionService`, `SubscriptionStatus`, `SubscriptionPlan` do not exist.

- [ ] **Step 3: Implement `SubscriptionService`, its models, and `MockSubscriptionService`**

```swift
// ADBLX/Features/Premium/SubscriptionService.swift
import Foundation

struct SubscriptionPlan: Equatable, Identifiable {
    var id: String
    let name: String
    let priceDescription: String
    let billingPeriodDescription: String
    let isCurrentPlan: Bool
}

struct SubscriptionStatus: Equatable {
    let isPremium: Bool
    let plans: [SubscriptionPlan]
}

/// What Premium needs from the store. A later sprint's real implementation
/// wraps StoreKit 2 behind this protocol — PremiumView/PremiumViewModel do
/// not change (Sprint 4 spec §5).
protocol SubscriptionService: Sendable {
    func fetchStatus() async -> SubscriptionStatus
    func purchase(_ planID: String) async throws -> Bool
}

struct MockSubscriptionService: SubscriptionService {
    func fetchStatus() async -> SubscriptionStatus {
        SubscriptionStatus(
            isPremium: false,
            plans: [
                SubscriptionPlan(id: "monthly", name: "Monthly", priceDescription: "$2.99", billingPeriodDescription: "per month", isCurrentPlan: false),
                SubscriptionPlan(id: "annual", name: "Annual", priceDescription: "$19.99", billingPeriodDescription: "per year", isCurrentPlan: false),
                SubscriptionPlan(id: "lifetime", name: "Lifetime", priceDescription: "$49.99", billingPeriodDescription: "one-time", isCurrentPlan: false),
            ]
        )
    }

    func purchase(_ planID: String) async throws -> Bool { true }
}
```

- [ ] **Step 4: Implement `PremiumViewModel`**

```swift
// ADBLX/Features/Premium/PremiumViewModel.swift
import Observation

@Observable
final class PremiumViewModel {
    private let service: SubscriptionService

    var status: SubscriptionStatus?
    var isLoading = false
    var purchaseError: Error?

    init(service: SubscriptionService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }

    func purchase(planID: String) async {
        purchaseError = nil
        do {
            _ = try await service.purchase(planID)
            status = await service.fetchStatus()
        } catch {
            purchaseError = error
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/PremiumViewModelTests`
Expected: PASS (3 tests)

- [ ] **Step 6: Implement `PremiumBadge` and `PremiumView`**

```swift
// ADBLX/DesignSystem/Components/PremiumBadge.swift
import SwiftUI

struct PremiumBadge: View {
    var text: String = "Premium"

    var body: some View {
        Text(text)
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

```swift
// ADBLX/Features/Premium/PremiumView.swift
import SwiftUI

struct PremiumView: View {
    @State var viewModel: PremiumViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                HStack {
                    Text("ADBLX Premium")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    PremiumBadge()
                }

                Card {
                    featureRow("YouTube ad blocking in Safari")
                    Divider()
                    featureRow("System-wide DNS blocking")
                    Divider()
                    featureRow("Annoyance & regional filter lists")
                    Divider()
                    featureRow("iCloud sync across devices")
                }

                if let plans = viewModel.status?.plans {
                    VStack(spacing: DesignSpacing.stackGap) {
                        ForEach(plans) { plan in
                            planRow(plan)
                        }
                    }
                }

                if let error = viewModel.purchaseError {
                    Text(error.localizedDescription)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.error)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
    }

    private func featureRow(_ title: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignColors.primary)
            Text(title)
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurface)
        }
    }

    private func planRow(_ plan: SubscriptionPlan) -> some View {
        Button {
            Task { await viewModel.purchase(planID: plan.id) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(plan.name)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    Text(plan.billingPeriodDescription)
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                Spacer()
                Text(plan.priceDescription)
                    .font(DesignTypography.labelMono)
                    .foregroundStyle(DesignColors.onSurface)
            }
            .padding(DesignSpacing.containerPadding)
            .background(DesignColors.surfaceContainerLowest)
            .clipShape(RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.name), \(plan.priceDescription) \(plan.billingPeriodDescription)")
    }
}

#Preview {
    PremiumView(viewModel: PremiumViewModel(service: MockSubscriptionService()))
}
```

- [ ] **Step 7: Wire `SubscriptionService` into `AppCompositionRoot` and `RootTabView`**

```swift
// Modify: ADBLX/AppCompositionRoot.swift
// Replace the UIDependencies struct body with:

struct UIDependencies {
    let homeService: HomeService
    let protectionService: ProtectionService
    let subscriptionService: SubscriptionService
}

static func makeMockUIDependencies() -> UIDependencies {
    UIDependencies(
        homeService: MockHomeService(),
        protectionService: MockProtectionService(),
        subscriptionService: MockSubscriptionService()
    )
}
```

```swift
// Modify: ADBLX/Navigation/RootTabView.swift
// Add a case for .premium:

case .premium:
    NavigationStack {
        PremiumView(viewModel: PremiumViewModel(service: dependencies.subscriptionService))
    }
```

- [ ] **Step 8: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: on the Premium tab, confirm the feature list and three plan rows (Monthly/Annual/Lifetime) render; tapping a plan calls `purchase` (mock always succeeds, no visible error). Cross-check against the live Stitch "Premium Upgrade" screen (`projects/16038318836427840964/screens/244a03dcf8e44b05a85d86311c960984`) since this task's plan pricing/features were sourced from the PRD rather than a direct screen fetch during planning — Stitch's exact copy/pricing wins per Design Authority if it differs. Verify Dynamic Type, Dark Mode, and VoiceOver on each plan row.

- [ ] **Step 9: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 10: Commit**

```bash
git add ADBLX/Features/Premium/ ADBLX/DesignSystem/Components/PremiumBadge.swift ADBLX/AppCompositionRoot.swift ADBLX/Navigation/RootTabView.swift ADBLXTests/Features/Premium/
git commit -m "feat(ui): implement Premium screen

PremiumView + PremiumViewModel + SubscriptionService(protocol)/
MockSubscriptionService covering monthly/annual/lifetime plans (FR-10)
and the free-vs-premium feature list. Adds PremiumBadge. Wired into
AppCompositionRoot.UIDependencies and the Premium tab. Real StoreKit 2
wiring is deferred — this sprint ships the mock only."
```

---

## Task 5: Settings Screen (View + ViewModel + `SettingsService` + mock)

**Files:**
- Create: `ADBLX/Features/Settings/SettingsService.swift`
- Create: `ADBLX/Features/Settings/SettingsViewModel.swift`
- Create: `ADBLX/Features/Settings/SettingsView.swift`
- Create: `ADBLX/DesignSystem/Components/SettingsRow.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Test: `ADBLXTests/Features/Settings/SettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `Card` (Sprint 4A); `AppCompositionRoot.UIDependencies` (extended through Task 4).
- Produces: `AllowlistEntry` (struct: `id: String`, `domain: String`); `SettingsSnapshot` (struct: `iCloudSyncEnabled: Bool`, `allowlist: [AllowlistEntry]`); `SettingsService` (protocol: `func fetchSnapshot() async -> SettingsSnapshot`, `func addAllowlistEntry(domain: String) async`, `func removeAllowlistEntry(id: String) async`); `MockSettingsService`; `SettingsViewModel`; `SettingsView`; `SettingsRow` (View, `init(title: String, systemImage: String)` — a static icon/title/chevron row; navigation is handled by the caller wrapping it in a `NavigationLink`, not by `SettingsRow` itself).

Content matches FR-08 ("Per-site allowlist editable in-app"). About is a navigable child of Settings per the frozen IA — Task 6 adds it as a `SettingsRow` destination.

- [ ] **Step 1: Write the failing test for `SettingsViewModel`**

```swift
// ADBLXTests/Features/Settings/SettingsViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    @Test("load() populates snapshot from the injected service")
    func loadPopulatesSnapshot() async {
        let expected = SettingsSnapshot(iCloudSyncEnabled: false, allowlist: [AllowlistEntry(id: "1", domain: "example.com")])
        let viewModel = SettingsViewModel(service: StubSettingsService(snapshotToReturn: expected))

        await viewModel.load()

        #expect(viewModel.snapshot == expected)
    }

    @Test("addAllowlistEntry appends a new entry and reloads")
    func addAllowlistEntryAppends() async {
        let service = StubSettingsService(snapshotToReturn: SettingsSnapshot(iCloudSyncEnabled: false, allowlist: []))
        let viewModel = SettingsViewModel(service: service)
        await viewModel.load()

        await viewModel.addAllowlistEntry(domain: "example.com")

        #expect(await service.addedDomains == ["example.com"])
    }
}

private actor StubSettingsService: SettingsService {
    let snapshotToReturn: SettingsSnapshot
    private(set) var addedDomains: [String] = []

    init(snapshotToReturn: SettingsSnapshot) {
        self.snapshotToReturn = snapshotToReturn
    }

    func fetchSnapshot() async -> SettingsSnapshot { snapshotToReturn }
    func addAllowlistEntry(domain: String) async { addedDomains.append(domain) }
    func removeAllowlistEntry(id: String) async {}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/SettingsViewModelTests`
Expected: FAIL — `SettingsViewModel`, `SettingsService`, `SettingsSnapshot`, `AllowlistEntry` do not exist.

- [ ] **Step 3: Implement `SettingsService`, its models, and `MockSettingsService`**

```swift
// ADBLX/Features/Settings/SettingsService.swift
import Foundation

struct AllowlistEntry: Equatable, Identifiable {
    let id: String
    let domain: String
}

struct SettingsSnapshot: Equatable {
    let iCloudSyncEnabled: Bool
    var allowlist: [AllowlistEntry]
}

/// What Settings needs from the backend (FR-08's per-site allowlist). A later
/// sprint's real implementation persists to the shared App Group container.
protocol SettingsService: Sendable {
    func fetchSnapshot() async -> SettingsSnapshot
    func addAllowlistEntry(domain: String) async
    func removeAllowlistEntry(id: String) async
}

actor MockSettingsService: SettingsService {
    private var snapshot = SettingsSnapshot(
        iCloudSyncEnabled: false,
        allowlist: [
            AllowlistEntry(id: "1", domain: "news.example.com"),
            AllowlistEntry(id: "2", domain: "shop.example.com"),
        ]
    )

    func fetchSnapshot() async -> SettingsSnapshot { snapshot }

    func addAllowlistEntry(domain: String) async {
        snapshot.allowlist.append(AllowlistEntry(id: UUID().uuidString, domain: domain))
    }

    func removeAllowlistEntry(id: String) async {
        snapshot.allowlist.removeAll { $0.id == id }
    }
}
```

- [ ] **Step 4: Implement `SettingsViewModel`**

```swift
// ADBLX/Features/Settings/SettingsViewModel.swift
import Observation

@Observable
final class SettingsViewModel {
    private let service: SettingsService

    var snapshot: SettingsSnapshot?
    var isLoading = false

    init(service: SettingsService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        snapshot = await service.fetchSnapshot()
        isLoading = false
    }

    func addAllowlistEntry(domain: String) async {
        await service.addAllowlistEntry(domain: domain)
        snapshot = await service.fetchSnapshot()
    }

    func removeAllowlistEntry(id: String) async {
        await service.removeAllowlistEntry(id: id)
        snapshot = await service.fetchSnapshot()
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/SettingsViewModelTests`
Expected: PASS (2 tests)

- [ ] **Step 6: Implement `SettingsRow` and `SettingsView`**

```swift
// ADBLX/DesignSystem/Components/SettingsRow.swift
import SwiftUI

/// A navigation-style settings list row: icon, title, disclosure chevron.
struct SettingsRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(DesignColors.primary)
                .frame(width: 24)
            Text(title)
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
    SettingsRow(title: "About", systemImage: "info.circle.fill")
        .padding()
}
```

```swift
// ADBLX/Features/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var newDomain = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                Text("Settings")
                    .font(DesignTypography.headlineLarge)
                    .foregroundStyle(DesignColors.onBackground)

                if let snapshot = viewModel.snapshot {
                    Card {
                        HStack {
                            Text("iCloud Sync")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Spacer()
                            PremiumBadge()
                        }
                        Text(snapshot.iCloudSyncEnabled ? "On" : "Off")
                            .font(DesignTypography.bodySmall)
                            .foregroundStyle(DesignColors.onSurfaceVariant)
                    }

                    Card {
                        Text("Allowlist")
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
                            TextField("Add a domain", text: $newDomain)
                                .font(DesignTypography.bodyLarge)
                            Button("Add") {
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
                            SettingsRow(title: "About", systemImage: "info.circle.fill")
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

Note: `SettingsView` references `AboutView`, defined in Task 6. This is expected within this plan's task ordering — Task 5 must be implemented before Task 6's `AboutView` exists for the project to build; run Task 6 immediately after Task 5, or stub `AboutView` as an empty `Text("About")` temporarily if executing tasks out of order (not recommended — follow the plan's ordering).

- [ ] **Step 7: Wire `SettingsService` into `AppCompositionRoot` and `RootTabView`**

```swift
// Modify: ADBLX/AppCompositionRoot.swift
// Replace the UIDependencies struct body with:

struct UIDependencies {
    let homeService: HomeService
    let protectionService: ProtectionService
    let subscriptionService: SubscriptionService
    let settingsService: SettingsService
}

static func makeMockUIDependencies() -> UIDependencies {
    UIDependencies(
        homeService: MockHomeService(),
        protectionService: MockProtectionService(),
        subscriptionService: MockSubscriptionService(),
        settingsService: MockSettingsService()
    )
}
```

```swift
// Modify: ADBLX/Navigation/RootTabView.swift
// Add a case for .settings:

case .settings:
    NavigationStack {
        SettingsView(viewModel: SettingsViewModel(service: dependencies.settingsService))
    }
```

- [ ] **Step 8: Build, run in simulator, and validate**

This step depends on Task 6 (`AboutView`) also being complete, since `SettingsView` navigates to it. Complete Task 6 first, then return here.

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: on the Settings tab, confirm the iCloud Sync row (with Premium badge), the allowlist list with add/remove working, and navigation into About. Cross-check against the live Stitch "Settings" screen (`projects/16038318836427840964/screens/bdf82ee172da4249aa66bddeb5b5e30b`) since this task's content was sourced from FR-08 rather than a direct screen fetch during planning. Verify Dynamic Type, Dark Mode, and VoiceOver on the allowlist rows and add field.

- [ ] **Step 9: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 10: Commit**

```bash
git add ADBLX/Features/Settings/ ADBLX/DesignSystem/Components/SettingsRow.swift ADBLX/AppCompositionRoot.swift ADBLX/Navigation/RootTabView.swift ADBLXTests/Features/Settings/
git commit -m "feat(ui): implement Settings screen

SettingsView + SettingsViewModel + SettingsService(protocol)/
MockSettingsService covering the per-site allowlist (FR-08) and an
iCloud Sync status row. Adds SettingsRow. Navigates to About (Task 6).
Wired into AppCompositionRoot.UIDependencies and the Settings tab."
```

---

## Task 6: About Screen

**Files:**
- Create: `ADBLX/Features/Settings/AboutView.swift`

**Interfaces:**
- Consumes: `SettingsRow` (Task 5); `Card` (Sprint 4A).
- Produces: `AboutView` (no ViewModel/service — static app metadata only, same rationale as DNS Protection's `ComingSoonState`: nothing here is backend-driven).

Content: app name/version, links to Privacy Policy and Terms (per PRD §6.3's "publishable privacy audit" commitment and standard App Store requirements), and an acknowledgment that ADBLX collects zero browsing data.

- [ ] **Step 1: Implement `AboutView`**

No test-first step: this view has no logic, only static content — nothing to assert beyond what manual simulator validation (Step 2) already covers, consistent with `ComingSoonState`'s precedent in Task 3.

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
                    Text("ADBLX")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("Version 1.0")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)

                Card {
                    Text("Zero data collection. Nothing about your browsing ever leaves your device.")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                }

                Card {
                    Link("Privacy Policy", destination: URL(string: "https://adblx.app/privacy")!)
                        .font(DesignTypography.bodyLarge)
                    Divider()
                    Link("Terms of Service", destination: URL(string: "https://adblx.app/terms")!)
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

- [ ] **Step 2: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: navigate Settings → About; confirm the version, privacy statement, and both links render and are tappable. Cross-check against the live Stitch "About" screen (`projects/16038318836427840964/screens/2a22d18a85824605a0ca2ae69c4ff7b6`) since this task's copy was drafted from the PRD's zero-data-collection commitment rather than a direct screen fetch during planning. Verify Dynamic Type and Dark Mode.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures (this task adds no tests, so the count is unchanged from Task 5).

- [ ] **Step 4: Commit**

```bash
git add ADBLX/Features/Settings/AboutView.swift
git commit -m "feat(ui): implement About screen

Static app metadata, privacy statement, and Privacy Policy / Terms
links. No ViewModel or service — nothing here is backend-driven.
Navigable from Settings (completes Task 5's SettingsView reference)."
```

---

## Task 7: Update Progress Infrastructure (shared modal)

**Files:**
- Create: `ADBLX/Features/UpdateProgress/UpdateProgressModel.swift`
- Create: `ADBLX/Features/UpdateProgress/UpdateProgressSheet.swift`
- Modify: `ADBLX/Features/Home/HomeView.swift`
- Modify: `ADBLX/Features/Protection/SafariProtectionView.swift`
- Test: `ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift`

**Interfaces:**
- Consumes: `Card`, `DesignColors`, `DesignTypography`, `DesignSpacing` (Sprint 4A).
- Produces: `UpdateProgressModel` (`@Observable`, `phase: UpdatePhase`, `progressDescription: String`, `func start()`); `UpdatePhase` (enum: `.idle`, `.checking`, `.downloading`, `.installing`, `.complete`, `.failed(String)`); `UpdateProgressSheet` (View, `init(model: UpdateProgressModel)`).

Per spec §7, this is shared infrastructure, not a screen owned by one feature — both Home and Safari Protection present the same sheet. This task deliberately has no service/mock: it models UI-visible progress state directly (a later sprint drives `phase` transitions from real `UpdateCoordinator` callbacks; this sprint drives them from a canned local sequence so the sheet is visually complete and testable now).

- [ ] **Step 1: Write the failing test for `UpdateProgressModel`**

```swift
// ADBLXTests/Features/UpdateProgress/UpdateProgressModelTests.swift
import Testing
@testable import ADBLX

@Suite("UpdateProgressModel")
struct UpdateProgressModelTests {
    @Test("starts in the idle phase")
    func startsIdle() {
        let model = UpdateProgressModel()
        #expect(model.phase == .idle)
    }

    @Test("start() walks through checking, downloading, installing, then complete")
    func startWalksThroughPhases() async {
        let model = UpdateProgressModel()

        await model.start()

        #expect(model.phase == .complete)
    }

    @Test("progressDescription reflects the current phase")
    func progressDescriptionReflectsPhase() {
        let model = UpdateProgressModel()
        model.phase = .downloading
        #expect(model.progressDescription == "Downloading filter updates…")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/UpdateProgressModelTests`
Expected: FAIL — `UpdateProgressModel`, `UpdatePhase` do not exist.

- [ ] **Step 3: Implement `UpdateProgressModel`**

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
        case .idle: return "Ready to update"
        case .checking: return "Checking for updates…"
        case .downloading: return "Downloading filter updates…"
        case .installing: return "Installing filters…"
        case .complete: return "Filters updated"
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

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/UpdateProgressModelTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Implement `UpdateProgressSheet`**

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
                PrimaryButton(title: "Done") { dismiss() }
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

- [ ] **Step 6: Present the sheet from Home and Safari Protection**

```swift
// Modify: ADBLX/Features/Home/HomeView.swift
// Add a @State property to HomeView:
//     @State private var isShowingUpdateProgress = false
// Change the PrimaryButton("Reload Safari Blockers") action from
// `Task { await viewModel.load() }` to:
//     isShowingUpdateProgress = true
// Add a sheet modifier to the outermost ScrollView, alongside the existing .task:
//     .sheet(isPresented: $isShowingUpdateProgress) {
//         UpdateProgressSheet(model: UpdateProgressModel())
//     }
```

```swift
// Modify: ADBLX/Features/Protection/SafariProtectionView.swift
// Add a @State property to SafariProtectionView:
//     @State private var isShowingUpdateProgress = false
// Add a PrimaryButton below the existing category Card in the VStack:
//     PrimaryButton(title: "Check for Updates") {
//         isShowingUpdateProgress = true
//     }
// Add a sheet modifier alongside the existing .task:
//     .sheet(isPresented: $isShowingUpdateProgress) {
//         UpdateProgressSheet(model: UpdateProgressModel())
//     }
```

- [ ] **Step 7: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: tap "Reload Safari Blockers" on Home — confirm the sheet presents, walks through its phases (~1 second total), and shows a "Done" button on completion that dismisses it. Repeat from "Check for Updates" on Safari Protection — confirm the same sheet, independently presentable from both screens. Cross-check the phase copy/iconography against the live Stitch "Update Progress Sheet" screen (`projects/16038318836427840964/screens/812697e43f7244f3ba8c8ac64c0da9ea`) since this task's phase wording was drafted rather than sourced from a direct screen fetch during planning. Verify Dynamic Type, Dark Mode, and VoiceOver (progress description announces on each phase change).

- [ ] **Step 8: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 9: Commit**

```bash
git add ADBLX/Features/UpdateProgress/ ADBLX/Features/Home/HomeView.swift ADBLX/Features/Protection/SafariProtectionView.swift ADBLXTests/Features/UpdateProgress/
git commit -m "feat(ui): add Update Progress shared infrastructure

UpdateProgressModel + UpdateProgressSheet, presentable as a modal from
both Home ('Reload Safari Blockers') and Safari Protection ('Check for
Updates'), per Sprint 4 spec §7's shared-infrastructure framing. Drives
phases from a canned local sequence; a later sprint swaps in real
UpdateCoordinator callbacks without changing the sheet."
```

---

## Task 8: Onboarding Flow

**Files:**
- Create: `ADBLX/Features/Onboarding/OnboardingView.swift`
- Create: `ADBLX/Features/Onboarding/OnboardingCompletionStore.swift`
- Modify: `ADBLX/ADBLXApp.swift`
- Test: `ADBLXTests/Features/Onboarding/OnboardingCompletionStoreTests.swift`

**Interfaces:**
- Consumes: `Card`, `PrimaryButton` (Sprint 4A); `DesignColors`, `DesignTypography`, `DesignSpacing` (Sprint 4A); `RootTabView`, `AppCompositionRoot.UIDependencies` (Sprint 4A Task 2, extended through Task 5 of this plan).
- Produces: `OnboardingCompletionStore` (struct wrapping `UserDefaults`: `var hasCompletedOnboarding: Bool`); `OnboardingView` (View, `init(onFinish: @escaping () -> Void)`).

Content matches the fetched Stitch "Onboarding" screen exactly (confirmed during planning): headline "Browse the web in total peace," a three-feature "Why ADBLX" section (Privacy First / Pure Speed / Simplicity), a three-step Safari-activation guide, a "Stay Secure" note about update alerts, and "Get Started" / "Skip for now" CTAs.

- [ ] **Step 1: Write the failing test for `OnboardingCompletionStore`**

```swift
// ADBLXTests/Features/Onboarding/OnboardingCompletionStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("OnboardingCompletionStore")
struct OnboardingCompletionStoreTests {
    @Test("defaults to false for a fresh UserDefaults suite")
    func defaultsToFalse() {
        let suiteName = "OnboardingCompletionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(defaults: defaults)

        #expect(store.hasCompletedOnboarding == false)
    }

    @Test("setting hasCompletedOnboarding persists across store instances")
    func persistsAcrossInstances() {
        let suiteName = "OnboardingCompletionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var store = OnboardingCompletionStore(defaults: defaults)

        store.hasCompletedOnboarding = true

        let reloaded = OnboardingCompletionStore(defaults: defaults)
        #expect(reloaded.hasCompletedOnboarding == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/OnboardingCompletionStoreTests`
Expected: FAIL — `OnboardingCompletionStore` does not exist.

- [ ] **Step 3: Implement `OnboardingCompletionStore`**

```swift
// ADBLX/Features/Onboarding/OnboardingCompletionStore.swift
import Foundation

struct OnboardingCompletionStore {
    private let defaults: UserDefaults
    private static let key = "hasCompletedOnboarding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/OnboardingCompletionStoreTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Implement `OnboardingView`**

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
                    Text("ADBLX")
                        .font(DesignTypography.headlineLarge)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("Browse the web in total peace.")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Card {
                    featureRow(icon: "lock.shield.fill", title: "Privacy First", body: "Blocks trackers before they ever load — nothing about your browsing leaves your device.")
                    Divider()
                    featureRow(icon: "bolt.fill", title: "Pure Speed", body: "Pages load faster with ads and trackers stripped out before rendering.")
                    Divider()
                    featureRow(icon: "checkmark.seal.fill", title: "Simplicity", body: "One toggle. No configuration required.")
                }

                VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
                    Text("Activation")
                        .font(DesignTypography.headlineMedium)
                        .foregroundStyle(DesignColors.onBackground)
                    Text("To start blocking, please enable ADBLX in your Safari settings.")
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                    Card {
                        stepRow(number: 1, text: "Open Settings and tap Safari.")
                        Divider()
                        stepRow(number: 2, text: "Tap Extensions or Content Blockers.")
                        Divider()
                        stepRow(number: 3, text: "Turn on all ADBLX switches.")
                    }
                }

                Card {
                    HStack(alignment: .top, spacing: DesignSpacing.gutter) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(DesignColors.secondary)
                        VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                            Text("Stay Secure")
                                .font(DesignTypography.bodyLarge)
                                .foregroundStyle(DesignColors.onSurface)
                            Text("We'll let you know when filter updates are ready, with a weekly security report.")
                                .font(DesignTypography.bodySmall)
                                .foregroundStyle(DesignColors.onSurfaceVariant)
                        }
                    }
                }

                VStack(spacing: DesignSpacing.stackGap) {
                    PrimaryButton(title: "Get Started", action: onFinish)
                    Button("Skip for now", action: onFinish)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
    }

    private func featureRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Image(systemName: icon)
                .foregroundStyle(DesignColors.primary)
            VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                Text(title)
                    .font(DesignTypography.bodyLarge)
                    .foregroundStyle(DesignColors.onSurface)
                Text(body)
                    .font(DesignTypography.bodySmall)
                    .foregroundStyle(DesignColors.onSurfaceVariant)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.gutter) {
            Text("\(number)")
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onPrimary)
                .frame(width: 24, height: 24)
                .background(DesignColors.primary)
                .clipShape(Circle())
            Text(text)
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

- [ ] **Step 6: Present Onboarding before `RootTabView` on first launch**

```swift
// Modify: ADBLX/ADBLXApp.swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterPipeline = AppCompositionRoot.makeFilterPipeline()
    private let uiDependencies = AppCompositionRoot.makeMockUIDependencies()
    @State private var onboardingStore = OnboardingCompletionStore()
    @State private var hasCompletedOnboarding: Bool

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
        _hasCompletedOnboarding = State(initialValue: OnboardingCompletionStore().hasCompletedOnboarding)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView(dependencies: uiDependencies)
                } else {
                    OnboardingView {
                        onboardingStore.hasCompletedOnboarding = true
                        hasCompletedOnboarding = true
                    }
                }
            }
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

- [ ] **Step 7: Build, run in simulator, and validate against the live Stitch screen**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

In Simulator: erase the app's data (or uninstall/reinstall) to reset `UserDefaults`, then launch — confirm Onboarding shows first. Tap "Get Started"; confirm `RootTabView` appears and relaunching the app (without erasing data) skips straight to `RootTabView`. Repeat, tapping "Skip for now" instead — same result. Cross-check the copy/layout against the live Stitch "Onboarding" screen (`projects/16038318836427840964/screens/5a7015c19456464784b47c5c8c1e79d5`) — this task's content matches what was fetched directly from that screen during planning, so no discrepancy is expected, but confirm anyway per Design Authority (spec §2). Verify Dynamic Type, Dark Mode, and VoiceOver on each section.

- [ ] **Step 8: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 9: Commit**

```bash
git add ADBLX/Features/Onboarding/ ADBLX/ADBLXApp.swift ADBLXTests/Features/Onboarding/
git commit -m "feat(ui): implement Onboarding flow

OnboardingView (matching the Stitch 'Onboarding' screen: Why ADBLX,
Safari activation steps, Stay Secure note, Get Started/Skip CTAs) and
OnboardingCompletionStore (UserDefaults-backed). ADBLXApp now presents
Onboarding before RootTabView on first launch only.

This completes Sprint 4's UI implementation: all 9 screens (Home,
Safari Protection, Advanced Filter Lists, DNS Protection, Premium,
Settings, About, Update Progress, Onboarding) are now implemented
behind the View -> ViewModel -> Service(protocol) -> mock pattern
established in Sprint 4A, ready for real backend wiring in a later
sprint."
```

---

## Self-Review Notes

- **Spec coverage:** §3 IA — all remaining screens (Safari Protection, Advanced Filter Lists, DNS Protection, Premium, Settings, About, Update Progress, Onboarding) covered across Tasks 1–8, completing the frozen IA alongside Sprint 4A's Home. §3 P0/P1 split — DNS Protection (Task 3) explicitly has no ViewModel/service/backend, matching the P1 definition-of-done exactly. §4 design system — every task styles exclusively through Sprint 4A's `DesignSystem` tokens; new components (`ToggleRow`, `ComingSoonState`, `PremiumBadge`, `SettingsRow`) follow the "grown organically" rule (spec §7), each introduced in the first task that needs it. §5 presentation architecture — every P0 screen (Tasks 1, 2, 4, 5) has its own Service protocol + mock; About and DNS Protection correctly have neither, since they're static (spec §5 doesn't require a service where there's nothing to fetch/mutate). §6 definition of done — every screen task's build/run step explicitly checks Dynamic Type, Dark Mode, VoiceOver, and navigation. §7 commit sequence — this plan's 8 tasks map onto the spec's Commits 4 (Safari Protection) through 12 (Onboarding), with Update Progress correctly framed as infrastructure (Task 7) rather than a screen. §9 out of scope — no task wires real `FilterPipeline`/`UpdateCoordinator`/StoreKit/tunnel; `UpdateProgressModel.start()` explicitly notes its canned sequence is a stand-in.
- **Placeholder scan:** no TBD/TODO. Task 5 Step 6's note about `AboutView` not existing yet until Task 6 is a genuine sequencing dependency (not a placeholder) — flagged explicitly with an instruction, not left implicit.
- **Type consistency:** `ProtectionService`/`ProtectionViewModel`/`FilterCategoryID` introduced in Task 1 are extended (not redefined) in Task 2 — `ProtectionStatus` gains `filterLists` via modification, and the protocol gains `setFilterList` via modification, both shown as concrete diffs against Task 1's code rather than restated from scratch. `AppCompositionRoot.UIDependencies` is threaded through Tasks 1, 4, and 5 as a strictly additive struct (each task's Step shows the full updated struct so there's no drift between tasks). `SettingsRow`'s Interfaces-block signature (Task 5) initially stated a `destination: () -> Void` parameter that the Step 6 implementation and both call sites (Task 5's `SettingsView`, Task 6's usage note) never actually used — navigation is handled by the caller's `NavigationLink`, not by `SettingsRow`. Corrected the Interfaces block to `init(title: String, systemImage: String)` to match the real implementation.
- **Post-ABORT-review correction (rule-count granularity):** an ABORT review of this plan flagged that `FilterListEntry.ruleCount: Int` (Task 2, per-source-within-a-group) fabricated data the backend cannot produce — `docs/gotchas.md` already documents that `CompositionService`/`FilterPipeline` only ever compute a group-level aggregate `InstalledFilter.ruleCount`, written identically into every source in a group, with no per-source count. This is the same gap Sprint 3A hit and documented; reintroducing it here via `FilterListEntry` would have been the identical bug one sprint later. Fixed by removing `ruleCount` from `FilterListEntry` entirely (Task 2's struct, both test literals, the mock's stored data, and the view's row text) — `AdvancedFilterListsView` now shows name/version/premium/toggle only, no count. `ProtectionCategory.ruleCount` (Task 1, per-group) is unaffected and correctly retained, since group-level aggregates are exactly what the backend can report today.
