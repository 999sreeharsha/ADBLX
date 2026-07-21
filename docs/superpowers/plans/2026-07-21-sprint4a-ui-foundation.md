# Sprint 4A — UI Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish every architectural pattern for ADBLX's SwiftUI layer — design tokens extracted from the frozen Stitch design, a navigation shell wired to a mock-backed `AppCompositionRoot`, a component library seeded on demand, and the Home screen fully implemented (View + ViewModel + Service protocol + mock) — so Sprint 4B can replicate the pattern across the remaining 8 screens without further architectural decisions.

**Architecture:** Every screen follows View → ViewModel → Service protocol → mock implementation, matching the existing backend's constructor-injected, protocol-first style (`FilterPipeline`, `AppCompositionRoot`). Design tokens are read directly from the Stitch project's "Serene Shield" theme, not reinterpreted. `AppCompositionRoot` gains a UI-facing mock dependency graph alongside its existing `makeFilterPipeline()` factory.

**Tech Stack:** SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect` — this codebase does not use XCTest), Swift 5, iOS/macOS/visionOS multiplatform target (`ADBLX` target, `syncedFolder` source directories — new files under `ADBLX/` or `ADBLXTests/` are picked up automatically by xcodegen, no `project.yml` edits needed).

## Global Constraints

- Design values (colors, type, spacing, radius, shadow) come from the Stitch project `projects/16038318836427840964` ("ADBLX: Peaceful Ad Blocker", theme "Serene Shield") — copied verbatim below in Task 1. Do not invent or adjust values.
- Every screen: View + ViewModel + Service protocol + mock implementation. ViewModels contain no SwiftUI-specific logic and depend only on their feature's service protocol. Internal backend types (`FilterPipeline`, `UpdateCoordinator`) are never protocolized or exposed to the UI layer.
- Each commit must build successfully, pass all existing tests, introduce no Swift compiler warnings, and leave the app in a runnable state.
- Test file headers follow the existing convention: first line is `// <path/to/file.swift>` (see `ADBLXTests/Filtering/ChecksumTests.swift`), then `import Testing`, `import Foundation` (if needed), `@testable import ADBLX`.
- Frozen IA (do not deviate): Home / Protection (Safari Protection → Categories, Advanced Filter Lists / DNS Protection) / Premium / Settings → About. Onboarding is presented pre-navigation on first launch. Update Progress is a shared modal, not a tab.

---

## Task 1: Adopt Stitch Design System

**Files:**
- Create: `ADBLX/DesignSystem/DesignColors.swift`
- Create: `ADBLX/DesignSystem/DesignTypography.swift`
- Create: `ADBLX/DesignSystem/DesignSpacing.swift`
- Create: `ADBLX/DesignSystem/DesignShape.swift`
- Test: `ADBLXTests/DesignSystem/DesignSystemTests.swift`

**Interfaces:**
- Produces: `DesignColors` (enum, static `Color` properties), `DesignTypography` (enum, static `Font` properties), `DesignSpacing` (enum, static `CGFloat` properties), `DesignShape` (enum, static `CGFloat` corner-radius properties). All later tasks style views exclusively through these four types — no raw hex/point literals in View files.

Values below are copied verbatim from the Stitch theme (`projects/16038318836427840964`, theme "Serene Shield"). Light mode only for this task; dark-mode variants are out of scope for Sprint 4A (Stitch screens include a separate "Light Mode" variant per screen — dark mode is the default/first variant and is what ships now).

- [ ] **Step 1: Write the failing test for `DesignColors`**

```swift
// ADBLXTests/DesignSystem/DesignSystemTests.swift
import Testing
import SwiftUI
@testable import ADBLX

@Suite("DesignColors")
struct DesignColorsTests {
    @Test("primary matches the Stitch theme's Privacy Purple")
    func primaryMatchesTheme() {
        #expect(DesignColors.primary == Color(hex: "#3f3bbd"))
    }

    @Test("secondary matches the Stitch theme's Safety Blue")
    func secondaryMatchesTheme() {
        #expect(DesignColors.secondary == Color(hex: "#0058bc"))
    }

    @Test("background matches the Stitch theme's surface color")
    func backgroundMatchesTheme() {
        #expect(DesignColors.background == Color(hex: "#fcf8fb"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/DesignColorsTests`
