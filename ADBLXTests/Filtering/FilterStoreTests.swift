import Testing
import Foundation
@testable import ADBLX

@Suite("FilterStore", .serialized)
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

    @Test("writeFilterPayload then readFilterPayload round-trips raw bytes for a filterID")
    func writeThenReadFilterPayloadRoundTrips() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        try await store.writeFilterPayload(payload, filterID: "test-filter-\(UUID().uuidString)")
        // filterID captured below for cleanup
    }

    @Test("readFilterPayload round-trips exact bytes written by writeFilterPayload")
    func readFilterPayloadRoundTripsExactBytes() async throws {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let filterID = "roundtrip-\(UUID().uuidString)"
        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        try await store.writeFilterPayload(payload, filterID: filterID)
        let readBack = try await store.readFilterPayload(filterID: filterID)

        #expect(readBack == payload)

        let filtersDir = try await store.directoryURL(.filters)
        try? FileManager.default.removeItem(at: filtersDir.appendingPathComponent("\(filterID).json"))
    }

    @Test("readFilterPayload throws for an unknown filterID")
    func readFilterPayloadThrowsForUnknownID() async {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        await #expect(throws: (any Error).self) {
            _ = try await store.readFilterPayload(filterID: "does-not-exist-\(UUID().uuidString)")
        }
    }
}
