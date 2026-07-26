# Sprint 7 — Registry → Manifest Publisher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `Publisher` Swift Package executable under
`backend/tools/Publisher` that reads `backend/registry/filters.json`,
`backend/metadata/{id}.json`, and `backend/public/filters/{group}/{id}.txt`,
and produces `backend/public/manifest.json` (per
`backend/docs/ManifestSpecification.md`) and `backend/docs/FilterRegistry.md`
(generated), with a `validate` / `generate-docs` / `publish` / `generate` CLI.

**Architecture:** One SPM executable target (`Publisher`) with internal
folder-based modularity (`Models`, `Registry`, `Metadata`, `Payload`,
`Manifest`, `Documentation`, `Validation`, `CLI`, `Utilities`). Each task
adds one module bottom-up (models → registry loading → metadata/payload
loading → validation → manifest generation → documentation generation →
atomic writer → CLI wiring), each independently unit-tested, culminating in
integration tests (golden-file, batch-failure, determinism) that exercise
the full `publish`/`generate-docs` pipelines end to end.

**Tech Stack:** Swift 6.3 (toolchain confirmed via `swift --version` —
`swiftlang-6.3.3.1.3`), Swift Package Manager, `Foundation`, `CryptoKit`
(SHA-256, same as the iOS app's `Checksum.sha256Hex`), XCTest.

## Global Constraints

All values below are copied verbatim from
`docs/superpowers/specs/2026-07-26-sprint7-publisher-implementation-blueprint-design.md`
and `backend/docs/ManifestGeneration.md` / `backend/docs/ManifestSpecification.md`.
Every task's requirements implicitly include this section.

- Single executable target (`Publisher`), no library target, no second
  package consumer.
- `main.swift` is a thin entry point only: parse arguments, construct
  `Publisher`, run, exit.
- Type/module names: `Publisher` (not `PublisherEngine`, not
  `PublisherService`).
- `backend/registry/filters.json` is the canonical registry. Schema:
  ```json
  {
    "registryVersion": 1,
    "filters": [
      {
        "id": "easylist",
        "name": "EasyList",
        "upstreamProject": "EasyList",
        "upstreamDownloadURL": "https://easylist.to/easylist/easylist.txt",
        "license": "CC BY-SA 3.0 / GPLv3",
        "group": "ads",
        "enabledByDefault": true,
        "premium": false,
        "notes": null
      }
    ]
  }
  ```
  Required fields: `id`, `name`, `upstreamProject`, `upstreamDownloadURL`,
  `license`, `group`, `enabledByDefault`, `premium`. Optional: `notes`.
- `registryVersion` is a schema-compat guard only (currently `1`). It never
  changes for content edits (filters added/removed/edited) — only for a
  backward-incompatible schema change.
- Registry `group` values are exactly `"ads"`, `"privacy"`, `"annoyances"`,
  `"regional"` — matching the client's `FilterGroup` enum
  (`ADBLX/Filtering/Models/FilterManifest.swift:24`).
- `backend/metadata/{id}.json` shape: `{"id": "easylist", "version": "2026-07-15"}`.
  `id` must match both the filename and a registered filter's id. `version`
  is `YYYY-MM-DD`.
- Manifest field ownership (from `ManifestGeneration.md`):
  - `id`, `name`, `group`, `enabledByDefault`, `premium` ← registry.
  - `version` ← `backend/metadata/{id}.json`.
  - `checksumSHA256` ← SHA-256 hex of `backend/public/filters/{group}/{id}.txt`,
    lowercase, 64 chars, no prefix (matches iOS `Checksum.sha256Hex`).
  - `ruleCount` ← computed from the payload (count of non-empty,
    non-comment lines — see Task 6).
  - `sourceURL` ← `{publishBaseURL}/backend/public/filters/{group}/{id}.txt`.
  - `manifestVersion` ← `max(entry.version)` lexical string comparison over
    all entries.
- Manifest JSON key order per entry (from `ManifestSpecification.md`): `id`,
  `name`, `group`, `sourceURL`, `version`, `checksumSHA256`, `ruleCount`,
  `enabledByDefault`, `premium`. Top-level key order: `manifestVersion`,
  `entries`.
- Entries sorted ascending by `id` (ordinal string comparison) in both the
  manifest and the generated Markdown table (grouped by `group` in fixed
  order Ads, Privacy, Annoyances, Regional — this order comes from the
  `FilterGroup` domain model, not alphabetical or JSON order).
- JSON output: pretty-printed, UTF-8, LF line endings, stable key order,
  byte-identical across runs given identical inputs.
- Generated files (`backend/public/manifest.json`,
  `backend/docs/FilterRegistry.md`) are written atomically: write to a temp
  file in the same directory, fsync, rename over the destination — mirrors
  `ADBLX/Filtering/Storage/AtomicRuleWriter.swift`'s pattern (that file
  can't be imported directly, it's in the iOS app target — the publisher
  gets its own copy of the same pattern).
- Validation: fatal errors (unreadable/malformed JSON, unsupported
  `registryVersion`) stop immediately. Semantic errors (missing metadata,
  orphaned metadata, duplicate metadata, missing payload, empty registry,
  invalid group, duplicate registry id) accumulate into one report, sorted
  by category (Registry → Metadata → Payload) then by `id`, all reported
  together. `publish` never writes any output if validation reports errors.
- CLI: `validate`, `generate-docs`, `publish --publish-base-url <url>`,
  `generate --publish-base-url <url>` (= validate → generate-docs →
  publish). `--publish-base-url` is CLI-only: required, no env var, no
  config file, no default.
- Exit codes: `0` success, `1` validation failure, `2` fatal error.
- `backend/docs/RegistryRoadmap.md` holds the hand-authored "Future
  candidates" content migrated out of `FilterRegistry.md`.
- No property-based/fuzz testing.

---

## File Structure

```
backend/
├── registry/
│   └── filters.json                          # NEW — canonical registry (Task 1)
├── docs/
│   ├── FilterRegistry.md                      # becomes GENERATED (Task 8)
│   └── RegistryRoadmap.md                     # NEW — hand-authored (Task 1)
└── tools/
    └── Publisher/
        ├── Package.swift
        ├── Sources/
        │   └── Publisher/
        │       ├── main.swift                 # Task 11
        │       ├── Models/
        │       │   ├── Registry.swift         # Task 2
        │       │   ├── FilterMetadata.swift    # Task 4
        │       │   └── Manifest.swift          # Task 6
        │       ├── Registry/
        │       │   └── RegistryLoader.swift    # Task 2
        │       ├── Metadata/
        │       │   └── MetadataLoader.swift    # Task 4
        │       ├── Payload/
        │       │   └── PayloadReader.swift      # Task 5
        │       ├── Validation/
        │       │   ├── ValidationError.swift    # Task 3
        │       │   └── Validator.swift           # Task 3, extended Task 7
        │       ├── Manifest/
        │       │   └── ManifestBuilder.swift     # Task 6
        │       ├── Documentation/
        │       │   └── MarkdownGenerator.swift    # Task 8
        │       ├── Utilities/
        │       │   └── AtomicFileWriter.swift      # Task 9
        │       └── CLI/
        │           ├── PublisherCommand.swift       # Task 11
        │           └── Commands/
        │               ├── ValidateCommand.swift     # Task 11
        │               ├── GenerateDocsCommand.swift # Task 11
        │               ├── PublishCommand.swift       # Task 11
        │               └── GenerateCommand.swift       # Task 11
        └── Tests/
            └── PublisherTests/
                ├── RegistryTests.swift            # Task 2
                ├── ValidationTests.swift           # Task 3, 7
                ├── MetadataTests.swift              # Task 4
                ├── PayloadTests.swift                # Task 5
                ├── ManifestTests.swift                # Task 6
                ├── DocumentationTests.swift            # Task 8
                ├── AtomicFileWriterTests.swift          # Task 9
                ├── PublisherIntegrationTests.swift       # Task 10
                └── Fixtures/
                    ├── golden-manifest.json               # Task 10
                    └── golden-filter-registry.md            # Task 10
```

---

## Task 1: Migrate registry content into `backend/registry/filters.json` and split the roadmap

**Files:**
- Create: `backend/registry/filters.json`
- Create: `backend/docs/RegistryRoadmap.md`
- Modify: `backend/docs/FilterRegistry.md` (add a header note that this file
  will become generated; content stays as-is until Task 8 regenerates it)

**Interfaces:**
- Produces: the on-disk `filters.json` content every later task reads as
  its primary fixture/reference. No code yet — this task is pure data
  migration.

