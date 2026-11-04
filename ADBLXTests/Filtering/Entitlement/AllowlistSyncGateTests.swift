import Testing
import Foundation
@testable import ADBLX

/// `syncAllowlist` recompiles groups from a list it read earlier, so it must not interleave
/// with a downgrade: a sync suspended in the compile would write the removed premium rules
/// back after the downgrade finished, and they would stay, because the reconciler only
/// compares `installed_filters.json` with entitlement. Deterministic: the compile is parked
/// at a known point and the gate queue observed.
@Suite("Allowlist sync vs. downgrade", .serialized)
struct AllowlistSyncGateTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )

    /// A lapsed user with a premium Annoyances list still installed.
    private func makeLapsedFixture() async throws -> Fixture {
        let store = FilterStore.temporary()
        let gate = FilterTransactionGate()
        let compiler = HoldOnceCompiler()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: compiler,
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(),
            allowlistStore: AllowlistStore(store: store), gate: gate
        )
        let premiumData = Data("[{\"trigger\":{\"url-filter\":\"cookie\"},\"action\":{\"type\":\"block\"}}]".utf8)
        _ = try await pipeline.install(GroupComposition(group: .annoyances, sources: [FilterSource(
            filterID: "fanboy-annoyances", version: "v1", checksumSHA256: Checksum.sha256Hex(of: premiumData),
            data: premiumData, premium: true
        )]), reloadStrategy: .deferred)
        let reconciler = PremiumEntitlementReconciler(
            store: store, pipeline: pipeline, manifestStore: ManifestStore(filterStore: store),
            reloader: ReloadCoordinator(), extensionIdentifiers: ids,
            entitlementService: StubEntitlementService(isPremiumEntitled: false), gate: gate
        )
        compiler.arm()
        return Fixture(store: store, gate: gate, compiler: compiler, pipeline: pipeline, reconciler: reconciler)
    }

    private func compiledAnnoyancesRuleCount(_ store: FilterStore) async throws -> Int? {
        let data = try await store.read("Annoyances.json", in: .compiled)
        return (try JSONSerialization.jsonObject(with: data) as? [Any])?.count
    }

    @Test("a sync arriving during a downgrade waits for it and restores no premium rules")
    func syncWaitsForInFlightDowngrade() async throws {
        let fixture = try await makeLapsedFixture()

        // 1. The downgrade takes the gate and parks in its recompile.
        let reconcile = Task { await fixture.reconciler.reconcile() }
        await fixture.compiler.waitUntilHeld()

        // 2. The allowlist edit arrives.
        let finished = FinishFlag()
        let sync = Task {
            defer { finished.set() }
            return try await fixture.pipeline.syncAllowlist(reloadStrategy: .deferred)
        }
        for _ in 0..<100_000 where await fixture.gate.waiterCount == 0 && !finished.isSet { await Task.yield() }
        #expect(await fixture.gate.waiterCount == 1, "sync did not queue behind the in-flight downgrade")
        #expect(!finished.isSet, "sync finished while the downgrade still held the gate")

        // 3. Let the downgrade finish; only then may the sync run.
        fixture.compiler.release()
        _ = await reconcile.value
        _ = try await sync.value

        #expect(try await compiledAnnoyancesRuleCount(fixture.store) == 0)
    }

    @Test("a downgrade arriving during a sync still removes the premium rules")
    func downgradeDuringSyncRemovesPremiumRules() async throws {
        let fixture = try await makeLapsedFixture()

        // 1. The sync reads the stale premium list and parks in its compile.
        let sync = Task { try await fixture.pipeline.syncAllowlist(reloadStrategy: .deferred) }
        await fixture.compiler.waitUntilHeld()

        // 2. The downgrade arrives. Unserialized, it finishes here, and step 3 undoes it.
        let finished = FinishFlag()
        let reconcile = Task {
            let outcome = await fixture.reconciler.reconcile()
            finished.set()
            return outcome
        }
        for _ in 0..<100_000 where await fixture.gate.waiterCount == 0 && !finished.isSet { await Task.yield() }

        // 3. The sync resumes and writes what it compiled.
        fixture.compiler.release()
        _ = try await sync.value
        guard case .downgraded(let removed, _, _) = await reconcile.value else {
            Issue.record("reconcile did not downgrade"); return
        }
        #expect(removed == 1)

        #expect(try await compiledAnnoyancesRuleCount(fixture.store) == 0)
    }
}

private struct Fixture {
    let store: FilterStore
    let gate: FilterTransactionGate
    let compiler: HoldOnceCompiler
    let pipeline: FilterPipeline
    let reconciler: PremiumEntitlementReconciler
}

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Compiles normally, except that the first compile after `arm()` parks until `release()`.
private nonisolated final class HoldOnceCompiler: RuleCompiler, @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private var isHeld = false
    private var isReleased = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arm() { lock.lock(); isArmed = true; lock.unlock() }

    func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        await holdIfArmed()
        return try await PassthroughRuleCompiler().compile(source: source, group: group)
    }

    private func holdIfArmed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard isArmed, !isReleased else { lock.unlock(); continuation.resume(); return }
            isArmed = false
            isHeld = true
            releaseWaiter = continuation
            let waiter = heldWaiter
            heldWaiter = nil
            lock.unlock()
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
