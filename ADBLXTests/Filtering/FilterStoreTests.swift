import Testing
import Foundation
@testable import ADBLX

@Suite("FilterStore", .serialized)
struct FilterStoreTests {
    private func makeIsolatedStore() -> (store: FilterStore, tempDir: URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FilterStoreTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let store = FilterStore(overrideBaseURL: temp)
        return (store, temp)
    }

    @Test("creates directories on demand and round-trips metadata writes")
    func roundTripsMetadata() async throws {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        let filename = "test-metadata-\(UUID().uuidString).json"
        let payload = Data("{\"key\":\"value\"}".utf8)

        try await store.writeMetadata(payload, filename: filename)
        let readBack = try await store.read(filename, in: .metadata)
        #expect(readBack == payload)
    }

    @Test("throws reading a filename that doesn't exist")
    func throwsOnMissingFile() async {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        await #expect(throws: (any Error).self) {
            _ = try await store.read("does-not-exist-\(UUID().uuidString).json", in: .compiled)
        }
    }

    @Test("snapshotForRollback then restore reproduces the exact prior Compiled/ and Metadata/ contents")
    func snapshotThenRestoreReproducesPriorState() async throws {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

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
    }

    @Test("restore removes files created after the snapshot that didn't exist before it")
    func restoreRemovesFilesCreatedAfterSnapshot() async throws {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        let compiledDir = try await store.directoryURL(.compiled)
        let priorFile = compiledDir.appendingPathComponent("Ads.json")
        try Data("[\"old\"]".utf8).write(to: priorFile, options: .atomic)

        let snapshot = try await store.snapshotForRollback()

        let newFile = compiledDir.appendingPathComponent("Privacy.json")
        try Data("[\"new-group-file\"]".utf8).write(to: newFile, options: .atomic)

        try await store.restore(snapshot)

        #expect(FileManager.default.fileExists(atPath: priorFile.path))
        #expect(!FileManager.default.fileExists(atPath: newFile.path))
    }

    @Test("writeFilterPayload then readFilterPayload round-trips raw bytes for a filterID")
    func writeThenReadFilterPayloadRoundTrips() async throws {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)
        let filterID = "test-filter-\(UUID().uuidString)"

        try await store.writeFilterPayload(payload, filterID: filterID)
        let readBack = try await store.readFilterPayload(filterID: filterID)
        #expect(readBack == payload)
    }

    @Test("readFilterPayload round-trips exact bytes written by writeFilterPayload")
    func readFilterPayloadRoundTripsExactBytes() async throws {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        let filterID = "roundtrip-\(UUID().uuidString)"
        let payload = Data("[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]".utf8)

        try await store.writeFilterPayload(payload, filterID: filterID)
        let readBack = try await store.readFilterPayload(filterID: filterID)
        #expect(readBack == payload)
    }

    @Test("readFilterPayload throws for an unknown filterID")
    func readFilterPayloadThrowsForUnknownID() async {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        await #expect(throws: (any Error).self) {
            _ = try await store.readFilterPayload(filterID: "does-not-exist-\(UUID().uuidString)")
        }
    }

    @Test("snapshotForRollback then restore reproduces prior Filters/ contents too")
    func snapshotThenRestoreReproducesPriorFiltersState() async throws {
        let (store, temp) = makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: temp) }

        let filtersDir = try await store.directoryURL(.filters)
        let filterFile = filtersDir.appendingPathComponent("easylist.json")
        try Data("[\"old-payload\"]".utf8).write(to: filterFile, options: .atomic)

        let snapshot = try await store.snapshotForRollback()

        // Simulate a .remove deleting the payload before a later failure.
        try? FileManager.default.removeItem(at: filterFile)

        try await store.restore(snapshot)

        #expect(try Data(contentsOf: filterFile) == Data("[\"old-payload\"]".utf8))
    }
}