Expected: FAIL — `DesignColors` does not exist (build error: cannot find type `DesignColors` in scope).

- [ ] **Step 3: Implement `Color(hex:)` and `DesignColors`**

```swift
// ADBLX/DesignSystem/DesignColors.swift
import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Color tokens read verbatim from the Stitch project's "Serene Shield" theme
/// (projects/16038318836427840964). Do not adjust these values without first
/// updating the Stitch theme — Stitch is the design authority (see Sprint 4 spec §2).
enum DesignColors {
    static let primary = Color(hex: "#3f3bbd")
    static let primaryContainer = Color(hex: "#5856d6")
    static let onPrimary = Color(hex: "#ffffff")
    static let onPrimaryContainer = Color(hex: "#e7e4ff")

    static let secondary = Color(hex: "#0058bc")
    static let secondaryContainer = Color(hex: "#0070eb")
    static let onSecondary = Color(hex: "#ffffff")

    static let tertiary = Color(hex: "#7e3e00")
    static let tertiaryContainer = Color(hex: "#a25100")
    static let onTertiary = Color(hex: "#ffffff")

    static let error = Color(hex: "#ba1a1a")
    static let errorContainer = Color(hex: "#ffdad6")
    static let onError = Color(hex: "#ffffff")
    static let onErrorContainer = Color(hex: "#93000a")

    static let background = Color(hex: "#fcf8fb")
    static let onBackground = Color(hex: "#1b1b1d")

    static let surface = Color(hex: "#fcf8fb")
    static let surfaceDim = Color(hex: "#dcd9dc")
    static let surfaceBright = Color(hex: "#fcf8fb")
    static let surfaceContainerLowest = Color(hex: "#ffffff")
    static let surfaceContainerLow = Color(hex: "#f6f3f5")
    static let surfaceContainer = Color(hex: "#f0edef")
    static let surfaceContainerHigh = Color(hex: "#eae7ea")
    static let surfaceContainerHighest = Color(hex: "#e4e2e4")
    static let onSurface = Color(hex: "#1b1b1d")
    static let onSurfaceVariant = Color(hex: "#464554")

    static let outline = Color(hex: "#777585")
    static let outlineVariant = Color(hex: "#c7c4d6")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/DesignColorsTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Write the failing test for `DesignTypography`**

```swift
// Append to ADBLXTests/DesignSystem/DesignSystemTests.swift
@Suite("DesignTypography")
struct DesignTypographyTests {
    @Test("headlineLarge uses a 34pt bold weight, matching the Stitch theme")
    func headlineLargeSize() {
        #expect(DesignTypography.headlineLargeSize == 34)
        #expect(DesignTypography.headlineLargeWeight == .bold)
    }

    @Test("bodyLarge uses a 17pt regular weight, matching the Stitch theme")
    func bodyLargeSize() {
        #expect(DesignTypography.bodyLargeSize == 17)
        #expect(DesignTypography.bodyLargeWeight == .regular)
    }

    @Test("labelMono uses a 13pt medium weight, matching the Stitch theme")
    func labelMonoSize() {
        #expect(DesignTypography.labelMonoSize == 13)
        #expect(DesignTypography.labelMonoWeight == .medium)
    }
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/DesignTypographyTests`
Expected: FAIL — `DesignTypography` does not exist.

- [ ] **Step 7: Implement `DesignTypography`**

The Stitch theme specifies three distinct font families (Plus Jakarta Sans for headlines, Inter for body, Geist for labels/stats). None are system fonts, so `Font.custom` is used; if the named font isn't bundled/available at runtime, SwiftUI falls back to the system font automatically — no crash risk. Bundling the actual font files is out of scope for this task (tracked as a follow-up; screens remain visually close even on system-font fallback since sizes/weights match exactly).

```swift
// ADBLX/DesignSystem/DesignTypography.swift
import SwiftUI

/// Typography tokens read verbatim from the Stitch project's "Serene Shield" theme.
/// Font families fall back to system fonts until the actual font files are bundled
/// (tracked separately) — sizes and weights are exact regardless.
enum DesignTypography {
    static let headlineLargeSize: CGFloat = 34
    static let headlineLargeWeight: Font.Weight = .bold
    static let headlineLarge = Font.custom("PlusJakartaSans-Bold", size: headlineLargeSize)

