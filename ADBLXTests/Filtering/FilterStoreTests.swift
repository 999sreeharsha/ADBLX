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
