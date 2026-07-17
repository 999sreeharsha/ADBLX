# Sprint 1: Rule Pipeline Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Sprint 0's bundled-JSON-copy path with a real, layered rule pipeline
(validate → compile → partition → atomically write → reload) for the Ads content blocker,
built from bundled test fixtures only — no networking this sprint.

**Architecture:** Six single-purpose stage types (`FilterValidator`, `RuleCompiler`,
`RulePartitioner`, `FilterStore`, `AtomicRuleWriter`, `ReloadCoordinator`) live in a new
`Filtering/` module in the main app target only. A new `FilterPipeline` actor, constructed via
dependency injection, is the sole type that sequences them and returns a typed
`PipelineResult`. `ContentBlockerBootstrap` shrinks to a single call into the pipeline at
launch; the `ADBLXAdsBlocker` extension's read path is updated to match the pipeline's new
`Compiled/` output location.

**Tech Stack:** Swift 5.0, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), Swift
Concurrency (actors, `async`/`await`), XcodeGen `syncedFolder` targets (no `project.yml` edits
needed — new files under `ADBLX/` and `ADBLXTests/` attach automatically).

## Global Constraints

- **Target placement:** everything in this plan except the one-line extension read-path fix
  lives in the main app (`ADBLX`) target only. Nothing goes into `Packages/ADBLXShared` or any
  Content Blocker extension target.
- **Logging policy:** any logging/statistics may only ever capture counts, durations, sizes,
  versions, checksums — never rule bodies, domains, hostnames, or URLs. No exception for debug
  builds.
- **Off-main-thread execution, and why it needs explicit annotation here:** `project.yml` sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` on the `ADBLX` target. Under that setting, every
  *non*-actor declaration (structs, protocol requirements, enum static funcs) defaults to
  `@MainActor` isolation unless marked `nonisolated` — so `FilterValidator`, `RuleCompiler`,
  `RulePartitioner`, `AtomicRuleWriter`, and `Checksum` must each be marked `nonisolated`
  explicitly, or they'll silently run on the main thread despite being called from off-main
  actor/task contexts, defeating the plan's own off-main-thread requirement. `FilterStore`,
  `ReloadCoordinator`, and `FilterPipeline` are declared as `actor` types, which are their own
  isolation domain regardless of the file-level default — no annotation needed on those three.
- **Errors surfaced, not swallowed:** every `ReloadCoordinator` call and every compile/write
  failure produces a typed, catchable error — never silently discarded.
- **Test framework:** Swift Testing, not XCTest — `@Suite`, `@Test`, `#expect`, `#require`,
  `await #expect(throws:)` for async throwing calls.
- **Integration point found during planning (not in the design spec):** the `ADBLXAdsBlocker`
  extension currently reads `Rules/Ads.json` from the App Group container root
  (`Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift`). `FilterStore`'s directory
  layout writes compiled output to `Compiled/`, not `Rules/`. Task 12 updates the extension's
  read path to `Compiled/Ads.json` — without it, the new pipeline writes rules the extension
  never looks for.
- **Compiled output filename convention:** `FilterPipeline` writes each partition's JSON to
  `Compiled/<Group>.json`, where `<Group>` is the capitalized `FilterGroup` raw value (Sprint 1:
  `Compiled/Ads.json` only).

---

### Task 1: Filtering module skeleton

**Files:**
- Create: `ADBLX/Filtering/README.md`

**Interfaces:**
- Produces: nothing code-facing — this task establishes the directory and its placement rules
  for every subsequent task.

- [ ] **Step 1: Create the module README**

```markdown
# Filtering module — target placement

**This entire module belongs in the main app target ONLY.**

- Do NOT add this module, or any file in it, to `Packages/ADBLXShared`. Shared-package adoption
  is gated on ADR-0003, which is not yet approved.
- Do NOT add this module to any Content Blocker extension target. Extensions read pre-compiled
  JSON from the App Group container and nothing else — they have a ~6MB memory ceiling and
  cannot host compilation, validation, or networking code.
- `FilterStore` (Storage/) is the *only* type permitted to touch the App Group container
  filesystem. If you need filesystem access elsewhere, route it through `FilterStore` instead
  of opening a new path.
- `RuleStatistics` and any diagnostics/logging must contain counts and durations only — never
  rule bodies, domains, hostnames, or URLs. See `docs/Architecture/Logging.md`.
- Every non-actor type in this module (`FilterValidator`, `RuleCompiler`, `RulePartitioner`,
  `AtomicRuleWriter`, `Checksum`) is explicitly `nonisolated` because the `ADBLX` target builds
  with `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` — see the plan's Global Constraints for why.

Sprint 1 scope: bundled test fixtures only, no networking until Part 10. `Compilation/` ships a
passthrough `RuleCompiler`, not a real compiler — see
`docs/superpowers/specs/2026-07-17-sprint1-rule-pipeline-design.md`.
```

- [ ] **Step 2: Verify the project still builds with the new empty directory**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ADBLX/Filtering/README.md
git commit -m "feat: add Filtering module skeleton and target-placement rules"
```

---

### Task 2: Domain Models

**Files:**
- Create: `ADBLX/Filtering/Models/RuleStatistics.swift`
- Create: `ADBLX/Filtering/Models/CompiledRuleSet.swift`
- Create: `ADBLX/Filtering/Models/FilterManifest.swift`
- Create: `ADBLX/Filtering/Models/FilterMetadata.swift`
- Create: `ADBLX/Filtering/Models/InstalledFilter.swift`
- Test: `ADBLXTests/Filtering/FilteringModelsTests.swift`

**Interfaces:**
- Produces:
  - `struct RuleStatistics: Codable, Equatable` — `compileDuration: TimeInterval`,
    `rulesLoaded: Int`, `duplicatesRemoved: Int`, `unsupportedRuleCount: Int`,
    `memoryEstimateBytes: Int`, `lastUpdated: Date`.
  - `struct CompiledRuleSet: Codable, Equatable` — `sourceFilterID: String`, `rawJSON: Data`,
    `ruleCount: Int`, `statistics: RuleStatistics`.
  - `enum FilterGroup: String, Codable, Equatable` — `.ads`, `.privacy`, `.annoyances`,
    `.regional`.
  - `struct FilterManifest: Codable, Equatable` — `manifestVersion: String`,
    `entries: [FilterManifest.Entry]`; nested `Entry: Codable, Equatable, Identifiable` —
    `id: String`, `name: String`, `group: FilterGroup`, `sourceURL: URL`, `version: String`,
    `checksumSHA256: String`, `ruleCount: Int`, `enabledByDefault: Bool`, `premium: Bool`.
  - `struct FilterMetadata: Codable, Equatable, Identifiable` — `id: String`,
    `displayName: String`, `group: FilterGroup`, `version: String`, `ruleCount: Int`,
    `premium: Bool`, `lastCompileDuration: TimeInterval?`.
  - `struct InstalledFilter: Codable, Equatable, Identifiable` — `id: String`,
    `group: FilterGroup`, `installedVersion: String`, `checksumSHA256: String`,
    `lastUpdated: Date`, `ruleCount: Int`.

- [ ] **Step 1: Write the failing round-trip tests**

```swift
// ADBLXTests/Filtering/FilteringModelsTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("Filtering Models")
struct FilteringModelsTests {
    @Test("RuleStatistics round-trips through JSON")
    func ruleStatisticsRoundTrip() throws {
        let original = RuleStatistics(
            compileDuration: 1.23,
            rulesLoaded: 70,
            duplicatesRemoved: 2,
            unsupportedRuleCount: 1,
            memoryEstimateBytes: 4096,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuleStatistics.self, from: data)
        #expect(decoded == original)
    }

