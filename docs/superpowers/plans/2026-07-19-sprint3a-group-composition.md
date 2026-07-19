# Sprint 3A — Group Composition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the pipeline's unit of compilation from "one filter" to "one `FilterGroup`, composed from N filters" — per `docs/superpowers/specs/2026-07-19-sprint3a-group-composition-design.md`.

**Architecture:** New `FilterSource`/`GroupComposition`/`ComposedRules` models feed a new `CompositionService` that merges multiple sources' JSON rule arrays into one before compilation. `RuleCompiler` and `RulePartitioner` drop their per-filter assumptions in favor of per-`FilterGroup`. `FilterPipeline` gains a single `install(_ composition: GroupComposition, reloadStrategy:)` entry point. `UpdatePlanner` emits one `.install(group:entries:)` action per group instead of per-filter actions, and `UpdateCoordinator` downloads/composes/installs one group at a time.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), xcodegen, xcodebuild + iOS Simulator.

## Global Constraints

- Swift Testing framework only — no XCTest (`@Suite`, `@Test`, `#expect`, `await #expect(throws:)`).
- Any type/method that must run off the `@MainActor` (this target defaults unannotated declarations to `@MainActor` via `SWIFT_DEFAULT_ACTOR_ISOLATION`) needs an explicit `nonisolated`.
- Test suites that touch the shared App Group container (`FilterStore`) must be `@Suite("...", .serialized)` — parallel runs race on the same files.
- Test command pattern (from Sprint 1/2 plans):
  `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/<SuiteName> test`
  Full suite (no `-only-testing`): same command without that flag.
- Commit after every task with tests green. Never leave the tree in a non-compiling state between tasks.
- Follow the design doc's ordering invariant: manifest order is authoritative end-to-end; nothing reorders `FilterSource`/`GroupComposition.sources`.

---

### Task 1: FilterSource and GroupComposition models

**Files:**
- Create: `ADBLX/Filtering/Models/FilterSource.swift`
- Create: `ADBLX/Filtering/Models/GroupComposition.swift`
- Test: `ADBLXTests/Filtering/FilteringModelsTests.swift` (append tests)

**Interfaces:**
- Produces: `FilterSource(filterID: String, version: String, checksumSHA256: String, data: Data)`, `GroupComposition(group: FilterGroup, sources: [FilterSource])`, both `Equatable`, `let`-only.

- [x] **Step 1: Write the failing tests**

Append to `ADBLXTests/Filtering/FilteringModelsTests.swift`, inside the `FilteringModelsTests` struct:

```swift
    @Test("FilterSource equality is field-based")
    func filterSourceEquality() {
        let a = FilterSource(filterID: "easylist", version: "2026-07-19", checksumSHA256: "abc", data: Data("[]".utf8))
        let b = FilterSource(filterID: "easylist", version: "2026-07-19", checksumSHA256: "abc", data: Data("[]".utf8))
        let c = FilterSource(filterID: "peter-lowe", version: "2026-07-19", checksumSHA256: "abc", data: Data("[]".utf8))
        #expect(a == b)
        #expect(a != c)
    }

    @Test("GroupComposition preserves source order and is not equal under reordering")
    func groupCompositionPreservesOrder() {
        let easyList = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: Data("[]".utf8))
        let peterLowe = FilterSource(filterID: "peter-lowe", version: "v1", checksumSHA256: "b", data: Data("[]".utf8))

        let ordered = GroupComposition(group: .ads, sources: [easyList, peterLowe])
        let reordered = GroupComposition(group: .ads, sources: [peterLowe, easyList])

        #expect(ordered.sources.map(\.filterID) == ["easylist", "peter-lowe"])
        #expect(ordered != reordered)
    }
```

- [x] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilteringModelsTests test`
Expected: FAIL — `cannot find 'FilterSource' in scope` / `cannot find 'GroupComposition' in scope`.

- [x] **Step 3: Create the models**

```swift
// ADBLX/Filtering/Models/FilterSource.swift
import Foundation

/// One filter's normalized source data, ready to be composed with sibling filters in the
/// same `FilterGroup` before compilation. Deliberately has no `group` field — the group
/// is a property of the `GroupComposition` this source lives inside, not of the source
/// itself, so nothing downstream can construct a composition whose sources disagree with
/// its own group.
struct FilterSource: Equatable {
    let filterID: String
    let version: String
    let checksumSHA256: String
    let data: Data
}
```

```swift
// ADBLX/Filtering/Models/GroupComposition.swift
import Foundation

