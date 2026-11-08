import Testing
import Foundation
@testable import ADBLX

/// A transaction is finished only when `commit` renames `Previous/` away, so a `Previous/` found
/// at launch belongs to one that died, and restoring it is always right. "The next launch" here is
/// a second `FilterStore` on the same container.
@Suite("Interrupted transaction recovery")
struct InterruptedTransactionRecoveryTests {
    private let before = Data("before".utf8)
    private let after = Data("after".utf8)

    @Test("a snapshot left by a transaction that died is restored at the next launch")
    func uncommittedSnapshotIsRestored() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(before, to: store)
        _ = try await store.snapshotForRollback()
        try await writeState(after, to: store)
        try await store.writeMetadata(after, filename: "manifest.json")

        let nextLaunch = FilterStore(overrideBaseURL: base)
        #expect(try await nextLaunch.recoverInterruptedTransaction())

        try await expectState(before, in: nextLaunch)
        #expect((try? await nextLaunch.read("manifest.json", in: .metadata)) == nil)
        try expectNoLeftovers(in: base)
    }

    @Test("a committed transaction leaves nothing for the next launch to undo")
    func committedTransactionIsKept() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(before, to: store)
        let snapshot = try await store.snapshotForRollback()
        try await writeState(after, to: store)
        try await store.commit(snapshot)

        let nextLaunch = FilterStore(overrideBaseURL: base)
        #expect(try await nextLaunch.recoverInterruptedTransaction() == false)

        try await expectState(after, in: nextLaunch)
        try expectNoLeftovers(in: base)
    }

    @Test("killed just before the commit rename, the next launch restores")
    func killedBeforeCommitIsRestored() async throws {
        let base = Self.makeBase()
        let reached = Reached()
        let store = FilterStore(overrideBaseURL: base, transactionHook: { step in
            guard step == .beforeCommit else { return }
            await reached.arrive()
            await Parked.forever()
        })
        try await writeState(before, to: store)
        let snapshot = try await store.snapshotForRollback()
        try await writeState(after, to: store)
        Task { try await store.commit(snapshot) }
        await reached.wait()

        let nextLaunch = FilterStore(overrideBaseURL: base)
        #expect(try await nextLaunch.recoverInterruptedTransaction())

        try await expectState(before, in: nextLaunch)
    }

    @Test("killed mid-snapshot, the partial copy is deleted and nothing live changes")
    func partialSnapshotIsDeleted() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(after, to: store)
        let partial = base.appendingPathComponent("Previous.partial/Compiled", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try before.write(to: partial.appendingPathComponent("Ads.json"))

        #expect(try await store.recoverInterruptedTransaction() == false)

        try await expectState(after, in: store)
        try expectNoLeftovers(in: base)
    }

    @Test("finished or spent snapshot directories are deleted without restoring them", arguments: ["Previous.done", "Previous.spent"])
    func finishedSnapshotIsDeleted(name: String) async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(after, to: store)
        let leftover = base.appendingPathComponent("\(name)/Compiled", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try before.write(to: leftover.appendingPathComponent("Ads.json"))

        #expect(try await store.recoverInterruptedTransaction() == false)

        try await expectState(after, in: store)
        try expectNoLeftovers(in: base)
    }

    // Without the snapshot's id there's no telling whether the copy finished.
    @Test("a Previous/ without a snapshot id is deleted, not restored")
    func unidentifiedSnapshotIsDeleted() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(after, to: store)
        let legacy = base.appendingPathComponent("Previous/Compiled", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try before.write(to: legacy.appendingPathComponent("Ads.json"))

        #expect(try await store.recoverInterruptedTransaction() == false)

        try await expectState(after, in: store)
        try expectNoLeftovers(in: base)
    }

    @Test("with nothing left over, recovery changes nothing")
    func nothingToRecover() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(after, to: store)

        #expect(try await store.recoverInterruptedTransaction() == false)

        try await expectState(after, in: store)
    }

    // A rollback that stops after its first swap leaves Previous/ holding one new directory and
    // two old ones. Restoring all three would put the new one back.
    @Test("a rollback killed after its first swap is finished at the next launch")
    func interruptedRollbackIsFinished() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base, swapPaths: { saved, live in
            if live.lastPathComponent == "Metadata" { throw CocoaError(.fileWriteUnknown) }
            try FilterStore.swapPathsAtomically(saved, live)
        })
        try await writeState(before, to: store)
        let snapshot = try await store.snapshotForRollback()
        try await writeState(after, to: store)
        await #expect(throws: CocoaError.self) { try await store.restore(snapshot) }

        let nextLaunch = FilterStore(overrideBaseURL: base)
        #expect(try await nextLaunch.recoverInterruptedTransaction())

        try await expectState(before, in: nextLaunch)
        try expectNoLeftovers(in: base)
    }

    @Test("a rollback that stopped part-way finishes when tried again in the same run")
    func interruptedRollbackFinishesOnRetry() async throws {
        let failOnMetadata = Flag(true)
        let store = FilterStore.temporary(swapPaths: { saved, live in
            if failOnMetadata.value, live.lastPathComponent == "Metadata" { throw CocoaError(.fileWriteUnknown) }
            try FilterStore.swapPathsAtomically(saved, live)
        })
        try await writeState(before, to: store)
        let snapshot = try await store.snapshotForRollback()
        try await writeState(after, to: store)
        await #expect(throws: CocoaError.self) { try await store.restore(snapshot) }
        failOnMetadata.value = false

        try await store.restore(snapshot)

        try await expectState(before, in: store)
    }

    @Test("a failed commit rename leaves the snapshot in place to restore")
    func failedCommitKeepsTheSnapshot() async throws {
        let store = FilterStore.temporary(fileManager: NoRenameToDone())
        try await writeState(before, to: store)
        let snapshot = try await store.snapshotForRollback()
        try await writeState(after, to: store)

        await #expect(throws: CocoaError.self) { try await store.commit(snapshot) }
        try await store.restore(snapshot)

        try await expectState(before, in: store)
    }

    // A marker from a snapshot whose clean-up was cut short must not travel into the next one.
    @Test("a stray marker in a live directory isn't copied into a new snapshot")
    func strayMarkerIsNotCopied() async throws {
        let base = Self.makeBase()
        let store = FilterStore(overrideBaseURL: base)
        try await writeState(before, to: store)
        let compiled = try await store.directoryURL(.compiled)
        try Data().write(to: compiled.appendingPathComponent(".snapshot-\(UUID().uuidString)"))

        _ = try await store.snapshotForRollback()

        let saved = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Previous/Compiled").path)
        #expect(saved.filter { $0.hasPrefix(".snapshot-") }.count == 1)
    }

    // MARK: - Helpers

    private static func makeBase() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeState(_ data: Data, to store: FilterStore) async throws {
        let compiled = try await store.directoryURL(.compiled)
        try data.write(to: compiled.appendingPathComponent("Ads.json"))
        try data.write(to: compiled.appendingPathComponent("Ads.sources.json"))
        try await store.writeMetadata(data, filename: "installed_filters.json")
        try await store.writeMetadata(data, filename: "pending_reloads.json")
        try await store.writeMetadata(data, filename: "update_throttle.json")
        try await store.writeMetadata(data, filename: "recompile_attempts.json")
        try await store.writeFilterPayload(data, filterID: "easylist")
    }

    private func expectState(_ data: Data, in store: FilterStore) async throws {
        #expect(try await store.read("Ads.json", in: .compiled) == data)
        #expect(try await store.read("Ads.sources.json", in: .compiled) == data)
        #expect(try await store.read("installed_filters.json", in: .metadata) == data)
        #expect(try await store.read("pending_reloads.json", in: .metadata) == data)
        #expect(try await store.read("update_throttle.json", in: .metadata) == data)
        #expect(try await store.read("recompile_attempts.json", in: .metadata) == data)
        #expect(try await store.readFilterPayload(filterID: "easylist") == data)
    }

    private func expectNoLeftovers(in base: URL) throws {
        let fileManager = FileManager.default
        for name in ["Previous", "Previous.partial", "Previous.done", "Previous.spent"] {
            #expect(!fileManager.fileExists(atPath: base.appendingPathComponent(name).path), "\(name) left behind")
        }
        for name in ["Compiled", "Metadata", "Filters"] {
            let files = try fileManager.contentsOfDirectory(atPath: base.appendingPathComponent(name).path)
            #expect(!files.contains { $0.hasPrefix(".snapshot-") }, "marker left in \(name)")
        }
    }
}

/// Holds a task suspended for good, as a killed process would leave its transaction.
nonisolated enum Parked {
    private static let box = ContinuationBox()

    static func forever() async {
        await withCheckedContinuation { box.keep($0) }
    }
}

private nonisolated final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func keep(_ continuation: CheckedContinuation<Void, Never>) { lock.withLock { continuations.append(continuation) } }
}

/// Lets a test wait until a transaction has reached a step.
actor Reached {
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() {
        arrived = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        if arrived { return }
        await withCheckedContinuation { waiters.append($0) }
    }
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

private nonisolated final class NoRenameToDone: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.lastPathComponent == "Previous.done" { throw CocoaError(.fileWriteUnknown) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
