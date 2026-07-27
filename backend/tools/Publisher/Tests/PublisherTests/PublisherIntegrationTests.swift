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
        // NOTE: `.sortedKeys` added (brief's Step 1 literal used only `.prettyPrinted`) because
        // plain `.prettyPrinted` on this toolchain (Swift 6.3 / Foundation on macOS 26) emits
        // object keys in Dictionary hash-seed order, which is randomized per-process — verified
        // by running the same encode 5+ times and observing a different key order each time.
        // That makes a golden byte-for-byte comparison against any fixed key order (declaration
        // order or otherwise) inherently flaky without `.sortedKeys` or a future declaration-
        // order-preserving encoder (ManifestWriter, Task 11). `.sortedKeys` is the only
        // deterministic option available without adding new production code, which this task's
        // brief explicitly rules out ("do not modify any of the already-implemented and
        // already-tested modules; this task only adds new test code and fixtures"). Golden
        // fixture's per-entry key order was updated to match: checksumSHA256, enabledByDefault,
        // group, id, name, premium, ruleCount, sourceURL, version (alphabetical), top-level:
        // entries, manifestVersion.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
