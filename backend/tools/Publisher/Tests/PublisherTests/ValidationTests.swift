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

    func test_fullValidate_duplicateMetadata() throws {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "easylist", group: "ads")])
        let metadataDir = try MetadataTests.makeTempDirectory()
        try MetadataTests.writeMetadata(id: "easylist", version: "2026-07-15", in: metadataDir)
        // A second metadata file, different filename, declaring the same id.
        let duplicateJSON = "{\"id\": \"easylist\", \"version\": \"2026-07-16\"}"
        try duplicateJSON.write(
            to: metadataDir.appendingPathComponent("easylist-duplicate.json"),
            atomically: true, encoding: .utf8
        )
        let payloadDir = try Self.makeTempPayloadTree(ids: ["easylist"], groups: ["ads"])

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains(.duplicateMetadata(id: "easylist")))
    }

    func test_fullValidate_metadataIDMismatch() throws {
        let registry = Registry(registryVersion: 1, filters: [makeEntry(id: "bar", group: "ads")])
        let metadataDir = try MetadataTests.makeTempDirectory()
        // File named foo.json but declares id "bar" — filename/id mismatch.
        let mismatchedJSON = "{\"id\": \"bar\", \"version\": \"2026-07-15\"}"
        try mismatchedJSON.write(
            to: metadataDir.appendingPathComponent("foo.json"),
            atomically: true, encoding: .utf8
        )
        let payloadDir = try Self.makeTempPayloadTree(ids: ["bar"], groups: ["ads"])

        let report = try Validator.validate(registry: registry, metadataDirectory: metadataDir, payloadDirectory: payloadDir)

        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains(.metadataIDMismatch(filename: "foo.json", declaredID: "bar")))
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
}