/// The input to one `FilterPipeline.install(_:reloadStrategy:)` call: every filter source
/// that should compose into a single compiled `Compiled/<Group>.json`.
///
/// **Invariant:** every `FilterSource` in `sources` belongs to `group`. This is
/// established once, by `UpdatePlanner` (which only ever buckets a manifest entry into
/// the bucket matching `entry.group`) and by `FilterPipeline.installBundledSnapshotIfNeeded`
/// (which hand-builds a single-source, single-group composition). Downstream components
/// (`CompositionService`, `RuleCompiler`, `RulePartitioner`) rely on this invariant and do
/// not revalidate it.
///
/// **Ordering:** `sources` order is authoritative and preserved end-to-end — manifest
/// order in, manifest order out of `CompositionService`. Nothing reorders it.
struct GroupComposition: Equatable {
    let group: FilterGroup
    let sources: [FilterSource]
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilteringModelsTests test`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Models/FilterSource.swift ADBLX/Filtering/Models/GroupComposition.swift ADBLXTests/Filtering/FilteringModelsTests.swift
git commit -m "feat: add FilterSource and GroupComposition composition models"
```

---

### Task 2: ComposedRules model

**Files:**
- Create: `ADBLX/Filtering/Models/ComposedRules.swift`
- Test: `ADBLXTests/Filtering/FilteringModelsTests.swift` (append test)

**Interfaces:**
- Consumes: nothing new (uses existing `FilterGroup`).
- Produces: `ComposedRules(group: FilterGroup, data: Data, sourceCount: Int, ruleCount: Int)`, `Equatable`, `let`-only. `CompositionService` (Task 3) returns this.

- [x] **Step 1: Write the failing test**

Append to `FilteringModelsTests`:

```swift
    @Test("ComposedRules equality is field-based")
    func composedRulesEquality() {
        let a = ComposedRules(group: .ads, data: Data("[]".utf8), sourceCount: 2, ruleCount: 10)
        let b = ComposedRules(group: .ads, data: Data("[]".utf8), sourceCount: 2, ruleCount: 10)
        let c = ComposedRules(group: .ads, data: Data("[]".utf8), sourceCount: 2, ruleCount: 11)
        #expect(a == b)
        #expect(a != c)
    }
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilteringModelsTests test`
Expected: FAIL — `cannot find 'ComposedRules' in scope`.

- [x] **Step 3: Create the model**

```swift
// ADBLX/Filtering/Models/ComposedRules.swift
import Foundation

/// Output of `CompositionService`: every source in a `GroupComposition` merged into one
/// rule set, ready for `RuleCompiler.compile(source:group:)`. `sourceCount`/`ruleCount`
/// exist so callers can log/report composition size without re-decoding `data`.
struct ComposedRules: Equatable {
    let group: FilterGroup
    let data: Data
    let sourceCount: Int
    let ruleCount: Int
}
```

- [x] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Models/ComposedRules.swift ADBLXTests/Filtering/FilteringModelsTests.swift
git commit -m "feat: add ComposedRules model"
```

---

### Task 3: CompositionService

**Files:**
- Create: `ADBLX/Filtering/Compilation/CompositionService.swift`
- Test: Create `ADBLXTests/Filtering/CompositionServiceTests.swift`

**Interfaces:**
- Consumes: `FilterSource`, `FilterGroup`, `ComposedRules` (Tasks 1-2).
- Produces: `protocol CompositionService { nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules }`, `struct JSONArrayCompositionService: CompositionService`, `enum CompositionServiceError: Error, Equatable { case invalidSource(filterID: String) }`. `FilterPipeline` (Task 7) depends on `CompositionService`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/CompositionServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("JSONArrayCompositionService")
struct CompositionServiceTests {
    private func rule(_ urlFilter: String) -> Data {
        Data("[{\"trigger\":{\"url-filter\":\"\(urlFilter)\"},\"action\":{\"type\":\"block\"}}]".utf8)
    }

    @Test("single source composes into a ComposedRules with matching rule count")
    func singleSourceComposes() throws {
        let source = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: rule("a.*"))
        let service = JSONArrayCompositionService()

        let composed = try service.compose([source], group: .ads)

        #expect(composed.group == .ads)
        #expect(composed.sourceCount == 1)
        #expect(composed.ruleCount == 1)
        let decoded = try JSONSerialization.jsonObject(with: composed.data) as? [Any]
        #expect(decoded?.count == 1)
    }

    @Test("multiple sources merge into one array in source order")
    func multipleSourcesMergeInOrder() throws {
        let easyList = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: rule("a.*"))
        let peterLowe = FilterSource(filterID: "peter-lowe", version: "v1", checksumSHA256: "b", data: rule("b.*"))
        let service = JSONArrayCompositionService()

        let composed = try service.compose([easyList, peterLowe], group: .ads)

        #expect(composed.sourceCount == 2)
        #expect(composed.ruleCount == 2)
        let decoded = try JSONSerialization.jsonObject(with: composed.data) as? [[String: Any]]
        let firstFilter = (decoded?.first?["trigger"] as? [String: Any])?["url-filter"] as? String
        let secondFilter = (decoded?.last?["trigger"] as? [String: Any])?["url-filter"] as? String
        #expect(firstFilter == "a.*")
        #expect(secondFilter == "b.*")
    }

    @Test("composing the same ordered sources twice produces byte-identical output")
    func composingTwiceIsDeterministic() throws {
        let easyList = FilterSource(filterID: "easylist", version: "v1", checksumSHA256: "a", data: rule("a.*"))
        let peterLowe = FilterSource(filterID: "peter-lowe", version: "v1", checksumSHA256: "b", data: rule("b.*"))
        let service = JSONArrayCompositionService()

        let first = try service.compose([easyList, peterLowe], group: .ads)
        let second = try service.compose([easyList, peterLowe], group: .ads)

        #expect(first.data == second.data)
    }

    @Test("throws invalidSource naming the offending filterID when a source isn't a JSON array")
    func throwsOnInvalidSource() {
        let bad = FilterSource(filterID: "corrupt", version: "v1", checksumSHA256: "a", data: Data("not json".utf8))
        let service = JSONArrayCompositionService()

        #expect(throws: CompositionServiceError.invalidSource(filterID: "corrupt")) {
            _ = try service.compose([bad], group: .ads)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/CompositionServiceTests test`
Expected: FAIL — `cannot find 'JSONArrayCompositionService' in scope`.

- [ ] **Step 3: Implement CompositionService**

```swift
// ADBLX/Filtering/Compilation/CompositionService.swift
import Foundation

/// Merges every `FilterSource` in a `GroupComposition` into one rule set before
/// compilation. Composition happens at the JSON-array level (decode each source,
/// concatenate the decoded arrays, re-encode once) rather than raw byte concatenation,
/// because `RuleCompiler`'s current implementation assumes its input is a single valid
/// Safari content-blocker JSON array — concatenating two such arrays as raw bytes would
/// not itself be valid JSON.
///
/// Pure, no I/O, `nonisolated` — same shape as `RuleCompiler`/`RulePartitioner`.
protocol CompositionService: Sendable {
    nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules
}

enum CompositionServiceError: Error, Equatable {
    case invalidSource(filterID: String)
}

struct JSONArrayCompositionService: CompositionService {
    nonisolated func compose(_ sources: [FilterSource], group: FilterGroup) throws -> ComposedRules {
        var merged: [Any] = []
        for source in sources {
            guard let array = try? JSONSerialization.jsonObject(with: source.data) as? [Any] else {
                throw CompositionServiceError.invalidSource(filterID: source.filterID)
            }
            merged.append(contentsOf: array)
        }
        // .sortedKeys: without it, JSONSerialization does not guarantee stable key
        // ordering for the dictionaries inside `merged` across separate encode calls —
        // "same ordered input twice → byte-identical output" depends on this.
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        return ComposedRules(group: group, data: data, sourceCount: sources.count, ruleCount: merged.count)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Compilation/CompositionService.swift ADBLXTests/Filtering/CompositionServiceTests.swift
git commit -m "feat: add CompositionService merging multi-source JSON rule arrays"
```

---

### Task 4: RuleCompiler drops filterID in favor of group

**Files:**
- Modify: `ADBLX/Filtering/Compilation/RuleCompiler.swift`
- Modify: `ADBLX/Filtering/Models/CompiledRuleSet.swift`
- Modify: `ADBLX/Filtering/Pipeline/FilterPipeline.swift:57` (call site)
- Modify: `ADBLXTests/Filtering/FilteringModelsTests.swift` (`compiledRuleSetRoundTrip`)
- Modify: `ADBLXTests/Filtering/RulePartitionerTests.swift` (both `CompiledRuleSet(...)` constructions)
- Modify: `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift` (two local `AlwaysFailingCompiler` conformances)

**Interfaces:**
- Produces: `protocol RuleCompiler { nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet }`; `CompiledRuleSet.group: FilterGroup` replaces `CompiledRuleSet.sourceFilterID: String`.
- Rationale: after composition there is no single source filter to name — a synthetic id (e.g. `"ads-composition"`) would misrepresent an identity that no longer exists at this layer. Per-filter identity stays where it's correct: `InstalledFilter`.

This is a protocol-signature change, so every conformance across the whole test target must update in this same task or nothing compiles.

- [ ] **Step 1: Update the failing round-trip test first**

In `ADBLXTests/Filtering/FilteringModelsTests.swift`, replace `compiledRuleSetRoundTrip`:

```swift
    @Test("CompiledRuleSet round-trips through JSON")
    func compiledRuleSetRoundTrip() throws {
        let stats = RuleStatistics(
            compileDuration: 0.5, rulesLoaded: 3, duplicatesRemoved: 0,
            unsupportedRuleCount: 0, memoryEstimateBytes: 128,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let original = CompiledRuleSet(
            group: .ads, rawJSON: Data("[]".utf8), ruleCount: 3,
            statistics: stats
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompiledRuleSet.self, from: data)
        #expect(decoded == original)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilteringModelsTests test`
Expected: FAIL — `CompiledRuleSet` has no member `group` (build error, since `sourceFilterID` is still required).

- [ ] **Step 3: Change CompiledRuleSet**

```swift
// ADBLX/Filtering/Models/CompiledRuleSet.swift
import Foundation

/// Output of the compilation stage: raw Safari content-blocker JSON, ready to be partitioned
/// and written into the App Group container. `rawJSON` is the actual Safari rule payload —
/// treat it as opaque data here; nothing in Models/ inspects or logs its contents.
///
/// `group`, not a filter id: a `CompiledRuleSet` is the result of compiling one
/// `GroupComposition`, which may span multiple source filters — there is no single
/// "source filter" left to name once composition has happened. Per-filter identity lives
/// in `InstalledFilter`, one entry per source, not here.
struct CompiledRuleSet: Codable, Equatable {
    var group: FilterGroup
    var rawJSON: Data
    var ruleCount: Int
    var statistics: RuleStatistics
}
```

- [ ] **Step 4: Change RuleCompiler and PassthroughRuleCompiler**

```swift
// ADBLX/Filtering/Compilation/RuleCompiler.swift
import Foundation

/// Converts a normalized, composed filter source into Safari content-blocker JSON.
///
/// Sprint 1 ships `PassthroughRuleCompiler` only (bundled test JSON → copy, no real parsing).
/// The SafariConverterLib-backed implementation lands once ADR-0001 (GPL-3.0 licensing
/// decision) resolves — this protocol boundary means that swap touches nothing outside
/// Compilation/.
///
/// Target: main app ONLY — never in a Content Blocker extension (6MB memory ceiling makes
/// real compilation there a non-starter regardless of which implementation this becomes).
/// The requirement is `nonisolated` — see Task 3's (Sprint 1) note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RuleCompiler: Sendable {
    /// Compiles already-composed `source` (see `CompositionService`) into a
    /// `CompiledRuleSet` for `group`. Must run off the main actor for any non-trivial
    /// input size.
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet
}

enum RuleCompilerError: Error {
    case invalidSource
}

/// Sprint 1 stub: treats `source` as already-valid Safari JSON and passes it through,
/// generating count-only statistics. Does NOT exercise NFR-01 (compile time / memory budget)
/// — there is no real compilation work happening yet. Do not report this implementation's
/// timings as NFR-01 verification.
struct PassthroughRuleCompiler: RuleCompiler {
    nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        guard !source.isEmpty else {
            throw RuleCompilerError.invalidSource
        }
        let start = Date()

        guard (try? JSONSerialization.jsonObject(with: source)) != nil else {
            throw RuleCompilerError.invalidSource
        }

        let ruleCount = try? estimateRuleCount(from: source)
        let duration = Date().timeIntervalSince(start)

        let stats = RuleStatistics(
            compileDuration: duration,
            rulesLoaded: ruleCount ?? 0,
            duplicatesRemoved: 0,
            unsupportedRuleCount: 0,
            memoryEstimateBytes: source.count,
            lastUpdated: Date()
        )

        return CompiledRuleSet(
            group: group,
            rawJSON: source,
            ruleCount: ruleCount ?? 0,
            statistics: stats
        )
    }

    private func estimateRuleCount(from data: Data) throws -> Int {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            return 0
        }
        return array.count
    }
}
```

- [ ] **Step 5: Fix the FilterPipeline call site**

In `ADBLX/Filtering/Pipeline/FilterPipeline.swift`, inside `install(filterID:source:version:reloadStrategy:)`, change:

```swift
        let compiled = try await compiler.compile(source: source, filterID: filterID)
```

to:

```swift
        let compiled = try await compiler.compile(source: source, group: .ads)
```

(This method is still Sprint 1/2's single-filter, `.ads`-only entry point at this point in the plan — it becomes group-aware in Task 8.)

- [ ] **Step 6: Fix RulePartitionerTests's two CompiledRuleSet constructions**

In `ADBLXTests/Filtering/RulePartitionerTests.swift`, in both `partitionsWithinBudget` and `throwsWhenOverBudget`, change:

```swift
        let ruleSet = CompiledRuleSet(
            sourceFilterID: "ads-bundled",
```

to:

```swift
        let ruleSet = CompiledRuleSet(
            group: .ads,
```

(Two occurrences, one per test — leave everything else in that struct literal unchanged.)

- [ ] **Step 7: Fix UpdateCoordinatorTests's two AlwaysFailingCompiler conformances**

In `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift`, both local `struct AlwaysFailingCompiler: RuleCompiler` definitions (in `installFailureRollsBackWithOneReload` and `restoreFailureDuringRollbackSurfacesRollbackFailed`) currently read:

```swift
        struct AlwaysFailingCompiler: RuleCompiler {
            nonisolated func compile(source: Data, filterID: String) async throws -> CompiledRuleSet {
                throw RuleCompilerError.invalidSource
            }
        }
```

Change both occurrences to:

```swift
        struct AlwaysFailingCompiler: RuleCompiler {
            nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
                throw RuleCompilerError.invalidSource
            }
        }
```

- [ ] **Step 8: Run the full test target to verify everything compiles and passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: PASS (all suites — this is a protocol change, confirm nothing else references the old signature).

- [ ] **Step 9: Commit**

```bash
git add ADBLX/Filtering/Compilation/RuleCompiler.swift ADBLX/Filtering/Models/CompiledRuleSet.swift ADBLX/Filtering/Pipeline/FilterPipeline.swift ADBLXTests/Filtering/FilteringModelsTests.swift ADBLXTests/Filtering/RulePartitionerTests.swift ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
git commit -m "refactor: RuleCompiler compiles composed rules for a group, not a single filterID"
```

---

### Task 5: GroupPartitioner replaces PassthroughAdsPartitioner

**Files:**
- Modify: `ADBLX/Filtering/Deployment/RulePartitioner.swift`
- Modify: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLXTests/Filtering/RulePartitionerTests.swift` (full rewrite)

**Interfaces:**
- Produces: `struct GroupExtensionIdentifiers { let ads, privacy, annoyances, regional: String; subscript(_ group: FilterGroup) -> String }`; `protocol RulePartitioner { nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules }` (singular return, not `[PartitionedRules]` — a `CompiledRuleSet` now corresponds to exactly one group by construction); `struct GroupPartitioner: RulePartitioner`.
- `GroupExtensionIdentifiers` has no optional/dictionary lookup: every group maps to a non-optional `String` field, and its `subscript` is an exhaustive `switch` over `FilterGroup` — an unmapped group is a compile error, not a runtime case.

- [ ] **Step 1: Write the failing tests (full replacement)**

```swift
// ADBLXTests/Filtering/RulePartitionerTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("GroupPartitioner")
struct GroupPartitionerTests {
    private let identifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func ruleSet(group: FilterGroup, ruleCount: Int) -> CompiledRuleSet {
        CompiledRuleSet(
            group: group,
            rawJSON: Data("[]".utf8),
            ruleCount: ruleCount,
            statistics: RuleStatistics(
                compileDuration: 0.01, rulesLoaded: ruleCount, duplicatesRemoved: 0,
                unsupportedRuleCount: 0, memoryEstimateBytes: 2048, lastUpdated: Date()
            )
        )
    }

    @Test("routes .ads to the Ads extension identifier")
    func routesAds() async throws {
        let partitioner = GroupPartitioner(extensionIdentifiers: identifiers)
        let partition = try await partitioner.partition(ruleSet(group: .ads, ruleCount: 70), group: .ads)

        #expect(partition.group == .ads)
        #expect(partition.extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")
        #expect(partition.ruleCount == 70)
    }

    @Test("routes each of the four groups to its own extension identifier", arguments: [
        (FilterGroup.ads, "com.ADBLX.ADBLX.AdsBlocker"),
        (FilterGroup.privacy, "com.ADBLX.ADBLX.PrivacyBlocker"),
        (FilterGroup.annoyances, "com.ADBLX.ADBLX.AnnoyancesBlocker"),
        (FilterGroup.regional, "com.ADBLX.ADBLX.RegionalBlocker"),
    ])
    func routesEveryGroup(group: FilterGroup, expectedIdentifier: String) async throws {
        let partitioner = GroupPartitioner(extensionIdentifiers: identifiers)
        let partition = try await partitioner.partition(ruleSet(group: group, ruleCount: 10), group: group)

        #expect(partition.extensionIdentifier == expectedIdentifier)
    }

    @Test("throws when rule count exceeds the per-extension budget")
    func throwsWhenOverBudget() async {
        let partitioner = GroupPartitioner(extensionIdentifiers: identifiers)
        await #expect(throws: RulePartitionerError.self) {
            _ = try await partitioner.partition(ruleSet(group: .ads, ruleCount: 150_001), group: .ads)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/GroupPartitionerTests test`
Expected: FAIL — `cannot find 'GroupExtensionIdentifiers' in scope` / `cannot find 'GroupPartitioner' in scope`.

- [ ] **Step 3: Implement GroupPartitioner (full replacement)**

```swift
// ADBLX/Filtering/Deployment/RulePartitioner.swift
import Foundation

/// Total mapping from `FilterGroup` to its Content Blocker extension's bundle identifier.
/// Every field is required and non-optional, and `subscript` is an exhaustive `switch` —
/// an unmapped group is a compile-time impossibility (a new `FilterGroup` case would fail
/// to compile here until handled), not a runtime `.unmappedGroup`-style error case.
struct GroupExtensionIdentifiers: Sendable {
    let ads: String
    let privacy: String
    let annoyances: String
    let regional: String

    subscript(_ group: FilterGroup) -> String {
        switch group {
        case .ads: return ads
        case .privacy: return privacy
        case .annoyances: return annoyances
        case .regional: return regional
        }
    }
}

/// Wraps one group's compiled rules for writing, plus which extension they belong to.
///
/// Target: main app ONLY. The requirement is `nonisolated` — see Task 3's (Sprint 1) note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RulePartitioner: Sendable {
    /// A `CompiledRuleSet` corresponds to exactly one group by construction (it came from
    /// one `GroupComposition`), so this returns a single `PartitionedRules`, not an array.
    nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules
}

struct PartitionedRules {
    var extensionIdentifier: String
    var group: FilterGroup
    var json: Data
    var ruleCount: Int
}

enum RulePartitionerError: Error {
    case ruleBudgetExceeded(group: FilterGroup, count: Int, limit: Int)
}

struct GroupPartitioner: RulePartitioner {
    /// Per PRD §6.1 / Appendix B.1 — 150K compiled rules per extension.
    static let ruleBudgetPerExtension = 150_000

    let extensionIdentifiers: GroupExtensionIdentifiers

    nonisolated func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules {
        guard ruleSet.ruleCount <= Self.ruleBudgetPerExtension else {
            throw RulePartitionerError.ruleBudgetExceeded(
                group: group,
                count: ruleSet.ruleCount,
                limit: Self.ruleBudgetPerExtension
            )
        }
        return PartitionedRules(
            extensionIdentifier: extensionIdentifiers[group],
            group: group,
            json: ruleSet.rawJSON,
            ruleCount: ruleSet.ruleCount
        )
    }
}
```

- [ ] **Step 4: Update AppCompositionRoot's mapping**

```swift
// ADBLX/AppCompositionRoot.swift
import Foundation

/// The single place that constructs a FilterPipeline with its real, concrete dependencies.
/// FilterPipeline itself never constructs its own dependencies — everything is injected —
/// so swapping PassthroughRuleCompiler for a SafariConverterLib-backed implementation (post
/// ADR-0001) only ever changes this file.
enum AppCompositionRoot {
    static let extensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    static func makeFilterPipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            partitioner: GroupPartitioner(extensionIdentifiers: extensionIdentifiers),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }
}
```

Note: `FilterPipeline.init` still doesn't take a `compositionService:` parameter yet — that's Task 7. This step only swaps the `partitioner:` argument's type.

- [ ] **Step 5: Run the GroupPartitionerTests suite to verify it passes**

Run: same command as Step 2.
Expected: PASS. (The rest of the target will not yet compile — `FilterPipeline.swift`, `FilterPipelineTests.swift`, and `UpdateCoordinatorTests.swift` still construct `PassthroughAdsPartitioner`, which no longer exists. That's fixed in Task 6, immediately next — don't run the full suite yet.)

- [ ] **Step 6: Commit**

```bash
git add ADBLX/Filtering/Deployment/RulePartitioner.swift ADBLX/AppCompositionRoot.swift ADBLXTests/Filtering/RulePartitionerTests.swift
git commit -m "refactor: GroupPartitioner replaces PassthroughAdsPartitioner with a total FilterGroup mapping"
```

---

### Task 6: Wire GroupPartitioner through FilterPipeline and remaining tests

**Files:**
- Modify: `ADBLX/Filtering/Pipeline/FilterPipeline.swift` (partition call site)
- Modify: `ADBLXTests/Filtering/FilterPipelineTests.swift` (`makePipeline()`)
- Modify: `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift` (all `FilterPipeline(...)` constructions)

**Interfaces:**
- Consumes: `GroupPartitioner`, `GroupExtensionIdentifiers` (Task 5).
- No new interfaces produced — this task only fixes compilation left over from Task 5's protocol change.

- [ ] **Step 1: Fix FilterPipeline's partition call site**

In `ADBLX/Filtering/Pipeline/FilterPipeline.swift`, inside `install(filterID:source:version:reloadStrategy:)`, replace:

```swift
        let partitions = try await partitioner.partition(compiled)

        var installedRuleCount = 0
        var extensionIdentifiers: [String] = []
        for partition in partitions {
            let destinationURL = try await store.directoryURL(.compiled)
                .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
            try writer.write(partition.json, to: destinationURL)
            installedRuleCount += partition.ruleCount
            extensionIdentifiers.append(partition.extensionIdentifier)
        }
```

with:

```swift
        let partition = try await partitioner.partition(compiled, group: .ads)

        let destinationURL = try await store.directoryURL(.compiled)
            .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
        try writer.write(partition.json, to: destinationURL)
        let installedRuleCount = partition.ruleCount
        let extensionIdentifiers = [partition.extensionIdentifier]
```

(Everything below this in the method already references `installedRuleCount: Int` and `extensionIdentifiers: [String]` — both names and types are unchanged, so the rest of the method body needs no edits.)

- [ ] **Step 2: Add a shared GroupExtensionIdentifiers constant to FilterPipelineTests and fix makePipeline()**

In `ADBLXTests/Filtering/FilterPipelineTests.swift`, add a suite-level constant and update `makePipeline()`:

```swift
@Suite("FilterPipeline", .serialized)
struct FilterPipelineTests {
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    private func makePipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }
```

(Only the struct header and `makePipeline()` change; every `@Test` method below stays as-is for this task.)

- [ ] **Step 3: Add the same constant to UpdateCoordinatorTests and fix every FilterPipeline(...) construction**

In `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift`, add alongside the existing `adsExtensionIdentifier` constant:

```swift
    private let groupExtensionIdentifiers = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker",
        privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker",
        regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
```

Then, in every one of the six `FilterPipeline(...)` constructions in this file (one per `@Test` method), replace:

```swift
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
```

with:

```swift
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
```

- [ ] **Step 4: Run the full test target to verify everything compiles and passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: PASS (all suites).

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Pipeline/FilterPipeline.swift ADBLXTests/Filtering/FilterPipelineTests.swift ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
git commit -m "refactor: wire GroupPartitioner through FilterPipeline and test constructions"
```

---

### Task 7: FilterPipeline gains install(_ composition:reloadStrategy:)

**Files:**
- Modify: `ADBLX/Filtering/Pipeline/FilterPipeline.swift` (full replacement)
- Modify: `ADBLX/AppCompositionRoot.swift` (pass `compositionService:`)
- Modify: `ADBLX/ContentBlockerBootstrap.swift` (log line — `PipelineResult.filterID` → `.group`)
- Modify: `ADBLXTests/Filtering/FilterPipelineTests.swift` (`makePipeline()` + one assertion + new tests)
- Modify: `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift` (all six `FilterPipeline(...)` constructions)

**Interfaces:**
- Consumes: `GroupComposition`, `CompositionService`, `JSONArrayCompositionService` (Tasks 1, 3).
- Produces: `FilterPipeline.install(_ composition: GroupComposition, reloadStrategy: ReloadStrategy = .immediate) async throws -> PipelineResult`. `PipelineResult.filterID: String` is replaced with `PipelineResult.group: FilterGroup` (a multi-source install has no single filter identity to report — see Task 4's rationale for `CompiledRuleSet`). `FilterPipeline.install(filterID:source:version:reloadStrategy:)` becomes a **transitional** adapter, kept only so `UpdateCoordinator` keeps compiling until Task 10 migrates it; it is deleted in Task 11.

- [ ] **Step 1: Write the failing tests first**

In `ADBLXTests/Filtering/FilterPipelineTests.swift`, update `makePipeline()` to inject a `compositionService:` and fix the one existing assertion that reads `result.filterID`:

```swift
    private func makePipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }
```

In `installsBundledSnapshotEndToEnd`, change:

```swift
        #expect(result.filterID == "ads-bundled")
```

to:

```swift
        #expect(result.group == .ads)
```

Then append two new tests to the same suite:

```swift
    @Test("install(composition:) composes multiple sources into one Compiled/Ads.json write and two metadata entries")
    func installComposesMultipleSourcesIntoOneWrite() async throws {
        let pipeline = makePipeline()
        let easyList = FilterSource(
            filterID: "easylist", version: "2026-07-19", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\"a.*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let peterLowe = FilterSource(
            filterID: "peter-lowe", version: "2026-07-19", checksumSHA256: "b",
            data: Data("[{\"trigger\":{\"url-filter\":\"b.*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [easyList, peterLowe])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.group == .ads)
        #expect(result.compiledRuleCount == 2)
        #expect(result.installedRuleCount == 2)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let writtenData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let writtenRules = try JSONSerialization.jsonObject(with: writtenData) as? [Any]
        #expect(writtenRules?.count == 2)

        let metadataDir = try await store.directoryURL(.metadata)
        let metadataData = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: metadataData)
        #expect(Set(filters.map(\.id)).isSuperset(of: ["easylist", "peter-lowe"]))
    }

    @Test("install(composition:) reload .deferred returns empty reloadResults")
    func installCompositionDeferredReloadSkipsReloadCall() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "deferred-test", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.reloadResults.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterPipelineTests test`
Expected: FAIL — `incorrect argument label` / `install(_:reloadStrategy:)` not found / `PipelineResult` has no member `group`.

- [ ] **Step 3: Implement the new install method (full replacement)**

```swift
// ADBLX/Filtering/Pipeline/FilterPipeline.swift
import Foundation

/// Sole orchestrator of the rule pipeline: validate → compose → compile → partition →
/// atomic write → persist metadata → reload. Every other Filtering/ type stays
/// single-purpose; this is the one place that knows the sequence, owns timing, and will
/// own progress/cancellation/retry as those needs arrive.
///
/// Target: main app ONLY.
actor FilterPipeline {
    private let validator: FilterValidator
    private let compiler: RuleCompiler
    private let compositionService: CompositionService
    private let partitioner: RulePartitioner
    private let store: FilterStore
    private let writer: AtomicRuleWriter
    private let reloader: ReloadCoordinator

    init(
        validator: FilterValidator,
        compiler: RuleCompiler,
        compositionService: CompositionService,
        partitioner: RulePartitioner,
        store: FilterStore,
        writer: AtomicRuleWriter,
        reloader: ReloadCoordinator
    ) {
        self.validator = validator
        self.compiler = compiler
        self.compositionService = compositionService
        self.partitioner = partitioner
        self.store = store
        self.writer = writer
        self.reloader = reloader
    }

    /// Installs an entire group's composition in one pass: validate every source, compose
    /// them into one rule set, compile once, partition once, write `Compiled/<Group>.json`
    /// once, merge every source into `installed_filters.json`, then reload per
    /// `reloadStrategy`. This is the pipeline's single entry point — see the Sprint 3A
    /// design doc for why Sprint 1/2's one-filter-at-a-time `install` was replaced by this.
    func install(
        _ composition: GroupComposition,
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        for source in composition.sources {
            try validator.validate(source.data)
        }

        let composed = try compositionService.compose(composition.sources, group: composition.group)
        let compiled = try await compiler.compile(source: composed.data, group: composition.group)
        let partition = try await partitioner.partition(compiled, group: composition.group)

        let destinationURL = try await store.directoryURL(.compiled)
            .appendingPathComponent("\(partition.group.rawValue.capitalized).json")
        try writer.write(partition.json, to: destinationURL)

        var existingFilters = (try? await loadInstalledFilters()) ?? []
        for source in composition.sources {
            let installedFilter = InstalledFilter(
                id: source.filterID,
                group: composition.group,
                installedVersion: source.version,
                checksumSHA256: source.checksumSHA256,
                lastUpdated: compiled.statistics.lastUpdated,
                ruleCount: compiled.ruleCount
            )
            existingFilters.removeAll { $0.id == source.filterID }
            existingFilters.append(installedFilter)
        }
        let installedFiltersData = try JSONEncoder().encode(existingFilters)
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadResults: [ReloadCoordinator.ReloadResult]
        if reloadStrategy == .immediate {
            reloadResults = await reloader.reload(extensionIdentifiers: [partition.extensionIdentifier])
        } else {
            reloadResults = []
        }

        return PipelineResult(
            group: composition.group,
            compiledRuleCount: compiled.ruleCount,
            installedRuleCount: partition.ruleCount,
            compileStatistics: compiled.statistics,
            reloadResults: reloadResults
        )
    }

    /// TRANSITIONAL — Sprint 1/2's single-filter entry point. Kept only so
    /// `UpdateCoordinator` keeps compiling until it migrates onto
    /// `install(_:reloadStrategy:)` directly (Sprint 3A Task 10). Delegates to the new
    /// method with a one-source, `.ads` `GroupComposition` — deleted in Task 11 once
    /// `UpdateCoordinator` no longer calls it.
    func install(
        filterID: String,
        source: Data,
        version: String = "bundled-snapshot",
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(
                filterID: filterID,
                version: version,
                checksumSHA256: Checksum.sha256Hex(of: source),
                data: source
            )]
        )
        return try await install(composition, reloadStrategy: reloadStrategy)
    }

    /// Sprint 1: always (re)installs from the bundled snapshot on every call — "IfNeeded"
    /// becomes meaningful once Part 10 adds version comparison against a fetched manifest.
    /// Reinstalling identical content on every launch is harmless (same bytes, same reload).
    func installBundledSnapshotIfNeeded() async throws -> PipelineResult {
        guard let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
            throw FilterPipelineError.bundledSnapshotMissing
        }
        let data = try Data(contentsOf: bundledURL)
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(
                filterID: "ads-bundled",
                version: "bundled-snapshot",
                checksumSHA256: Checksum.sha256Hex(of: data),
                data: data
            )]
        )
        return try await install(composition)
    }

    private func loadInstalledFilters() async throws -> [InstalledFilter] {
        let data = try await store.read("installed_filters.json", in: .metadata)
        return try JSONDecoder().decode([InstalledFilter].self, from: data)
    }
}

enum ReloadStrategy {
    case immediate
    case deferred
}

struct PipelineResult {
    var group: FilterGroup
    var compiledRuleCount: Int
    var installedRuleCount: Int
    var compileStatistics: RuleStatistics
    var reloadResults: [ReloadCoordinator.ReloadResult]
}

enum FilterPipelineError: Error {
    case bundledSnapshotMissing
}
```

- [ ] **Step 4: Fix ContentBlockerBootstrap's log line**

In `ADBLX/ContentBlockerBootstrap.swift`, change:

```swift
            logger.info("Filter pipeline installed \(result.installedRuleCount) rule(s) for \(result.filterID, privacy: .public)")
```

to:

```swift
            logger.info("Filter pipeline installed \(result.installedRuleCount) rule(s) for \(result.group.rawValue, privacy: .public)")
```

- [ ] **Step 5: Add compositionService to AppCompositionRoot**

In `ADBLX/AppCompositionRoot.swift`, in `makeFilterPipeline()`, add the new argument:

```swift
    static func makeFilterPipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: extensionIdentifiers),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }
```

- [ ] **Step 6: Add compositionService to every UpdateCoordinatorTests FilterPipeline(...) construction**

In `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift`, in all six `FilterPipeline(...)` constructions, add `compositionService: JSONArrayCompositionService(),` immediately after `compiler: ...,` (or `compiler: AlwaysFailingCompiler(),` where that local type is used) and before `partitioner:`. For example, the coordinator-under-test in `notModifiedShortCircuits` changes from:

```swift
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
```

to:

```swift
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
```

Apply the same one-line insertion to the other five constructions in this file (the `AlwaysFailingCompiler` ones included).

- [ ] **Step 7: Run the full test target to verify everything compiles and passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: PASS (all suites).

- [ ] **Step 8: Commit**

```bash
git add ADBLX/Filtering/Pipeline/FilterPipeline.swift ADBLX/AppCompositionRoot.swift ADBLX/ContentBlockerBootstrap.swift ADBLXTests/Filtering/FilterPipelineTests.swift ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
git commit -m "feat: FilterPipeline.install(_ composition:reloadStrategy:) — one write per group"
```

---

### Task 8: installBundledSnapshotIfNeeded already migrated — confirm and lock in

Task 7's full replacement already migrated `installBundledSnapshotIfNeeded()` to build a `GroupComposition` and call the new method (there is no separate "old path" left for it — it never went through the transitional `install(filterID:source:...)` adapter). This task exists to make that explicit and verify it end-to-end, since Task 7's step 3 changed it silently as part of the full-file replacement.

**Files:**
- Verify only: `ADBLX/Filtering/Pipeline/FilterPipeline.swift` (`installBundledSnapshotIfNeeded`, already updated)
- Test: `ADBLXTests/Filtering/FilterPipelineTests.swift` (`installsBundledSnapshotEndToEnd`, already updated in Task 7)

- [ ] **Step 1: Re-run the existing bundled-snapshot test to confirm it exercises the composition path**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterPipelineTests/installsBundledSnapshotEndToEnd test`
Expected: PASS — this test's assertions (`result.group == .ads`, `Compiled/Ads.json` exists with 70 rules, `installed_filters.json`/`statistics.json` exist) already prove `installBundledSnapshotIfNeeded` goes through `install(_ composition:)`, since that's the only method in `FilterPipeline` that writes `Compiled/Ads.json`.

- [ ] **Step 2: Read `installBundledSnapshotIfNeeded` and confirm no residual call to the transitional adapter**

```bash
grep -n "func installBundledSnapshotIfNeeded" -A 12 /Users/sreeharshag/Work/ADBLX/ADBLX/Filtering/Pipeline/FilterPipeline.swift
```

Expected output: the method builds a `GroupComposition` and calls `install(composition)` — not `install(filterID:source:...)`.

- [ ] **Step 3: Commit (no-op if Task 7 already committed this — skip if `git status` is clean)**

```bash
git status --short
```

If clean, there is nothing to commit for this task — proceed to Task 9. This step exists so a reviewer can gate Task 8 independently of Task 7 even though no new diff lands here.

---

### Task 9: UpdatePlanner emits one .install(group:entries:) per group

**Files:**
- Modify: `ADBLX/Filtering/Updates/UpdatePlan.swift`
- Modify: `ADBLXTests/Filtering/Updates/UpdatePlannerTests.swift` (full rewrite)
- Modify: `ADBLX/Filtering/Updates/UpdateCoordinator.swift` (one call site, temporary compile bridge — fully replaced in Task 10)

**Interfaces:**
- Produces: `enum UpdateAction { case install(group: FilterGroup, entries: [FilterManifest.Entry]); case remove(filterID: String); case keep(filterID: String); case skipPremium(FilterManifest.Entry) }` — `.unsupportedGroup` and `.groupConflict` are gone. `UpdateCoordinator` (Task 10) consumes `.install(group:entries:)`.
- Ordering: entries destined for `.install` are grouped by `FilterGroup` (first-encountered-group order for the groups themselves; manifest order preserved within each group's `entries` array) — grouping is by key, not manifest adjacency.

- [ ] **Step 1: Write the failing tests (full replacement)**

```swift
// ADBLXTests/Filtering/Updates/UpdatePlannerTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("UpdatePlanner")
struct UpdatePlannerTests {
    private func entry(
        id: String, group: FilterGroup = .ads, version: String = "2026-07-18",
        checksum: String = "checksum-a", premium: Bool = false
    ) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: id, name: id, group: group,
            sourceURL: URL(string: "https://example.com/\(id).txt")!,
            version: version, checksumSHA256: checksum, ruleCount: 10,
            enabledByDefault: true, premium: premium
        )
    }

    private func installed(
        id: String, group: FilterGroup = .ads, version: String = "2026-07-18",
        checksum: String = "checksum-a"
    ) -> InstalledFilter {
        InstalledFilter(
            id: id, group: group, installedVersion: version, checksumSHA256: checksum,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000), ruleCount: 10
        )
    }