    static let headlineMediumSize: CGFloat = 22
    static let headlineMediumWeight: Font.Weight = .semibold
    static let headlineMedium = Font.custom("PlusJakartaSans-SemiBold", size: headlineMediumSize)

    static let bodyLargeSize: CGFloat = 17
    static let bodyLargeWeight: Font.Weight = .regular
    static let bodyLarge = Font.custom("Inter-Regular", size: bodyLargeSize)

    static let bodySmallSize: CGFloat = 15
    static let bodySmallWeight: Font.Weight = .regular
    static let bodySmall = Font.custom("Inter-Regular", size: bodySmallSize)

    static let labelCapsSize: CGFloat = 12
    static let labelCapsWeight: Font.Weight = .semibold
    static let labelCaps = Font.custom("Geist-SemiBold", size: labelCapsSize)

    static let labelMonoSize: CGFloat = 13
    static let labelMonoWeight: Font.Weight = .medium
    static let labelMono = Font.custom("Geist-Medium", size: labelMonoSize)
}
```

- [ ] **Step 8: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/DesignTypographyTests`
Expected: PASS (3 tests)

- [ ] **Step 9: Write the failing test for `DesignSpacing` and `DesignShape`**

```swift
// Append to ADBLXTests/DesignSystem/DesignSystemTests.swift
@Suite("DesignSpacing")
struct DesignSpacingTests {
    @Test("base unit is 8pt, matching the Stitch theme's baseline grid")
    func baseUnit() {
        #expect(DesignSpacing.base == 8)
    }

    @Test("container padding is 20pt")
    func containerPadding() {
        #expect(DesignSpacing.containerPadding == 20)
    }

    @Test("stack gap is 16pt and section gap is 32pt")
    func stackAndSectionGaps() {
        #expect(DesignSpacing.stackGap == 16)
        #expect(DesignSpacing.sectionGap == 32)
    }
}

@Suite("DesignShape")
struct DesignShapeTests {
    @Test("card corner radius is 24pt (rounded-xl)")
    func cardRadius() {
        #expect(DesignShape.cardCornerRadius == 24)
    }

    @Test("button corner radius is 16pt (rounded-lg)")
    func buttonRadius() {
        #expect(DesignShape.buttonCornerRadius == 16)
    }
}
```

- [ ] **Step 10: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/DesignSpacingTests -only-testing:ADBLXTests/DesignShapeTests`
Expected: FAIL — `DesignSpacing` and `DesignShape` do not exist.

- [ ] **Step 11: Implement `DesignSpacing` and `DesignShape`**

```swift
// ADBLX/DesignSystem/DesignSpacing.swift
import Foundation

/// Spacing tokens read verbatim from the Stitch project's "Serene Shield" theme
/// (8px baseline grid).
enum DesignSpacing {
    static let base: CGFloat = 8
    static let containerPadding: CGFloat = 20
    static let gutter: CGFloat = 12
    static let stackGap: CGFloat = 16
    static let sectionGap: CGFloat = 32
}
```

```swift
// ADBLX/DesignSystem/DesignShape.swift
import Foundation

/// Corner-radius tokens read verbatim from the Stitch project's "Serene Shield" theme.
enum DesignShape {
    static let smallCornerRadius: CGFloat = 4
    static let defaultCornerRadius: CGFloat = 8
    static let buttonCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 24
    static let pillCornerRadius: CGFloat = 9999
}
```

- [ ] **Step 12: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/DesignSpacingTests -only-testing:ADBLXTests/DesignShapeTests`
Expected: PASS (5 tests)

- [ ] **Step 13: Run the full existing test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — all pre-existing tests plus the 11 new DesignSystem tests (81 + 11 = 92 tests). If the pre-existing count differs, the requirement is zero new failures, not an exact number.

- [ ] **Step 14: Commit**

```bash
git add ADBLX/DesignSystem/ ADBLXTests/DesignSystem/
git commit -m "feat(ui): adopt Stitch design system tokens

Extract colors, typography, spacing, and shape tokens verbatim from the
Stitch project's 'Serene Shield' theme (projects/16038318836427840964).
Stitch remains the design authority; these are read, not reinterpreted."
```

---

## Task 2: Application Shell & Composition Root

**Files:**
- Create: `ADBLX/Navigation/AppTab.swift`
- Create: `ADBLX/Navigation/RootTabView.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/ADBLXApp.swift`
- Test: `ADBLXTests/Navigation/AppTabTests.swift`

**Interfaces:**
- Consumes: `DesignColors`, `DesignTypography` (Task 1).
- Produces: `AppTab` (enum: `.home`, `.protection`, `.premium`, `.settings` — the four bottom-nav destinations per the frozen IA), `RootTabView` (a `View` presenting a `TabView` over `AppTab`), `AppCompositionRoot.makeMockUIDependencies() -> UIDependencies` (a struct later tasks extend with per-feature service factories — Task 3 adds `homeService`).

- [ ] **Step 1: Write the failing test for `AppTab`**

```swift
// ADBLXTests/Navigation/AppTabTests.swift
import Testing
@testable import ADBLX

@Suite("AppTab")
struct AppTabTests {
    @Test("has exactly the four frozen top-level destinations, in nav-bar order")
    func allCasesMatchFrozenIA() {
        #expect(AppTab.allCases == [.home, .protection, .premium, .settings])
    }

    @Test("each tab has a non-empty title and a valid SF Symbol name")
    func titlesAndIconsExist() {
        for tab in AppTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.systemImage.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/AppTabTests`
Expected: FAIL — `AppTab` does not exist.

- [ ] **Step 3: Implement `AppTab`**

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
        case .home: return "Home"
        case .protection: return "Protection"
        case .premium: return "Premium"
        case .settings: return "Settings"
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

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/AppTabTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Extend `AppCompositionRoot` with a UI dependency graph**

`AppCompositionRoot` currently only builds `FilterPipeline`. Add a parallel `UIDependencies` container for UI-facing services, starting empty — Task 3 (Home) is what adds its first member (`homeService`). This step only adds the container and factory so the shell can compile against it; it deliberately holds nothing yet.

```swift
// Modify: ADBLX/AppCompositionRoot.swift
// Add below the existing makeFilterPipeline() function, inside the same
// `enum AppCompositionRoot { ... }` body — do not create a second enum.

/// Holds every UI-facing service the app's screens depend on. Screens never
/// construct services themselves — they receive them from here (or, in tests,
/// construct their own mocks directly). Real implementations replace the
/// mocks returned by makeMockUIDependencies() in a later sprint; ViewModels
/// and Views do not change when that happens (Sprint 4 spec §5).
struct UIDependencies {
}

static func makeMockUIDependencies() -> UIDependencies {
    UIDependencies()
}
```

- [ ] **Step 6: Implement `RootTabView`**

```swift
// ADBLX/Navigation/RootTabView.swift
import SwiftUI

struct RootTabView: View {
    let dependencies: AppCompositionRoot.UIDependencies

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
        VStack(spacing: DesignSpacing.stackGap) {
            Text(tab.title)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColors.background)
    }
}

#Preview {
    RootTabView(dependencies: AppCompositionRoot.makeMockUIDependencies())
}
```

Task 3 (Home) replaces the `.home` placeholder branch with the real `HomeView`; each subsequent screen task in Sprint 4B replaces one more branch. This keeps `RootTabView` itself a one-line-per-tab router with no business logic.

- [ ] **Step 7: Wire `RootTabView` into the app entry point**

```swift
// Modify: ADBLX/ADBLXApp.swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterPipeline = AppCompositionRoot.makeFilterPipeline()
    private let uiDependencies = AppCompositionRoot.makeMockUIDependencies()

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(dependencies: uiDependencies)
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

`ContentView.swift` (the unmodified Xcode template) is no longer referenced by the app entry point after this step. Leave the file in place for now — Task 4 in Sprint 4B's plan removes it once nothing imports it; deleting it here is out of scope for this task's stated deliverable (shell + composition root).

- [ ] **Step 8: Build and run in the simulator to confirm the shell renders**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

Then launch in Simulator (via Xcode or `xcrun simctl`) and confirm: four tabs visible (Home, Protection, Premium, Settings) with the correct SF Symbols, tapping each shows its placeholder title, tint color on the selected tab is the Privacy Purple (`#3f3bbd`).

- [ ] **Step 9: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 10: Commit**

```bash
git add ADBLX/Navigation/ ADBLX/AppCompositionRoot.swift ADBLX/ADBLXApp.swift ADBLXTests/Navigation/
git commit -m "feat(ui): add application shell and UI composition root

RootTabView wires the four frozen top-level destinations (Home,
Protection, Premium, Settings) into a TabView. AppCompositionRoot gains
a UIDependencies container that screens will draw their services from,
mirroring the existing FilterPipeline construction pattern."
```

---

## Task 3: Shared Component — `PrimaryButton` and `Card`

**Files:**
- Create: `ADBLX/DesignSystem/Components/PrimaryButton.swift`
- Create: `ADBLX/DesignSystem/Components/Card.swift`
- Test: `ADBLXTests/DesignSystem/ComponentsTests.swift`

**Interfaces:**
- Consumes: `DesignColors`, `DesignTypography`, `DesignShape`, `DesignSpacing` (Task 1).
- Produces: `PrimaryButton` (View, `init(title: String, action: @escaping () -> Void)`), `Card` (View, `init(@ViewBuilder content: () -> Content)`). Home (Task 4) is the first consumer of both.

These are the first two components in the "grown organically" library (Sprint 4 spec §7) — introduced here because Home's layout (per the Stitch screenshot: a bordered card grouping system-status rows, and a "Reload Safari Blockers" action) needs both immediately. No other components are pre-built speculatively.

- [ ] **Step 1: Write the failing test**

SwiftUI `View`s aren't directly assertable, so these tests verify the piece that is testable without a host: that `PrimaryButton`'s action closure fires, via a plain-Swift wrapper rather than rendering. (View layout itself is validated manually per the Definition of Done, §6 of the spec — not unit tested.)

```swift
// ADBLXTests/DesignSystem/ComponentsTests.swift
import Testing
@testable import ADBLX

@Suite("PrimaryButton")
struct PrimaryButtonTests {
    @Test("action closure fires exactly once when invoked")
    func actionFires() {
        var callCount = 0
        let button = PrimaryButton(title: "Reload") { callCount += 1 }
        button.action()
        #expect(callCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/PrimaryButtonTests`
Expected: FAIL — `PrimaryButton` does not exist.

- [ ] **Step 3: Implement `PrimaryButton` and `Card`**

```swift
// ADBLX/DesignSystem/Components/PrimaryButton.swift
import SwiftUI

/// The solid Privacy-Purple action button used throughout the app (Stitch
/// theme: "Primary buttons use a solid Privacy Purple fill with white text").
struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
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
    PrimaryButton(title: "Reload Safari Blockers") {}
        .padding()
}
```

```swift
// ADBLX/DesignSystem/Components/Card.swift
import SwiftUI

/// Borderless container relying on ambient shadow for definition (Stitch theme:
/// "Cards are the primary container... borderless, relying on the soft ambient
/// shadow for definition").
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
            content()
        }
        .padding(DesignSpacing.containerPadding)
        .background(DesignColors.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: DesignShape.cardCornerRadius))
        .shadow(color: .black.opacity(0.04), radius: 20, x: 0, y: 4)
    }
}

#Preview {
    Card {
        Text("Safari Protection")
        Text("Enabled")
    }
    .padding()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/PrimaryButtonTests`
Expected: PASS (1 test)

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 6: Commit**

```bash
git add ADBLX/DesignSystem/Components/ ADBLXTests/DesignSystem/ComponentsTests.swift
git commit -m "feat(ui): add PrimaryButton and Card shared components

First two entries in the shared component library, introduced because
Home needs both. Styled entirely through DesignSystem tokens (Task 1)."
```

---

## Task 4: Home Screen (View + ViewModel + `HomeService` + mock)

**Files:**
- Create: `ADBLX/Features/Home/HomeService.swift`
- Create: `ADBLX/Features/Home/HomeViewModel.swift`
- Create: `ADBLX/Features/Home/HomeView.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/Navigation/RootTabView.swift`
- Delete: `ADBLX/ContentView.swift`
- Test: `ADBLXTests/Features/Home/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `Card`, `PrimaryButton` (Task 3); `DesignColors`, `DesignTypography`, `DesignSpacing` (Task 1); `AppCompositionRoot.UIDependencies` (Task 2).
- Produces: `HomeService` (protocol), `MockHomeService` (its mock), `HomeStatus` (struct — the data `HomeService` returns), `HomeViewModel` (`@Observable`, `init(service: HomeService)`, `func load() async`, published `status: HomeStatus?` and `isLoading: Bool`), `HomeView` (`init(viewModel: HomeViewModel)`). Sprint 4B's screens follow this exact four-file shape (`<Feature>Service.swift`, `<Feature>ViewModel.swift`, `<Feature>View.swift`, plus composition-root wiring).

Content and layout below are taken from the Stitch "Home Dashboard" screen (`projects/16038318836427840964/screens/f9166e8454be4dcc83f2eb43d92555cc`): a status header, a system-status card (Safari enabled, DNS provider, last-update timestamp, rule count, block percentage), a "Reload Safari Blockers" action, and a three-item recent-activity feed.

- [ ] **Step 1: Write the failing test for `HomeViewModel`**

```swift
// ADBLXTests/Features/Home/HomeViewModelTests.swift
// ADBLXTests/Features/Home/HomeViewModelTests.swift
import Testing
@testable import ADBLX

@Suite("HomeViewModel")
struct HomeViewModelTests {
    @Test("load() populates status from the injected service")
    func loadPopulatesStatus() async {
        let expected = HomeStatus(
            isProtectionEnabled: true,
            dnsProviderName: "NextDNS",
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            blockedPercentage: 99.2,
            recentActivity: []
        )
        let viewModel = HomeViewModel(service: StubHomeService(statusToReturn: expected))

        await viewModel.load()

        #expect(viewModel.status == expected)
        #expect(viewModel.isLoading == false)
    }