    @Test("CompiledRuleSet round-trips through JSON")
    func compiledRuleSetRoundTrip() throws {
        let stats = RuleStatistics(
            compileDuration: 0.5, rulesLoaded: 3, duplicatesRemoved: 0,
            unsupportedRuleCount: 0, memoryEstimateBytes: 128,
            lastUpdated: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let original = CompiledRuleSet(
            sourceFilterID: "ads-bundled", rawJSON: Data("[]".utf8), ruleCount: 3,
            statistics: stats
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CompiledRuleSet.self, from: data)
        #expect(decoded == original)
    }

    @Test("FilterManifest round-trips through JSON")
    func filterManifestRoundTrip() throws {
        let entry = FilterManifest.Entry(
            id: "ads-bundled", name: "Ads", group: .ads,
            sourceURL: URL(string: "https://example.com/ads.txt")!,
            version: "2026-07-17", checksumSHA256: "abc123", ruleCount: 70,
            enabledByDefault: true, premium: false
        )
        let original = FilterManifest(manifestVersion: "1", entries: [entry])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterManifest.self, from: data)
        #expect(decoded == original)
    }

    @Test("FilterMetadata round-trips through JSON")
    func filterMetadataRoundTrip() throws {
        let original = FilterMetadata(
            id: "ads-bundled", displayName: "Ads", group: .ads, version: "2026-07-17",
            ruleCount: 70, premium: false, lastCompileDuration: 0.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FilterMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test("InstalledFilter round-trips through JSON")
    func installedFilterRoundTrip() throws {
        let original = InstalledFilter(
            id: "ads-bundled", group: .ads, installedVersion: "bundled-snapshot",
            checksumSHA256: "abc123", lastUpdated: Date(timeIntervalSince1970: 1_752_000_000),
            ruleCount: 70
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InstalledFilter.self, from: data)
        #expect(decoded == original)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilteringModelsTests test`
Expected: build fails — `cannot find 'RuleStatistics' in scope` (and similarly for the other four types)

- [ ] **Step 3: Write the models**

```swift
// ADBLX/Filtering/Models/RuleStatistics.swift
import Foundation

/// Compile/pipeline statistics for a single filter or a full compile pass.
///
/// PRIVACY CONSTRAINT (docs/Architecture/Logging.md): every field here must remain a count,
/// duration, or size estimate. Never add a field that could hold a rule body, domain,
/// hostname, or URL — including for debug builds. If you're tempted to log "which rules were
/// unsupported," log the *count* of unsupported rules, not their content.
struct RuleStatistics: Codable, Equatable {
    var compileDuration: TimeInterval
    var rulesLoaded: Int
    var duplicatesRemoved: Int
    var unsupportedRuleCount: Int
    var memoryEstimateBytes: Int
    var lastUpdated: Date
}
```

```swift
// ADBLX/Filtering/Models/CompiledRuleSet.swift
import Foundation

/// Output of the compilation stage: raw Safari content-blocker JSON, ready to be partitioned
/// and written into the App Group container. `rawJSON` is the actual Safari rule payload —
/// treat it as opaque data here; nothing in Models/ inspects or logs its contents.
struct CompiledRuleSet: Codable, Equatable {
    var sourceFilterID: String
    var rawJSON: Data
    var ruleCount: Int
    var statistics: RuleStatistics
}
```

```swift
// ADBLX/Filtering/Models/FilterManifest.swift
import Foundation

/// Mirrors the CDN-hosted `manifest.json` catalog (PRD §6.2).
/// Populated from the network starting in Part 10; for Sprint 1, loaded from a bundled
/// test fixture to exercise the rest of the pipeline without networking.
struct FilterManifest: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var group: FilterGroup
        var sourceURL: URL
        /// Date-based version string, e.g. "2026-07-15".
        var version: String
        var checksumSHA256: String
        var ruleCount: Int
        var enabledByDefault: Bool
        var premium: Bool
    }

    var manifestVersion: String
    var entries: [Entry]
}

enum FilterGroup: String, Codable, Equatable {
    case ads
    case privacy
    case annoyances
    case regional
}
```

```swift
// ADBLX/Filtering/Models/FilterMetadata.swift
import Foundation

/// Per-list metadata surfaced in the Filters catalog UI (FR-09).
/// Contains no rule content or domain data — display-facing facts only.
struct FilterMetadata: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var group: FilterGroup
    var version: String
    var ruleCount: Int
    var premium: Bool
    var lastCompileDuration: TimeInterval?
}
```

```swift
// ADBLX/Filtering/Models/InstalledFilter.swift
import Foundation

/// Tracks what's actually on disk right now, as opposed to `FilterManifest` which describes
/// what's available. Persisted as `installed_filters.json` (FilterStore/Metadata).
struct InstalledFilter: Codable, Equatable, Identifiable {
    var id: String
    var group: FilterGroup
    var installedVersion: String
    var checksumSHA256: String
    var lastUpdated: Date
    var ruleCount: Int
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilteringModelsTests test`
Expected: `** TEST SUCCEEDED **`, 5 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Models ADBLXTests/Filtering/FilteringModelsTests.swift
git commit -m "feat: add Filtering domain models with round-trip tests"
```

---

### Task 3: Checksum utility

**Files:**
- Create: `ADBLX/Filtering/Utilities/Checksum.swift`
- Test: `ADBLXTests/Filtering/ChecksumTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `enum Checksum { nonisolated static func sha256Hex(of data: Data) -> String }`.

- [ ] **Step 1: Write the failing test**

```swift
// ADBLXTests/Filtering/ChecksumTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("Checksum")
struct ChecksumTests {
    @Test("produces the known SHA-256 hex digest for a known input")
    func knownDigest() {
        let digest = Checksum.sha256Hex(of: Data("abc".utf8))
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/ChecksumTests test`
Expected: build fails — `cannot find 'Checksum' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Utilities/Checksum.swift
import Foundation
import CryptoKit

/// sha256 helper. Wired in this sprint per the metadata model, but not yet exercised in
/// anger — checksum verification against downloaded lists activates in Part 10 (FR-04).
///
/// `nonisolated`: the ADBLX target defaults unannotated declarations to @MainActor
/// (SWIFT_DEFAULT_ACTOR_ISOLATION), and this is called from off-main-actor pipeline code.
enum Checksum {
    nonisolated static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/ChecksumTests test`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Utilities/Checksum.swift ADBLXTests/Filtering/ChecksumTests.swift
git commit -m "feat: add sha256 checksum utility"
```

---

### Task 4: FilterValidator

**Files:**
- Create: `ADBLX/Filtering/Validation/FilterValidator.swift`
- Test: `ADBLXTests/Filtering/FilterValidatorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct FilterValidator { var maxByteCount: Int; nonisolated func validate(_ data:
  Data) throws }`, `enum FilterValidator.ValidationError: Error, Equatable { case notUTF8,
  empty, tooLarge(byteCount: Int, limit: Int), invalidJSON }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/FilterValidatorTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterValidator")
struct FilterValidatorTests {
    @Test("rejects empty data")
    func rejectsEmpty() {
        let validator = FilterValidator()
        #expect(throws: FilterValidator.ValidationError.empty) {
            try validator.validate(Data())
        }
    }

    @Test("rejects data over the size ceiling")
    func rejectsOversized() {
        var validator = FilterValidator()
        validator.maxByteCount = 10
        #expect(throws: FilterValidator.ValidationError.tooLarge(byteCount: 11, limit: 10)) {
            try validator.validate(Data(repeating: 0x41, count: 11))
        }
    }

    @Test("rejects non-UTF8 bytes")
    func rejectsNonUTF8() {
        let validator = FilterValidator()
        #expect(throws: FilterValidator.ValidationError.notUTF8) {
            try validator.validate(Data([0xFF, 0xFE, 0xFD]))
        }
    }

    @Test("rejects malformed JSON")
    func rejectsMalformedJSON() {
        let validator = FilterValidator()
        #expect(throws: FilterValidator.ValidationError.invalidJSON) {
            try validator.validate(Data("not json".utf8))
        }
    }