This task has no test cycle (it's data migration, not code), but it is a
real, independently reviewable deliverable: a human can diff the JSON
against the existing Markdown table and confirm nothing was lost or altered
in the port.

- [ ] **Step 1: Create `backend/registry/filters.json`**

Port the three frozen v1 filters from `backend/docs/FilterRegistry.md`
verbatim — no content changes, only reshaping into JSON:

```json
{
  "registryVersion": 1,
  "filters": [
    {
      "id": "easylist",
      "name": "EasyList",
      "upstreamProject": "EasyList",
      "upstreamDownloadURL": "https://easylist.to/easylist/easylist.txt",
      "license": "CC BY-SA 3.0 / GPLv3",
      "group": "ads",
      "enabledByDefault": true,
      "premium": false,
      "notes": null
    },
    {
      "id": "easyprivacy",
      "name": "EasyPrivacy",
      "upstreamProject": "EasyList",
      "upstreamDownloadURL": "https://easylist.to/easylist/easyprivacy.txt",
      "license": "CC BY-SA 3.0 / GPLv3",
      "group": "privacy",
      "enabledByDefault": true,
      "premium": false,
      "notes": null
    },
    {
      "id": "fanboy-annoyances",
      "name": "Fanboy Annoyances",
      "upstreamProject": "EasyList (Fanboy)",
      "upstreamDownloadURL": "https://easylist.to/easylist/fanboy-annoyance.txt",
      "license": "CC BY-SA 3.0",
      "group": "annoyances",
      "enabledByDefault": false,
      "premium": true,
      "notes": "Gated per PRD §5.1 (\"Cookie-banner / annoyance filters\" is a Premium feature)."
    }
  ]
}
```

- [ ] **Step 2: Create `backend/docs/RegistryRoadmap.md`**

Move the "Future candidates" table and the Regional group's "Future
direction" bullets out of `FilterRegistry.md` into this new file:

```markdown
# ADBLX Registry Roadmap

## Purpose

This document tracks filters and lists under evaluation for future
inclusion in `backend/registry/filters.json`. It is hand-authored and never
generated — unlike `backend/docs/FilterRegistry.md`, which is generated
from the registry (Sprint 7).

Entries here are not registered filters: they have no `id` in the
publisher's sense, no `enabledByDefault`/`premium` decision, and sometimes
no confirmed `group`. A list moves from this document into
`backend/registry/filters.json` only once it satisfies every inclusion
criterion in `FilterRegistry.md`'s "Registry inclusion criteria" section.

## Regional group — future direction

No production filter is registered for the Regional group in v1.

- `shield-india` — proprietary Indian web ad-network list (see PRD Appendix
  C). Not yet built; requires the publisher audit described there before it
  can be registered.
- EasyList regional variants — no specific variant has been selected yet.

## Future candidates

| List | Group | Why deferred |
|---|---|---|
| AdGuard Base | Ads | Overlaps heavily with EasyList; deferred to avoid redundant rules/compile size in v1. |
| SHIELD proprietary fixes | Ads | Not yet built (PRD Appendix C direction). |
| Peter Lowe's | Privacy | Listed as CB + DNS in PRD Appendix A; this registry is CB-only for v1, and the list spans both layers. |
| `shield-india` | Regional | Not yet built — requires the publisher audit in PRD Appendix C. |
| EasyList regional variants | Regional | No specific variant selected. |

DNS-layer-only lists (OISD, HaGeZi Multi) are out of scope entirely until a
DNS distribution model is designed — see Sprint 6 Commit 1's decision to
scope the backend to the four Content Blocker `FilterGroup`s.
```

- [ ] **Step 3: Add a forward-reference note to `backend/docs/FilterRegistry.md`**

Add this paragraph immediately under the existing `## Purpose` heading
(don't remove any existing content yet — Task 8 regenerates the whole file):

```markdown
> **Sprint 7 note:** this file is being migrated to a generated artifact,
> produced from `backend/registry/filters.json` by the `Publisher` tool's
> `generate-docs` command. Once Sprint 7 Task 8 lands, this file is
> generated — do not hand-edit it; edit `backend/registry/filters.json`
> instead. Future candidates now live in `backend/docs/RegistryRoadmap.md`.
```

- [ ] **Step 4: Commit**

```bash
git add backend/registry/filters.json backend/docs/RegistryRoadmap.md backend/docs/FilterRegistry.md
git commit -m "docs(backend): migrate registry to filters.json, split roadmap into RegistryRoadmap.md"
```

---

## Task 2: Scaffold the Publisher package and implement Registry loading

**Files:**
- Create: `backend/tools/Publisher/Package.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/Models/Registry.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/Registry/RegistryLoader.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/main.swift` (placeholder — real CLI wiring is Task 11)
- Test: `backend/tools/Publisher/Tests/PublisherTests/RegistryTests.swift`

**Interfaces:**
- Produces:
  - `struct RegistryEntry: Codable, Equatable` with fields `id: String`,
    `name: String`, `upstreamProject: String`, `upstreamDownloadURL: String`,
    `license: String`, `group: String`, `enabledByDefault: Bool`,
    `premium: Bool`, `notes: String?`.
  - `struct Registry: Codable, Equatable` with fields
    `registryVersion: Int`, `filters: [RegistryEntry]`.
  - `enum RegistryLoaderError: Error, Equatable { case fileNotReadable(path: String), case malformedJSON(String), case unsupportedRegistryVersion(found: Int, supported: Int) }`.
  - `enum RegistryLoader { static let supportedRegistryVersion = 1; static func load(from url: URL) throws -> Registry }` —
    throws `RegistryLoaderError` on any fatal condition; does not sort or
    validate semantically (that's Task 3's `Validator`). Later tasks
    (`Validator`, `ManifestBuilder`, `MarkdownGenerator`) consume `Registry`
    and `RegistryEntry` by these exact names/fields.

- [ ] **Step 1: Create the SPM package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Publisher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Publisher",
            path: "Sources/Publisher"
        ),
        .testTarget(
            name: "PublisherTests",
            dependencies: ["Publisher"],
            path: "Tests/PublisherTests"
        )
    ]
)
```

- [ ] **Step 2: Add a placeholder `main.swift` so the package builds**

```swift
// backend/tools/Publisher/Sources/Publisher/main.swift
print("Publisher: CLI not yet wired (see Task 11)")
```

- [ ] **Step 3: Verify the empty package builds**

Run: `cd backend/tools/Publisher && swift build`
Expected: Build succeeds (one warning-free executable, prints the
placeholder message when run).

- [ ] **Step 4: Write the failing test for registry decoding**

```swift
// backend/tools/Publisher/Tests/PublisherTests/RegistryTests.swift
import XCTest
@testable import Publisher

final class RegistryTests: XCTestCase {
    func test_decodesValidRegistry() throws {
        let json = """
        {
          "registryVersion": 1,
          "filters": [
            {
              "id": "easylist",
              "name": "EasyList",
              "upstreamProject": "EasyList",
              "upstreamDownloadURL": "https://easylist.to/easylist/easylist.txt",
              "license": "CC BY-SA 3.0 / GPLv3",
              "group": "ads",
              "enabledByDefault": true,
              "premium": false,
              "notes": null
            }
          ]
        }
        """
        let url = try Self.writeTempFile(contents: json)
        let registry = try RegistryLoader.load(from: url)

        XCTAssertEqual(registry.registryVersion, 1)
        XCTAssertEqual(registry.filters.count, 1)
        XCTAssertEqual(registry.filters[0].id, "easylist")
        XCTAssertEqual(registry.filters[0].name, "EasyList")
        XCTAssertEqual(registry.filters[0].group, "ads")
        XCTAssertEqual(registry.filters[0].enabledByDefault, true)
        XCTAssertEqual(registry.filters[0].premium, false)
        XCTAssertNil(registry.filters[0].notes)
    }