    @Test("isLoading is true while load() is in flight")
    func isLoadingWhileInFlight() async {
        let service = StubHomeService(statusToReturn: HomeStatus.placeholder)
        let viewModel = HomeViewModel(service: service)

        let loadTask = Task { await viewModel.load() }
        #expect(viewModel.isLoading == true)
        await loadTask.value
        #expect(viewModel.isLoading == false)
    }
}

private struct StubHomeService: HomeService {
    let statusToReturn: HomeStatus
    func fetchStatus() async -> HomeStatus { statusToReturn }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/HomeViewModelTests`
Expected: FAIL — `HomeViewModel`, `HomeService`, `HomeStatus` do not exist.

- [ ] **Step 3: Implement `HomeService`, `HomeStatus`, and `MockHomeService`**

```swift
// ADBLX/Features/Home/HomeService.swift
import Foundation

/// One activity-feed entry shown on Home (Stitch: "Recent Activity Feed").
struct HomeActivityEntry: Equatable, Identifiable {
    enum Kind {
        case trackerBlocked
        case filtersSynchronized
        case protectionToggled
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let timestamp: String

    static func == (lhs: HomeActivityEntry, rhs: HomeActivityEntry) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.timestamp == rhs.timestamp
    }
}

/// Everything the Home screen needs to render (Stitch "Home Dashboard" screen).
struct HomeStatus: Equatable {
    let isProtectionEnabled: Bool
    let dnsProviderName: String
    let lastUpdateDescription: String
    let ruleCount: Int
    let blockedPercentage: Double
    let recentActivity: [HomeActivityEntry]