    @Test("new manifest entry with no installed counterpart produces .install for its group")
    func newEntryProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.install(group: .ads, entries: [entry(id: "easylist")])])
    }

    @Test("unchanged installed entry produces .keep")
    func unchangedEntryProducesKeep() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist")])
        #expect(plan.actions == [.keep(filterID: "easylist")])
    }

    @Test("changed version on an installed entry produces .install")
    func changedVersionProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist", version: "2026-07-19")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist", version: "2026-07-18")])
        #expect(plan.actions == [.install(group: .ads, entries: [entry(id: "easylist", version: "2026-07-19")])])
    }

    @Test("changed checksum on an installed entry produces .install")
    func changedChecksumProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist", checksum: "checksum-b")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist", checksum: "checksum-a")])
        #expect(plan.actions == [.install(group: .ads, entries: [entry(id: "easylist", checksum: "checksum-b")])])
    }

    @Test("installed filter absent from the manifest produces .remove")
    func removedFromManifestProducesRemove() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "fanboy")])
        #expect(plan.actions == [.remove(filterID: "fanboy")])
    }

    @Test("never-installed premium entry produces .skipPremium, not .keep")
    func neverInstalledPremiumProducesSkipPremium() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "premium-list", premium: true)])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.skipPremium(entry(id: "premium-list", premium: true))])
    }

    @Test("already-installed premium entry with a version change still produces .install")
    func installedPremiumEntryStillUpdates() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "premium-list", version: "v2", premium: true)])
        let plan = UpdatePlanner.plan(
            manifest: manifest,
            installed: [installed(id: "premium-list", version: "v1")]
        )
        #expect(plan.actions == [.install(group: .ads, entries: [entry(id: "premium-list", version: "v2", premium: true)])])
    }

    @Test("non-.ads group entry produces .install for its own group, not .unsupportedGroup")
    func nonAdsGroupProducesInstallForItsGroup() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easyprivacy", group: .privacy)])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.install(group: .privacy, entries: [entry(id: "easyprivacy", group: .privacy)])])
    }

    @Test("two .ads entries needing install in the same plan produce one .install carrying both, in manifest order")
    func twoAdsInstallsProduceOneGroupedAction() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            entry(id: "easylist"),
            entry(id: "peter-lowe", checksum: "checksum-c"),
        ])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [
            .install(group: .ads, entries: [
                entry(id: "easylist"),
                entry(id: "peter-lowe", checksum: "checksum-c"),
            ]),
        ])
    }

    @Test("entries across all four groups produce one .install action per group, in first-encountered order")
    func entriesAcrossAllGroupsProduceOneActionPerGroup() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            entry(id: "easylist", group: .ads),
            entry(id: "easyprivacy", group: .privacy),
            entry(id: "fanboy-annoyances", group: .annoyances),
            entry(id: "regional-fr", group: .regional),
        ])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [
            .install(group: .ads, entries: [entry(id: "easylist", group: .ads)]),
            .install(group: .privacy, entries: [entry(id: "easyprivacy", group: .privacy)]),
            .install(group: .annoyances, entries: [entry(id: "fanboy-annoyances", group: .annoyances)]),
            .install(group: .regional, entries: [entry(id: "regional-fr", group: .regional)]),
        ])
    }

    @Test("grouping is by FilterGroup key, not manifest adjacency — interleaved entries for the same group still merge into one action")
    func interleavedEntriesForSameGroupStillMerge() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            entry(id: "easylist", group: .ads),
            entry(id: "easyprivacy", group: .privacy),
            entry(id: "peter-lowe", group: .ads, checksum: "checksum-c"),
        ])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [
            .install(group: .ads, entries: [
                entry(id: "easylist", group: .ads),
                entry(id: "peter-lowe", group: .ads, checksum: "checksum-c"),
            ]),
            .install(group: .privacy, entries: [entry(id: "easyprivacy", group: .privacy)]),
        ])
    }

    @Test("empty manifest and empty installed list produces an empty plan")
    func emptyInputsProduceEmptyPlan() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/UpdatePlannerTests test`
Expected: FAIL — `type 'UpdateAction' has no member 'install' with matching labels` (still the old per-entry `.install(FilterManifest.Entry)` case) / `.unsupportedGroup` and `.groupConflict` tests will not compile since those cases still exist and the new tests reference the new shape.

- [ ] **Step 3: Rewrite UpdatePlan.swift**

```swift
// ADBLX/Filtering/Updates/UpdatePlan.swift
import Foundation