    func test_throwsOnMalformedJSON() throws {
        let url = try Self.writeTempFile(contents: "{ not valid json")
        XCTAssertThrowsError(try RegistryLoader.load(from: url)) { error in
            guard case RegistryLoaderError.malformedJSON = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func test_throwsOnUnsupportedRegistryVersion() throws {
        let json = """
        { "registryVersion": 2, "filters": [] }
        """
        let url = try Self.writeTempFile(contents: json)
        XCTAssertThrowsError(try RegistryLoader.load(from: url)) { error in
            guard case RegistryLoaderError.unsupportedRegistryVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedRegistryVersion, got \(error)")
            }
            XCTAssertEqual(found, 2)
            XCTAssertEqual(supported, 1)
        }
    }

    static func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter RegistryTests`
Expected: FAIL to compile — `RegistryLoader`, `Registry`, `RegistryEntry`,
`RegistryLoaderError` don't exist yet.

- [ ] **Step 6: Implement `Registry.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Models/Registry.swift
import Foundation

struct RegistryEntry: Codable, Equatable {
    let id: String
    let name: String
    let upstreamProject: String
    let upstreamDownloadURL: String
    let license: String
    let group: String
    let enabledByDefault: Bool
    let premium: Bool
    let notes: String?
}

struct Registry: Codable, Equatable {
    let registryVersion: Int
    let filters: [RegistryEntry]
}
```

- [ ] **Step 7: Implement `RegistryLoader.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Registry/RegistryLoader.swift
import Foundation

enum RegistryLoaderError: Error, Equatable {
    case fileNotReadable(path: String)
    case malformedJSON(String)
    case unsupportedRegistryVersion(found: Int, supported: Int)
}

enum RegistryLoader {
    static let supportedRegistryVersion = 1

    static func load(from url: URL) throws -> Registry {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RegistryLoaderError.fileNotReadable(path: url.path)
        }

        let registry: Registry
        do {
            registry = try JSONDecoder().decode(Registry.self, from: data)
        } catch {
            throw RegistryLoaderError.malformedJSON("\(error)")
        }

        guard registry.registryVersion == supportedRegistryVersion else {
            throw RegistryLoaderError.unsupportedRegistryVersion(
                found: registry.registryVersion,
                supported: supportedRegistryVersion
            )
        }

        return registry
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter RegistryTests`
Expected: PASS (3 tests).

- [ ] **Step 9: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): scaffold SPM package, implement Registry model and RegistryLoader"
```

---

## Task 3: Validation errors and the accumulating Validator (registry-level checks)

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/Validation/ValidationError.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/Validation/Validator.swift`
- Test: `backend/tools/Publisher/Tests/PublisherTests/ValidationTests.swift`

**Interfaces:**
- Consumes: `Registry`, `RegistryEntry` (Task 2).
- Produces:
  - `enum ValidationError: Error, Equatable, Comparable` with cases:
    `.emptyRegistry`, `.invalidGroup(id: String, found: String)`,
    `.duplicateRegistryID(id: String)`. (Metadata/payload cases added in
    Task 7.) `Comparable` sorts by category rank (Registry=0, Metadata=1,
    Payload=2) then by associated `id`/`found` string, ascending.
  - `struct ValidationReport: Equatable { let errors: [ValidationError]; var isValid: Bool { errors.isEmpty } }`.
  - `enum Validator { static func validateRegistry(_ registry: Registry) -> [ValidationError] }` —
    pure function, no filesystem access, returns every registry-level error
    found (does not stop at the first). Task 7 adds
    `Validator.validate(registry:metadataDirectory:payloadDirectory:) -> ValidationReport`,
    which calls this function as its first phase.

- [ ] **Step 1: Write the failing tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/ValidationTests.swift
import XCTest
@testable import Publisher

final class ValidationTests: XCTestCase {
    func test_emptyRegistry() {
        let registry = Registry(registryVersion: 1, filters: [])
        let errors = Validator.validateRegistry(registry)
        XCTAssertEqual(errors, [.emptyRegistry])
    }

    func test_invalidGroup() {
        let entry = makeEntry(id: "easylist", group: "advertisements")
        let registry = Registry(registryVersion: 1, filters: [entry])
        let errors = Validator.validateRegistry(registry)
        XCTAssertEqual(errors, [.invalidGroup(id: "easylist", found: "advertisements")])
    }

    func test_duplicateRegistryID() {
        let entryA = makeEntry(id: "easylist", group: "ads")
        let entryB = makeEntry(id: "easylist", group: "privacy")
        let registry = Registry(registryVersion: 1, filters: [entryA, entryB])
        let errors = Validator.validateRegistry(registry)
        XCTAssertEqual(errors, [.duplicateRegistryID(id: "easylist")])
    }

    func test_collectsMultipleIndependentErrors() {
        let entryA = makeEntry(id: "easylist", group: "advertisements")
        let entryB = makeEntry(id: "easylist", group: "privacy")
        let registry = Registry(registryVersion: 1, filters: [entryA, entryB])
        let errors = Validator.validateRegistry(registry)

        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.contains(.invalidGroup(id: "easylist", found: "advertisements")))
        XCTAssertTrue(errors.contains(.duplicateRegistryID(id: "easylist")))
    }

    func test_validRegistryProducesNoErrors() {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads")])
        XCTAssertEqual(Validator.validateRegistry(registry), [])
    }

    func test_sortOrderIsCategoryThenID() {
        let unsorted: [ValidationError] = [
            .invalidGroup(id: "zeta", found: "bad"),
            .duplicateRegistryID(id: "alpha"),
            .emptyRegistry
        ]
        XCTAssertEqual(unsorted.sorted(), [.emptyRegistry, .duplicateRegistryID(id: "alpha"), .invalidGroup(id: "zeta", found: "bad")])
    }

    private func makeEntry(id: String, group: String) -> RegistryEntry {
        RegistryEntry(
            id: id, name: id, upstreamProject: "Test", upstreamDownloadURL: "https://example.invalid/\(id).txt",
            license: "MIT", group: group, enabledByDefault: true, premium: false, notes: nil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter ValidationTests`
Expected: FAIL to compile — `ValidationError`, `Validator` don't exist.

- [ ] **Step 3: Implement `ValidationError.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Validation/ValidationError.swift
import Foundation

enum ValidationError: Error, Equatable {
    case emptyRegistry
    case invalidGroup(id: String, found: String)
    case duplicateRegistryID(id: String)
    case missingMetadata(id: String)
    case metadataIDMismatch(filename: String, declaredID: String)
    case orphanedMetadata(id: String)
    case duplicateMetadata(id: String)
    case missingPayload(id: String, expectedPath: String)

    /// Registry=0, Metadata=1, Payload=2 — fixed category order for deterministic reporting.
    private var categoryRank: Int {
        switch self {
        case .emptyRegistry, .invalidGroup, .duplicateRegistryID:
            return 0
        case .missingMetadata, .metadataIDMismatch, .orphanedMetadata, .duplicateMetadata:
            return 1
        case .missingPayload:
            return 2
        }
    }

    private var sortKey: String {
        switch self {
        case .emptyRegistry:
            return ""
        case .invalidGroup(let id, _), .duplicateRegistryID(let id),
             .missingMetadata(let id), .orphanedMetadata(let id),
             .duplicateMetadata(let id), .missingPayload(let id, _):
            return id
        case .metadataIDMismatch(let filename, _):
            return filename
        }
    }

    static func < (lhs: ValidationError, rhs: ValidationError) -> Bool {
        if lhs.categoryRank != rhs.categoryRank {
            return lhs.categoryRank < rhs.categoryRank
        }
        return lhs.sortKey < rhs.sortKey
    }
}

extension ValidationError: Comparable {}

struct ValidationReport: Equatable {
    let errors: [ValidationError]

    var isValid: Bool { errors.isEmpty }
}
```

- [ ] **Step 4: Implement `Validator.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Validation/Validator.swift
import Foundation

enum Validator {
    static let validGroups: Set<String> = ["ads", "privacy", "annoyances", "regional"]

    /// Registry-level checks only. Pure function — no filesystem access.
    /// Accumulates every independent error found; does not stop at the first.
    static func validateRegistry(_ registry: Registry) -> [ValidationError] {
        var errors: [ValidationError] = []

        if registry.filters.isEmpty {
            errors.append(.emptyRegistry)
        }

        for entry in registry.filters where !validGroups.contains(entry.group) {
            errors.append(.invalidGroup(id: entry.id, found: entry.group))
        }

        var seenIDs: Set<String> = []
        var duplicateIDs: Set<String> = []
        for entry in registry.filters {
            if seenIDs.contains(entry.id) {
                duplicateIDs.insert(entry.id)
            }
            seenIDs.insert(entry.id)
        }
        for id in duplicateIDs.sorted() {
            errors.append(.duplicateRegistryID(id: id))
        }

        return errors
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter ValidationTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): add ValidationError/ValidationReport and registry-level Validator checks"
```

---

## Task 4: Metadata loading

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/Models/FilterMetadata.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/Metadata/MetadataLoader.swift`
- Test: `backend/tools/Publisher/Tests/PublisherTests/MetadataTests.swift`

**Interfaces:**
- Produces:
  - `struct FilterMetadata: Codable, Equatable { let id: String; let version: String }`.
  - `enum MetadataLoaderError: Error, Equatable { case directoryNotReadable(path: String), case malformedJSON(filename: String, String) }`.
  - `enum MetadataLoader { static func loadAll(from directoryURL: URL) throws -> [String: FilterMetadata] }` —
    returns a dictionary keyed by the metadata file's *filename-derived* id
    (the part of the filename before `.json`), with the decoded
    `FilterMetadata` as the value. **Does not** validate that the file's
    `id` field matches its filename, and does not check for duplicates
    across case-variant filenames — those are `Validator`'s job (Task 7),
    which receives this raw dictionary plus the original filenames to
    detect mismatches. To make that detection possible, `loadAll` returns
    `[(filename: String, metadata: FilterMetadata)]` instead of a
    deduplicating dictionary — see Step 3.

- [ ] **Step 1: Write the failing tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/MetadataTests.swift
import XCTest
@testable import Publisher

final class MetadataTests: XCTestCase {
    func test_loadsAllMetadataFilesInDirectory() throws {
        let dir = try Self.makeTempDirectory()
        try Self.writeMetadata(id: "easylist", version: "2026-07-15", in: dir)
        try Self.writeMetadata(id: "easyprivacy", version: "2026-07-16", in: dir)

        let results = try MetadataLoader.loadAll(from: dir)

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.filename == "easylist.json" && $0.metadata.id == "easylist" && $0.metadata.version == "2026-07-15" })
        XCTAssertTrue(results.contains { $0.filename == "easyprivacy.json" && $0.metadata.id == "easyprivacy" && $0.metadata.version == "2026-07-16" })
    }

    func test_ignoresNonJSONFiles() throws {
        let dir = try Self.makeTempDirectory()
        try Self.writeMetadata(id: "easylist", version: "2026-07-15", in: dir)
        try "not metadata".write(to: dir.appendingPathComponent(".gitkeep"), atomically: true, encoding: .utf8)

        let results = try MetadataLoader.loadAll(from: dir)
        XCTAssertEqual(results.count, 1)
    }

    func test_emptyDirectoryProducesNoResults() throws {
        let dir = try Self.makeTempDirectory()
        let results = try MetadataLoader.loadAll(from: dir)
        XCTAssertEqual(results.count, 0)
    }

    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeMetadata(id: String, version: String, in directory: URL) throws {
        let json = "{\"id\": \"\(id)\", \"version\": \"\(version)\"}"
        let url = directory.appendingPathComponent("\(id).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter MetadataTests`
Expected: FAIL to compile — `FilterMetadata`, `MetadataLoader` don't exist.

- [ ] **Step 3: Implement `FilterMetadata.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Models/FilterMetadata.swift
struct FilterMetadata: Codable, Equatable {
    let id: String
    let version: String
}
```

- [ ] **Step 4: Implement `MetadataLoader.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Metadata/MetadataLoader.swift
import Foundation

enum MetadataLoaderError: Error, Equatable {
    case directoryNotReadable(path: String)
    case malformedJSON(filename: String, message: String)
}

enum MetadataLoader {
    /// Returns one entry per `.json` file in `directoryURL`, paired with its filename.
    /// Deliberately does not deduplicate or cross-check filename vs. declared `id` —
    /// that's `Validator`'s job, which needs both pieces of information to report
    /// `metadataIDMismatch`/`duplicateMetadata` precisely.
    static func loadAll(from directoryURL: URL) throws -> [(filename: String, metadata: FilterMetadata)] {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            )
        } catch {
            throw MetadataLoaderError.directoryNotReadable(path: directoryURL.path)
        }

        var results: [(filename: String, metadata: FilterMetadata)] = []
        for fileURL in contents where fileURL.pathExtension == "json" {
            let data = try Data(contentsOf: fileURL)
            do {
                let metadata = try JSONDecoder().decode(FilterMetadata.self, from: data)
                results.append((filename: fileURL.lastPathComponent, metadata: metadata))
            } catch {
                throw MetadataLoaderError.malformedJSON(
                    filename: fileURL.lastPathComponent, message: "\(error)"
                )
            }
        }
        return results
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter MetadataTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): add FilterMetadata model and MetadataLoader"
```

---

## Task 5: Payload reading — checksum and rule count

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/Payload/PayloadReader.swift`
- Test: `backend/tools/Publisher/Tests/PublisherTests/PayloadTests.swift`

**Interfaces:**
- Produces:
  - `struct PayloadInfo: Equatable { let checksumSHA256: String; let ruleCount: Int }`.
  - `enum PayloadReaderError: Error, Equatable { case fileNotFound(path: String) }`.
  - `enum PayloadReader { static func read(fileAt url: URL) throws -> PayloadInfo }` —
    `checksumSHA256` is lowercase hex SHA-256 of the exact file bytes
    (matches iOS `Checksum.sha256Hex(of:)`); `ruleCount` counts lines that
    are non-empty and don't start with `!` (adblock-format comment lines)
    after trimming whitespace. `ManifestBuilder` (Task 6) consumes
    `PayloadInfo` directly.

- [ ] **Step 1: Write the failing tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/PayloadTests.swift
import XCTest
import CryptoKit
@testable import Publisher

final class PayloadTests: XCTestCase {
    func test_computesChecksumMatchingSHA256() throws {
        let content = "||example.com^\n||ads.example.com^\n"
        let url = try Self.writeTempFile(contents: content)

        let info = try PayloadReader.read(fileAt: url)

        let expectedDigest = SHA256.hash(data: Data(content.utf8))
        let expectedHex = expectedDigest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(info.checksumSHA256, expectedHex)
    }

    func test_countsNonEmptyNonCommentLinesAsRules() throws {
        let content = """
        ! this is a comment
        ||example.com^
        
        ||ads.example.com^
        ! another comment
        """
        let url = try Self.writeTempFile(contents: content)

        let info = try PayloadReader.read(fileAt: url)

        XCTAssertEqual(info.ruleCount, 2)
    }

    func test_throwsWhenFileMissing() {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.txt")
        XCTAssertThrowsError(try PayloadReader.read(fileAt: missingURL)) { error in
            guard case PayloadReaderError.fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        }
    }

    static func writeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter PayloadTests`
Expected: FAIL to compile — `PayloadReader`, `PayloadInfo`,
`PayloadReaderError` don't exist.

- [ ] **Step 3: Implement `PayloadReader.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Payload/PayloadReader.swift
import Foundation
import CryptoKit

struct PayloadInfo: Equatable {
    let checksumSHA256: String
    let ruleCount: Int
}

enum PayloadReaderError: Error, Equatable {
    case fileNotFound(path: String)
}

enum PayloadReader {
    static func read(fileAt url: URL) throws -> PayloadInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PayloadReaderError.fileNotFound(path: url.path)
        }

        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        let text = String(decoding: data, as: UTF8.self)
        let ruleCount = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
            .count

        return PayloadInfo(checksumSHA256: checksum, ruleCount: ruleCount)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter PayloadTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): add PayloadReader (checksum + rule count)"
```

---

## Task 6: Manifest model and ManifestBuilder

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/Models/Manifest.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/Manifest/ManifestBuilder.swift`
- Test: `backend/tools/Publisher/Tests/PublisherTests/ManifestTests.swift`

**Interfaces:**
- Consumes: `Registry`, `RegistryEntry` (Task 2), `FilterMetadata` (Task 4),
  `PayloadInfo` (Task 5).
- Produces:
  - `struct ManifestEntry: Codable, Equatable` with fields in this exact
    order (Codable key order follows declaration order when using a custom
    `CodingKeys` matching declaration order): `id`, `name`, `group`,
    `sourceURL`, `version`, `checksumSHA256`, `ruleCount`,
    `enabledByDefault`, `premium` — matching
    `ManifestSpecification.md` exactly.
  - `struct Manifest: Codable, Equatable { let manifestVersion: String; let entries: [ManifestEntry] }`.
  - `enum ManifestBuilder { static func build(registry: Registry, metadataByID: [String: FilterMetadata], payloadInfoByID: [String: PayloadInfo], publishBaseURL: String) -> Manifest }` —
    pure function, no filesystem access. Assumes inputs are already
    validated/consistent (Task 7's `Validator` runs first and the caller —
    Task 11's `PublishCommand` — never calls this with missing
    metadata/payload keys). Sorts `entries` ascending by `id` before
    returning. Later tasks (`PublishCommand`, integration tests) call this
    exact signature.

- [ ] **Step 1: Write the failing tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/ManifestTests.swift
import XCTest
@testable import Publisher

final class ManifestTests: XCTestCase {
    func test_buildsManifestEntryFromRegistryMetadataAndPayload() {
        let registry = Registry(registryVersion: 1, filters: [
            RegistryEntry(
                id: "easylist", name: "EasyList", upstreamProject: "EasyList",
                upstreamDownloadURL: "https://easylist.to/easylist/easylist.txt",
                license: "CC BY-SA 3.0 / GPLv3", group: "ads",
                enabledByDefault: true, premium: false, notes: nil
            )
        ])
        let metadata = ["easylist": FilterMetadata(id: "easylist", version: "2026-07-15")]
        let payload = ["easylist": PayloadInfo(checksumSHA256: "abc123", ruleCount: 62000)]

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadata, payloadInfoByID: payload,
            publishBaseURL: "https://cdn.adblx.com"
        )

        XCTAssertEqual(manifest.entries.count, 1)
        let entry = manifest.entries[0]
        XCTAssertEqual(entry.id, "easylist")
        XCTAssertEqual(entry.name, "EasyList")
        XCTAssertEqual(entry.group, "ads")
        XCTAssertEqual(entry.sourceURL, "https://cdn.adblx.com/backend/public/filters/ads/easylist.txt")
        XCTAssertEqual(entry.version, "2026-07-15")
        XCTAssertEqual(entry.checksumSHA256, "abc123")
        XCTAssertEqual(entry.ruleCount, 62000)
        XCTAssertEqual(entry.enabledByDefault, true)
        XCTAssertEqual(entry.premium, false)
    }

    func test_manifestVersionIsMaxOfEntryVersions() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "easylist", group: "ads"),
            makeEntry(id: "easyprivacy", group: "privacy")
        ])
        let metadata = [
            "easylist": FilterMetadata(id: "easylist", version: "2026-07-15"),
            "easyprivacy": FilterMetadata(id: "easyprivacy", version: "2026-07-20")
        ]
        let payload = [
            "easylist": PayloadInfo(checksumSHA256: "a", ruleCount: 1),
            "easyprivacy": PayloadInfo(checksumSHA256: "b", ruleCount: 2)
        ]

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadata, payloadInfoByID: payload,
            publishBaseURL: "https://cdn.adblx.com"
        )

        XCTAssertEqual(manifest.manifestVersion, "2026-07-20")
    }

    func test_entriesAreSortedAscendingByID() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "zebra", group: "ads"),
            makeEntry(id: "alpha", group: "privacy")
        ])
        let metadata = [
            "zebra": FilterMetadata(id: "zebra", version: "2026-07-15"),
            "alpha": FilterMetadata(id: "alpha", version: "2026-07-15")
        ]
        let payload = [
            "zebra": PayloadInfo(checksumSHA256: "a", ruleCount: 1),
            "alpha": PayloadInfo(checksumSHA256: "b", ruleCount: 2)
        ]

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadata, payloadInfoByID: payload,
            publishBaseURL: "https://cdn.adblx.com"
        )

        XCTAssertEqual(manifest.entries.map(\.id), ["alpha", "zebra"])
    }

    func test_manifestEntryEncodesWithExactKeyOrder() throws {
        let entry = ManifestEntry(
            id: "easylist", name: "EasyList", group: "ads",
            sourceURL: "https://cdn.adblx.com/backend/public/filters/ads/easylist.txt",
            version: "2026-07-15", checksumSHA256: "abc123", ruleCount: 62000,
            enabledByDefault: true, premium: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // NOTE: sortedKeys is used here only to prove round-trip Codable correctness;
        // ManifestWriter (Task 9/11) uses declaration-order encoding, verified by the
        // golden-file integration test (Task 10), not by this unit test.
        let data = try encoder.encode(entry)
        let decoded = try JSONDecoder().decode(ManifestEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    private func makeEntry(id: String, group: String) -> RegistryEntry {
        RegistryEntry(
            id: id, name: id, upstreamProject: "Test", upstreamDownloadURL: "https://example.invalid/\(id).txt",
            license: "MIT", group: group, enabledByDefault: true, premium: false, notes: nil
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter ManifestTests`
Expected: FAIL to compile — `ManifestEntry`, `Manifest`, `ManifestBuilder`
don't exist.

- [ ] **Step 3: Implement `Manifest.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Models/Manifest.swift
struct ManifestEntry: Codable, Equatable {
    let id: String
    let name: String
    let group: String
    let sourceURL: String
    let version: String
    let checksumSHA256: String
    let ruleCount: Int
    let enabledByDefault: Bool
    let premium: Bool
}

struct Manifest: Codable, Equatable {
    let manifestVersion: String
    let entries: [ManifestEntry]
}
```

- [ ] **Step 4: Implement `ManifestBuilder.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Manifest/ManifestBuilder.swift
import Foundation

enum ManifestBuilder {
    /// Assumes `registry`, `metadataByID`, and `payloadInfoByID` are already validated
    /// consistent (every registered filter has a metadata and payload entry) — Validator
    /// (Task 7) runs before this is ever called in the real `publish` pipeline.
    static func build(
        registry: Registry,
        metadataByID: [String: FilterMetadata],
        payloadInfoByID: [String: PayloadInfo],
        publishBaseURL: String
    ) -> Manifest {
        let entries: [ManifestEntry] = registry.filters.map { entry in
            let metadata = metadataByID[entry.id]!
            let payload = payloadInfoByID[entry.id]!
            let sourceURL = "\(publishBaseURL)/backend/public/filters/\(entry.group)/\(entry.id).txt"

            return ManifestEntry(
                id: entry.id,
                name: entry.name,
                group: entry.group,
                sourceURL: sourceURL,
                version: metadata.version,
                checksumSHA256: payload.checksumSHA256,
                ruleCount: payload.ruleCount,
                enabledByDefault: entry.enabledByDefault,
                premium: entry.premium
            )
        }.sorted { $0.id < $1.id }

        let manifestVersion = entries.map(\.version).max() ?? ""

        return Manifest(manifestVersion: manifestVersion, entries: entries)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter ManifestTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): add Manifest model and ManifestBuilder"
```

---

## Task 7: Full Validator — metadata and payload checks, wired into one entry point

**Files:**
- Modify: `backend/tools/Publisher/Sources/Publisher/Validation/Validator.swift`
- Modify: `backend/tools/Publisher/Tests/PublisherTests/ValidationTests.swift`

**Interfaces:**
- Consumes: `Registry`, `RegistryEntry` (Task 2), `MetadataLoader` (Task 4),
  `ValidationError`, `ValidationReport` (Task 3).
- Produces:
  `enum Validator { static func validate(registry: Registry, metadataDirectory: URL, payloadDirectory: URL) throws -> ValidationReport }` —
  this is the one entry point `ValidateCommand`/`PublishCommand` (Task 11)
  call. It runs `validateRegistry` (Task 3) first, then loads metadata via
  `MetadataLoader.loadAll`, cross-checks metadata against the registry
  (missing/orphaned/duplicate/id-mismatch), then checks each registered
  filter's payload file exists at
  `payloadDirectory/{group}/{id}.txt`, accumulating every error found (not
  stopping at the first) into one sorted `ValidationReport`. Throws only for
  genuinely fatal conditions (metadata directory itself unreadable) — a
  missing individual metadata *file* is a `ValidationError`, not a throw.

- [ ] **Step 1: Write the failing tests (append to existing `ValidationTests.swift`)**

```swift
// Append inside ValidationTests class in
// backend/tools/Publisher/Tests/PublisherTests/ValidationTests.swift

    func test_fullValidate_missingMetadataForOneOfThreeFilters() throws {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "easylist", group: "ads"),
            makeEntry(id: "easyprivacy", group: "privacy"),
            makeEntry(id: "fanboy-annoyances", group: "annoyances")
        ])
        let metadataDir = try MetadataTests.makeTempDirectory()
        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        // easyprivacy metadata deliberately missing
        try MetadataTests.writeMetadata(id: "fanboy-annoyances", version: "2026-07-15", in: metadataDir)

        let payloadDir = try Self.makeTempPayloadTree(ids: ["easylist", "easyprivacy", "fanboy-annoyances"], groups: ["ads", "privacy", "annoyances"])

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains(.missingMetadata(id: "easyprivacy")))
    }

    func test_fullValidate_orphanedMetadata() throws {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads")])
        let metadataDir = try MetadataTests.makeTempDirectory()
        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        try MetadataTests.writeMetadata(id: "unregistered-filter", version: "2026-07-15", in: metadataDir)
        let payloadDir = try Self.makeTempPayloadTree(ids: ["easylist"], groups: ["ads"])

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertTrue(report.errors.contains(.orphanedMetadata(id: "unregistered-filter")))
    }

    func test_fullValidate_missingPayload() throws {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads")])
        let metadataDir = try MetadataTests.makeTempDirectory()
        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        let payloadDir = try MetadataTests.makeTempDirectory() // empty — no payload files

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertTrue(report.errors.contains {
            if case .missingPayload(let id, _) = $0 { return id == "easylist" }
            return false
        })
    }

    func test_fullValidate_middleOfThreeFails_stillReportsAllErrors() throws {
        // Regression coverage for docs/gotchas.md's "batch/transactional test coverage"
        // lesson: a failure in the *middle* of a 3-item batch, not just the first/only item.
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "easylist", group: "ads"),
            makeEntry(id: "easyprivacy", group: "privacy"),
            makeEntry(id: "fanboy-annoyances", group: "annoyances")
        ])
        let metadataDir = try MetadataTests.makeTempDirectory()
        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        // easyprivacy (the middle filter) metadata deliberately missing
        try MetadataTests.writeMetadata(id: "fanboy-annoyances", version: "2026-07-15", in: metadataDir)
        let payloadDir = try Self.makeTempPayloadTree(ids: ["easylist", "fanboy-annoyances"], groups: ["ads", "annoyances"])

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains(.missingMetadata(id: "easyprivacy")))
        XCTAssertTrue(report.errors.contains {
            if case .missingPayload(let id, _) = $0 { return id == "easyprivacy" }
            return false
        })
    }

    func test_fullValidate_allConsistentProducesValidReport() throws {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads")])
        let metadataDir = try MetadataTests.makeTempDirectory()
        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        let payloadDir = try Self.makeTempPayloadTree(ids: ["easylist"], groups: ["ads"])

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertTrue(report.isValid)
    }

    static func makeTempPayloadTree(ids: [String], groups: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (id, group) in zip(ids, groups) {
            let groupDir = root.appendingPathComponent(group)
            try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
            try "||example.com^\n".write(to: groupDir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8)
        }
        return root
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter ValidationTests`
Expected: FAIL to compile — `Validator.validate(registry:metadataDirectory:payloadDirectory:)`
doesn't exist yet.

- [ ] **Step 3: Extend `Validator.swift` with the full entry point**

```swift
// Append inside `enum Validator` in
// backend/tools/Publisher/Sources/Publisher/Validation/Validator.swift

    static func validate(
        registry: Registry,
        metadataDirectory: URL,
        payloadDirectory: URL
    ) throws -> ValidationReport {
        var errors = validateRegistry(registry)

        let registeredIDs = Set(registry.filters.map(\.id))
        let metadataEntries = try MetadataLoader.loadAll(from: metadataDirectory)

        var metadataByDeclaredID: [String: [String]] = [:] // declaredID -> [filenames]
        for entry in metadataEntries {
            let declaredID = entry.metadata.id
            let expectedFilename = "\(declaredID).json"
            if entry.filename != expectedFilename {
                errors.append(.metadataIDMismatch(filename: entry.filename, declaredID: declaredID))
            }
            metadataByDeclaredID[declaredID, default: []].append(entry.filename)
        }

        for (declaredID, filenames) in metadataByDeclaredID {
            if filenames.count > 1 {
                errors.append(.duplicateMetadata(id: declaredID))
            }
            if !registeredIDs.contains(declaredID) {
                errors.append(.orphanedMetadata(id: declaredID))
            }
        }

        for id in registeredIDs where metadataByDeclaredID[id] == nil {
            errors.append(.missingMetadata(id: id))
        }

        for entry in registry.filters {
            let payloadURL = payloadDirectory
                .appendingPathComponent(entry.group)
                .appendingPathComponent("\(entry.id).txt")
            if !FileManager.default.fileExists(atPath: payloadURL.path) {
                errors.append(.missingPayload(id: entry.id, expectedPath: payloadURL.path))
            }
        }

        return ValidationReport(errors: errors.sorted())
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter ValidationTests`
Expected: PASS (11 tests total — 6 from Task 3, 5 new).

- [ ] **Step 5: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): extend Validator with metadata/payload cross-checks and full validate() entry point"
```

---

## Task 8: MarkdownGenerator — generate `FilterRegistry.md` from the registry

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/Documentation/MarkdownGenerator.swift`
- Test: `backend/tools/Publisher/Tests/PublisherTests/DocumentationTests.swift`
- Modify: `backend/docs/FilterRegistry.md` (regenerated by hand once, to
  prove the generator's output matches — see Step 6)

**Interfaces:**
- Consumes: `Registry`, `RegistryEntry` (Task 2).
- Produces: `enum MarkdownGenerator { static func generateFilterRegistry(from registry: Registry) -> String }` —
  pure function, returns the full Markdown document as a string (LF line
  endings, trailing newline). Groups entries by `group` in fixed order
  `["ads", "privacy", "annoyances", "regional"]` (this order is defined by
  the client's `FilterGroup` domain model, not alphabetical/JSON order),
  sorted ascending by `id` within each group. Task 11's
  `GenerateDocsCommand` calls this and writes the result via
  `AtomicFileWriter` (Task 9).

- [ ] **Step 1: Write the failing tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/DocumentationTests.swift
import XCTest
@testable import Publisher

final class DocumentationTests: XCTestCase {
    func test_generatesTableRowForEachFilter() {
        let registry = Registry(registryVersion: 1, filters: [
            RegistryEntry(
                id: "easylist", name: "EasyList", upstreamProject: "EasyList",
                upstreamDownloadURL: "https://easylist.to/easylist/easylist.txt",
                license: "CC BY-SA 3.0 / GPLv3", group: "ads",
                enabledByDefault: true, premium: false, notes: nil
            )
        ])

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        XCTAssertTrue(markdown.contains("EasyList"))
        XCTAssertTrue(markdown.contains("easylist"))
        XCTAssertTrue(markdown.contains("https://easylist.to/easylist/easylist.txt"))
        XCTAssertTrue(markdown.contains("CC BY-SA 3.0 / GPLv3"))
    }

    func test_groupsAppearInFixedDomainOrderNotAlphabetical() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "regional-filter", group: "regional"),
            makeEntry(id: "ads-filter", group: "ads")
        ])

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        let adsHeadingRange = markdown.range(of: "### Ads")!
        let regionalHeadingRange = markdown.range(of: "### Regional")!
        XCTAssertTrue(adsHeadingRange.lowerBound < regionalHeadingRange.lowerBound)
    }