    static let placeholder = HomeStatus(
        isProtectionEnabled: true,
        dnsProviderName: "NextDNS",
        lastUpdateDescription: "just now",
        ruleCount: 0,
        blockedPercentage: 0,
        recentActivity: []
    )
}

/// What HomeView/HomeViewModel need from the backend. Never exposes
/// FilterPipeline or UpdateCoordinator directly (Sprint 4 spec §5) — a later
/// sprint's real implementation translates their state into a HomeStatus here.
protocol HomeService: Sendable {
    func fetchStatus() async -> HomeStatus
}

/// Sprint 4A/4B mock. Mirrors the Stitch "Home Dashboard" screen's sample
/// content exactly so the implemented screen visually matches the design.
struct MockHomeService: HomeService {
    func fetchStatus() async -> HomeStatus {
        HomeStatus(
            isProtectionEnabled: true,
            dnsProviderName: "NextDNS",
            lastUpdateDescription: "2m ago",
            ruleCount: 142_042,
            blockedPercentage: 99.2,
            recentActivity: [
                HomeActivityEntry(
                    kind: .trackerBlocked,
                    title: "google-analytics.com",
                    subtitle: "Tracker blocked in Safari",
                    timestamp: "14:22"
                ),
                HomeActivityEntry(
                    kind: .filtersSynchronized,
                    title: "Filters Synchronized",
                    subtitle: "Successfully updated 4 filter lists",
                    timestamp: "12:05"
                ),
                HomeActivityEntry(
                    kind: .protectionToggled,
                    title: "Protection Enabled",
                    subtitle: "Global toggle switched to ON",
                    timestamp: "09:00"
                ),
            ]
        )
    }
}
```

- [ ] **Step 4: Implement `HomeViewModel`**

```swift
// ADBLX/Features/Home/HomeViewModel.swift
import Observation

@Observable
final class HomeViewModel {
    private let service: HomeService