/// One outcome of diffing a fetched `FilterManifest` against the currently
/// `InstalledFilter`s. Pure data — `UpdateCoordinator` decides what to actually do with
/// each case; this type only describes what's true about each manifest entry (or, for
/// `.install`, each group of entries).
enum UpdateAction: Equatable {
    /// One or more entries in the same `FilterGroup` that are new, or whose
    /// version/checksum changed relative to what's installed. Grouped so
    /// `UpdateCoordinator` composes and installs them in a single `FilterPipeline` call —
    /// see the Sprint 3A design doc for why per-filter `.install` was replaced by this.
    case install(group: FilterGroup, entries: [FilterManifest.Entry])
    /// Installed filter no longer present in the manifest.
    case remove(filterID: String)
    /// Installed, unchanged, still entitled — no action needed.
    case keep(filterID: String)
    /// Not installed, gated behind a purchase that doesn't exist yet (no StoreKit this sprint).
    case skipPremium(FilterManifest.Entry)
}

struct UpdatePlan: Equatable {
    var actions: [UpdateAction]
}

/// Pure diff: no I/O, no async. Compares each manifest entry against the matching
/// `InstalledFilter` (by `id`) on `(version, checksumSHA256)`, then buckets every entry
/// that needs installing by `FilterGroup` — grouping is by key, not manifest adjacency,
/// so entries for the same group don't need to be consecutive in the manifest.
enum UpdatePlanner {
    static func plan(manifest: FilterManifest, installed: [InstalledFilter]) -> UpdatePlan {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var manifestIDs = Set<String>()
        var actions: [UpdateAction] = []
        var installsByGroup: [FilterGroup: [FilterManifest.Entry]] = [:]
        var groupOrder: [FilterGroup] = []

        for entry in manifest.entries {
            manifestIDs.insert(entry.id)

            if let existing = installedByID[entry.id] {
                if existing.installedVersion == entry.version && existing.checksumSHA256 == entry.checksumSHA256 {
                    actions.append(.keep(filterID: entry.id))
                    continue
                }
                // else: version/checksum changed — falls through to grouping below.
            } else if entry.premium {
                actions.append(.skipPremium(entry))
                continue
            }
            // else: new, non-premium entry — falls through to grouping below.

            if installsByGroup[entry.group] == nil {
                groupOrder.append(entry.group)
            }
            installsByGroup[entry.group, default: []].append(entry)
        }

        for group in groupOrder {
            actions.append(.install(group: group, entries: installsByGroup[group] ?? []))
        }

        for filter in installed where !manifestIDs.contains(filter.id) {
            actions.append(.remove(filterID: filter.id))
        }

        return UpdatePlan(actions: actions)
    }
}
```

- [ ] **Step 4: Patch UpdateCoordinator's call site so the target still compiles**

`UpdateAction.install` just changed shape from `install(FilterManifest.Entry)` to
`install(group: FilterGroup, entries: [FilterManifest.Entry])`. `UpdateCoordinator.swift`
isn't rewritten until Task 10, but it still pattern-matches the *old* shape — and
`xcodebuild test` builds the whole target before running any test, so leaving this
unpatched would make even a `-only-testing:ADBLXTests/UpdatePlannerTests` run fail at
the build step, not the test step. This is a temporary bridge only — Task 10 replaces
this entire block with the real grouped-install loop.

In `ADBLX/Filtering/Updates/UpdateCoordinator.swift`, inside `run()`, change:

```swift
        let installs: [FilterManifest.Entry] = plan.actions.compactMap {
            if case .install(let entry) = $0 { return entry }
            return nil
        }
