import Testing
import Foundation
@testable import ADBLX

/// An allowlist edit holds the transaction gate, so it can wait behind a filter update for as
/// long as that update's compiles take. Settings has to show that, and the edit must still land.
@Suite("Allowlist edit waiting behind an update", .serialized)
struct AllowlistEditWaitTests {
    @Test("an edit waiting for the gate is applied once the update finishes")
    func waitingEditIsApplied() async throws {
        let ids = GroupExtensionIdentifiers(
            ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
            annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
        )
        let store = FilterStore.temporary()
        let gate = FilterTransactionGate()
        let allowlistStore = AllowlistStore(store: store)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(),
            allowlistStore: allowlistStore, gate: gate
        )
        let rules = Data("[{\"trigger\":{\"url-filter\":\"x\"},\"action\":{\"type\":\"block\"}}]".utf8)
        _ = try await pipeline.install(GroupComposition(group: .ads, sources: [FilterSource(
            filterID: "easylist", version: "v1", checksumSHA256: Checksum.sha256Hex(of: rules), data: rules
        )]), reloadStrategy: .deferred)
        let service = RealSettingsService(allowlistStore: allowlistStore, pipeline: pipeline)

        // An update in progress: it holds the gate until told to finish.
        let update = HeldGate()
        let updateTask = Task { await gate.run { await update.holdUntilReleased() } }
        await update.waitUntilHeld()

        let edit = Task { await service.addAllowlistEntry(domain: "example.com") }
        for _ in 0..<100_000 where await gate.waiterCount == 0 { await Task.yield() }
        #expect(await gate.waiterCount == 1, "the edit did not queue behind the update")
        let compiledWhileWaiting = try await store.read("Ads.json", in: .compiled)
        #expect(!String(decoding: compiledWhileWaiting, as: UTF8.self).contains("example"))

        update.release()
        await updateTask.value
        await edit.value

        let compiled = try await store.read("Ads.json", in: .compiled)
        #expect(String(decoding: compiled, as: UTF8.self).contains("example"))
        #expect(await service.fetchSnapshot().allowlist.map(\.domain) == ["example.com"])
    }

    @Test("Settings shows an edit as pending until it finishes")
    @MainActor
    func viewModelShowsPending() async {
        let service = HoldingSettingsService()
        let viewModel = SettingsViewModel(service: service)
        #expect(!viewModel.isApplyingAllowlistEdit)

        let add = Task { await viewModel.addAllowlistEntry(domain: "example.com") }
        await service.waitUntilHeld()
        #expect(viewModel.isApplyingAllowlistEdit)

        service.release()
        await add.value
        #expect(!viewModel.isApplyingAllowlistEdit)
    }
}

private nonisolated final class HeldGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var isReleased = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdUntilReleased() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            isHeld = true
            let waiter = heldWaiter
            heldWaiter = nil
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiter = continuation
                lock.unlock()
            }
            waiter?.resume()
        }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isHeld {
                lock.unlock()
                continuation.resume()
            } else {
                heldWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isReleased = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

private nonisolated final class HoldingSettingsService: SettingsService, @unchecked Sendable {
    private let held = HeldGate()

    func waitUntilHeld() async { await held.waitUntilHeld() }
    func release() { held.release() }

    func fetchSnapshot() async -> SettingsSnapshot {
        SettingsSnapshot(iCloudSyncEnabled: false, allowlist: [])
    }
    func addAllowlistEntry(domain: String) async -> AllowlistEditOutcome {
        await held.holdUntilReleased()
        return .applied
    }
    func removeAllowlistEntry(id: String) async -> AllowlistEditOutcome {
        await held.holdUntilReleased()
        return .applied
    }
}
