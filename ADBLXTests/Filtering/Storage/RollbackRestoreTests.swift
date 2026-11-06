import Testing
import Foundation
@testable import ADBLX

/// `restore` used to delete each directory and copy the snapshot back, so a crash or a full disk
/// part-way left files missing. Moving the snapshot into place needs no space and no copy.
@Suite("Rollback restore")
struct RollbackRestoreTests {
    private let before = Data("[{\"trigger\":{\"url-filter\":\"before\"},\"action\":{\"type\":\"block\"}}]".utf8)
    private let after = Data("[{\"trigger\":{\"url-filter\":\"after\"},\"action\":{\"type\":\"block\"}}]".utf8)

    @Test("a restore on a full disk still puts every directory back")
    func restoreNeedsNoSpace() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterStore-\(UUID().uuidString)", isDirectory: true)
        let store = FilterStore(overrideBaseURL: base)
        let compiled = try await store.directoryURL(.compiled)
        try before.write(to: compiled.appendingPathComponent("Ads.json"))
        try await store.writeMetadata(before, filename: "installed_filters.json")
        try await store.writeFilterPayload(before, filterID: "easylist")
        let snapshot = try await store.snapshotForRollback()

        try after.write(to: compiled.appendingPathComponent("Ads.json"))
        try after.write(to: compiled.appendingPathComponent("Privacy.json"))
        try await store.writeMetadata(after, filename: "installed_filters.json")
        try await store.writeFilterPayload(after, filterID: "easylist")

        let fullDisk = FilterStore(fileManager: NoSpaceToCopy(), overrideBaseURL: base)
        try await fullDisk.restore(snapshot)

        #expect(try await store.read("Ads.json", in: .compiled) == before)
        #expect((try? await store.read("Privacy.json", in: .compiled)) == nil)
        #expect(try await store.read("installed_filters.json", in: .metadata) == before)
        #expect(try await store.readFilterPayload(filterID: "easylist") == before)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("Previous").path))
    }

    // A swap in one call is what makes a crash unable to leave a directory half-restored. If
    // restore copied, or moved the live directory aside first, the snapshot's directory would
    // not itself become the live one.
    @Test("restore makes the snapshot's own directory the live one")
    func restoreSwapsRatherThanCopies() async throws {
        let store = FilterStore.temporary()
        let compiled = try await store.directoryURL(.compiled)
        try before.write(to: compiled.appendingPathComponent("Ads.json"))
        let snapshot = try await store.snapshotForRollback()
        let saved = compiled.deletingLastPathComponent().appendingPathComponent("Previous/Compiled")
        let savedInode = try inode(of: saved)
        let liveInode = try inode(of: compiled)
        try after.write(to: compiled.appendingPathComponent("Ads.json"))

        try await store.restore(snapshot)

        #expect(try inode(of: compiled) == savedInode)
        #expect(try inode(of: compiled) != liveInode)
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

private nonisolated final class NoSpaceToCopy: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