```

to:

```swift
        // TEMPORARY bridge for the new grouped .install(group:entries:) shape —
        // Task 10 replaces this whole block with per-group download/compose/install.
        let installs: [FilterManifest.Entry] = plan.actions.compactMap { action -> [FilterManifest.Entry]? in
            if case .install(_, let entries) = action { return entries }
            return nil
        }.flatMap { $0 }
```

- [ ] **Step 5: Run the full test target to verify everything compiles and passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: PASS (all suites) — this confirms both the new `UpdatePlannerTests` and the still-`.ads`-only `UpdateCoordinatorTests` (unchanged in this task, still passing against the temporary bridge) are green together.

- [ ] **Step 6: Commit**

```bash
git add ADBLX/Filtering/Updates/UpdatePlan.swift ADBLXTests/Filtering/Updates/UpdatePlannerTests.swift ADBLX/Filtering/Updates/UpdateCoordinator.swift
git commit -m "refactor: UpdatePlanner emits one .install(group:entries:) per group; remove .unsupportedGroup and .groupConflict"
```

---

### Task 10: UpdateCoordinator installs one GroupComposition per group

**Files:**
- Modify: `ADBLX/Filtering/Updates/UpdateCoordinator.swift` (full replacement)
- Modify: `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift` (`makeCoordinator` + every test's coordinator construction)

**Interfaces:**
- Consumes: `UpdateAction.install(group:entries:)` (Task 9), `GroupComposition`, `FilterSource` (Task 1), `FilterPipeline.install(_:reloadStrategy:)` (Task 7), `GroupExtensionIdentifiers` (Task 5).
- Produces: `UpdateCoordinator.init(..., extensionIdentifiers: GroupExtensionIdentifiers)` replaces `init(..., adsExtensionIdentifier: String)`. `UpdateRunResult` cases are unchanged.

- [ ] **Step 1: Update makeCoordinator and one test to use the new init signature first**

In `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift`, change `makeCoordinator`:

```swift
    private func makeCoordinator(
        manifestResponse: (Data, URLResponse),
        filterResponse: (Data, URLResponse),
        pipeline: FilterPipeline,
        store: FilterStore
    ) -> UpdateCoordinator {
        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success(manifestResponse),
            filterSourceURL: .success(filterResponse),
        ])
        return UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )
    }
