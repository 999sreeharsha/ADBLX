# Sprint 2: Update Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Feed Sprint 1's rule pipeline from the network: fetch `manifest.json`, diff
against installed filters, download and SHA-256-verify changed filters, install them
transactionally through `FilterPipeline`, and roll back the entire batch on any
failure — all without breaking any Sprint 1 caller or duplicating Sprint 1's models.

**Architecture:** A new `Filtering/Updates/` module (flat, six files) owns manifest
fetch/cache, filter download, and orchestration. It consumes Sprint 1's
`FilterManifest`, `InstalledFilter`, and `Checksum` as-is, and drives Sprint 1's
`FilterPipeline`/`FilterStore` through two small additive changes to those two types.
`ReloadCoordinator` is untouched. Networking is testable without a real server via a
tiny `HTTPSession` protocol `URLSession` conforms to.

**Tech Stack:** Swift 5.0, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`),
Swift Concurrency (actors, `async`/`await`), `URLSession`/`URLRequest`/`HTTPURLResponse`,
CryptoKit (via existing `Checksum`), XcodeGen `syncedFolder` targets (no `project.yml`
edits needed — new files under `ADBLX/` and `ADBLXTests/` attach automatically).

## Global Constraints

- **Target placement:** everything in this plan lives in the main app (`ADBLX`) target
  only — same rule as Sprint 1. Nothing goes into `Packages/ADBLXShared` or any Content
  Blocker extension target.
- **Logging policy:** any logging/statistics may only ever capture counts, durations,
  sizes, versions, checksums — never rule bodies, domains, hostnames, or URLs. No
  exception for debug builds. (`docs/Architecture/Logging.md`)
- **Off-main-thread execution:** `project.yml` sets `SWIFT_DEFAULT_ACTOR_ISOLATION:
  MainActor` on the `ADBLX` target. Non-actor declarations default to `@MainActor`
  unless marked `nonisolated`. `Checksum.verify` must be `nonisolated` (it extends an
  already-`nonisolated` enum). `ManifestClient`, `FilterDownloadClient`,
  `ManifestStore`, and `UpdateCoordinator` are declared as `actor` types, which are
  their own isolation domain — no `nonisolated` annotation needed on those.
- **Test framework:** Swift Testing, not XCTest — `@Suite`, `@Test`, `#expect`,
  `await #expect(throws:)` for async throwing calls.
- **Simulator destination:** every `xcodebuild` command in this plan uses
  `-destination "id=$(Scripts/find-simulator-udid.sh)"` (already created in Sprint 1)
  instead of a hardcoded device name.
- **No real network in tests:** every test in this plan uses a mock `HTTPSession` or
  operates on local temp files. No test may reach an actual server.
- **Serialize suites that share App Group file paths:** Swift Testing runs tests within
  a suite in parallel by default. Any suite where multiple tests read-modify-write the
  *same* fixed App Group path (`installed_filters.json`, `Compiled/Ads.json`,
  `manifest.json`) must be declared `@Suite(.serialized, "Name")` to avoid racing on
  that shared file within the suite — a lost-update race here is a real flake, not a
  hypothetical. `FilterPipelineTests`, `FilterStoreTests`, `ManifestStoreTests`, and
  `UpdateCoordinatorTests` all need this; suites that only use per-test temp files or
  in-memory mocks (`UpdatePlannerTests`, `ManifestClientTests`,
  `FilterDownloadClientTests`, `HTTPSessionTests`) don't. **This does not eliminate
  racing *across* those four suites** — `.serialized` only prevents concurrent test
  execution within one suite, and all four target the same real App Group container
  (`AppGroup.identifier` / `group.com.ADBLX.shared`, the only App Group ID actually
  registered in this project's entitlements — an additional test-only App Group ID is
  not an available fix without a provisioning change). Task 10's full-suite run is the
  only place this residual cross-suite race is reachable (every other task's
  `-only-testing:` command runs one suite at a time and is race-free); see Task 10 for
  how this is handled.
- **New files attach automatically:** all new files in this plan go under `ADBLX/` or
  `ADBLXTests/`, both `syncedFolder` targets in `project.yml` — run `xcodegen generate`
  before building, but no manual `project.yml` edits are needed.
- **Design authority:** `docs/superpowers/specs/2026-07-18-sprint2-update-pipeline-design.md`
  is the architectural contract for this plan. If an implementation detail here seems
  to conflict with it, the design doc wins — flag it rather than silently diverging.

---

### Task 1: `HTTPSession` protocol + JSON-decodable manifest fixture helper

**Files:**
- Create: `ADBLX/Filtering/Updates/HTTPSession.swift`
- Test: `ADBLXTests/Filtering/Updates/HTTPSessionTests.swift`

**Interfaces:**
- Produces: `protocol HTTPSession: Sendable { func data(for request: URLRequest) async throws -> (Data, URLResponse) }`, `extension URLSession: HTTPSession {}`. Every later networking task (`ManifestClient`, `FilterDownloadClient`) and their tests depend on this protocol and on the `MockHTTPSession` test helper this task defines.

- [ ] **Step 1: Write the failing test for `MockHTTPSession`**

```swift
// ADBLXTests/Filtering/Updates/HTTPSessionTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("HTTPSession")
struct HTTPSessionTests {
    @Test("MockHTTPSession returns the canned response for a matching URL")
    func mockReturnsCannedResponse() async throws {
        let url = URL(string: "https://example.com/manifest.json")!
        let responseData = Data("{\"key\":\"value\"}".utf8)
        let httpResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let mock = MockHTTPSession(responses: [url: .success((responseData, httpResponse))])

        let (data, response) = try await mock.data(for: URLRequest(url: url))

        #expect(data == responseData)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("MockHTTPSession throws the canned error for a matching URL")
    func mockThrowsCannedError() async {
        let url = URL(string: "https://example.com/manifest.json")!
        let mock = MockHTTPSession(responses: [url: .failure(URLError(.timedOut))])

        await #expect(throws: URLError.self) {
            _ = try await mock.data(for: URLRequest(url: url))
        }
    }

    @Test("MockHTTPSession throws for an unregistered URL")
    func mockThrowsForUnknownURL() async {
        let mock = MockHTTPSession(responses: [:])
        await #expect(throws: MockHTTPSession.UnregisteredURL.self) {
            _ = try await mock.data(for: URLRequest(url: URL(string: "https://example.com/other.json")!))
        }
    }
}
```