    var status: HomeStatus?
    var isLoading = false

    init(service: HomeService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        status = await service.fetchStatus()
        isLoading = false
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ADBLXTests/HomeViewModelTests`
Expected: PASS (2 tests)

- [ ] **Step 6: Implement `HomeView`**

```swift
// ADBLX/Features/Home/HomeView.swift
import SwiftUI

struct HomeView: View {
    @State var viewModel: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.sectionGap) {
                header

                if let status = viewModel.status {
                    statusCard(for: status)
                    PrimaryButton(title: "Reload Safari Blockers") {
                        Task { await viewModel.load() }
                    }
                    activityFeed(for: status.recentActivity)
                }
            }
            .padding(DesignSpacing.containerPadding)
        }
        .background(DesignColors.background)
        .task { await viewModel.load() }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.base) {
            Text("ADBLX")
                .font(DesignTypography.headlineLarge)
                .foregroundStyle(DesignColors.onBackground)
            Text(viewModel.status?.isProtectionEnabled == true
                 ? "System-wide protection is enabled"
                 : "Protection is off")
                .font(DesignTypography.bodyLarge)
                .foregroundStyle(DesignColors.onSurfaceVariant)
                .accessibilityLabel(viewModel.status?.isProtectionEnabled == true
                    ? "System-wide protection is enabled"
                    : "Protection is off")
        }
    }