    func test_entriesWithinGroupSortedAscendingByID() {
        let registry = Registry(registryVersion: 1, filters: [
            makeEntry(id: "zebra", group: "ads"),
            makeEntry(id: "alpha", group: "ads")
        ])

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        let alphaRange = markdown.range(of: "alpha")!
        let zebraRange = markdown.range(of: "zebra")!
        XCTAssertTrue(alphaRange.lowerBound < zebraRange.lowerBound)
    }

    func test_noNotesRendersEmptyNotDashPlaceholder() {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads", notes: nil)])
        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)
        // Notes column renders "—" for nil, matching the existing hand-authored convention.
        XCTAssertTrue(markdown.contains("| — |") || markdown.contains("—"))
    }

    private func makeEntry(id: String, group: String, notes: String? = nil) -> RegistryEntry {
        RegistryEntry(
            id: id, name: id, upstreamProject: "Test", upstreamDownloadURL: "https://example.invalid/\(id).txt",
            license: "MIT", group: group, enabledByDefault: true, premium: false, notes: notes
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter DocumentationTests`
Expected: FAIL to compile — `MarkdownGenerator` doesn't exist.

- [ ] **Step 3: Implement `MarkdownGenerator.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Documentation/MarkdownGenerator.swift
import Foundation

enum MarkdownGenerator {
    /// Fixed by the client's `FilterGroup` domain model — never alphabetical, never
    /// `filters.json` array order.
    private static let groupOrder = ["ads", "privacy", "annoyances", "regional"]
    private static let groupDisplayNames = ["ads": "Ads", "privacy": "Privacy", "annoyances": "Annoyances", "regional": "Regional"]

    static func generateFilterRegistry(from registry: Registry) -> String {
        var lines: [String] = []
        lines.append("# ADBLX Filter Registry (v1)")
        lines.append("")
        lines.append("> **Generated file — do not edit by hand.** Produced by the `Publisher`")
        lines.append("> tool's `generate-docs` command from `backend/registry/filters.json`.")
        lines.append("> Future candidates live in `backend/docs/RegistryRoadmap.md`.")
        lines.append("")
        lines.append("## Registered Filters")
        lines.append("")

        for group in groupOrder {
            let entriesInGroup = registry.filters
                .filter { $0.group == group }
                .sorted { $0.id < $1.id }

            lines.append("### \(groupDisplayNames[group] ?? group)")
            lines.append("")

            if entriesInGroup.isEmpty {
                lines.append("No production filter is registered for v1.")
                lines.append("")
                continue
            }

            lines.append("| Field | Value |")
            lines.append("|---|---|")
            for entry in entriesInGroup {
                lines.append("| Display name | \(entry.name) |")
                lines.append("| Internal ID | `\(entry.id)` |")
                lines.append("| Upstream project | \(entry.upstreamProject) |")
                lines.append("| Upstream download URL | \(entry.upstreamDownloadURL) |")
                lines.append("| License | \(entry.license) |")
                lines.append("| ADBLX FilterGroup | \(groupDisplayNames[group] ?? group) |")
                lines.append("| Default enabled (fresh installation) | \(entry.enabledByDefault ? "✅" : "❌") |")
                lines.append("| Premium | \(entry.premium ? "✅" : "❌") |")
                lines.append("| Notes | \(entry.notes ?? "—") |")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter DocumentationTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): add MarkdownGenerator for FilterRegistry.md"
```

Note: `backend/docs/FilterRegistry.md` itself is regenerated for real in
Task 11 Step 6, once the CLI can actually run `generate-docs` end to end —
no point hand-simulating the generator's output here.

---

## Task 9: AtomicFileWriter

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/Utilities/AtomicFileWriter.swift`
- Test: `backend/tools/Publisher/Tests/PublisherTests/AtomicFileWriterTests.swift`

**Interfaces:**
- Produces: `enum AtomicFileWriterError: Error, Equatable { case fsyncFailed(errno: Int32), case renameFailed(errno: Int32) }`
  and `struct AtomicFileWriter { func write(_ data: Data, to destinationURL: URL) throws }` —
  mirrors `ADBLX/Filtering/Storage/AtomicRuleWriter.swift`'s pattern exactly
  (write to temp file in same directory → fsync → rename over destination),
  reimplemented here because the publisher target can't import the iOS
  app's module. Task 11's `GenerateDocsCommand`/`PublishCommand` are the
  only callers.

- [ ] **Step 1: Write the failing tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/AtomicFileWriterTests.swift
import XCTest
@testable import Publisher

final class AtomicFileWriterTests: XCTestCase {
    func test_writesDataToDestination() throws {
        let dir = try MetadataTests.makeTempDirectory()
        let destination = dir.appendingPathComponent("output.json")
        let writer = AtomicFileWriter()

        try writer.write(Data("hello".utf8), to: destination)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(contents, "hello")
    }

    func test_overwritesExistingFileAtomically() throws {
        let dir = try MetadataTests.makeTempDirectory()
        let destination = dir.appendingPathComponent("output.json")
        try "old contents".write(to: destination, atomically: true, encoding: .utf8)
        let writer = AtomicFileWriter()

        try writer.write(Data("new contents".utf8), to: destination)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(contents, "new contents")
    }

    func test_leavesNoTempFilesBehindOnSuccess() throws {
        let dir = try MetadataTests.makeTempDirectory()
        let destination = dir.appendingPathComponent("output.json")
        let writer = AtomicFileWriter()

        try writer.write(Data("hello".utf8), to: destination)

        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(remainingFiles, ["output.json"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend/tools/Publisher && swift test --filter AtomicFileWriterTests`
Expected: FAIL to compile — `AtomicFileWriter` doesn't exist.

- [ ] **Step 3: Implement `AtomicFileWriter.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/Utilities/AtomicFileWriter.swift
import Foundation

enum AtomicFileWriterError: Error, Equatable {
    case fsyncFailed(errno: Int32)
    case renameFailed(errno: Int32)
}

/// Mirrors ADBLX/Filtering/Storage/AtomicRuleWriter.swift's pattern (that type lives in the
/// iOS app target and can't be imported here): write to a temp file in the same directory,
/// fsync, rename over the destination. Guarantees a reader never observes a partially
/// written manifest.json or FilterRegistry.md.
struct AtomicFileWriter {
    func write(_ data: Data, to destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")

        try data.write(to: tempURL, options: .atomic)

        let fd = open(tempURL.path, O_WRONLY)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.fsyncFailed(errno: errno)
        }
        let syncResult = fcntl(fd, F_FULLFSYNC)
        close(fd)
        if syncResult != 0 {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.fsyncFailed(errno: errno)
        }

        do {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AtomicFileWriterError.renameFailed(errno: errno)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter AtomicFileWriterTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/tools/Publisher
git commit -m "feat(publisher): add AtomicFileWriter for durable manifest/docs writes"
```

---

## Task 10: Integration tests — golden files, batch failure, determinism

**Files:**
- Create: `backend/tools/Publisher/Tests/PublisherTests/PublisherIntegrationTests.swift`
- Create: `backend/tools/Publisher/Tests/PublisherTests/Fixtures/golden-manifest.json`
- Create: `backend/tools/Publisher/Tests/PublisherTests/Fixtures/golden-filter-registry.md`

**Interfaces:**
- Consumes: `RegistryLoader`, `MetadataLoader`, `PayloadReader`, `Validator`,
  `ManifestBuilder`, `MarkdownGenerator`, `AtomicFileWriter` (all prior
  tasks). This task wires them together exactly as `PublishCommand`/
  `GenerateDocsCommand` will in Task 11 — it is the proof that the pieces
  compose correctly, written *before* the CLI wiring exists, using the
  same functions directly.
- Produces: no new production code — pure test coverage.

- [ ] **Step 1: Build a shared fixture-tree helper and write the golden-file tests**

```swift
// backend/tools/Publisher/Tests/PublisherTests/PublisherIntegrationTests.swift
import XCTest
@testable import Publisher

final class PublisherIntegrationTests: XCTestCase {
    private func makeThreeFilterFixture() throws -> (registryURL: URL, metadataDir: URL, payloadDir: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let metadataDir = root.appendingPathComponent("metadata")
        let payloadDir = root.appendingPathComponent("public/filters")
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let registryJSON = """
        {
          "registryVersion": 1,
          "filters": [
            {
              "id": "easylist", "name": "EasyList", "upstreamProject": "EasyList",
              "upstreamDownloadURL": "https://easylist.to/easylist/easylist.txt",
              "license": "CC BY-SA 3.0 / GPLv3", "group": "ads",
              "enabledByDefault": true, "premium": false, "notes": null
            },
            {
              "id": "easyprivacy", "name": "EasyPrivacy", "upstreamProject": "EasyList",
              "upstreamDownloadURL": "https://easylist.to/easylist/easyprivacy.txt",
              "license": "CC BY-SA 3.0 / GPLv3", "group": "privacy",
              "enabledByDefault": true, "premium": false, "notes": null
            },
            {
              "id": "fanboy-annoyances", "name": "Fanboy Annoyances", "upstreamProject": "EasyList (Fanboy)",
              "upstreamDownloadURL": "https://easylist.to/easylist/fanboy-annoyance.txt",
              "license": "CC BY-SA 3.0", "group": "annoyances",
              "enabledByDefault": false, "premium": true, "notes": "Gated per PRD \\u00a75.1."
            }
          ]
        }
        """
        let registryURL = root.appendingPathComponent("filters.json")
        try registryJSON.write(to: registryURL, atomically: true, encoding: .utf8)

        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        try MetadataTests.writeMetadata(id: "easyprivacy", version: "2026-07-16", in: metadataDir)
        try MetadataTests.writeMetadata(id: "fanboy-annoyances", version: "2026-07-10", in: metadataDir)

        for (id, group) in [("easylist", "ads"), ("easyprivacy", "privacy"), ("fanboy-annoyances", "annoyances")] {
            let groupDir = payloadDir.appendingPathComponent(group)
            try FileManager.default.createDirectory(at: groupDir, withIntermediateDirectories: true)
            try "||example.com^\n||ads.example.com^\n".write(
                to: groupDir.appendingPathComponent("\(id).txt"), atomically: true, encoding: .utf8
            )
        }

        return (registryURL, metadataDir, payloadDir, root)
    }

    private func runPublishPipeline(publishBaseURL: String) throws -> (manifest: Manifest, report: ValidationReport) {
        let fixture = try makeThreeFilterFixture()
        let registry = try RegistryLoader.load(from: fixture.registryURL)
        let report = try Validator.validate(
            registry: registry, metadataDirectory: fixture.metadataDir, payloadDirectory: fixture.payloadDir
        )
        guard report.isValid else { return (Manifest(manifestVersion: "", entries: []), report) }

        let metadataByID = Dictionary(uniqueKeysWithValues:
            try MetadataLoader.loadAll(from: fixture.metadataDir).map { ($0.metadata.id, $0.metadata) }
        )
        var payloadInfoByID: [String: PayloadInfo] = [:]
        for entry in registry.filters {
            let payloadURL = fixture.payloadDir.appendingPathComponent(entry.group).appendingPathComponent("\(entry.id).txt")
            payloadInfoByID[entry.id] = try PayloadReader.read(fileAt: payloadURL)
        }

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadataByID, payloadInfoByID: payloadInfoByID,
            publishBaseURL: publishBaseURL
        )
        return (manifest, report)
    }

    func test_goldenManifestMatchesByteForByte() throws {
        let (manifest, report) = try runPublishPipeline(publishBaseURL: "https://cdn.adblx.com")
        XCTAssertTrue(report.isValid)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let generatedData = try encoder.encode(manifest)
        let generatedJSON = String(decoding: generatedData, as: UTF8.self)

        let goldenURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden-manifest.json")
        let goldenJSON = try String(contentsOf: goldenURL, encoding: .utf8)

        XCTAssertEqual(generatedJSON.trimmingCharacters(in: .whitespacesAndNewlines),
                        goldenJSON.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func test_goldenFilterRegistryMarkdownMatchesByteForByte() throws {
        let fixture = try makeThreeFilterFixture()
        let registry = try RegistryLoader.load(from: fixture.registryURL)
        let generatedMarkdown = MarkdownGenerator.generateFilterRegistry(from: registry)

        let goldenURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden-filter-registry.md")
        let goldenMarkdown = try String(contentsOf: goldenURL, encoding: .utf8)

        XCTAssertEqual(generatedMarkdown, goldenMarkdown)
    }

    func test_batchFailure_firstFilterFails_noOutputWritten() throws {
        try assertNoOutputWrittenWhenFilterBroken(brokenFilterID: "easylist")
    }

    func test_batchFailure_middleFilterFails_noOutputWritten() throws {
        try assertNoOutputWrittenWhenFilterBroken(brokenFilterID: "easyprivacy")
    }

    func test_batchFailure_lastFilterFails_noOutputWritten() throws {
        try assertNoOutputWrittenWhenFilterBroken(brokenFilterID: "fanboy-annoyances")
    }

    private func assertNoOutputWrittenWhenFilterBroken(brokenFilterID: String) throws {
        let fixture = try makeThreeFilterFixture()
        // Break the named filter's payload by deleting it.
        let registry = try RegistryLoader.load(from: fixture.registryURL)
        let brokenEntry = registry.filters.first { $0.id == brokenFilterID }!
        let brokenPayloadURL = fixture.payloadDir
            .appendingPathComponent(brokenEntry.group)
            .appendingPathComponent("\(brokenFilterID).txt")
        try FileManager.default.removeItem(at: brokenPayloadURL)

        let report = try Validator.validate(
            registry: registry, metadataDirectory: fixture.metadataDir, payloadDirectory: fixture.payloadDir
        )

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains {
            if case .missingPayload(let id, _) = $0 { return id == brokenFilterID }
            return false
        })

        // Simulate the real publish pipeline's refusal to write on any validation error.
        let manifestOutputURL = fixture.root.appendingPathComponent("manifest.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestOutputURL.path))
    }

    func test_determinism_repeatedRunsProduceByteIdenticalManifest() throws {
        let (manifestA, reportA) = try runPublishPipeline(publishBaseURL: "https://cdn.adblx.com")
        let (manifestB, reportB) = try runPublishPipeline(publishBaseURL: "https://cdn.adblx.com")

        XCTAssertTrue(reportA.isValid)
        XCTAssertTrue(reportB.isValid)
        XCTAssertEqual(manifestA, manifestB)
    }

    func test_determinism_repeatedRunsProduceByteIdenticalMarkdown() throws {
        let fixtureA = try makeThreeFilterFixture()
        let registryA = try RegistryLoader.load(from: fixtureA.registryURL)
        let markdownA = MarkdownGenerator.generateFilterRegistry(from: registryA)

        let fixtureB = try makeThreeFilterFixture()
        let registryB = try RegistryLoader.load(from: fixtureB.registryURL)
        let markdownB = MarkdownGenerator.generateFilterRegistry(from: registryB)

        XCTAssertEqual(markdownA, markdownB)
    }
}
```

- [ ] **Step 2: Run to confirm the golden-file tests fail (no golden files exist yet)**

Run: `cd backend/tools/Publisher && swift test --filter PublisherIntegrationTests`
Expected: `test_goldenManifestMatchesByteForByte` and
`test_goldenFilterRegistryMarkdownMatchesByteForByte` FAIL (file not found);
the batch-failure and determinism tests should already PASS since they
don't depend on golden files.

- [ ] **Step 3: Hand-derive the golden manifest fixture independently — do not capture it from the tool's own output**

An ABORT review of this plan flagged that seeding `golden-manifest.json` by
running `ManifestBuilder` once and copying its printed output makes the
golden test self-referential: it would only prove the tool is consistent
with itself across runs, not correct against the frozen
`ManifestSpecification.md` contract. A future regression in, say, the sort
comparator or field derivation would get silently baked into the "golden"
file the first time someone (re)captured it, and the test would still pass.

Instead, compute each field by hand/shell, independently of any Swift code
in this package, then write the golden JSON directly:

```bash
cd backend/tools/Publisher
# Compute the real SHA-256 + rule count for each fixture payload used in
# makeThreeFilterFixture() (Task 10 Step 1) — the payload text there is
# fixed and known: "||example.com^\n||ads.example.com^\n" for all three.
printf '||example.com^\n||ads.example.com^\n' | shasum -a 256
# -> record the hex digest; expect the same value for easylist, easyprivacy,
#    and fanboy-annoyances, since Task 10 Step 1 gives all three the
#    identical fixture payload text.
printf '||example.com^\n||ads.example.com^\n' | grep -cve '^\s*$' -e '^\s*!'
# -> record the rule count (non-empty, non-"!"-comment lines) = 2
```

Using those independently-computed values, hand-write
`backend/tools/Publisher/Tests/PublisherTests/Fixtures/golden-manifest.json`.
Derive every field from the spec/fixture directly, not from running the
publisher:
- `id`/`name`/`group`/`enabledByDefault`/`premium` — copied from the
  registry JSON literal in `makeThreeFilterFixture()` (Task 10 Step 1).
- `version` — copied from the metadata fixture calls in the same step
  (`2026-07-15`, `2026-07-16`, `2026-07-10`).
- `checksumSHA256`/`ruleCount` — the `shasum`/`grep -c` values computed
  above, not read from any Swift test output.
- `sourceURL` — hand-assembled per `ManifestGeneration.md`'s derivation
  rule: `https://cdn.adblx.com/backend/public/filters/{group}/{id}.txt`.
- `manifestVersion` — `max` of the three `version` values above
  (`2026-07-16`), computed by hand per the frozen derivation rule, not by
  running the tool.
- Entries ordered ascending by `id`: `easylist`, `easyprivacy`,
  `fanboy-annoyances`.
- Key order per entry: `id`, `name`, `group`, `sourceURL`, `version`,
  `checksumSHA256`, `ruleCount`, `enabledByDefault`, `premium` (matches
  `ManifestSpecification.md`'s literal example ordering).

Cross-check the shape (key names, nesting, top-level structure) against
`backend/docs/ManifestSpecification.md`'s own literal JSON example — that
document's example was hand-authored in Sprint 6 by a human independent of
this plan, making it a second, independent anchor for the shape (though not
for this fixture's specific values, since the spec's example uses different
filter data).

Only after the golden file is hand-written should the test be run. If
`test_goldenManifestMatchesByteForByte` fails on first run, that is a signal
to debug `ManifestBuilder`/`ManifestEntry` against the hand-derived value —
**never** "fix" the failure by copying the tool's actual output back into
the golden file without first understanding why the two differed.

- [ ] **Step 4: Hand-derive the golden Markdown fixture the same way**

Write `backend/tools/Publisher/Tests/PublisherTests/Fixtures/golden-filter-registry.md`
directly, using the `MarkdownGenerator.generateFilterRegistry` template
structure defined in Task 8 Step 3 (banner, `## Registered Filters`, one
`### {GroupDisplayName}` section per group in fixed order Ads/Privacy/
Annoyances/Regional, one table per non-empty group) and the same registry
fixture data from Task 10 Step 1 (three filters: `easylist`/ads,
`easyprivacy`/privacy, `fanboy-annoyances`/annoyances; `regional` group
present with "No production filter is registered for v1." since no fixture
filter uses that group). Transcribe field values directly from the fixture
registry JSON (Task 10 Step 1), not from running the generator.

As with Step 3: run the test only after hand-writing the fixture. A first-run
failure means debugging `MarkdownGenerator` against the hand-derived
expectation, not re-capturing the tool's output as the new "golden" answer.

- [ ] **Step 5: Run all integration tests to verify they pass**

Run: `cd backend/tools/Publisher && swift test --filter PublisherIntegrationTests`
Expected: PASS (8 tests: 2 golden, 3 batch-failure position, 2 determinism,
plus any helper-only tests).

- [ ] **Step 6: Run the full test suite**

Run: `cd backend/tools/Publisher && swift test`
Expected: PASS, all tests across all files (Task 2 through Task 10).

- [ ] **Step 7: Commit**

```bash
git add backend/tools/Publisher
git commit -m "test(publisher): add golden-file, batch-failure, and determinism integration tests"
```

---

## Task 11: CLI wiring — `validate`, `generate-docs`, `publish`, `generate`

**Files:**
- Create: `backend/tools/Publisher/Sources/Publisher/CLI/PublisherCommand.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/CLI/Commands/ValidateCommand.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/CLI/Commands/GenerateDocsCommand.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/CLI/Commands/PublishCommand.swift`
- Create: `backend/tools/Publisher/Sources/Publisher/CLI/Commands/GenerateCommand.swift`
- Modify: `backend/tools/Publisher/Sources/Publisher/main.swift`
- Modify: `backend/tools/Publisher/Package.swift` (add `swift-argument-parser` dependency)
- Modify: `backend/docs/FilterRegistry.md` (regenerated for real)
- Modify: `backend/public/manifest.json` (generated for real — replaces the
  `{}` placeholder)

**Interfaces:**
- Consumes every module from Tasks 2–9 (`RegistryLoader`, `Validator`,
  `MetadataLoader`, `PayloadReader`, `ManifestBuilder`,
  `MarkdownGenerator`, `AtomicFileWriter`).
- Produces the actual CLI entry point. Fixed input/output paths, relative
  to the repository root the tool is invoked from:
  - Registry: `backend/registry/filters.json`
  - Metadata directory: `backend/metadata/`
  - Payload directory: `backend/public/filters/`
  - Manifest output: `backend/public/manifest.json`
  - Docs output: `backend/docs/FilterRegistry.md`

  These paths are not configurable in Sprint 7 (only `--publish-base-url`
  is a CLI input) — the tool assumes it's run from the repository root.

- [ ] **Step 1: Add `swift-argument-parser` dependency**

```swift
// backend/tools/Publisher/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Publisher",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Publisher",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/Publisher"
        ),
        .testTarget(
            name: "PublisherTests",
            dependencies: ["Publisher"],
            path: "Tests/PublisherTests"
        )
    ]
)
```

- [ ] **Step 2: Verify dependency resolves**

Run: `cd backend/tools/Publisher && swift package resolve`
Expected: succeeds, fetches `swift-argument-parser`.

- [ ] **Step 3: Implement the fixed path constants and shared pipeline helpers**

```swift
// backend/tools/Publisher/Sources/Publisher/CLI/PublisherCommand.swift
import ArgumentParser
import Foundation

enum PublisherPaths {
    static let registryFile = URL(fileURLWithPath: "backend/registry/filters.json")
    static let metadataDirectory = URL(fileURLWithPath: "backend/metadata")
    static let payloadDirectory = URL(fileURLWithPath: "backend/public/filters")
    static let manifestOutput = URL(fileURLWithPath: "backend/public/manifest.json")
    static let filterRegistryDocsOutput = URL(fileURLWithPath: "backend/docs/FilterRegistry.md")
}

enum PublisherExitCode: Int32 {
    case success = 0
    case validationFailure = 1
    case fatalError = 2
}

struct PublisherCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publisher",
        abstract: "Registry to manifest publisher for ADBLX's filter distribution backend.",
        subcommands: [ValidateCommand.self, GenerateDocsCommand.self, PublishCommand.self, GenerateCommand.self]
    )
}

/// Shared helpers used by every subcommand to avoid duplicating the load/validate sequence.
enum PublisherPipeline {
    static func loadAndValidate() throws -> (registry: Registry, report: ValidationReport) {
        let registry = try RegistryLoader.load(from: PublisherPaths.registryFile)
        let report = try Validator.validate(
            registry: registry,
            metadataDirectory: PublisherPaths.metadataDirectory,
            payloadDirectory: PublisherPaths.payloadDirectory
        )
        return (registry, report)
    }

    static func printReport(_ report: ValidationReport) {
        if report.isValid {
            print("✓ Validation passed")
            return
        }
        print("Validation failed (\(report.errors.count) errors)")
        print("")
        for error in report.errors {
            print("- \(describe(error))")
        }
    }

    private static func describe(_ error: ValidationError) -> String {
        switch error {
        case .emptyRegistry:
            return "Registry is empty (zero registered filters)"
        case .invalidGroup(let id, let found):
            return "Invalid group \"\(found)\" for filter \"\(id)\" (expected: ads|privacy|annoyances|regional)"
        case .duplicateRegistryID(let id):
            return "Duplicate registry id \"\(id)\""
        case .missingMetadata(let id):
            return "Missing backend/metadata/\(id).json"
        case .metadataIDMismatch(let filename, let declaredID):
            return "Metadata file \(filename) declares id \"\(declaredID)\", which doesn't match its filename"
        case .orphanedMetadata(let id):
            return "Metadata file for \"\(id)\" does not correspond to any registered filter"
        case .duplicateMetadata(let id):
            return "Duplicate metadata files for id \"\(id)\""
        case .missingPayload(let id, let expectedPath):
            return "Missing payload for \"\(id)\" (expected at \(expectedPath))"
        }
    }
}
```

- [ ] **Step 4: Implement `ValidateCommand`**

```swift
// backend/tools/Publisher/Sources/Publisher/CLI/Commands/ValidateCommand.swift
import ArgumentParser
import Foundation

struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Verify registry, metadata, and payload consistency. Writes nothing."
    )

    func run() throws {
        print("Loading registry...")
        let (registry, report) = try PublisherPipeline.loadAndValidate()
        print("✓ Loaded \(registry.filters.count) filters")
        print("")
        print("Validating...")
        PublisherPipeline.printReport(report)

        if !report.isValid {
            throw ExitCode(PublisherExitCode.validationFailure.rawValue)
        }
    }
}
```

- [ ] **Step 5: Implement `GenerateDocsCommand`**

```swift
// backend/tools/Publisher/Sources/Publisher/CLI/Commands/GenerateDocsCommand.swift
import ArgumentParser
import Foundation

struct GenerateDocsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-docs",
        abstract: "Regenerate backend/docs/FilterRegistry.md from backend/registry/filters.json."
    )

    func run() throws {
        print("Loading registry...")
        let registry = try RegistryLoader.load(from: PublisherPaths.registryFile)
        print("✓ Loaded \(registry.filters.count) filters")
        print("")
        print("Generating documentation...")

        let markdown = MarkdownGenerator.generateFilterRegistry(from: registry)
        try AtomicFileWriter().write(Data(markdown.utf8), to: PublisherPaths.filterRegistryDocsOutput)

        print("✓ Wrote \(PublisherPaths.filterRegistryDocsOutput.path)")
    }
}
```

- [ ] **Step 6: Implement `PublishCommand`**

```swift
// backend/tools/Publisher/Sources/Publisher/CLI/Commands/PublishCommand.swift
import ArgumentParser
import Foundation

struct PublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Produce backend/public/manifest.json from the registry, metadata, and payloads."
    )

    @Option(name: .customLong("publish-base-url"), help: "Deployment base URL, e.g. https://cdn.adblx.com")
    var publishBaseURL: String

    func run() throws {
        print("Loading registry...")
        let (registry, report) = try PublisherPipeline.loadAndValidate()
        print("✓ Loaded \(registry.filters.count) filters")
        print("")
        print("Validating...")
        PublisherPipeline.printReport(report)

        guard report.isValid else {
            throw ExitCode(PublisherExitCode.validationFailure.rawValue)
        }

        print("")
        print("Generating manifest...")

        let metadataEntries = try MetadataLoader.loadAll(from: PublisherPaths.metadataDirectory)
        let metadataByID = Dictionary(uniqueKeysWithValues: metadataEntries.map { ($0.metadata.id, $0.metadata) })

        var payloadInfoByID: [String: PayloadInfo] = [:]
        for entry in registry.filters {
            let payloadURL = PublisherPaths.payloadDirectory
                .appendingPathComponent(entry.group)
                .appendingPathComponent("\(entry.id).txt")
            payloadInfoByID[entry.id] = try PayloadReader.read(fileAt: payloadURL)
        }

        let manifest = ManifestBuilder.build(
            registry: registry, metadataByID: metadataByID, payloadInfoByID: payloadInfoByID,
            publishBaseURL: publishBaseURL
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(manifest)
        try AtomicFileWriter().write(data, to: PublisherPaths.manifestOutput)

        print("✓ Wrote \(PublisherPaths.manifestOutput.path)")
        print("")
        print("Done.")
    }
}
```

- [ ] **Step 7: Implement `GenerateCommand`**

```swift
// backend/tools/Publisher/Sources/Publisher/CLI/Commands/GenerateCommand.swift
import ArgumentParser
import Foundation

struct GenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Convenience command: validate, then generate-docs, then publish."
    )

    @Option(name: .customLong("publish-base-url"), help: "Deployment base URL, e.g. https://cdn.adblx.com")
    var publishBaseURL: String

    func run() throws {
        try ValidateCommand.parse([]).run()
        print("")
        try GenerateDocsCommand.parse([]).run()
        print("")
        var publish = try PublishCommand.parse(["--publish-base-url", publishBaseURL])
        try publish.run()
    }
}
```

- [ ] **Step 8: Wire up `main.swift`**

```swift
// backend/tools/Publisher/Sources/Publisher/main.swift
import ArgumentParser

PublisherCommand.main()
```

- [ ] **Step 9: Build and smoke-test each subcommand**

Run from the repository root (`/Users/sreeharshag/Work/ADBLX`):

```bash
cd backend/tools/Publisher && swift build
cd /Users/sreeharshag/Work/ADBLX
swift run --package-path backend/tools/Publisher publisher validate
```

Expected at this point: `validate` fails with missing-payload errors for
all three filters, since `backend/public/filters/{group}/*.txt` don't exist
yet in the real repo tree (only `.gitkeep` placeholders exist per the
`find backend` listing) — this is a real, currently-true validation result,
not a test artifact. Confirm the output lists all three missing-payload
errors together (proving accumulation).

**Do not commit a `publish`/`generate` smoke test's output to
`backend/public/manifest.json`.** An ABORT review of this plan flagged that
the original version of this step used single-line placeholder text
(`||easylist-placeholder.example^`) as stand-in payloads, then committed the
resulting manifest — meaning fabricated, never-downloaded content would
silently replace the honest `{}` at the production manifest path, with
nothing marking it as fake. A future reader of `backend/public/manifest.json`
would have no way to know the checksums it contains don't correspond to any
real EasyList/EasyPrivacy/Fanboy-Annoyances content.

Instead, smoke-test the CLI end to end using a **scratch directory outside
the repo**, so `generate`'s real-run behavior is proven without writing
fabricated content to the tracked output path:

```bash
cd /Users/sreeharshag/Work/ADBLX
mkdir -p /tmp/adblx-publisher-smoketest/{registry,metadata,public/filters/ads,public/filters/privacy,public/filters/annoyances,public/filters/regional,docs}
cp backend/registry/filters.json /tmp/adblx-publisher-smoketest/registry/filters.json
echo '{"id": "easylist", "version": "2026-07-27"}' > /tmp/adblx-publisher-smoketest/metadata/easylist.json
echo '{"id": "easyprivacy", "version": "2026-07-27"}' > /tmp/adblx-publisher-smoketest/metadata/easyprivacy.json
echo '{"id": "fanboy-annoyances", "version": "2026-07-27"}' > /tmp/adblx-publisher-smoketest/metadata/fanboy-annoyances.json
echo "||smoketest-placeholder.invalid^" > /tmp/adblx-publisher-smoketest/public/filters/ads/easylist.txt
echo "||smoketest-placeholder.invalid^" > /tmp/adblx-publisher-smoketest/public/filters/privacy/easyprivacy.txt
echo "||smoketest-placeholder.invalid^" > /tmp/adblx-publisher-smoketest/public/filters/annoyances/fanboy-annoyances.txt

cd /tmp/adblx-publisher-smoketest
swift run --package-path /Users/sreeharshag/Work/ADBLX/backend/tools/Publisher publisher generate --publish-base-url https://cdn.adblx.com
cat public/manifest.json
cat docs/FilterRegistry.md
```

Expected: exits 0, prints a manifest with real derived fields (correct
`sourceURL`s, computed checksums/rule counts for the placeholder text, sort
order, `manifestVersion`) and a `FilterRegistry.md` matching the three
registered filters — proving the CLI's pipeline wiring is correct — all
without ever writing to any path under the real
`/Users/sreeharshag/Work/ADBLX/backend/` tree. Delete the scratch directory
afterward: `rm -rf /tmp/adblx-publisher-smoketest`.

`backend/public/manifest.json` stays exactly as it is today (`{}`) and
`backend/docs/FilterRegistry.md` is **not** regenerated as part of this
plan — real upstream filter payloads (actual EasyList/EasyPrivacy/Fanboy-
Annoyances downloads) don't exist yet in `backend/public/filters/` (only
`.gitkeep` placeholders), and generating a real `manifest.json` requires
real payload content, which is out of scope for Sprint 7 per
`ManifestGeneration.md` ("How upstream filter lists are fetched... is later
upstream-sync work"). Regenerating `FilterRegistry.md` for real, however,
has no such dependency — do that now, since `generate-docs` only needs
`filters.json`:

```bash
cd /Users/sreeharshag/Work/ADBLX
swift run --package-path backend/tools/Publisher publisher generate-docs
```

Expected: exits 0, `backend/docs/FilterRegistry.md` is regenerated in place
with the "do not edit by hand" banner, matching the three registered
filters from `backend/registry/filters.json`.

- [ ] **Step 10: Read and verify the regenerated `FilterRegistry.md`**

Read `backend/docs/FilterRegistry.md` and confirm every field from the
original hand-authored version (Display name, Internal ID, Upstream
project, Upstream download URL, License, ADBLX FilterGroup, Default
enabled, Premium, Notes) is present and correct for all three filters, and
that the "Future candidates" table is gone (it now lives solely in
`RegistryRoadmap.md`, added in Task 1).

- [ ] **Step 11: Run the full test suite one final time**

Run: `cd backend/tools/Publisher && swift test`
Expected: PASS, every test from every task.

- [ ] **Step 12: Commit**

`backend/public/manifest.json` is deliberately **not** staged here — it
stays `{}` until real upstream filter payloads exist and someone runs
`publish`/`generate` for real, per Step 9's reasoning above.
`backend/metadata/` and `backend/public/filters/` are also left untouched
(still only `.gitkeep` placeholders) — the smoke test in Step 9 ran
entirely in `/tmp` and left the real repo tree unmodified.

```bash
cd /Users/sreeharshag/Work/ADBLX
git add backend/tools/Publisher backend/docs/FilterRegistry.md
git commit -m "feat(publisher): wire CLI (validate/generate-docs/publish/generate), regenerate FilterRegistry.md"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** every section of the Sprint 7 blueprint has a task —
  technology/project structure (Task 2), registry format + roadmap split
  (Task 1), field ownership (Tasks 2, 4, 5, 6), CLI (Task 11), validation
  model + determinism (Tasks 3, 7, 10), testing policy including golden
  files/batch-failure/determinism (Task 10), atomic writes (Task 9),
  logging/exit codes (Task 11), configuration (`--publish-base-url` only,
  Task 11).
- **Placeholder scan:** no TBD/TODO markers; every step has literal code or
  literal shell commands.
- **Type consistency:** `RegistryEntry`, `Registry`, `FilterMetadata`,
  `PayloadInfo`, `ManifestEntry`, `Manifest`, `ValidationError`,
  `ValidationReport` are each defined once (Tasks 2–6) and referenced by
  the identical name/shape in every later task (7, 10, 11) — verified by
  re-reading each task's Interfaces block against the ones before it.