`MockHTTPSession` doesn't exist yet — this test is written against the interface this
task is about to create in the same file as `HTTPSession` itself (test-target-visible
helper, not production code shipped to users, but living in the main target so both
`ManifestClientTests` and `FilterDownloadClientTests` in later tasks can reuse it via
`@testable import ADBLX`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/HTTPSessionTests test`
Expected: FAIL — `HTTPSession`/`MockHTTPSession` not found in scope.

- [ ] **Step 3: Write `HTTPSession` and `MockHTTPSession`**

```swift
// ADBLX/Filtering/Updates/HTTPSession.swift
import Foundation

/// Thin seam over `URLSession.data(for:)` so `ManifestClient`/`FilterDownloadClient`
/// can be unit-tested with canned responses — no real network, no `URLProtocol` stubbing.
protocol HTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

/// Test/debug helper: returns a canned `Result` keyed by exact request URL.
/// Lives in the main target (not the test target) so it's reusable across every
/// `Updates/` test suite via `@testable import ADBLX`, matching how production types
/// in this module are structured.
final class MockHTTPSession: HTTPSession, @unchecked Sendable {
    struct UnregisteredURL: Error {
        var url: URL
    }

    private var responses: [URL: Result<(Data, URLResponse), Error>]

    init(responses: [URL: Result<(Data, URLResponse), Error>]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let result = responses[url] else {
            throw UnregisteredURL(url: request.url ?? URL(string: "about:blank")!)
        }
        return try result.get()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/HTTPSessionTests test`
Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/HTTPSession.swift ADBLXTests/Filtering/Updates/HTTPSessionTests.swift
git commit -m "feat: add HTTPSession protocol and MockHTTPSession test helper"
```

---

### Task 2: `Checksum.verify(fileURL:against:)`

**Files:**
- Modify: `ADBLX/Filtering/Utilities/Checksum.swift`
- Test: `ADBLXTests/Filtering/ChecksumTests.swift` (existing — extend)

**Interfaces:**
- Consumes: `Checksum.sha256Hex(of:) -> String` (existing, unchanged).
- Produces: `nonisolated static func Checksum.verify(fileURL: URL, against expectedHex: String) throws`, `enum ChecksumError: Error, Equatable { case mismatch(expected: String, actual: String) }`. `UpdateCoordinator` (Task 9) calls this on every downloaded filter before any install.

- [ ] **Step 1: Write the failing tests**

```swift
// Append to ADBLXTests/Filtering/ChecksumTests.swift, inside the existing ChecksumTests struct
    @Test("verify passes when the file's hash matches the expected hex digest")
    func verifyPassesOnMatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("payload.txt")
        try Data("abc".utf8).write(to: fileURL)

        try Checksum.verify(fileURL: fileURL, against: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("verify throws ChecksumError.mismatch when the file's hash doesn't match")
    func verifyThrowsOnMismatch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("payload.txt")
        try Data("abc".utf8).write(to: fileURL)

        #expect(throws: ChecksumError.mismatch(
            expected: "0000000000000000000000000000000000000000000000000000000000000000",
            actual: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )) {
            try Checksum.verify(
                fileURL: fileURL,
                against: "0000000000000000000000000000000000000000000000000000000000000000"
            )
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/ChecksumTests test`
Expected: FAIL — `Checksum.verify` and `ChecksumError` not found in scope.

- [ ] **Step 3: Implement `verify` and `ChecksumError`**

```swift
// ADBLX/Filtering/Utilities/Checksum.swift — full replacement
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

    /// Reads `fileURL` and compares its SHA-256 against `expectedHex`. Callers holding a
    /// `URL` (e.g. a downloaded filter's temp file) never need to load the whole file into
    /// `Data` themselves just to verify it — this does that internally.
    nonisolated static func verify(fileURL: URL, against expectedHex: String) throws {
        let data = try Data(contentsOf: fileURL)
        let actual = sha256Hex(of: data)
        guard actual == expectedHex else {
            throw ChecksumError.mismatch(expected: expectedHex, actual: actual)
        }
    }
}

enum ChecksumError: Error, Equatable {
    case mismatch(expected: String, actual: String)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/ChecksumTests test`
Expected: `** TEST SUCCEEDED **`, 3 tests passed (1 existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Utilities/Checksum.swift ADBLXTests/Filtering/ChecksumTests.swift
git commit -m "feat: add Checksum.verify(fileURL:against:) for downloaded filter integrity checks"
```

---

### Task 3: `UpdateAction`, `UpdatePlan`, `UpdatePlanner`

**Files:**
- Create: `ADBLX/Filtering/Updates/UpdatePlan.swift`
- Test: `ADBLXTests/Filtering/Updates/UpdatePlannerTests.swift`

**Interfaces:**
- Consumes: `FilterManifest`, `FilterManifest.Entry` (id, name, group, sourceURL,
  version, checksumSHA256, ruleCount, enabledByDefault, premium — all existing, from
  `ADBLX/Filtering/Models/FilterManifest.swift`), `InstalledFilter` (id, group,
  installedVersion, checksumSHA256, lastUpdated, ruleCount — existing, from
  `ADBLX/Filtering/Models/InstalledFilter.swift`), `FilterGroup` (existing enum:
  `.ads`, `.privacy`, `.annoyances`, `.regional`).
- Produces: `enum UpdateAction: Equatable`, `struct UpdatePlan: Equatable { var actions:
  [UpdateAction] }`, `enum UpdatePlanner { static func plan(manifest: FilterManifest,
  installed: [InstalledFilter]) -> UpdatePlan }`. `UpdateCoordinator` (Task 9) calls
  `UpdatePlanner.plan` and filters `plan.actions` for `.install` cases to build its
  download batch.

- [ ] **Step 1: Write the failing tests**

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

    @Test("new manifest entry with no installed counterpart produces .install")
    func newEntryProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.install(entry(id: "easylist"))])
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
        #expect(plan.actions == [.install(entry(id: "easylist", version: "2026-07-19"))])
    }

    @Test("changed checksum on an installed entry produces .install")
    func changedChecksumProducesInstall() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easylist", checksum: "checksum-b")])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [installed(id: "easylist", checksum: "checksum-a")])
        #expect(plan.actions == [.install(entry(id: "easylist", checksum: "checksum-b"))])
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
        #expect(plan.actions == [.install(entry(id: "premium-list", version: "v2", premium: true))])
    }

    @Test("non-.ads group entry produces .unsupportedGroup")
    func nonAdsGroupProducesUnsupportedGroup() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry(id: "easyprivacy", group: .privacy)])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [.unsupportedGroup(entry(id: "easyprivacy", group: .privacy))])
    }

    @Test("second .ads entry needing install in the same plan produces .groupConflict")
    func secondAdsInstallInSamePlanProducesGroupConflict() {
        let manifest = FilterManifest(manifestVersion: "1", entries: [
            entry(id: "easylist"),
            entry(id: "peter-lowe", checksum: "checksum-c"),
        ])
        let plan = UpdatePlanner.plan(manifest: manifest, installed: [])
        #expect(plan.actions == [
            .install(entry(id: "easylist")),
            .groupConflict(entry(id: "peter-lowe", checksum: "checksum-c")),
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
Expected: FAIL — `UpdateAction`/`UpdatePlan`/`UpdatePlanner` not found in scope.

- [ ] **Step 3: Implement `UpdateAction`, `UpdatePlan`, `UpdatePlanner`**

```swift
// ADBLX/Filtering/Updates/UpdatePlan.swift
import Foundation

/// One outcome of diffing a fetched `FilterManifest` against the currently
/// `InstalledFilter`s. Pure data — `UpdateCoordinator` decides what to actually do with
/// each case; this type only describes what's true about each manifest entry.
enum UpdateAction: Equatable {
    /// New filter, or an installed filter whose version/checksum changed.
    case install(FilterManifest.Entry)
    /// Installed filter no longer present in the manifest.
    case remove(filterID: String)
    /// Installed, unchanged, still entitled — no action needed.
    case keep(filterID: String)
    /// Not installed, gated behind a purchase that doesn't exist yet (no StoreKit this sprint).
    case skipPremium(FilterManifest.Entry)
    /// Non-`.ads` group — `RulePartitioner` can only route `.ads` this sprint.
    case unsupportedGroup(FilterManifest.Entry)
    /// A second (or later) `.ads`-group entry in the same plan that would also need
    /// installing. `FilterPipeline`/`RulePartitioner` support only one compiled `.ads`
    /// output per install call this sprint, so only the first such entry becomes
    /// `.install`; the rest surface here instead of silently overwriting it.
    case groupConflict(FilterManifest.Entry)
}

struct UpdatePlan: Equatable {
    var actions: [UpdateAction]
}

/// Pure diff: no I/O, no async. Compares each manifest entry against the matching
/// `InstalledFilter` (by `id`) on `(version, checksumSHA256)`.
enum UpdatePlanner {
    static func plan(manifest: FilterManifest, installed: [InstalledFilter]) -> UpdatePlan {
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
        var manifestIDs = Set<String>()
        var actions: [UpdateAction] = []
        var groupsWithPendingInstall = Set<FilterGroup>()

        for entry in manifest.entries {
            manifestIDs.insert(entry.id)

            guard entry.group == .ads else {
                actions.append(.unsupportedGroup(entry))
                continue
            }

            if let existing = installedByID[entry.id] {
                if existing.installedVersion == entry.version && existing.checksumSHA256 == entry.checksumSHA256 {
                    actions.append(.keep(filterID: entry.id))
                } else if groupsWithPendingInstall.contains(entry.group) {
                    actions.append(.groupConflict(entry))
                } else {
                    actions.append(.install(entry))
                    groupsWithPendingInstall.insert(entry.group)
                }
            } else if entry.premium {
                actions.append(.skipPremium(entry))
            } else if groupsWithPendingInstall.contains(entry.group) {
                actions.append(.groupConflict(entry))
            } else {
                actions.append(.install(entry))
                groupsWithPendingInstall.insert(entry.group)
            }
        }

        for filter in installed where !manifestIDs.contains(filter.id) {
            actions.append(.remove(filterID: filter.id))
        }

        return UpdatePlan(actions: actions)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/UpdatePlannerTests test`
Expected: `** TEST SUCCEEDED **`, 10 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/UpdatePlan.swift ADBLXTests/Filtering/Updates/UpdatePlannerTests.swift
git commit -m "feat: add UpdatePlanner pure diff between manifest and installed filters"
```

---

### Task 4: `ManifestStore`

**Files:**
- Create: `ADBLX/Filtering/Updates/ManifestStore.swift`
- Test: `ADBLXTests/Filtering/Updates/ManifestStoreTests.swift`

**Interfaces:**
- Consumes: `FilterStore` (existing actor — `init(appGroupIdentifier:fileManager:)`,
  `func read(_ filename: String, in directory: Directory) async throws -> Data`,
  `func writeMetadata(_ data: Data, filename: String) async throws`), `AppGroup.identifier`
  (existing constant), `FilterManifest` (existing, `Codable`).
- Produces: `struct CachedManifest: Codable, Equatable { var manifest: FilterManifest;
  var etag: String? }`, `actor ManifestStore { init(filterStore: FilterStore); func
  load() async throws -> CachedManifest?; func save(_ manifest: FilterManifest, etag:
  String?) async throws }`. `UpdateCoordinator` (Task 9) calls `load()` before fetching
  and `save(_:etag:)` after a successful commit or a no-op-because-unchanged run.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/Updates/ManifestStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite(.serialized, "ManifestStore")
struct ManifestStoreTests {
    private func sampleManifest() -> FilterManifest {
        let entry = FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads,
            sourceURL: URL(string: "https://example.com/easylist.txt")!,
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
        return FilterManifest(manifestVersion: "1", entries: [entry])
    }

    @Test("load returns nil when nothing has been saved yet")
    func loadReturnsNilInitially() async throws {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: filterStore)

        // Ensure a clean slate: remove any manifest.json left by a previous run.
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))

        let cached = try await manifestStore.load()
        #expect(cached == nil)
    }

    @Test("save then load round-trips the manifest and ETag byte-for-byte")
    func saveThenLoadRoundTrips() async throws {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: filterStore)
        let manifest = sampleManifest()

        try await manifestStore.save(manifest, etag: "\"etag-value\"")
        let cached = try await manifestStore.load()

        #expect(cached == CachedManifest(manifest: manifest, etag: "\"etag-value\""))

        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
    }

    @Test("save with a nil ETag round-trips a nil ETag")
    func saveWithNilETagRoundTrips() async throws {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: filterStore)
        let manifest = sampleManifest()

        try await manifestStore.save(manifest, etag: nil)
        let cached = try await manifestStore.load()

        #expect(cached == CachedManifest(manifest: manifest, etag: nil))

        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/ManifestStoreTests test`
Expected: FAIL — `ManifestStore`/`CachedManifest` not found in scope.

- [ ] **Step 3: Implement `CachedManifest` and `ManifestStore`**

```swift
// ADBLX/Filtering/Updates/ManifestStore.swift
import Foundation

/// The cached manifest plus the HTTP ETag it was fetched with, persisted as one file.
/// ETag is transport metadata, not part of the manifest's meaning — kept as a sibling
/// field here rather than added to `FilterManifest` itself, so `FilterManifest` stays
/// representable from any source (bundle, disk fixture, import), not just the network.
struct CachedManifest: Codable, Equatable {
    var manifest: FilterManifest
    var etag: String?
}

/// Persists the cached manifest via `FilterStore`'s `Metadata` directory, consistent
/// with how `installed_filters.json` and `statistics.json` are already stored.
actor ManifestStore {
    private static let filename = "manifest.json"

    private let filterStore: FilterStore

    init(filterStore: FilterStore) {
        self.filterStore = filterStore
    }

    /// Returns `nil` if nothing has been cached yet — not an error condition.
    func load() async throws -> CachedManifest? {
        let data: Data
        do {
            data = try await filterStore.read(Self.filename, in: .metadata)
        } catch {
            return nil
        }
        return try JSONDecoder().decode(CachedManifest.self, from: data)
    }

    func save(_ manifest: FilterManifest, etag: String?) async throws {
        let cached = CachedManifest(manifest: manifest, etag: etag)
        let data = try JSONEncoder().encode(cached)
        try await filterStore.writeMetadata(data, filename: Self.filename)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/ManifestStoreTests test`
Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/ManifestStore.swift ADBLXTests/Filtering/Updates/ManifestStoreTests.swift
git commit -m "feat: add ManifestStore for persisting cached manifest + ETag"
```

---

### Task 5: `ManifestClient`

**Files:**
- Create: `ADBLX/Filtering/Updates/ManifestClient.swift`
- Test: `ADBLXTests/Filtering/Updates/ManifestClientTests.swift`

**Interfaces:**
- Consumes: `HTTPSession` (Task 1), `MockHTTPSession` (Task 1, test-only), `FilterManifest` (existing).
- Produces: `enum ManifestFetchResult: Equatable { case notModified; case
  updated(FilterManifest, etag: String?) }`, `enum ManifestClientError: Error, Equatable
  { case unexpectedStatusCode(Int); case invalidResponse }`, `actor ManifestClient {
  init(session: HTTPSession, endpoint: URL); func fetch(previousETag: String?) async
  throws -> ManifestFetchResult }`. `UpdateCoordinator` (Task 9) calls `fetch(previousETag:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/Updates/ManifestClientTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("ManifestClient")
struct ManifestClientTests {
    private let endpoint = URL(string: "https://example.com/manifest.json")!

    private func sampleManifestJSON() -> Data {
        let entry = FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads, sourceURL: URL(string: "https://example.com/easylist.txt")!,
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
        let manifest = FilterManifest(manifestVersion: "1", entries: [entry])
        return try! JSONEncoder().encode(manifest)
    }

    @Test("200 with valid JSON returns .updated with the decoded manifest and ETag")
    func returns200AsUpdated() async throws {
        let responseData = sampleManifestJSON()
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200, httpVersion: nil,
            headerFields: ["ETag": "\"v1\""]
        )!
        let session = MockHTTPSession(responses: [endpoint: .success((responseData, response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        let result = try await client.fetch(previousETag: nil)

        guard case .updated(let manifest, let etag) = result else {
            Issue.record("expected .updated")
            return
        }
        #expect(manifest.entries.first?.id == "easylist")
        #expect(etag == "\"v1\"")
    }

    @Test("304 returns .notModified")
    func returns304AsNotModified() async throws {
        let response = HTTPURLResponse(url: endpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        let result = try await client.fetch(previousETag: "\"v1\"")

        #expect(result == .notModified)
    }

    @Test("request includes If-None-Match when a previous ETag is supplied")
    func includesIfNoneMatchHeader() async throws {
        final class CapturingSession: HTTPSession, @unchecked Sendable {
            var capturedRequest: URLRequest?
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                capturedRequest = request
                let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        }
        let session = CapturingSession()
        let client = ManifestClient(session: session, endpoint: endpoint)

        _ = try await client.fetch(previousETag: "\"cached-etag\"")

        #expect(session.capturedRequest?.value(forHTTPHeaderField: "If-None-Match") == "\"cached-etag\"")
    }

    @Test("404 throws ManifestClientError.unexpectedStatusCode")
    func returns404Throws() async {
        let response = HTTPURLResponse(url: endpoint, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: ManifestClientError.unexpectedStatusCode(404)) {
            _ = try await client.fetch(previousETag: nil)
        }
    }

    @Test("500 throws ManifestClientError.unexpectedStatusCode")
    func returns500Throws() async {
        let response = HTTPURLResponse(url: endpoint, statusCode: 500, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data(), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: ManifestClientError.unexpectedStatusCode(500)) {
            _ = try await client.fetch(previousETag: nil)
        }
    }

    @Test("malformed JSON body on a 200 throws a decoding error")
    func malformedJSONThrows() async {
        let response = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [endpoint: .success((Data("not json".utf8), response))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: (any Error).self) {
            _ = try await client.fetch(previousETag: nil)
        }
    }

    @Test("network error propagates")
    func networkErrorPropagates() async {
        let session = MockHTTPSession(responses: [endpoint: .failure(URLError(.timedOut))])
        let client = ManifestClient(session: session, endpoint: endpoint)

        await #expect(throws: URLError.self) {
            _ = try await client.fetch(previousETag: nil)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/ManifestClientTests test`
Expected: FAIL — `ManifestClient`/`ManifestFetchResult`/`ManifestClientError` not found in scope.

- [ ] **Step 3: Implement `ManifestClient`**

```swift
// ADBLX/Filtering/Updates/ManifestClient.swift
import Foundation

enum ManifestFetchResult: Equatable {
    case notModified
    case updated(FilterManifest, etag: String?)
}

enum ManifestClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case invalidResponse
}

/// Fetches `manifest.json` from a configurable endpoint, honoring ETag/If-None-Match.
actor ManifestClient {
    private let session: HTTPSession
    private let endpoint: URL

    init(session: HTTPSession, endpoint: URL) {
        self.session = session
        self.endpoint = endpoint
    }

    func fetch(previousETag: String?) async throws -> ManifestFetchResult {
        var request = URLRequest(url: endpoint)
        if let previousETag {
            request.setValue(previousETag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ManifestClientError.invalidResponse
        }

        if httpResponse.statusCode == 304 {
            return .notModified
        }
        guard httpResponse.statusCode == 200 else {
            throw ManifestClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let manifest = try JSONDecoder().decode(FilterManifest.self, from: data)
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        return .updated(manifest, etag: etag)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/ManifestClientTests test`
Expected: `** TEST SUCCEEDED **`, 7 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/ManifestClient.swift ADBLXTests/Filtering/Updates/ManifestClientTests.swift
git commit -m "feat: add ManifestClient with ETag/If-None-Match/304 support"
```

---

### Task 6: `FilterDownloadClient`

**Files:**
- Create: `ADBLX/Filtering/Updates/FilterDownloadClient.swift`
- Test: `ADBLXTests/Filtering/Updates/FilterDownloadClientTests.swift`

**Interfaces:**
- Consumes: `HTTPSession`, `MockHTTPSession` (Task 1), `FilterManifest.Entry` (existing).
- Produces: `struct DownloadedFilter: Equatable { var filterID: String; var
  tempFileURL: URL; var expectedChecksum: String; var version: String }`, `enum
  FilterDownloadClientError: Error, Equatable { case unexpectedStatusCode(Int); case
  invalidResponse }`, `actor FilterDownloadClient { init(session: HTTPSession); func
  download(_ entry: FilterManifest.Entry) async throws -> DownloadedFilter }`.
  `UpdateCoordinator` (Task 9) calls `download(_:)` once per `.install` entry in the plan.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/Updates/FilterDownloadClientTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("FilterDownloadClient")
struct FilterDownloadClientTests {
    private func sampleEntry() -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads,
            sourceURL: URL(string: "https://example.com/easylist.txt")!,
            version: "2026-07-18", checksumSHA256: "abc123", ruleCount: 100,
            enabledByDefault: true, premium: false
        )
    }

    @Test("successful download writes the response body to a temp file and returns matching metadata")
    func successfulDownloadWritesTempFile() async throws {
        let entry = sampleEntry()
        let body = Data("[\"rule-a\", \"rule-b\"]".utf8)
        let response = HTTPURLResponse(url: entry.sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [entry.sourceURL: .success((body, response))])
        let client = FilterDownloadClient(session: session)

        let downloaded = try await client.download(entry)

        #expect(downloaded.filterID == "easylist")
        #expect(downloaded.expectedChecksum == "abc123")
        #expect(downloaded.version == "2026-07-18")
        #expect(try Data(contentsOf: downloaded.tempFileURL) == body)

        try? FileManager.default.removeItem(at: downloaded.tempFileURL)
    }

    @Test("non-2xx status throws FilterDownloadClientError.unexpectedStatusCode")
    func non2xxThrows() async {
        let entry = sampleEntry()
        let response = HTTPURLResponse(url: entry.sourceURL, statusCode: 404, httpVersion: nil, headerFields: nil)!
        let session = MockHTTPSession(responses: [entry.sourceURL: .success((Data(), response))])
        let client = FilterDownloadClient(session: session)

        await #expect(throws: FilterDownloadClientError.unexpectedStatusCode(404)) {
            _ = try await client.download(entry)
        }
    }

    @Test("network error propagates")
    func networkErrorPropagates() async {
        let entry = sampleEntry()
        let session = MockHTTPSession(responses: [entry.sourceURL: .failure(URLError(.notConnectedToInternet))])
        let client = FilterDownloadClient(session: session)

        await #expect(throws: URLError.self) {
            _ = try await client.download(entry)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterDownloadClientTests test`
Expected: FAIL — `FilterDownloadClient`/`DownloadedFilter`/`FilterDownloadClientError` not found in scope.

- [ ] **Step 3: Implement `FilterDownloadClient`**

```swift
// ADBLX/Filtering/Updates/FilterDownloadClient.swift
import Foundation

struct DownloadedFilter: Equatable {
    var filterID: String
    var tempFileURL: URL
    var expectedChecksum: String
    var version: String
}

enum FilterDownloadClientError: Error, Equatable {
    case unexpectedStatusCode(Int)
    case invalidResponse
}

/// Downloads one filter's body to a temp file. Does not verify checksums or install —
/// purely fetch-and-locate-on-disk, so callers can verify before touching any App Group
/// state (see UpdateCoordinator's data flow in the Sprint 2 design doc).
actor FilterDownloadClient {
    private let session: HTTPSession

    init(session: HTTPSession) {
        self.session = session
    }

    func download(_ entry: FilterManifest.Entry) async throws -> DownloadedFilter {
        let (data, response) = try await session.data(for: URLRequest(url: entry.sourceURL))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FilterDownloadClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw FilterDownloadClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(entry.id)-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)

        return DownloadedFilter(
            filterID: entry.id,
            tempFileURL: tempURL,
            expectedChecksum: entry.checksumSHA256,
            version: entry.version
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterDownloadClientTests test`
Expected: `** TEST SUCCEEDED **`, 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/FilterDownloadClient.swift ADBLXTests/Filtering/Updates/FilterDownloadClientTests.swift
git commit -m "feat: add FilterDownloadClient for downloading manifest entries to temp files"
```

---

### Task 7: `FilterPipeline` — deferred reload + metadata accumulation

**Files:**
- Modify: `ADBLX/Filtering/Pipeline/FilterPipeline.swift`
- Test: `ADBLXTests/Filtering/FilterPipelineTests.swift` (existing — extend)

**Interfaces:**
- Consumes: `FilterStore.read(_:in:)` (existing), `ReloadCoordinator.reload(extensionIdentifiers:)` (existing).
- Produces: `enum ReloadStrategy { case immediate, case deferred }` (new), `func
  install(filterID: String, source: Data, version: String = "bundled-snapshot",
  reloadStrategy: ReloadStrategy = .immediate) async throws -> PipelineResult`
  (signature change, both new parameters default to preserve Sprint 1 behavior exactly).
  `UpdateCoordinator` (Task 9) calls `install(filterID:source:version:reloadStrategy:)`
  passing the downloaded filter's real manifest version and `.deferred`.

**This task changes existing, tested behavior — read both existing tests in
`FilterPipelineTests.swift` before editing `FilterPipeline.swift` so the accumulation
fix doesn't break `installsBundledSnapshotEndToEnd`, which asserts a single-element
`installed_filters.json`.**

**Why the `version` parameter matters (found in ABORT review, not in the original
design pass):** without it, `install()` always writes `installedVersion:
"bundled-snapshot"` to `installed_filters.json` regardless of what was actually
installed. `UpdatePlanner` (Task 3) requires `installedVersion == entry.version` to
emit `.keep`. A manifest-driven install would then never match on a later run — the
planner would emit `.install` for the same unchanged filter on every run that isn't
short-circuited by a 304, silently defeating "download only changed filters"
(acceptance criterion 3) while every test in Tasks 1–9 still passes, because none of
them exercise a second `run()` against an already-installed filter. Task 9 adds the
test that would have caught this.

- [ ] **Step 1: Serialize the suite, then write the failing tests**

First, change the existing suite declaration at the top of
`ADBLXTests/Filtering/FilterPipelineTests.swift` from:

```swift
@Suite("FilterPipeline")
struct FilterPipelineTests {
```

to:

```swift
@Suite(.serialized, "FilterPipeline")
struct FilterPipelineTests {
```

This suite's tests write to the same fixed App Group path
(`Metadata/installed_filters.json`) — see the Global Constraints note on serializing
suites that share App Group file paths. Without this, the two new accumulation tests
below can race against each other and against `installsBundledSnapshotEndToEnd`.

Then append the new tests:

```swift
// Append to ADBLXTests/Filtering/FilterPipelineTests.swift, inside the existing FilterPipelineTests struct
    @Test("reloadStrategy .deferred skips the reload call and returns empty reloadResults")
    func deferredReloadSkipsReloadCall() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        let result = try await pipeline.install(filterID: "deferred-test", source: source, reloadStrategy: .deferred)

        #expect(result.reloadResults.isEmpty)
    }

    @Test("installing a second filter after a first accumulates both in installed_filters.json")
    func installingSecondFilterAccumulatesMetadata() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        _ = try await pipeline.install(filterID: "filter-a", source: source, reloadStrategy: .deferred)
        _ = try await pipeline.install(filterID: "filter-b", source: source, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(Set(filters.map(\.id)) == ["filter-a", "filter-b"])
    }

    @Test("re-installing the same filterID replaces its entry instead of duplicating it")
    func reinstallingSameFilterIDReplacesEntry() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        _ = try await pipeline.install(filterID: "filter-a", source: source, reloadStrategy: .deferred)
        _ = try await pipeline.install(filterID: "filter-a", source: source, reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.map(\.id) == ["filter-a"])
    }

    @Test("install(version:) records the passed version, not the bundled-snapshot default")
    func installRecordsPassedVersion() async throws {
        let pipeline = makePipeline()
        let source = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        _ = try await pipeline.install(filterID: "filter-versioned", source: source, version: "2026-07-18", reloadStrategy: .deferred)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        let data = try Data(contentsOf: metadataDir.appendingPathComponent("installed_filters.json"))
        let filters = try JSONDecoder().decode([InstalledFilter].self, from: data)

        #expect(filters.first(where: { $0.id == "filter-versioned" })?.installedVersion == "2026-07-18")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterPipelineTests test`
Expected: FAIL — `reloadStrategy` parameter not found on `install`.

- [ ] **Step 3: Implement the deferred-reload mode and metadata accumulation**

```swift
// ADBLX/Filtering/Pipeline/FilterPipeline.swift — full replacement
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
    ///
    /// `version`: the value recorded as `InstalledFilter.installedVersion`. Defaults to
    /// `"bundled-snapshot"`, matching Sprint 1's only caller. `UpdateCoordinator`
    /// (Sprint 2) passes the manifest entry's real version — `UpdatePlanner` compares
    /// this value against `FilterManifest.Entry.version` to decide `.keep` vs
    /// `.install` on the next run, so an un-passed (default) version here would make a
    /// manifest-driven install never converge to `.keep`.
    ///
    /// `reloadStrategy`: `.immediate` (default) reloads the affected extensions before
    /// returning, matching Sprint 1 behavior exactly. `.deferred` skips the reload —
    /// used by `UpdateCoordinator` (Sprint 2) so a multi-filter batch triggers exactly
    /// one reload after every filter in the batch has installed successfully, rather
    /// than one reload per filter.
    func install(
        filterID: String,
        source: Data,
        version: String = "bundled-snapshot",
        reloadStrategy: ReloadStrategy = .immediate
    ) async throws -> PipelineResult {
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

        // Sprint 2: accumulate rather than overwrite — read the existing list, replace
        // this filterID's entry if present (by id) or append it, write the merged array
        // back. Compiled/<Group>.json above is still one file per group, still
        // overwritten per call — true multi-source rule composition per group is
        // deferred (see Sprint 2 design doc, "Known dependency on Sprint 1's
        // single-entry metadata overwrite").
        let installedFilter = InstalledFilter(
            id: filterID,
            group: .ads,
            installedVersion: version,
            checksumSHA256: Checksum.sha256Hex(of: source),
            lastUpdated: compiled.statistics.lastUpdated,
            ruleCount: compiled.ruleCount
        )
        var existingFilters = (try? await loadInstalledFilters()) ?? []
        existingFilters.removeAll { $0.id == filterID }
        existingFilters.append(installedFilter)
        let installedFiltersData = try JSONEncoder().encode(existingFilters)
        try await store.writeMetadata(installedFiltersData, filename: "installed_filters.json")

        let statisticsData = try JSONEncoder().encode(compiled.statistics)
        try await store.writeMetadata(statisticsData, filename: "statistics.json")

        let reloadResults: [ReloadCoordinator.ReloadResult]
        if reloadStrategy == .immediate {
            reloadResults = await reloader.reload(extensionIdentifiers: extensionIdentifiers)
        } else {
            reloadResults = []
        }

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

- [ ] **Step 4: Run tests to verify they pass, including the existing Sprint 1 tests**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterPipelineTests test`
Expected: `** TEST SUCCEEDED **`, 6 tests passed (2 existing Sprint 1 tests still pass unmodified + 4 new). If `installsBundledSnapshotEndToEnd` fails, check that a stale `installed_filters.json` from a prior manual run isn't polluting the App Group container — the accumulation fix means old entries from unrelated `filterID`s now persist across runs where they previously got overwritten.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Pipeline/FilterPipeline.swift ADBLXTests/Filtering/FilterPipelineTests.swift
git commit -m "feat: add deferred reload strategy and installed_filters.json accumulation to FilterPipeline"
```

---

### Task 8: `FilterStore` — rollback snapshot/restore

**Files:**
- Modify: `ADBLX/Filtering/Storage/FilterStore.swift`
- Test: `ADBLXTests/Filtering/FilterStoreTests.swift` (existing — extend)

**Interfaces:**
- Consumes: existing `FilterStore` internals (`containerURL()`, `url(for:)`, `fileManager`).
- Produces: `struct RollbackSnapshot` (opaque to callers), `func snapshotForRollback()
  async throws -> RollbackSnapshot`, `func restore(_ snapshot: RollbackSnapshot) async
  throws` on `FilterStore`. `UpdateCoordinator` (Task 9) calls `snapshotForRollback()`
  before any batch write and `restore(_:)` if any install in the batch fails.

- [ ] **Step 1: Serialize the suite, then write the failing tests**

First, change the existing suite declaration at the top of
`ADBLXTests/Filtering/FilterStoreTests.swift` from:

```swift
@Suite("FilterStore")
struct FilterStoreTests {
```

to:

```swift
@Suite(.serialized, "FilterStore")
struct FilterStoreTests {
```

Both new tests below write to the same fixed path
(`Compiled/Ads.json`) — see the Global Constraints note on serializing suites that
share App Group file paths.

Then append the new tests:

```swift
// Append to ADBLXTests/Filtering/FilterStoreTests.swift, inside the existing FilterStoreTests struct
    @Test("snapshotForRollback then restore reproduces the exact prior Compiled/ and Metadata/ contents")
    func snapshotThenRestoreReproducesPriorState() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)

        let compiledDir = try await store.directoryURL(.compiled)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledFile = compiledDir.appendingPathComponent("Ads.json")
        let metadataFile = metadataDir.appendingPathComponent("installed_filters.json")

        try Data("[\"old-compiled\"]".utf8).write(to: compiledFile, options: .atomic)
        try Data("[\"old-metadata\"]".utf8).write(to: metadataFile, options: .atomic)

        let snapshot = try await store.snapshotForRollback()

        // Mutate as if an install partially succeeded before a later failure.
        try Data("[\"new-compiled\"]".utf8).write(to: compiledFile, options: .atomic)
        try Data("[\"new-metadata\"]".utf8).write(to: metadataFile, options: .atomic)

        try await store.restore(snapshot)

        #expect(try Data(contentsOf: compiledFile) == Data("[\"old-compiled\"]".utf8))
        #expect(try Data(contentsOf: metadataFile) == Data("[\"old-metadata\"]".utf8))

        try? FileManager.default.removeItem(at: compiledFile)
        try? FileManager.default.removeItem(at: metadataFile)
    }

    @Test("restore removes files created after the snapshot that didn't exist before it")
    func restoreRemovesFilesCreatedAfterSnapshot() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)

        let compiledDir = try await store.directoryURL(.compiled)
        let priorFile = compiledDir.appendingPathComponent("Ads.json")
        try Data("[\"old\"]".utf8).write(to: priorFile, options: .atomic)

        let snapshot = try await store.snapshotForRollback()

        let newFile = compiledDir.appendingPathComponent("Privacy.json")
        try Data("[\"new-group-file\"]".utf8).write(to: newFile, options: .atomic)

        try await store.restore(snapshot)

        #expect(FileManager.default.fileExists(atPath: priorFile.path))
        #expect(!FileManager.default.fileExists(atPath: newFile.path))

        try? FileManager.default.removeItem(at: priorFile)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterStoreTests test`
Expected: FAIL — `snapshotForRollback`/`restore`/`RollbackSnapshot` not found in scope.

- [ ] **Step 3: Implement `snapshotForRollback` and `restore`**

```swift
// ADBLX/Filtering/Storage/FilterStore.swift — full replacement
import Foundation

/// Sole owner of the App Group filesystem layout:
///
///   Filters/     — raw/normalized filter list source data
///   Compiled/    — partitioned, compiled JSON ready for each Content Blocker extension
///   Metadata/    — installed_filters.json, manifest.json, statistics.json
///   Previous/    — rollback snapshot root (Compiled/, Metadata/ copies); only exists
///                  transiently during an UpdateCoordinator batch (Sprint 2)
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

    /// Copies the current `Compiled/` and `Metadata/` directories into a `Previous/`
    /// root, replacing any leftover snapshot from an earlier run. Call before any write
    /// in an update batch begins; pair with `restore(_:)` on failure.
    func snapshotForRollback() throws -> RollbackSnapshot {
        let previousRoot = try previousRootURL()
        if fileManager.fileExists(atPath: previousRoot.path) {
            try fileManager.removeItem(at: previousRoot)
        }
        try fileManager.createDirectory(at: previousRoot, withIntermediateDirectories: true)

        let compiledSnapshot = previousRoot.appendingPathComponent("Compiled", isDirectory: true)
        let metadataSnapshot = previousRoot.appendingPathComponent("Metadata", isDirectory: true)

        try copyDirectoryContents(from: try url(for: .compiled), to: compiledSnapshot)
        try copyDirectoryContents(from: try url(for: .metadata), to: metadataSnapshot)

        return RollbackSnapshot(compiledSnapshotDir: compiledSnapshot, metadataSnapshotDir: metadataSnapshot)
    }

    /// Replaces the entire current contents of `Compiled/` and `Metadata/` with the
    /// snapshot's contents (files present only in the current state and absent from the
    /// snapshot are removed), then discards the `Previous/` root.
    func restore(_ snapshot: RollbackSnapshot) throws {
        try replaceDirectoryContents(at: try url(for: .compiled), with: snapshot.compiledSnapshotDir)
        try replaceDirectoryContents(at: try url(for: .metadata), with: snapshot.metadataSnapshotDir)

        let previousRoot = try previousRootURL()
        try? fileManager.removeItem(at: previousRoot)
    }

    private func previousRootURL() throws -> URL {
        try containerURL().appendingPathComponent("Previous", isDirectory: true)
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            try fileManager.copyItem(
                at: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
        }
    }

    private func replaceDirectoryContents(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) {
            try fileManager.copyItem(
                at: source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name)
            )
        }
    }
}

/// Opaque to callers outside this file — a copy of `Compiled/` and `Metadata/` taken by
/// `snapshotForRollback()`, consumed by `restore(_:)`.
struct RollbackSnapshot {
    fileprivate let compiledSnapshotDir: URL
    fileprivate let metadataSnapshotDir: URL
}

enum FilterStoreError: Error {
    case appGroupContainerUnavailable
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/FilterStoreTests test`
Expected: `** TEST SUCCEEDED **`, 4 tests passed (2 existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Storage/FilterStore.swift ADBLXTests/Filtering/FilterStoreTests.swift
git commit -m "feat: add FilterStore.snapshotForRollback/restore for update rollback"
```

---

### Task 9: `UpdateCoordinator`

**Files:**
- Create: `ADBLX/Filtering/Updates/UpdateCoordinator.swift`
- Test: `ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ManifestClient.fetch(previousETag:)` (Task 5), `ManifestStore.load()`/`save(_:etag:)`
  (Task 4), `FilterDownloadClient.download(_:)` (Task 6), `Checksum.verify(fileURL:against:)`
  (Task 2), `UpdatePlanner.plan(manifest:installed:)` (Task 3), `FilterPipeline.install(filterID:source:reloadStrategy:)`
  (Task 7), `FilterStore.snapshotForRollback()`/`restore(_:)`/`read(_:in:)` (Task 8, existing),
  `ReloadCoordinator.reload(extensionIdentifiers:)` (existing).
- Produces: `enum UpdateRunResult { case upToDate; case updated(installedFilterIDs:
  [String], reloadResults: [ReloadCoordinator.ReloadResult]); case rolledBack(reason:
  Error) }`, `actor UpdateCoordinator { init(...); func run() async throws ->
  UpdateRunResult }`. This is the top-level entry point Sprint 3+ UI/scheduling code
  calls — no other task consumes its output within this plan.

- [ ] **Step 1: Write the failing tests**

```swift
// ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite(.serialized, "UpdateCoordinator")
struct UpdateCoordinatorTests {
    private let manifestEndpoint = URL(string: "https://example.com/manifest.json")!
    private let filterSourceURL = URL(string: "https://example.com/easylist.txt")!
    private let adsExtensionIdentifier = "com.ADBLX.ADBLX.AdsBlocker"

    private func manifestEntry(checksum: String) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: "easylist", name: "EasyList", group: .ads, sourceURL: filterSourceURL,
            version: "2026-07-18", checksumSHA256: checksum, ruleCount: 1,
            enabledByDefault: true, premium: false
        )
    }

    private func filterSourceJSON() -> Data {
        Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
    }

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
            adsExtensionIdentifier: adsExtensionIdentifier
        )
    }

    @Test("304 short-circuits to .upToDate with no downloads or installs")
    func notModifiedShortCircuits() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let manifestStore = ManifestStore(filterStore: store)
        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: "irrelevant")])
        try await manifestStore.save(manifest, etag: "\"cached-etag\"")

        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 304, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (Data(), manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .upToDate = result else {
            Issue.record("expected .upToDate, got \(result)")
            return
        }
    }

    @Test("successful single-filter update installs, commits the manifest, and reloads once")
    func successfulUpdateInstallsAndReloadsOnce() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(
            url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""]
        )!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .updated(let installedIDs, let reloadResults) = result else {
            Issue.record("expected .updated, got \(result)")
            return
        }
        #expect(installedIDs == ["easylist"])
        #expect(reloadResults.count == 1)
        #expect(reloadResults[0].extensionIdentifier == adsExtensionIdentifier)

        let cached = try await ManifestStore(filterStore: store).load()
        #expect(cached?.etag == "\"v1\"")

        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
    }

    @Test("checksum mismatch aborts before any write and leaves prior state untouched")
    func checksumMismatchAbortsBeforeWrite() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let compiledFile = compiledDir.appendingPathComponent("Ads.json")
        try Data("[\"prior\"]".utf8).write(to: compiledFile, options: .atomic)

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: "wrong-checksum")])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        await #expect(throws: ChecksumError.self) {
            _ = try await coordinator.run()
        }

        #expect(try Data(contentsOf: compiledFile) == Data("[\"prior\"]".utf8))
        try? FileManager.default.removeItem(at: compiledFile)
    }

    @Test("install failure mid-batch rolls back to prior Compiled/ and Metadata/ state with exactly one reload")
    func installFailureRollsBackWithOneReload() async throws {
        struct AlwaysFailingCompiler: RuleCompiler {
            nonisolated func compile(source: Data, filterID: String) async throws -> CompiledRuleSet {
                throw RuleCompilerError.invalidSource
            }
        }

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        let metadataDir = try await store.directoryURL(.metadata)
        let compiledFile = compiledDir.appendingPathComponent("Ads.json")
        let metadataFile = metadataDir.appendingPathComponent("installed_filters.json")
        try Data("[\"prior-compiled\"]".utf8).write(to: compiledFile, options: .atomic)
        try Data("[]".utf8).write(to: metadataFile, options: .atomic)

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: AlwaysFailingCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let result = try await coordinator.run()

        guard case .rolledBack = result else {
            Issue.record("expected .rolledBack, got \(result)")
            return
        }
        #expect(try Data(contentsOf: compiledFile) == Data("[\"prior-compiled\"]".utf8))
        #expect(try Data(contentsOf: metadataFile) == Data("[]".utf8))

        try? FileManager.default.removeItem(at: compiledFile)
        try? FileManager.default.removeItem(at: metadataFile)
    }

    @Test("a second run against an unchanged manifest converges to .upToDate via the planner, not just via 304")
    func secondRunConvergesToUpToDateViaPlanner() async throws {
        // Regression test for a gap found in ABORT review: if FilterPipeline.install
        // doesn't record the real manifest version (Task 7's `version:` parameter),
        // UpdatePlanner can never match installedVersion == entry.version, so this
        // filter would re-download and re-install on every run forever, even when the
        // manifest hasn't changed and the server never sends a 304. This test proves
        // convergence through the planner path, independent of ETag/304 behavior — the
        // mock manifest response is a 200 both times, not a 304.
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))

        let manifest = FilterManifest(manifestVersion: "1", entries: [manifestEntry(checksum: Checksum.sha256Hex(of: filterSourceJSON()))])
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestResponse = HTTPURLResponse(url: manifestEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let filterResponse = HTTPURLResponse(url: filterSourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)!

        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            partitioner: PassthroughAdsPartitioner(adsExtensionIdentifier: adsExtensionIdentifier),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        let coordinator = makeCoordinator(
            manifestResponse: (manifestData, manifestResponse),
            filterResponse: (filterSourceJSON(), filterResponse),
            pipeline: pipeline, store: store
        )

        let firstResult = try await coordinator.run()
        guard case .updated = firstResult else {
            Issue.record("expected first run to be .updated, got \(firstResult)")
            return
        }

        let secondResult = try await coordinator.run()
        guard case .upToDate = secondResult else {
            Issue.record("expected second run to be .upToDate (planner should emit .keep, not .install), got \(secondResult)")
            return
        }

        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/UpdateCoordinatorTests test`
Expected: FAIL — `UpdateCoordinator`/`UpdateRunResult` not found in scope.

- [ ] **Step 3: Implement `UpdateCoordinator`**

```swift
// ADBLX/Filtering/Updates/UpdateCoordinator.swift
import Foundation

enum UpdateRunResult {
    case upToDate
    case updated(installedFilterIDs: [String], reloadResults: [ReloadCoordinator.ReloadResult])
    case rolledBack(reason: Error)
}

/// Orchestrates one full update transaction: fetch manifest → plan → download → verify
/// → install (deferred reload) → commit metadata + single reload, or roll back the
/// entire batch and reload once with the restored state on any failure past the
/// checksum-verification point. See the Sprint 2 design doc for the full data flow and
/// the `.ads`-only / group-conflict limitations this sprint operates under.
actor UpdateCoordinator {
    private let manifestClient: ManifestClient
    private let manifestStore: ManifestStore
    private let downloadClient: FilterDownloadClient
    private let pipeline: FilterPipeline
    private let store: FilterStore
    private let reloader: ReloadCoordinator
    private let adsExtensionIdentifier: String

    init(
        manifestClient: ManifestClient,
        manifestStore: ManifestStore,
        downloadClient: FilterDownloadClient,
        pipeline: FilterPipeline,
        store: FilterStore,
        reloader: ReloadCoordinator,
        adsExtensionIdentifier: String
    ) {
        self.manifestClient = manifestClient
        self.manifestStore = manifestStore
        self.downloadClient = downloadClient
        self.pipeline = pipeline
        self.store = store
        self.reloader = reloader
        self.adsExtensionIdentifier = adsExtensionIdentifier
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
        let installs: [FilterManifest.Entry] = plan.actions.compactMap {
            if case .install(let entry) = $0 { return entry }
            return nil
        }

        guard !installs.isEmpty else {
            try await manifestStore.save(manifest, etag: etag)
            return .upToDate
        }

        var downloaded: [DownloadedFilter] = []
        for entry in installs {
            downloaded.append(try await downloadClient.download(entry))
        }
        for filter in downloaded {
            try Checksum.verify(fileURL: filter.tempFileURL, against: filter.expectedChecksum)
        }

        let snapshot = try await store.snapshotForRollback()
        // .ads is the only routable group this sprint — see the Sprint 2 design doc's
        // "Known dependency on Sprint 1's partitioning scope."
        let affectedExtensionIDs = [adsExtensionIdentifier]

        do {
            for filter in downloaded {
                // Bridge because FilterPipeline.install is Data-based from Sprint 1. If
                // a future overload accepts a URL directly, this read disappears.
                let data = try Data(contentsOf: filter.tempFileURL)
                // version: filter.version is required, not cosmetic — UpdatePlanner compares
                // InstalledFilter.installedVersion against FilterManifest.Entry.version to
                // decide .keep vs .install on the next run. Omitting it (leaving the
                // "bundled-snapshot" default) would make this filter never converge to
                // .keep, defeating "download only changed filters" on every subsequent run.
                _ = try await pipeline.install(filterID: filter.filterID, source: data, version: filter.version, reloadStrategy: .deferred)
            }
            try await manifestStore.save(manifest, etag: etag)
            let reloadResults = await reloader.reload(extensionIdentifiers: affectedExtensionIDs)
            return .updated(installedFilterIDs: downloaded.map(\.filterID), reloadResults: reloadResults)
        } catch {
            try await store.restore(snapshot)
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" -only-testing:ADBLXTests/UpdateCoordinatorTests test`
Expected: `** TEST SUCCEEDED **`, 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add ADBLX/Filtering/Updates/UpdateCoordinator.swift ADBLXTests/Filtering/Updates/UpdateCoordinatorTests.swift
git commit -m "feat: add UpdateCoordinator orchestrating the full manifest-driven update transaction"
```

---

### Task 10: Full test suite + clean build verification

**Files:** None created or modified — verification only.

**Interfaces:** None — this task verifies Tasks 1–9 together, not in isolation.

- [ ] **Step 1: Run the entire ADBLXTests suite**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" test`
Expected: `** TEST SUCCEEDED **`, all suites pass — Sprint 0/1 suites (`AppGroupTests`,
`FilteringModelsTests`, `ChecksumTests`, `FilterValidatorTests`,
`PassthroughRuleCompilerTests`, `PassthroughAdsPartitionerTests`, `FilterStoreTests`,
`AtomicRuleWriterTests`, `FilterPipelineTests`, `ReloadCoordinatorTests`,
`RuleCompilerTests`, `RulePartitionerTests`) plus every Sprint 2 suite added in this
plan (`HTTPSessionTests`, `UpdatePlannerTests`, `ManifestStoreTests`,
`ManifestClientTests`, `FilterDownloadClientTests`, `UpdateCoordinatorTests`).

**Known residual flakiness risk at this step specifically (not at any single-suite
`-only-testing:` step in Tasks 1–9):** `FilterPipelineTests`, `FilterStoreTests`,
`ManifestStoreTests`, and `UpdateCoordinatorTests` are each internally serialized
(`.serialized`), but Swift Testing can still run *different* suites concurrently
against each other, and all four write to the same real App Group container
(`group.com.ADBLX.shared` — the only App Group ID registered in this project's
entitlements; there's no test-only App Group available to isolate against without a
provisioning change, which is out of scope here). If this step fails intermittently
with a JSON-decoding error or an unexpected `installed_filters.json`/`Compiled/Ads.json`
content mismatch — and the same failing test passes when re-run via its own
single-suite `-only-testing:` command — that's this cross-suite race, not a real
implementation bug. Re-run Step 1 once before investigating further. If it's
consistently flaky, the durable fix (parameterizing `FilterStore`'s fixed filenames or
container subpath per test — not attempted in this plan) is follow-up work, not a
Sprint 2 blocker.

- [ ] **Step 2: Clean build from scratch**

Run: `cd /Users/sreeharshag/Work/ADBLX && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX clean && xcodegen generate && xcodebuild -project ADBLX.xcodeproj -scheme ADBLX -destination "id=$(Scripts/find-simulator-udid.sh)" build`
Expected: `** BUILD SUCCEEDED **`, confirming no leftover file-reference or target-membership issues from the six new `Filtering/Updates/` files.

- [ ] **Step 3: Confirm no stray App Group state leaked between test runs**

Run: `find ~/Library/Developer/CoreSimulator/Devices -path "*group.com.ADBLX.shared/Metadata*" -name "*.json" 2>/dev/null | xargs -I{} sh -c 'echo {}; cat {}' 2>/dev/null | head -100`
Expected: manual read — confirm `manifest.json`/`installed_filters.json` (if present)
contain only test fixture data (`easylist`, `filter-a`, `filter-b`, etc.), not anything
unexpected. This is a sanity check, not a pass/fail gate — the individual tests already
clean up their own App Group writes via `defer`/trailing `removeItem` calls.

- [ ] **Step 4: Commit (only if Step 3 required a fix; otherwise this task has nothing to commit)**

No commit expected for this task under normal conditions — it verifies work already
committed in Tasks 1–9. If Step 1 or Step 2 surfaces a failure, fix it as a small
follow-up commit referencing which task's change caused it, then re-run Steps 1–2.

---

## Post-plan note

This plan intentionally does not implement: a real manifest-hosting endpoint (Sprint 2
uses only mocked `HTTPSession` responses — see the design doc's "Manifest source"
decision), StoreKit/premium purchase flow, multi-group rule composition, or background
scheduling (`BGAppRefreshTask`). `UpdateCoordinator.run()` is written to be callable
from either a foreground trigger or a future scheduler without modification — wiring an
actual caller (a "Check for Updates" button, a launch-time check, or a background task)
is Sprint 3+ scope per the design doc's "Out of scope for Sprint 2" section.

**Blocking risk for whoever does that wiring (found in ABORT review):**
`ContentBlockerBootstrap`/`installBundledSnapshotIfNeeded()` unconditionally reinstalls
the bundled snapshot on every app launch — that's unchanged Sprint 1 behavior, and nothing
in this plan touches it. The moment a Sprint 3+ launch path calls
`UpdateCoordinator.run()` *in addition to* the existing bootstrap call (rather than
*instead of* it), the sequence becomes: update installs a real EasyList → app relaunches
→ bootstrap overwrites `Compiled/Ads.json` and `installed_filters.json` back to the
bundled snapshot → the update is silently reverted. This plan does not fix it, because
nothing in Sprint 2 calls `run()` yet, so it's unreachable today — but whichever plan
wires up the first real caller of `UpdateCoordinator.run()` must either gate
`installBundledSnapshotIfNeeded()` behind "no update has ever succeeded" (e.g. skip it
if `ManifestStore.load()` returns non-nil) or remove the unconditional bootstrap call
entirely in favor of `UpdateCoordinator.run()`. Flagging here so it isn't rediscovered
the hard way after Sprint 3 ships.