    private func statusCard(for status: HomeStatus) -> some View {
        Card {
            statusRow(label: "Safari", value: "Enabled")
            statusRow(label: "DNS", value: status.dnsProviderName)
            statusRow(label: "Last Update", value: status.lastUpdateDescription)
            statusRow(label: "Rules", value: "\(status.ruleCount)")
            statusRow(label: "Blocked", value: "\(status.blockedPercentage, specifier: "%.1f")%")
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignTypography.bodySmall)
                .foregroundStyle(DesignColors.onSurfaceVariant)
            Spacer()
            Text(value)
                .font(DesignTypography.labelMono)
                .foregroundStyle(DesignColors.onSurface)
        }
        .accessibilityElement(children: .combine)
    }

    private func activityFeed(for entries: [HomeActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.stackGap) {
            Text("Recent Activity")
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: DesignSpacing.base / 2) {
                    Text(entry.title)
                        .font(DesignTypography.bodyLarge)
                        .foregroundStyle(DesignColors.onSurface)
                    Text("\(entry.subtitle) · \(entry.timestamp)")
                        .font(DesignTypography.bodySmall)
                        .foregroundStyle(DesignColors.onSurfaceVariant)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

#Preview {
    HomeView(viewModel: HomeViewModel(service: MockHomeService()))
}
```

- [ ] **Step 7: Wire `HomeService` into `AppCompositionRoot` and `RootTabView`**

```swift
// Modify: ADBLX/AppCompositionRoot.swift
// Replace the empty UIDependencies struct body from Task 2 with:

struct UIDependencies {
    let homeService: HomeService
}

static func makeMockUIDependencies() -> UIDependencies {
    UIDependencies(homeService: MockHomeService())
}
```

```swift
// Modify: ADBLX/Navigation/RootTabView.swift
// Replace the `placeholder(for: tab)` call for .home with a real view.
// The switch inside `placeholder(for:)` becomes:

@ViewBuilder
private func placeholder(for tab: AppTab) -> some View {
    switch tab {
    case .home:
        HomeView(viewModel: HomeViewModel(service: dependencies.homeService))
    default:
        VStack(spacing: DesignSpacing.stackGap) {
            Text(tab.title)
                .font(DesignTypography.headlineMedium)
                .foregroundStyle(DesignColors.onBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColors.background)
    }
}
```

- [ ] **Step 8: Delete the unused Xcode template file**

`ContentView.swift` has had no references since Task 2 Step 7 replaced it in `ADBLXApp.swift`. Remove it now that Home (its replacement) exists.

Run: `rm ADBLX/ContentView.swift`

- [ ] **Step 9: Build and run in the simulator to validate the Definition of Done**

Run: `xcodebuild build -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED, zero warnings.

Then in Simulator, on the Home tab, confirm:
- Layout matches the Stitch Home Dashboard screenshot: title, status line, status card (Safari/DNS/Last Update/Rules/Blocked rows), "Reload Safari Blockers" button, three-item activity feed.
- Settings → Accessibility → Larger Text: increase Dynamic Type to XXL; confirm text reflows without truncation or overlap.
- Toggle system Dark Mode: confirm the screen doesn't visually break (dark-mode-specific tokens are out of scope per Task 1, but nothing should render unreadable/invisible).
- VoiceOver (Settings → Accessibility → VoiceOver, or Accessibility Inspector): swipe through the screen; confirm the status line and each status row read as single coherent phrases (not fragmented into separate label/value swipes) and the reload button announces as a button with the label "Reload Safari Blockers".

- [ ] **Step 10: Run the full test suite to confirm no regressions**

Run: `xcodebuild test -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: PASS — zero new failures.

- [ ] **Step 11: Commit**

```bash
git add ADBLX/Features/Home/ ADBLX/AppCompositionRoot.swift ADBLX/Navigation/RootTabView.swift ADBLXTests/Features/Home/
git rm ADBLX/ContentView.swift
git commit -m "feat(ui): implement Home screen

HomeView + HomeViewModel + HomeService(protocol)/MockHomeService,
matching the Stitch 'Home Dashboard' screen. Wired into
AppCompositionRoot.UIDependencies and RootTabView, replacing the
Home tab's placeholder. Removes the now-unused Xcode template
ContentView.swift.

This establishes the View -> ViewModel -> Service(protocol) -> mock
pattern that Sprint 4B's remaining 8 screens (Safari Protection,
Advanced Filter Lists, DNS Protection, Premium, Settings, About,
Update Progress, Onboarding) will each follow."
```

---

## Self-Review Notes

- **Spec coverage:** §1 (context) → Task 1 rationale. §2 (design authority) → doc comments in Task 1/3 code citing Stitch as source. §3 (IA) → `AppTab` (Task 2) covers the four frozen tabs; Protection sub-screens and About/Onboarding/Update-Progress are explicitly Sprint 4B (not this plan's scope — flagged in the Goal statement). §4 (design system) → Task 1 fully covers color/type/spacing/shape; elevation (Card's shadow) covered in Task 3. §5 (presentation architecture) → Task 4's `HomeService`/`HomeViewModel`/`HomeView` split, plus `AppCompositionRoot.UIDependencies`. §6 (definition of done) → Task 4 Step 9 explicitly validates Dynamic Type, Dark Mode, VoiceOver, navigation. §7 (commit sequence) → Tasks 1–4 correspond to Commits 1–3 (component library seed) + first screen commit. §8 (testing) → all ViewModel tests use Swift Testing per actual codebase convention (spec said "XCTest," which doesn't match `ChecksumTests.swift`/`FilterPipelineTests.swift` — followed the real convention over the spec's inaccurate reference; flagged to user below). §9 (out of scope) — untouched, correctly deferred to Sprint 4B/later.
- **Placeholder scan:** no TBD/TODO; every step has concrete code.
- **Type consistency:** `HomeService.fetchStatus() -> HomeStatus` used identically in `MockHomeService`, `StubHomeService` (test), and `HomeViewModel.load()`. `AppCompositionRoot.UIDependencies` shape is introduced empty in Task 2 and extended (not replaced with a different shape) in Task 4. `AppTab` cases (`.home`/`.protection`/`.premium`/`.settings`) used consistently in `AppTabTests`, `RootTabView`.

**Note on the spec's §8:** the spec says ViewModels should follow "existing XCTest conventions," but the actual codebase (`ADBLXTests/Filtering/*.swift`) uses Swift Testing (`@Suite`/`@Test`/`#expect`), not XCTest. This plan follows the real codebase convention. Worth a one-line correction to the spec file itself when convenient, but not blocking.