```

(Only the last constructor argument changes — `adsExtensionIdentifier: adsExtensionIdentifier` becomes `extensionIdentifiers: groupExtensionIdentifiers`. The `adsExtensionIdentifier` suite-level constant stays, since `manifestEntry`/assertions elsewhere still reference it by name for the single-group scenarios.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/UpdateCoordinatorTests test`
Expected: FAIL — `UpdateCoordinator.init` has no parameter `extensionIdentifiers` (still expects `adsExtensionIdentifier`).

- [ ] **Step 3: Rewrite UpdateCoordinator.swift**

```swift
// ADBLX/Filtering/Updates/UpdateCoordinator.swift
import Foundation

enum UpdateRunResult {
    case upToDate
    case updated(installedFilterIDs: [String], reloadResults: [ReloadCoordinator.ReloadResult])
    case rolledBack(reason: Error)
    case rollbackFailed(originalReason: Error, restoreError: Error)
}

/// Orchestrates one full update transaction: fetch manifest → plan (grouped by
/// `FilterGroup`) → download + verify each group → compose + install one
/// `GroupComposition` per affected group (deferred reload) → commit metadata + reload
/// once per affected extension, or roll back the entire batch and reload once with the
/// restored state on any failure past the checksum-verification point. See the Sprint 2
/// and Sprint 3A design docs for the full data flow.
actor UpdateCoordinator {
    private let manifestClient: ManifestClient
    private let manifestStore: ManifestStore
    private let downloadClient: FilterDownloadClient
    private let pipeline: FilterPipeline
    private let store: FilterStore
    private let reloader: ReloadCoordinator
    private let extensionIdentifiers: GroupExtensionIdentifiers

    init(
        manifestClient: ManifestClient,
        manifestStore: ManifestStore,
        downloadClient: FilterDownloadClient,
        pipeline: FilterPipeline,
        store: FilterStore,
        reloader: ReloadCoordinator,
        extensionIdentifiers: GroupExtensionIdentifiers
    ) {
        self.manifestClient = manifestClient
        self.manifestStore = manifestStore
        self.downloadClient = downloadClient
        self.pipeline = pipeline
        self.store = store
        self.reloader = reloader
        self.extensionIdentifiers = extensionIdentifiers
    }

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

    private func currentInstalledFilters() async throws -> [InstalledFilter] {
        do {
            let data = try await store.read("installed_filters.json", in: .metadata)
            return try JSONDecoder().decode([InstalledFilter].self, from: data)
        } catch {
            return []
        }
    }
}
```

- [ ] **Step 4: Run the UpdateCoordinatorTests suite to verify it passes**