    @Test("accepts valid JSON array")
    func acceptsValidJSON() throws {
        let validator = FilterValidator()
        try validator.validate(Data("[{\"a\":1}]".utf8))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilterValidatorTests test`
Expected: build fails — `cannot find 'FilterValidator' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Validation/FilterValidator.swift
import Foundation

/// Basic sanity validation before a filter source enters the compile stage.
/// This is a precursor to FR-04 (checksum verification), NOT FR-04 itself — checksum
/// enforcement activates in Part 10 once downloads exist. This sprint only guards against
/// obviously-bad bundled fixtures.
///
/// Target: main app ONLY. `validate` is `nonisolated` — see Task 3's note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
struct FilterValidator {
    enum ValidationError: Error, Equatable {
        case notUTF8
        case empty
        case tooLarge(byteCount: Int, limit: Int)
        case invalidJSON
    }

    /// Generous ceiling — this is a sanity guard against corrupt/truncated downloads,
    /// not a tight budget. The real rule-count budget (150K/extension) is enforced later,
    /// in the partitioning stage, against parsed rule counts.
    var maxByteCount: Int = 50 * 1024 * 1024

    nonisolated func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw ValidationError.empty
        }
        guard data.count <= maxByteCount else {
            throw ValidationError.tooLarge(byteCount: data.count, limit: maxByteCount)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ValidationError.notUTF8
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ValidationError.invalidJSON
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilterValidatorTests test`
Expected: `** TEST SUCCEEDED **`, 5 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Validation ADBLXTests/Filtering/FilterValidatorTests.swift
git commit -m "feat: add FilterValidator with UTF-8/size/JSON sanity checks"
```

---

### Task 5: RuleCompiler protocol + PassthroughRuleCompiler

**Files:**
- Create: `ADBLX/Filtering/Compilation/RuleCompiler.swift`
- Test: `ADBLXTests/Filtering/RuleCompilerTests.swift`

**Interfaces:**
- Consumes: `CompiledRuleSet`, `RuleStatistics` (Task 2).
- Produces: `protocol RuleCompiler: Sendable { nonisolated func compile(source: Data, filterID:
  String) async throws -> CompiledRuleSet }`, `struct PassthroughRuleCompiler: RuleCompiler`,
  `enum RuleCompilerError: Error { case invalidSource }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/RuleCompilerTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("PassthroughRuleCompiler")
struct PassthroughRuleCompilerTests {
    @Test("compiles a valid JSON array, counting rules")
    func compilesValidArray() async throws {
        let source = Data("[{\"a\":1},{\"a\":2},{\"a\":3}]".utf8)
        let compiler = PassthroughRuleCompiler()
        let result = try await compiler.compile(source: source, filterID: "test-filter")

        #expect(result.sourceFilterID == "test-filter")
        #expect(result.ruleCount == 3)
        #expect(result.rawJSON == source)
        #expect(result.statistics.rulesLoaded == 3)
        #expect(result.statistics.duplicatesRemoved == 0)
        #expect(result.statistics.unsupportedRuleCount == 0)
    }

    @Test("throws on empty source")
    func throwsOnEmpty() async {
        let compiler = PassthroughRuleCompiler()
        await #expect(throws: RuleCompilerError.self) {
            _ = try await compiler.compile(source: Data(), filterID: "test-filter")
        }
    }

    @Test("throws on invalid JSON")
    func throwsOnInvalidJSON() async {
        let compiler = PassthroughRuleCompiler()
        await #expect(throws: RuleCompilerError.self) {
            _ = try await compiler.compile(source: Data("not json".utf8), filterID: "test-filter")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/PassthroughRuleCompilerTests test`
Expected: build fails — `cannot find 'PassthroughRuleCompiler' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Compilation/RuleCompiler.swift
import Foundation

/// Converts a normalized filter source into Safari content-blocker JSON.
///
/// Sprint 1 ships `PassthroughRuleCompiler` only (bundled test JSON → copy, no real parsing).
/// The SafariConverterLib-backed implementation lands once ADR-0001 (GPL-3.0 licensing
/// decision) resolves — this protocol boundary means that swap touches nothing outside
/// Compilation/.
///
/// Target: main app ONLY — never in a Content Blocker extension (6MB memory ceiling makes
/// real compilation there a non-starter regardless of which implementation this becomes).
/// The requirement is `nonisolated` — see Task 3's note on SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RuleCompiler: Sendable {
    /// Compiles raw filter source data into a `CompiledRuleSet`.
    /// Must run off the main actor for any non-trivial input size.
    nonisolated func compile(source: Data, filterID: String) async throws -> CompiledRuleSet
}

enum RuleCompilerError: Error {
    case invalidSource
}

/// Sprint 1 stub: treats `source` as already-valid Safari JSON and passes it through,
/// generating count-only statistics. Does NOT exercise NFR-01 (compile time / memory budget)
/// — there is no real compilation work happening yet. Do not report this implementation's
/// timings as NFR-01 verification.
struct PassthroughRuleCompiler: RuleCompiler {
    nonisolated func compile(source: Data, filterID: String) async throws -> CompiledRuleSet {
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
            sourceFilterID: filterID,
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/PassthroughRuleCompilerTests test`
Expected: `** TEST SUCCEEDED **`, 3 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Compilation ADBLXTests/Filtering/RuleCompilerTests.swift
git commit -m "feat: add RuleCompiler protocol and passthrough implementation"
```

---

### Task 6: RulePartitioner protocol + PassthroughAdsPartitioner

**Files:**
- Create: `ADBLX/Filtering/Deployment/RulePartitioner.swift`
- Test: `ADBLXTests/Filtering/RulePartitionerTests.swift`

**Interfaces:**
- Consumes: `CompiledRuleSet`, `RuleStatistics`, `FilterGroup` (Task 2).
- Produces: `protocol RulePartitioner: Sendable { nonisolated func partition(_ ruleSet:
  CompiledRuleSet) async throws -> [PartitionedRules] }`, `struct PartitionedRules {
  extensionIdentifier: String; group: FilterGroup; json: Data; ruleCount: Int }`,
  `struct PassthroughAdsPartitioner: RulePartitioner { let adsExtensionIdentifier: String }`,
  `enum RulePartitionerError: Error { case ruleBudgetExceeded(group: FilterGroup, count: Int,
  limit: Int) }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/RulePartitionerTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("PassthroughAdsPartitioner")
struct PassthroughAdsPartitionerTests {
    @Test("partitions within budget into a single Ads partition")
    func partitionsWithinBudget() async throws {
        let ruleSet = CompiledRuleSet(
            sourceFilterID: "ads-bundled",
            rawJSON: Data("[]".utf8),
            ruleCount: 70,
            statistics: RuleStatistics(
                compileDuration: 0.01, rulesLoaded: 70, duplicatesRemoved: 0,
                unsupportedRuleCount: 0, memoryEstimateBytes: 2048, lastUpdated: Date()
            )
        )
        let partitioner = PassthroughAdsPartitioner(adsExtensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker")
        let partitions = try await partitioner.partition(ruleSet)

        #expect(partitions.count == 1)
        #expect(partitions[0].group == .ads)
        #expect(partitions[0].extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")
        #expect(partitions[0].ruleCount == 70)
    }

    @Test("throws when rule count exceeds the per-extension budget")
    func throwsWhenOverBudget() async {
        let ruleSet = CompiledRuleSet(
            sourceFilterID: "ads-bundled",
            rawJSON: Data("[]".utf8),
            ruleCount: 150_001,
            statistics: RuleStatistics(
                compileDuration: 0.01, rulesLoaded: 150_001, duplicatesRemoved: 0,
                unsupportedRuleCount: 0, memoryEstimateBytes: 2048, lastUpdated: Date()
            )
        )
        let partitioner = PassthroughAdsPartitioner(adsExtensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker")
        await #expect(throws: RulePartitionerError.self) {
            _ = try await partitioner.partition(ruleSet)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/PassthroughAdsPartitionerTests test`
Expected: build fails — `cannot find 'PassthroughAdsPartitioner' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Deployment/RulePartitioner.swift
import Foundation

/// Splits compiled rules across the 4 Content Blocker extensions, respecting each
/// extension's 150K-rule budget.
///
/// Sprint 1 scope: passthrough for the Ads extension only. Privacy/Annoyances/Regional
/// extensions continue to ship their existing Sprint 0 bundled-JSON copy unchanged this
/// sprint — this is a deliberate scope line, not a regression against FR-01.
///
/// Target: main app ONLY. The requirement is `nonisolated` — see Task 3's note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
protocol RulePartitioner: Sendable {
    nonisolated func partition(_ ruleSet: CompiledRuleSet) async throws -> [PartitionedRules]
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

struct PassthroughAdsPartitioner: RulePartitioner {
    /// Per PRD §6.1 / Appendix B.1 — 150K compiled rules per extension.
    static let ruleBudgetPerExtension = 150_000

    let adsExtensionIdentifier: String

    nonisolated func partition(_ ruleSet: CompiledRuleSet) async throws -> [PartitionedRules] {
        guard ruleSet.ruleCount <= Self.ruleBudgetPerExtension else {
            throw RulePartitionerError.ruleBudgetExceeded(
                group: .ads,
                count: ruleSet.ruleCount,
                limit: Self.ruleBudgetPerExtension
            )
        }
        return [
            PartitionedRules(
                extensionIdentifier: adsExtensionIdentifier,
                group: .ads,
                json: ruleSet.rawJSON,
                ruleCount: ruleSet.ruleCount
            )
        ]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/PassthroughAdsPartitionerTests test`
Expected: `** TEST SUCCEEDED **`, 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Deployment/RulePartitioner.swift ADBLXTests/Filtering/RulePartitionerTests.swift
git commit -m "feat: add RulePartitioner protocol and Ads-only passthrough implementation"
```

---

### Task 7: FilterStore

**Files:**
- Create: `ADBLX/Filtering/Storage/FilterStore.swift`
- Test: `ADBLXTests/Filtering/FilterStoreTests.swift`

**Interfaces:**
- Consumes: `AppGroup.identifier` (existing, `ADBLX/AppGroup.swift`).
- Produces: `actor FilterStore { enum Directory { case filters, compiled, metadata };
  init(appGroupIdentifier: String, fileManager: FileManager = .default); func read(_ filename:
  String, in directory: Directory) throws -> Data; func writeMetadata(_ data: Data, filename:
  String) throws; func directoryURL(_ directory: Directory) throws -> URL }`,
  `enum FilterStoreError: Error { case appGroupContainerUnavailable }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/FilterStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterStore")
struct FilterStoreTests {
    @Test("creates directories on demand and round-trips metadata writes")
    func roundTripsMetadata() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let filename = "test-metadata-\(UUID().uuidString).json"
        let payload = Data("{\"key\":\"value\"}".utf8)

        try await store.writeMetadata(payload, filename: filename)
        let readBack = try await store.read(filename, in: .metadata)
        #expect(readBack == payload)

        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent(filename))
    }

    @Test("throws reading a filename that doesn't exist")
    func throwsOnMissingFile() async {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        await #expect(throws: (any Error).self) {
            _ = try await store.read("does-not-exist-\(UUID().uuidString).json", in: .compiled)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilterStoreTests test`
Expected: build fails — `cannot find 'FilterStore' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Storage/FilterStore.swift
import Foundation

/// Sole owner of the App Group filesystem layout:
///
///   Filters/     — raw/normalized filter list source data
///   Compiled/    — partitioned, compiled JSON ready for each Content Blocker extension
///   Metadata/    — installed_filters.json, manifest.json, statistics.json
///
/// No other type in the app should call `FileManager` against the App Group container
/// directly. Route all reads/writes through this actor so there's one place that understands
/// the on-disk layout and one place to audit for the atomic-write guarantee (see
/// AtomicRuleWriter).
///
/// Target: main app ONLY. Extensions read the `Compiled/` directory via their own
/// (read-only, minimal) file access — they do not use this type.
actor FilterStore {
    enum Directory {
        case filters
        case compiled
        case metadata
    }

    private let appGroupIdentifier: String
    private let fileManager: FileManager

    init(appGroupIdentifier: String, fileManager: FileManager = .default) {
        self.appGroupIdentifier = appGroupIdentifier
        self.fileManager = fileManager
    }

    /// Root container URL for the App Group. Not exposed outside this type —
    /// callers ask for files/data, not paths.
    private func containerURL() throws -> URL {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw FilterStoreError.appGroupContainerUnavailable
        }
        return url
    }

    private func url(for directory: Directory) throws -> URL {
        let base = try containerURL()
        let subpath: String
        switch directory {
        case .filters: subpath = "Filters"
        case .compiled: subpath = "Compiled"
        case .metadata: subpath = "Metadata"
        }
        let dir = base.appendingPathComponent(subpath, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Reads raw data for a named file within a directory. Throws if absent —
    /// callers decide fallback/rollback behavior, this type doesn't guess.
    func read(_ filename: String, in directory: Directory) throws -> Data {
        let fileURL = try url(for: directory).appendingPathComponent(filename)
        return try Data(contentsOf: fileURL)
    }

    /// Non-atomic convenience write for metadata-sized files (small, low update frequency).
    /// Compiled rule JSON MUST go through AtomicRuleWriter instead — this method is not
    /// safe for anything a Content Blocker extension will load.
    func writeMetadata(_ data: Data, filename: String) throws {
        let fileURL = try url(for: .metadata).appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
    }

    func directoryURL(_ directory: Directory) throws -> URL {
        try url(for: directory)
    }
}

enum FilterStoreError: Error {
    case appGroupContainerUnavailable
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilterStoreTests test`
Expected: `** TEST SUCCEEDED **`, 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Storage/FilterStore.swift ADBLXTests/Filtering/FilterStoreTests.swift
git commit -m "feat: add FilterStore as sole owner of App Group filesystem layout"
```

---

### Task 8: AtomicRuleWriter with AtomicFilesystem seam

**Files:**
- Create: `ADBLX/Filtering/Storage/AtomicRuleWriter.swift`
- Test: `ADBLXTests/Filtering/AtomicRuleWriterTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `protocol AtomicFilesystem: Sendable { func write(_ data: Data, to url: URL) throws;
  func fsync(atPath path: String) throws; func replace(_ destination: URL, with tempURL: URL)
  throws }`, `struct RealFilesystem: AtomicFilesystem`, `struct AtomicRuleWriter {
  init(filesystem: AtomicFilesystem = RealFilesystem()); nonisolated func write(_ data: Data,
  to destinationURL: URL) throws }`, `enum AtomicRuleWriter.WriteError: Error, Equatable { case
  fsyncFailed(errno: Int32), renameFailed(errno: Int32) }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/AtomicRuleWriterTests.swift
import Testing
import Foundation
@testable import ADBLX

private struct FailingFilesystem: AtomicFilesystem {
    enum FailAt {
        case write, fsync, replace
    }

    enum InjectedError: Error {
        case injected
    }

    let failAt: FailAt

    func write(_ data: Data, to url: URL) throws {
        if failAt == .write { throw InjectedError.injected }
        try data.write(to: url, options: .atomic)
    }

    func fsync(atPath path: String) throws {
        if failAt == .fsync { throw InjectedError.injected }
    }

    func replace(_ destination: URL, with tempURL: URL) throws {
        if failAt == .replace { throw InjectedError.injected }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
    }
}

@Suite("AtomicRuleWriter")
struct AtomicRuleWriterTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("writes data to destination via the real filesystem")
    func happyPath() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("rules.json")
        let writer = AtomicRuleWriter()
        try writer.write(Data("[]".utf8), to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: destination) == Data("[]".utf8))
    }

    @Test("fsync failure leaves the prior committed file intact and cleans up the temp file")
    func fsyncFailureLeavesOldFileIntact() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("rules.json")
        try Data("[\"old\"]".utf8).write(to: destination)

        let writer = AtomicRuleWriter(filesystem: FailingFilesystem(failAt: .fsync))
        #expect(throws: (any Error).self) {
            try writer.write(Data("[\"new\"]".utf8), to: destination)
        }

        #expect(try Data(contentsOf: destination) == Data("[\"old\"]".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["rules.json"])
    }

    @Test("replace failure leaves the prior committed file intact and cleans up the temp file")
    func replaceFailureLeavesOldFileIntact() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let destination = dir.appendingPathComponent("rules.json")
        try Data("[\"old\"]".utf8).write(to: destination)

        let writer = AtomicRuleWriter(filesystem: FailingFilesystem(failAt: .replace))
        #expect(throws: (any Error).self) {
            try writer.write(Data("[\"new\"]".utf8), to: destination)
        }

        #expect(try Data(contentsOf: destination) == Data("[\"old\"]".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == ["rules.json"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/AtomicRuleWriterTests test`
Expected: build fails — `cannot find type 'AtomicFilesystem' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Storage/AtomicRuleWriter.swift
import Foundation

/// Durability seam for AtomicRuleWriter. Production uses RealFilesystem; tests inject a
/// FailingFilesystem that throws at a chosen step, proving FR-05's guarantee (old file stays
/// intact and loadable on any failure) without needing to crash the process mid-write.
protocol AtomicFilesystem: Sendable {
    func write(_ data: Data, to url: URL) throws
    func fsync(atPath path: String) throws
    func replace(_ destination: URL, with tempURL: URL) throws
}

struct RealFilesystem: AtomicFilesystem {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Raw POSIX `open` + `F_FULLFSYNC` (full device flush, not just the weaker default
    /// `fsync` buffering guarantee); always closes the fd, including on the throw path.
    func fsync(atPath path: String) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else {
            throw AtomicRuleWriter.WriteError.fsyncFailed(errno: errno)
        }
        defer { close(fd) }

        let result = fcntl(fd, F_FULLFSYNC)
        if result != 0 {
            throw AtomicRuleWriter.WriteError.fsyncFailed(errno: errno)
        }
    }

    func replace(_ destination: URL, with tempURL: URL) throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
    }
}

/// Writes compiled rule JSON so that a reader (a Content Blocker extension, or this app on
/// next launch) never observes a partial or corrupted file — even across a crash or power
/// loss mid-write.
///
/// Sequence: write to a temp file in the same directory → fsync → rename over the target.
/// `rename(2)` is atomic on APFS for same-volume moves, so the reader either sees the old
/// file or the fully-written new one, never something in between.
///
/// Maps to FR-05 (atomic write; rollback to last-good on failure).
/// Target: main app ONLY. `write` is `nonisolated` — see Task 3's note on
/// SWIFT_DEFAULT_ACTOR_ISOLATION.
struct AtomicRuleWriter {
    enum WriteError: Error, Equatable {
        case fsyncFailed(errno: Int32)
        case renameFailed(errno: Int32)
    }

    private let filesystem: AtomicFilesystem

    init(filesystem: AtomicFilesystem = RealFilesystem()) {
        self.filesystem = filesystem
    }

    /// Writes `data` to `destinationURL`, replacing any existing file atomically.
    /// On failure, the destination file is left untouched (old contents still readable) —
    /// callers should treat a thrown error as "keep last-good rules," per FR-05.
    nonisolated func write(_ data: Data, to destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        try filesystem.write(data, to: tempURL)

        do {
            try filesystem.fsync(atPath: tempURL.path)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        do {
            try filesystem.replace(destinationURL, with: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WriteError.renameFailed(errno: errno)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/AtomicRuleWriterTests test`
Expected: `** TEST SUCCEEDED **`, 3 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Storage/AtomicRuleWriter.swift ADBLXTests/Filtering/AtomicRuleWriterTests.swift
git commit -m "feat: add AtomicRuleWriter with fault-injectable filesystem seam"
```

---

### Task 9: ReloadCoordinator

**Files:**
- Create: `ADBLX/Filtering/Deployment/ReloadCoordinator.swift`
- Test: `ADBLXTests/Filtering/ReloadCoordinatorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `actor ReloadCoordinator { struct ReloadResult { var extensionIdentifier: String;
  var success: Bool; var error: Error?; var duration: TimeInterval }; func
  reload(extensionIdentifier: String) async -> ReloadResult; func
  reload(extensionIdentifiers: [String]) async -> [ReloadResult] }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/ReloadCoordinatorTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("ReloadCoordinator")
struct ReloadCoordinatorTests {
    @Test("returns a failed result with a captured error for an unknown extension identifier")
    func failsGracefullyForUnknownIdentifier() async {
        let coordinator = ReloadCoordinator()
        let result = await coordinator.reload(extensionIdentifier: "com.ADBLX.does-not-exist")

        #expect(result.extensionIdentifier == "com.ADBLX.does-not-exist")
        #expect(result.success == false)
        #expect(result.error != nil)
    }

    @Test("reload(extensionIdentifiers:) returns one result per identifier, in order")
    func reloadsMultipleInOrder() async {
        let coordinator = ReloadCoordinator()
        let results = await coordinator.reload(extensionIdentifiers: ["a", "b"])
        #expect(results.map(\.extensionIdentifier) == ["a", "b"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/ReloadCoordinatorTests test`
Expected: build fails — `cannot find 'ReloadCoordinator' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Deployment/ReloadCoordinator.swift
import Foundation
import SafariServices

/// The ONLY call site in the app for `SFContentBlockerManager.reloadContentBlocker`.
/// Every deployment path (manual update, automatic update, rollback) must go through this
/// type — never call `SFContentBlockerManager` directly elsewhere.
///
/// Maps to FR-06 (reload affected extensions after compile; report per-extension status).
/// Target: main app ONLY (extensions cannot reload themselves or each other).
actor ReloadCoordinator {
    struct ReloadResult {
        var extensionIdentifier: String
        var success: Bool
        var error: Error?
        /// Wall-clock time for the reload call. Cheap to capture now, and gives FR-06
        /// diagnostics (e.g. "reload of X is taking longer than expected") without a
        /// separate instrumentation pass later.
        var duration: TimeInterval
    }

    enum ReloadError: Error {
        case underlying(Error)
    }

    /// Reloads a single Content Blocker extension by its bundle identifier.
    /// Errors are returned, never swallowed — callers (typically a view model) surface
    /// "enable in Settings"-style messaging per FR-06's UI requirement.
    func reload(extensionIdentifier: String) async -> ReloadResult {
        let start = Date()
        return await withCheckedContinuation { continuation in
            SFContentBlockerManager.reloadContentBlocker(withIdentifier: extensionIdentifier) { error in
                continuation.resume(returning: ReloadResult(
                    extensionIdentifier: extensionIdentifier,
                    success: error == nil,
                    error: error,
                    duration: Date().timeIntervalSince(start)
                ))
            }
        }
    }

    /// Reloads multiple extensions and returns per-extension results — never a single
    /// aggregated boolean, since FR-06 requires reporting per-extension status in the UI.
    func reload(extensionIdentifiers: [String]) async -> [ReloadResult] {
        var results: [ReloadResult] = []
        for identifier in extensionIdentifiers {
            results.append(await reload(extensionIdentifier: identifier))
        }
        return results
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/ReloadCoordinatorTests test`
Expected: `** TEST SUCCEEDED **`, 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Deployment/ReloadCoordinator.swift ADBLXTests/Filtering/ReloadCoordinatorTests.swift
git commit -m "feat: add ReloadCoordinator as sole SFContentBlockerManager call site"
```

---

### Task 10: FilterPipeline orchestrator

**Files:**
- Create: `ADBLX/Filtering/Pipeline/FilterPipeline.swift`
- Test: `ADBLXTests/Filtering/FilterPipelineTests.swift`

**Interfaces:**
- Consumes: `FilterValidator` (Task 4), `RuleCompiler`/`PassthroughRuleCompiler` (Task 5),
  `RulePartitioner`/`PassthroughAdsPartitioner`/`PartitionedRules` (Task 6), `FilterStore`
  (Task 7), `AtomicRuleWriter` (Task 8), `ReloadCoordinator`/`ReloadCoordinator.ReloadResult`
  (Task 9), `InstalledFilter`, `RuleStatistics`, `Checksum.sha256Hex` (Tasks 2–3).
- Produces: `actor FilterPipeline { init(validator: FilterValidator, compiler: RuleCompiler,
  partitioner: RulePartitioner, store: FilterStore, writer: AtomicRuleWriter, reloader:
  ReloadCoordinator); func install(filterID: String, source: Data) async throws ->
  PipelineResult; func installBundledSnapshotIfNeeded() async throws -> PipelineResult }`,
  `struct PipelineResult { var filterID: String; var compiledRuleCount: Int; var
  installedRuleCount: Int; var compileStatistics: RuleStatistics; var reloadResults:
  [ReloadCoordinator.ReloadResult] }`, `enum FilterPipelineError: Error { case
  bundledSnapshotMissing }`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/FilterPipelineTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterPipeline")
struct FilterPipelineTests {
    private func makePipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: "com.ADBLX.ADBLX.AdsBlocker"),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }

    @Test("installs the bundled Ads snapshot end-to-end and returns a populated PipelineResult")
    func installsBundledSnapshotEndToEnd() async throws {
        let pipeline = makePipeline()
        let result = try await pipeline.installBundledSnapshotIfNeeded()

        #expect(result.filterID == "ads-bundled")
        #expect(result.compiledRuleCount == 70)
        #expect(result.installedRuleCount == 70)
        #expect(result.compileStatistics.rulesLoaded == 70)
        #expect(result.reloadResults.count == 1)
        #expect(result.reloadResults[0].extensionIdentifier == "com.ADBLX.ADBLX.AdsBlocker")

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let writtenData = try Data(contentsOf: compiledDir.appendingPathComponent("Ads.json"))
        let writtenRules = try JSONSerialization.jsonObject(with: writtenData) as? [Any]
        #expect(writtenRules?.count == 70)

        let metadataDir = try await store.directoryURL(.metadata)
        #expect(FileManager.default.fileExists(atPath: metadataDir.appendingPathComponent("installed_filters.json").path))
        #expect(FileManager.default.fileExists(atPath: metadataDir.appendingPathComponent("statistics.json").path))
    }

    @Test("throws when the source fails validation")
    func throwsOnInvalidSource() async {
        let pipeline = makePipeline()
        await #expect(throws: FilterValidator.ValidationError.self) {
            _ = try await pipeline.install(filterID: "bad", source: Data())
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilterPipelineTests test`
Expected: build fails — `cannot find 'FilterPipeline' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// ADBLX/Filtering/Pipeline/FilterPipeline.swift
import Foundation

/// Sole orchestrator of the rule pipeline: validate → compile → partition → atomic write →
/// persist metadata → reload. Every other Filtering/ type stays single-purpose; this is the
/// one place that knows the sequence, owns timing, and will own progress/cancellation/retry
/// as those needs arrive.
///
/// Target: main app ONLY.
actor FilterPipeline {
    private let validator: FilterValidator
    private let compiler: RuleCompiler
    private let partitioner: RulePartitioner
    private let store: FilterStore
    private let writer: AtomicRuleWriter
    private let reloader: ReloadCoordinator

    init(
        validator: FilterValidator,
        compiler: RuleCompiler,
        partitioner: RulePartitioner,
        store: FilterStore,
        writer: AtomicRuleWriter,
        reloader: ReloadCoordinator
    ) {
        self.validator = validator
        self.compiler = compiler
        self.partitioner = partitioner
        self.store = store
        self.writer = writer
        self.reloader = reloader
    }

    /// Runs the full pipeline for one filter source and returns a summary of what happened —
    /// callers (ViewModel, logging, future Metrics/UI status) read this one object instead of
    /// interrogating each stage afterward.
    func install(filterID: String, source: Data) async throws -> PipelineResult {
        try validator.validate(source)
        let compiled = try await compiler.compile(source: source, filterID: filterID)
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

        // Sprint 1: single-entry overwrite (only the Ads filter is pipeline-managed this
        // sprint). Multi-filter accumulation arrives with the manifest-driven flow in Part 10.
        let installedFilter = InstalledFilter(
            id: filterID,
            group: .ads,
            installedVersion: "bundled-snapshot",
            checksumSHA256: Checksum.sha256Hex(of: source),
            lastUpdated: compiled.statistics.lastUpdated,
            ruleCount: compiled.ruleCount
        )
        let installedFiltersData = try JSONEncoder().encode([installedFilter])
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadResults = await reloader.reload(extensionIdentifiers: extensionIdentifiers)

        return PipelineResult(
            filterID: filterID,
            compiledRuleCount: compiled.ruleCount,
            installedRuleCount: installedRuleCount,
            compileStatistics: compiled.statistics,
            reloadResults: reloadResults
        )
    }

    /// Sprint 1: always (re)installs from the bundled snapshot on every call — "IfNeeded"
    /// becomes meaningful once Part 10 adds version comparison against a fetched manifest.
    /// Reinstalling identical content on every launch is harmless (same bytes, same reload).
    func installBundledSnapshotIfNeeded() async throws -> PipelineResult {
        guard let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
            throw FilterPipelineError.bundledSnapshotMissing
        }
        let data = try Data(contentsOf: bundledURL)
        return try await install(filterID: "ads-bundled", source: data)
    }
}

struct PipelineResult {
    var filterID: String
    var compiledRuleCount: Int
    var installedRuleCount: Int
    var compileStatistics: RuleStatistics
    var reloadResults: [ReloadCoordinator.ReloadResult]
}

enum FilterPipelineError: Error {
    case bundledSnapshotMissing
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/FilterPipelineTests test`
Expected: `** TEST SUCCEEDED **`, 2 tests passed

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Pipeline/FilterPipeline.swift ADBLXTests/Filtering/FilterPipelineTests.swift
git commit -m "feat: add FilterPipeline orchestrator tying stages into install()"
```

---

### Task 11: Retire ContentBlockerBootstrap into the pipeline

**Files:**
- Create: `ADBLX/AppCompositionRoot.swift`
- Modify: `ADBLX/ContentBlockerBootstrap.swift` (full rewrite)
- Modify: `ADBLX/ADBLXApp.swift`
- Modify: `ADBLXTests/ContentBlockerBootstrapTests.swift` (full rewrite)

**Interfaces:**
- Consumes: `FilterPipeline`, `FilterValidator`, `PassthroughRuleCompiler`,
  `PassthroughAdsPartitioner`, `FilterStore`, `AtomicRuleWriter`, `ReloadCoordinator` (Tasks
  4–10), `AppGroup.identifier` (existing).
- Produces: `enum AppCompositionRoot { static let adsExtensionIdentifier: String; static func
  makeFilterPipeline() -> FilterPipeline }`, `enum ContentBlockerBootstrap { @discardableResult
  nonisolated static func ensureInitialRulesInstalled(pipeline: FilterPipeline) async -> Bool
  }`.

This task removes `ContentBlockerBootstrap`'s two Sprint 0 methods
(`ensureInitialRulesInstalled()` / `reloadIfNeeded()`, which called `FileManager` and
`SFContentBlockerManager` directly) and replaces them with one method that delegates to
`FilterPipeline`, satisfying Part 3 ("no other type touches these paths directly") and Part 5
("grep for direct calls outside ReloadCoordinator returns zero results").

- [ ] **Step 1: Write the failing test for the new bootstrap signature**

```swift
// ADBLXTests/ContentBlockerBootstrapTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("installs the bundled snapshot via the pipeline and reports success")
    func installsBundledSnapshot() async throws {
        let pipeline = AppCompositionRoot.makeFilterPipeline()
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
        #expect(result == true)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Ads.json").path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/ContentBlockerBootstrapTests test`
Expected: build fails — `cannot find 'AppCompositionRoot' in scope` (and/or `ensureInitialRulesInstalled(pipeline:)` has no matching signature)

- [ ] **Step 3: Write the composition root**

```swift
// ADBLX/AppCompositionRoot.swift
import Foundation

/// The single place that constructs a FilterPipeline with its real, concrete dependencies.
/// FilterPipeline itself never constructs its own dependencies — everything is injected —
/// so swapping PassthroughRuleCompiler for a SafariConverterLib-backed implementation (post
/// ADR-0001) only ever changes this file.
enum AppCompositionRoot {
    static let adsExtensionIdentifier = "com.ADBLX.ADBLX.AdsBlocker"

    static func makeFilterPipeline() -> FilterPipeline {
        FilterPipeline(
            validator: FilterValidator(),
            compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
            store: FilterStore(appGroupIdentifier: AppGroup.identifier),
            writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator()
        )
    }
}
```

- [ ] **Step 4: Rewrite ContentBlockerBootstrap**

```swift
// ADBLX/ContentBlockerBootstrap.swift
import Foundation
import OSLog

/// Sprint 0 had this type copy bundled JSON and call SFContentBlockerManager directly.
/// Sprint 1 replaces both with a single delegation into FilterPipeline, so FilterStore and
/// ReloadCoordinator become (and stay) the only types touching the App Group filesystem and
/// SFContentBlockerManager respectively.
enum ContentBlockerBootstrap {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "Bootstrap"
    )

    /// `nonisolated`: called from a detached, off-main-actor Task at launch — see the plan's
    /// Global Constraints note on SWIFT_DEFAULT_ACTOR_ISOLATION.
    @discardableResult
    nonisolated static func ensureInitialRulesInstalled(pipeline: FilterPipeline) async -> Bool {
        do {
            let result = try await pipeline.installBundledSnapshotIfNeeded()
            logger.info("Filter pipeline installed \(result.installedRuleCount) rule(s) for \(result.filterID, privacy: .public)")
            return true
        } catch {
            logger.error("Filter pipeline install failed: \(error, privacy: .public)")
            return false
        }
    }
}
```

- [ ] **Step 5: Wire ADBLXApp to construct the pipeline and call the new bootstrap**

```swift
// ADBLX/ADBLXApp.swift
import SwiftUI
import MetricKit

@main
struct ADBLXApp: App {
    private let metricsSubscriber = MetricsSubscriber()
    private let filterPipeline = AppCompositionRoot.makeFilterPipeline()

    init() {
        MXMetricManager.shared.add(metricsSubscriber)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ADBLXTests/ContentBlockerBootstrapTests test`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Grep-verify Part 3 and Part 5 acceptance criteria now hold**

Run: `cd /Users/sreeharshag/Work/ADBLX && grep -rn "containerURL(forSecurityApplicationGroupIdentifier" ADBLX --include="*.swift" | grep -v "Filtering/Storage/FilterStore.swift"`
Expected: no output (only `FilterStore` touches the App Group container directly)

Run: `cd /Users/sreeharshag/Work/ADBLX && grep -rn "SFContentBlockerManager" ADBLX --include="*.swift" | grep -v "Filtering/Deployment/ReloadCoordinator.swift"`
Expected: no output (only `ReloadCoordinator` calls `SFContentBlockerManager` directly)

- [ ] **Step 8: Commit**

```bash
git add ADBLX/AppCompositionRoot.swift ADBLX/ContentBlockerBootstrap.swift ADBLX/ADBLXApp.swift ADBLXTests/ContentBlockerBootstrapTests.swift
git commit -m "feat: route launch bootstrap through FilterPipeline via AppCompositionRoot"
```

---

### Task 12: Update AdsBlocker extension read path to Compiled/

**Files:**
- Modify: `Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift`

**Interfaces:**
- Consumes: nothing new — this is a one-line path change so the extension reads what
  `FilterPipeline` (Task 10) actually writes.

This is the integration fix called out in the plan's Global Constraints: the extension
currently reads `Rules/Ads.json`, but `FilterStore`/`FilterPipeline` write to
`Compiled/Ads.json`. Without this change, the new pipeline writes rules the extension never
looks for and it silently falls back to the stale bundled copy.

- [ ] **Step 1: Update the App Group read path**

```swift
// Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift
import Foundation
import OSLog

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    // Bundle.main inside an app extension resolves to the extension's own bundle ID
    // (com.ADBLX.ADBLX.AdsBlocker), not the app's — hardcode the shared app subsystem
    // so Console.app/log stream filtering by "com.ADBLX.ADBLX" catches both.
    private static let logger = Logger(subsystem: "com.ADBLX.ADBLX", category: "AppGroup")

    func beginRequest(with context: NSExtensionContext) {
        guard let url = Self.rulesURL() else {
            context.cancelRequest(withError: CocoaError(.fileNoSuchFile))
            return
        }

        guard let itemProvider = NSItemProvider(contentsOf: url) else {
            context.cancelRequest(withError: CocoaError(.fileReadCorruptFile))
            return
        }

        let item = NSExtensionItem()
        item.attachments = [itemProvider]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    private static func rulesURL() -> URL? {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            // Sprint 1: FilterStore/FilterPipeline write compiled output to Compiled/<Group>.json,
            // not the Sprint 0 Rules/Ads.json path.
            let appGroupURL = containerURL.appendingPathComponent("Compiled/Ads.json")
            if FileManager.default.fileExists(atPath: appGroupURL.path) {
                logger.info("Using App Group rules (\(ruleCount(at: appGroupURL)) rules)")
                return appGroupURL
            }
        }
        let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json")
        logger.info("Falling back to bundled rules (\(bundledURL.map { ruleCount(at: $0) } ?? 0) rules)")
        return bundledURL
    }

    private static func ruleCount(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return 0
        }
        return rules.count
    }
}
```

- [ ] **Step 2: Verify the extension target still builds**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manually verify end-to-end on the simulator**

Run the app in the simulator (Xcode Run, or `xcrun simctl launch booted com.ADBLX.ADBLX` after install), then check:

Run: `xcrun simctl get_app_container booted com.ADBLX.ADBLX data`
Then inspect `<container>/Shared/AppGroup/group.com.ADBLX.shared/Compiled/Ads.json` exists and contains 70 rule objects — confirms the app-launch pipeline call actually reaches the location the extension now reads from.

- [ ] **Step 4: Commit**

```bash
git add Extensions/ADBLXAdsBlocker/ContentBlockerRequestHandler.swift
git commit -m "fix: read compiled Ads rules from Compiled/ to match FilterPipeline output"
```

---

### Task 13: Logging policy document

**Files:**
- Create: `docs/Architecture/Logging.md`

**Interfaces:**
- Produces: nothing code-facing — this is the authoritative doc every `Filtering/` file's
  comments (Tasks 2–10) already cite by path.

- [ ] **Step 1: Write the policy doc**

```markdown
# Logging Policy

Applies to all logging, diagnostics, crash reports, and any future MetricKit payload in
ADBLX — with no exception for debug builds.

## Allowed

- Counts (e.g. rules loaded, duplicates removed, unsupported-rule count)
- Durations (e.g. compile time, reload time)
- Sizes (e.g. memory estimate in bytes, file size)
- Versions (e.g. filter version string, manifest version)
- Checksums (e.g. SHA-256 hex digest)

## Forbidden

- URLs
- Domains
- Hostnames
- Rule text / rule bodies
- Cookies
- Headers
- Query strings

If you're tempted to log "which rules were unsupported," log the *count* of unsupported rules,
never their content. `RuleStatistics` (`ADBLX/Filtering/Models/RuleStatistics.swift`) is the
canonical example of a type that only ever holds allowed fields — use it as the template for
any future diagnostics type.
```

- [ ] **Step 2: Commit**

```bash
git add docs/Architecture/Logging.md
git commit -m "docs: add Logging.md, the policy already cited throughout Filtering/"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-07-17-sprint1-rule-pipeline-design.md`):
- §2.1 FilterPipeline + DI → Task 10 (and Task 11's `AppCompositionRoot`). ✓
- §2.2 Normalize footnote → captured in this plan's Architecture line and Task 10's pipeline
  sequence (validate → compile → partition, no normalize stage). ✓
- §2.3 ContentBlockerBootstrap retirement → Task 11. ✓
- §2.4 Bundled fixtures (none new; reuse `blockerList.json`; in-memory invalid cases) → Task 5
  reuses no file (constructs Data inline), Task 10/11 reuse the existing bundled
  `blockerList.json`, Task 4's invalid cases are in-memory. ✓
- §2.5 Logging.md → Task 13. ✓
- §2.6 AtomicFilesystem seam → Task 8. ✓
- §2.7 DI boundary → folded into Task 10's initializer design. ✓
- Part 2 Models + round-trip tests → Task 2. ✓
- Part 3 FilterStore, sole-owner enforcement → Task 7 (type) + Task 11 Step 7 (grep proof). ✓
- Part 4 AtomicRuleWriter, kill-during-write → Task 8. ✓
- Part 5 ReloadCoordinator, sole-call-site enforcement → Task 9 (type) + Task 11 Step 7 (grep
  proof). ✓
- Part 6 RuleCompiler → Task 5. ✓
- Part 7 RulePartitioner, Ads-only scope → Task 6. ✓
- Part 8 Metadata (installed_filters.json, statistics.json; checksum wired not verified) →
  Task 10's `install()`. `manifest.json` is explicitly out of scope this sprint (no manifest
  exists until Part 10's networking lands) — not a gap, matches the plan's own deferral.
- Part 9 Validation → Task 4. ✓
- Integration gap found during planning (extension read path) → Task 12. ✓

**Placeholder scan:** no TBD/TODO markers; every step has complete, runnable code or an exact
command with expected output.

**Type consistency:** `PipelineResult`, `ReloadCoordinator.ReloadResult`, `PartitionedRules`,
`InstalledFilter`, `RuleStatistics`, `FilterGroup`, `AtomicFilesystem`/`RealFilesystem` field
names and types are identical everywhere they're referenced across Tasks 2–12 (cross-checked
against each task's Interfaces block).

---

Plan complete and saved to `docs/superpowers/plans/2026-07-17-sprint1-rule-pipeline.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
