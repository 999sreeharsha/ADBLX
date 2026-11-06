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

    // After a restore stops part-way, the swapped directories' newer contents sit in Previous/.
    // Restoring that a second time would put the newer state back.
    @Test("a snapshot whose restore stopped part-way is refused a second time")
    func spentSnapshotIsRefused() async throws {
        let store = FilterStore.temporary(swapPaths: { saved, live in
            if live.lastPathComponent == "Metadata" { throw CocoaError(.fileWriteUnknown) }
            try FilterStore.swapPathsAtomically(saved, live)
        })
        let compiled = try await store.directoryURL(.compiled)
        try before.write(to: compiled.appendingPathComponent("Ads.json"))
        try await store.writeMetadata(before, filename: "installed_filters.json")
        let snapshot = try await store.snapshotForRollback()
        try after.write(to: compiled.appendingPathComponent("Ads.json"))
        try await store.writeMetadata(after, filename: "installed_filters.json")
        await #expect(throws: CocoaError.self) { try await store.restore(snapshot) }

        await #expect(throws: FilterStoreError.snapshotSpent) { try await store.restore(snapshot) }

        #expect(try await store.read("Ads.json", in: .compiled) == before)
        #expect(try await store.read("installed_filters.json", in: .metadata) == after)
    }

    @Test("a restore whose first swap fails changes nothing and can be tried again")
    func failedFirstSwapLeavesSnapshotUsable() async throws {
        let failures = Counter()
        let store = FilterStore.temporary(swapPaths: { saved, live in
            if failures.increment() == 1 { throw CocoaError(.fileWriteUnknown) }
            try FilterStore.swapPathsAtomically(saved, live)
        })
        let compiled = try await store.directoryURL(.compiled)
        try before.write(to: compiled.appendingPathComponent("Ads.json"))
        let snapshot = try await store.snapshotForRollback()
        try after.write(to: compiled.appendingPathComponent("Ads.json"))
        await #expect(throws: CocoaError.self) { try await store.restore(snapshot) }

        try await store.restore(snapshot)

        #expect(try await store.read("Ads.json", in: .compiled) == before)
    }

    @Test("a new snapshot after a spent one restores normally")
    func newSnapshotAfterSpentOne() async throws {
        let failOnMetadata = Flag(true)
        let store = FilterStore.temporary(swapPaths: { saved, live in
            if failOnMetadata.value, live.lastPathComponent == "Metadata" { throw CocoaError(.fileWriteUnknown) }
            try FilterStore.swapPathsAtomically(saved, live)
        })
        let compiled = try await store.directoryURL(.compiled)
        try before.write(to: compiled.appendingPathComponent("Ads.json"))
        try? await store.restore(try await store.snapshotForRollback())
        failOnMetadata.value = false

        let snapshot = try await store.snapshotForRollback()
        try after.write(to: compiled.appendingPathComponent("Ads.json"))
        try await store.restore(snapshot)

        #expect(try await store.read("Ads.json", in: .compiled) == before)
        #expect(!FileManager.default.fileExists(atPath: compiled.deletingLastPathComponent().appendingPathComponent("Previous.spent").path))
    }

    @Test("the container directory can be flushed after the swaps")
    func containerFlushes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try FilterStore.flushDirectory(directory)
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private nonisolated final class NoSpaceToCopy: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