Run: same command as Step 2.
Expected: PASS — every existing single-group test continues to pass unchanged in behavior (one group, one entry, same reload/rollback semantics as Sprint 2), now routed through the grouped code path.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/UpdateCoordinator.swift ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
git commit -m "refactor: UpdateCoordinator downloads, composes, and installs one GroupComposition per group"
```

---

### Task 11: Delete the transitional FilterPipeline.install(filterID:source:...) adapter

**Files:**
- Modify: `ADBLX/Filtering/Pipeline/FilterPipeline.swift` (remove the transitional method)
- Modify: `ADBLXTests/Filtering/FilterPipelineTests.swift` (rewrite the four tests that called it)

**Interfaces:**
- Removes: `FilterPipeline.install(filterID:source:version:reloadStrategy:)`. Confirms `install(_ composition:reloadStrategy:)` is the pipeline's only entry point (`installBundledSnapshotIfNeeded` already calls it directly, per Task 7/8).

By this point `UpdateCoordinator` (Task 10) no longer calls the transitional adapter — it builds `GroupComposition` directly. `FilterPipelineTests` is the last caller.

- [ ] **Step 1: Confirm the adapter has no other callers**

```bash
grep -rn "\.install(filterID:" /Users/sreeharshag/Work/ADBLX/ADBLX/ /Users/sreeharshag/Work/ADBLX/ADBLXTests/
```

Expected output: only hits inside `ADBLXTests/Filtering/FilterPipelineTests.swift` (the four tests rewritten below). If `UpdateCoordinator.swift` shows up here, stop — Task 10 wasn't fully applied; fix that first.

- [ ] **Step 2: Rewrite the four FilterPipelineTests that use the adapter**

In `ADBLXTests/Filtering/FilterPipelineTests.swift`, replace `throwsOnInvalidSource`, `deferredReloadSkipsReloadCall`, `installingSecondFilterAccumulatesMetadata`, and `reinstallingSameFilterIDReplacesEntry`, and `installRecordsPassedVersion` with:

```swift
    @Test("throws when a source fails validation")
    func throwsOnInvalidSource() async {
        let pipeline = makePipeline()
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(filterID: "bad", version: "v1", checksumSHA256: "a", data: Data())]
        )
        await #expect(throws: FilterValidator.ValidationError.self) {
            _ = try await pipeline.install(composition)
        }
    }

    @Test("reloadStrategy .deferred skips the reload call and returns empty reloadResults")
    func deferredReloadSkipsReloadCall() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "deferred-test", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        let result = try await pipeline.install(composition, reloadStrategy: .deferred)

        #expect(result.reloadResults.isEmpty)
    }

    @Test("installing a second composition after a first accumulates both filters in installed_filters.json")
    func installingSecondCompositionAccumulatesMetadata() async throws {
        let pipeline = makePipeline()
        let source = { (id: String) in
            FilterSource(
                filterID: id, version: "v1", checksumSHA256: "a",
                data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
            )
        }

        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source("filter-a")]), reloadStrategy: .deferred)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [source("filter-b")]), reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(Set(filters.map(\.id)).isSuperset(of: ["filter-a", "filter-b"]))
    }

    @Test("re-installing the same filterID replaces its entry instead of duplicating it")
    func reinstallingSameFilterIDReplacesEntry() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "filter-a", version: "v1", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)
        _ = try await pipeline.install(composition, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.filter { $0.id == "filter-a" }.count == 1)
    }

    @Test("install(composition:) records each source's passed version, not a bundled-snapshot default")
    func installRecordsPassedVersion() async throws {
        let pipeline = makePipeline()
        let source = FilterSource(
            filterID: "filter-versioned", version: "2026-07-18", checksumSHA256: "a",
            data: Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        )
        let composition = GroupComposition(group: .ads, sources: [source])

        _ = try await pipeline.install(composition, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.first(where: { $0.id == "filter-versioned" })?.installedVersion == "2026-07-18")
    }
```

(Note: `installComposesMultipleSourcesIntoOneWrite` and `installCompositionDeferredReloadSkipsReloadCall` from Task 7 already cover multi-source composition and deferred reload via the new API directly — `deferredReloadSkipsReloadCall` above is now redundant with `installCompositionDeferredReloadSkipsReloadCall`; delete `installCompositionDeferredReloadSkipsReloadCall` from Task 7 to avoid duplicate coverage, keeping the single `deferredReloadSkipsReloadCall` name for continuity with Sprint 1/2's test naming.)

- [ ] **Step 3: Run tests to verify they fail (adapter still present, but tests now call install(_:reloadStrategy:) exclusively — this step just confirms no leftover reference to the old signature causes a silent pass)**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterPipelineTests test`
Expected: PASS (the adapter still exists at this point, but nothing calls it anymore — this is expected to already pass; the real proof of "deleted" comes in Step 5).

- [ ] **Step 4: Delete the transitional adapter**

In `ADBLX/Filtering/Pipeline/FilterPipeline.swift`, remove this entire method:

```swift
    /// TRANSITIONAL — Sprint 1/2's single-filter entry point. ...
    func install(
        filterID: String,
        source: Data,
        version: String = "bundled-snapshot",
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
        let composition = GroupComposition(
            group: .ads,
            sources: [FilterSource(
                filterID: filterID,
                version: version,
                checksumSHA256: Checksum.sha256Hex(of: source),
                data: source
            )]
        )
        return try await install(composition, reloadStrategy: reloadStrategy)
    }
```

- [ ] **Step 5: Run the full test target to verify everything still compiles and passes with the adapter gone**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: PASS (all suites) — this is the proof: the whole target compiles with only one `install` method on `FilterPipeline`.

- [ ] **Step 6: Commit**

```bash
git add ADBLX/Filtering/Pipeline/FilterPipeline.swift ADBLXTests/Filtering/FilterPipelineTests.swift
git commit -m "refactor: delete transitional FilterPipeline.install(filterID:source:...) — install(_:reloadStrategy:) is the only entry point"
```

---

### Task 12: Multi-group UpdateCoordinator integration tests

**Files:**
- Modify: `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift` (append two tests)

**Interfaces:**
- Consumes: everything from Tasks 1-11. This is the Sprint 3A acceptance-criteria proof: a manifest spanning all four groups produces four `Compiled/*.json` files, one reload per affected extension, correctly paired to its group (not just present as a set); and a failure partway through a multi-group batch rolls back every group's writes, not just the failing one.

> Amended after an ABORT review of this plan: the original single test used `Set` equality on reload identifiers, which cannot detect a transposed group→identifier mapping (e.g. Annoyances and Regional's bundle IDs swapped in `GroupExtensionIdentifiers`) because all four identifiers would still appear in the set regardless of which group they got paired with. It also had no coverage of a partial-failure rollback across multiple groups — Sprint 2's inherited rollback test only ever had one group to fail. Both gaps are closed below.

- [ ] **Step 1: Write the failing tests**

Append to `UpdateCoordinatorTests`:

```swift
    @Test("manifest spanning all four groups installs each group once and reloads each affected extension once")
    func manifestAcrossAllGroupsInstallsEachGroupOnce() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledDir = try await store.directoryURL(.compiled)
        for filename in ["manifest.json", "installed_filters.json"] {
            try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent(filename))
        }
        for filename in ["Ads.json", "Privacy.json", "Annoyances.json", "Regional.json"] {
            try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent(filename))
        }

        let privacyURL = URL(string: "https://example.com/easyprivacy.txt")!
        let annoyancesURL = URL(string: "https://example.com/fanboy-annoyances.txt")!
        let regionalURL = URL(string: "https://example.com/regional-fr.txt")!
        let ruleJSON = filterSourceJSON()

        let entries = [
            manifestEntry(checksum: Checksum.sha256Hex(of: ruleJSON)),
            FilterManifest.Entry(
                id: "easyprivacy", name: "EasyPrivacy", group: .privacy, sourceURL: privacyURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
            FilterManifest.Entry(
                id: "fanboy-annoyances", name: "Fanboy Annoyances", group: .annoyances, sourceURL: annoyancesURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
            FilterManifest.Entry(
                id: "regional-fr", name: "Regional FR", group: .regional, sourceURL: regionalURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
        ]
        let manifest = FilterManifest(manifestVersion: "1", entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let okResponse = { (url: URL) in HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)! }

        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success((manifestData, manifestResponse)),
            filterSourceURL: .success((ruleJSON, okResponse(filterSourceURL))),
            privacyURL: .success((ruleJSON, okResponse(privacyURL))),
            annoyancesURL: .success((ruleJSON, okResponse(annoyancesURL))),
            regionalURL: .success((ruleJSON, okResponse(regionalURL))),
        ])
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
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )

        let result = try await coordinator.run()

        guard case .updated(let installedIDs, let reloadResults) = result else {
            Issue.record("expected .updated, got \(result)")
            return
        }
        #expect(Set(installedIDs) == ["easylist", "easyprivacy", "fanboy-annoyances", "regional-fr"])
        // Ordered, hardcoded-literal comparison — not a Set, and not built from the
        // `groupExtensionIdentifiers` constant used to construct the SUT above. A Set
        // comparison (or reusing the same constant on both sides) cannot catch a
        // transposed group→identifier mapping: e.g. if `annoyances` and `regional`'s
        // strings were swapped in `GroupExtensionIdentifiers`, all four identifiers would
        // still appear, and an assertion built from the same swapped constant would agree
        // with itself. `UpdateCoordinator.run()` builds `affectedExtensionIDs` via
        // `installGroups.map { extensionIdentifiers[$0.group] }`, and `installGroups`
        // preserves manifest order (Ads, Privacy, Annoyances, Regional — see the `entries`
        // array above), so `reloadResults` — which `ReloadCoordinator.reload(extensionIdentifiers:)`
        // produces in the same order it's given — must match this exact sequence.
        #expect(reloadResults.map(\.extensionIdentifier) == [
            "com.ADBLX.ADBLX.AdsBlocker",
            "com.ADBLX.ADBLX.PrivacyBlocker",
            "com.ADBLX.ADBLX.AnnoyancesBlocker",
            "com.ADBLX.ADBLX.RegionalBlocker",
        ])

        for filename in ["Ads.json", "Privacy.json", "Annoyances.json", "Regional.json"] {
            #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent(filename).path))
        }

        for filename in ["manifest.json", "installed_filters.json"] {
            try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent(filename))
        }
        for filename in ["Ads.json", "Privacy.json", "Annoyances.json", "Regional.json"] {
            try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent(filename))
        }
    }

    @Test("failure in one group of a multi-group batch rolls back every group's writes, with a reload planned for every originally-affected group")
    func multiGroupPartialFailureRollsBackEntireBatch() async throws {
        // Fails compilation only for .annoyances — Ads and Privacy (earlier in
        // UpdateCoordinator's per-group loop, per manifest order) must succeed and write
        // real content BEFORE Annoyances throws, so this proves rollback undoes every
        // group's writes in the batch, not just the one that failed. Sprint 2's inherited
        // rollback test only ever had one group to fail — this is the first test of
        // Sprint 3A's actual new failure surface: a partial failure partway through a
        // multi-group batch.
        struct FailsForGroupCompiler: RuleCompiler {
            let failingGroup: FilterGroup
            nonisolated func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
                guard group != failingGroup else { throw RuleCompilerError.invalidSource }
                return try await PassthroughRuleCompiler().compile(source: source, group: group)
            }
        }

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledDir = try await store.directoryURL(.compiled)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))

        let priorAds = Data("[\"prior-ads\"]".utf8)
        let priorPrivacy = Data("[\"prior-privacy\"]".utf8)
        try priorAds.write(to: compiledDir.appendingPathComponent("Ads.json"), options: .atomic)
        try priorPrivacy.write(to: compiledDir.appendingPathComponent("Privacy.json"), options: .atomic)
        try Data("[]".utf8).write(to: metadataDir.appendingPathComponent("installed_filters.json"), options: .atomic)

        let privacyURL = URL(string: "https://example.com/easyprivacy-partial.txt")!
        let annoyancesURL = URL(string: "https://example.com/fanboy-annoyances-partial.txt")!
        let ruleJSON = filterSourceJSON()

        let entries = [
            manifestEntry(checksum: Checksum.sha256Hex(of: ruleJSON)),
            FilterManifest.Entry(
                id: "easyprivacy", name: "EasyPrivacy", group: .privacy, sourceURL: privacyURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
            FilterManifest.Entry(
                id: "fanboy-annoyances", name: "Fanboy Annoyances", group: .annoyances, sourceURL: annoyancesURL,
                version: "2026-07-19", checksumSHA256: Checksum.sha256Hex(of: ruleJSON), ruleCount: 1,
                enabledByDefault: true, premium: false
            ),
        ]
        let manifest = FilterManifest(manifestVersion: "1", entries: entries)
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let okResponse = { (url: URL) in HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)! }

        let session = MockHTTPSession(responses: [
            manifestEndpoint: .success((manifestData, manifestResponse)),
            filterSourceURL: .success((ruleJSON, okResponse(filterSourceURL))),
            privacyURL: .success((ruleJSON, okResponse(privacyURL))),
            annoyancesURL: .success((ruleJSON, okResponse(annoyancesURL))),
        ])
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: FailsForGroupCompiler(failingGroup: .annoyances),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: groupExtensionIdentifiers),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = UpdateCoordinator(
            manifestClient: ManifestClient(session: session, endpoint: manifestEndpoint),
            manifestStore: ManifestStore(filterStore: store),
            downloadClient: FilterDownloadClient(session: session),
            pipeline: pipeline,
            store: store,
            reloader: ReloadCoordinator(),
            extensionIdentifiers: groupExtensionIdentifiers
        )

        let result = try await coordinator.run()

        guard case .rolledBack = result else {
            Issue.record("expected .rolledBack, got \(result)")
            return
        }

        // Ads and Privacy both installed successfully (writing real compiled content)
        // before Annoyances threw — rollback must restore ALL THREE to their prior
        // state, not just undo the group that failed.
        #expect(try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json")) == priorAds)
        #expect(try Data(contentsOf: compiledDir.appendingPathComponent("Privacy.json")) == priorPrivacy)
        let installedFiltersData = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        #expect(installedFiltersData == Data("[]".utf8))

        try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent("Ads.json"))
        try? FileManager.default.removeItem(at: compiledDir.appendingPathComponent("Privacy.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/UpdateCoordinatorTests/manifestAcrossAllGroupsInstallsEachGroupOnce -only-testing:ADBLXTests/UpdateCoordinatorTests/multiGroupPartialFailureRollsBackEntireBatch test`
Expected: FAIL if any earlier task's behavior is incomplete (e.g. only `.ads` gets installed, fewer than 4 reload results, the reload order doesn't match manifest order, or a partial-batch failure doesn't roll back every group) — if every prior task was implemented correctly, both may already PASS on first run; that's fine, they're still the required proof-of-acceptance tests and must be committed either way. If either fails, the failure message will point at which group didn't get installed/reloaded/rolled-back correctly.

- [ ] **Step 3: If either failed, fix the gap; otherwise proceed**

No new production code should be needed if Tasks 1-11 were implemented as specified — both tests exercise existing code paths, not new ones. If `manifestAcrossAllGroupsInstallsEachGroupOnce` fails, re-check `UpdateCoordinator.run()`'s grouping/reload logic against Task 10's implementation. If `multiGroupPartialFailureRollsBackEntireBatch` fails, re-check that `store.snapshotForRollback()` is called before the per-group install loop (not inside it) and that `store.restore(snapshot)` runs unconditionally in the `catch` block, both per Task 10's implementation.

- [ ] **Step 4: Run the full test target one final time**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: PASS (all suites) — this is Sprint 3A's final green build.

- [ ] **Step 5: Commit**

```bash
git add ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
git commit -m "test: multi-group UpdateCoordinator integration — group/identifier pairing and partial-failure rollback"
```

---

## Post-Sprint Checklist

- [ ] `grep -rn "unsupportedGroup\|groupConflict\|PassthroughAdsPartitioner\|sourceFilterID" ADBLX/ ADBLXTests/` returns no results.
- [ ] `grep -rn "func install(filterID:" ADBLX/` returns no results (only `install(_ composition:reloadStrategy:)` remains).
- [ ] Full suite green: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`

---

## Execution Sessions (added by harden-plan)

Sessions are capped at 2-3 tasks, weighted (not just counted): a HEAVY task
(wide blast radius — 3+ files, a new module/protocol, or a core-logic rewrite)
counts as 2 and pairs with at most one LIGHT task (a mechanical/single-file/
verification-only task, counts as 1); no session exceeds weight 3. Splits
land at architectural seams; no session separates a migration from the
consumer it would otherwise leave non-compiling (see Task 9's Step 4 — the
temporary `UpdateCoordinator.swift` bridge exists specifically so Tasks 9 and
10 are safe to run in *different* sessions without ever leaving the tree
broken in between).

`subagent-driven-development` already reviews each task individually — the
checkpoint below is a *session-boundary* review only: a fresh `plan-reviewer`
subagent re-examines the whole session's combined diff against this plan
file, in a context that never saw why any line was written the way it was.

**Rule for the executing session:** when you complete the last task of the
current session group, STOP. Do not start the next group. Run the exit
checklist and tell the user the session is safe to `/clear`.

**Exit checklist (every session):**
1. Tick this group's checkboxes in this plan file.
2. Confirm each task's commit exists (`git log --oneline -n <task count>`).
3. Run the `plan-reviewer` subagent on the group's combined diff (pass this plan's path and the task range).
4. Record any surprise/workaround as one line in `docs/gotchas.md`.
5. Tell the user: "Session N complete and reviewed — safe to `/clear`."

---

- **Session 1: Tasks 1-2** (weight 2) — `FilterSource`/`GroupComposition` models, `ComposedRules` model. Full Commit 1 plus the model half of Commit 2.
  Resume prompt for Session 2:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-2 are complete (see checkboxes and git log). Start at Task 3. Stop after Task 3.`

- **Session 2: Task 3** (weight 2) — `CompositionService`: new protocol + `JSONArrayCompositionService`, merge/determinism logic. Alone because Task 4 is also heavy (2+2 > 3).
  Resume prompt for Session 3:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-3 are complete (see checkboxes and git log). Start at Task 4. Stop after Task 4.`

- **Session 3: Task 4** (weight 2) — `RuleCompiler` drops `filterID` for `group`; ripples to 6 files in one task (protocol change, whole-target rebuild required). Give this one your full attention — it's the widest single-task blast radius in the plan.
  Resume prompt for Session 4:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-4 are complete (see checkboxes and git log). Start at Task 5. Stop after Task 6.`

- **Session 4: Tasks 5-6** (weight 3) — `GroupPartitioner` replaces `PassthroughAdsPartitioner`, then wired through `FilterPipeline` and remaining tests. These two must stay together: Task 5 alone leaves the target non-compiling by design (documented in Task 5's own Step 5) — Task 6 is what makes it green again.
  Resume prompt for Session 5:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-6 are complete (see checkboxes and git log). Start at Task 7. Stop after Task 8.`

- **Session 5: Tasks 7-8** (weight 3) — `FilterPipeline.install(_ composition:reloadStrategy:)`, the heart of Sprint 3A, plus its `installBundledSnapshotIfNeeded` confirmation. Full Commit 4.
  Resume prompt for Session 6:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-8 are complete (see checkboxes and git log). Start at Task 9. Stop after Task 9.`

- **Session 6: Task 9** (weight 2) — `UpdatePlanner` emits one `.install(group:entries:)` per group. Alone despite being safely followed by Task 10 in a different session — the temporary `UpdateCoordinator.swift` compile bridge (Step 4) is exactly what makes that split safe. Highest correctness risk in the plan per the ABORT review (subtle grouping/fall-through control flow) — read Step 3's `UpdatePlanner.plan` body carefully against the "falls through to grouping below" comments before approving.
  Resume prompt for Session 7:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-9 are complete (see checkboxes and git log). Start at Task 10. Stop after Task 10.`

- **Session 7: Task 10** (weight 2) — `UpdateCoordinator` rewritten to download/compose/install one `GroupComposition` per group; replaces Task 9's temporary bridge entirely. Core orchestration + rollback/reload semantics — the other highest-risk task per the ABORT review (rollback ordering, `affectedExtensionIDs` construction).
  Resume prompt for Session 8:
  `Continue executing docs/superpowers/plans/2026-07-19-sprint3a-group-composition.md. Tasks 1-10 are complete (see checkboxes and git log). Start at Task 11. Stop after Task 12.`

- **Session 8: Tasks 11-12** (weight 3) — delete the transitional `FilterPipeline.install(filterID:source:...)` adapter, then the multi-group integration tests. Final session: pay particular attention to Task 12's two tests — confirm the reload-identifier assertion is the ordered/hardcoded-literal form (not `Set` equality) and that the partial-failure rollback test exercises a 2-of-3-groups-succeed-then-fail sequence, per the ABORT review amendment. A clean report here means the Post-Sprint Checklist above should also pass — this is the plan's last session, no resume prompt needed.

If `plan-reviewer` reports a gap at any checkpoint, fix it before starting the next session — don't carry a known gap forward on the assumption a later session will happen to catch it.
