import Testing
import Foundation
@testable import ADBLX

/// An allowlist edit recompiles every installed group. When that fails the edit is reverted,
/// and when Safari doesn't take the new rules the edit stays; either way the user is told.
@Suite("Allowlist edits that don't take effect say so")
@MainActor
struct AllowlistEditFailureTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    private let oneRule = Data("[{\"trigger\":{\"url-filter\":\"ad\"},\"action\":{\"type\":\"block\"}}]".utf8)
    private let compileFailed = String(localized: "settings.allowlist.compileFailed")
    private let reloadFailed = String(localized: "updateprogress.status.reloadFailed")

    private struct Harness {
        let store: FilterStore
        let allowlistStore: AllowlistStore
        let pipeline: FilterPipeline
        let service: RealSettingsService
        let reloads: FailingReloads
        let partitioner: SwitchablePartitioner
    }

    private func makeHarness(reloadsFail: Bool = false) -> Harness {
        let store = FilterStore.temporary()
        let allowlistStore = AllowlistStore(store: store)
        let reloads = FailingReloads(failing: reloadsFail)
        let state = EnabledBlockers()
        let partitioner = SwitchablePartitioner(ids: ids)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: PassthroughRuleCompiler(),
            compositionService: JSONArrayCompositionService(),
            partitioner: partitioner,
            store: store, writer: AtomicRuleWriter(),
            reloader: ReloadCoordinator(timeoutSeconds: 3, reloadOperation: reloads.operation),
            allowlistStore: allowlistStore, gate: FilterTransactionGate(), stateProvider: state
        )
        let service = RealSettingsService(allowlistStore: allowlistStore, pipeline: pipeline, stateProvider: state)
        return Harness(store: store, allowlistStore: allowlistStore, pipeline: pipeline, service: service, reloads: reloads, partitioner: partitioner)
    }

    private func install(_ group: FilterGroup, in h: Harness) async throws {
        let source = FilterSource(filterID: "\(group.rawValue)-list", version: "1", checksumSHA256: Checksum.sha256Hex(of: oneRule), data: oneRule)
        _ = try await h.pipeline.install(GroupComposition(group: group, sources: [source]), reloadStrategy: .deferred)
    }

    private func ruleCount(_ filename: String, in store: FilterStore) async throws -> Int {
        let data = try await store.read(filename, in: .compiled)
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any]).count
    }

    @Test("a failed compile reverts the edit and says the allowlist wasn't changed")
    func failedCompileSaysSo() async throws {
        let h = makeHarness()
        try await install(.ads, in: h)
        h.partitioner.failing = .ads
        let model = SettingsViewModel(service: h.service)

        await model.addAllowlistEntry(domain: "example.com")

        #expect(model.allowlistEditError == compileFailed)
        #expect(await h.allowlistStore.load().isEmpty)
    }

    // A batch of two: Ads compiles and is written before Privacy fails.
    @Test("a compile that fails on a later group leaves the earlier group's rules as they were")
    func failureMidBatchRestoresEarlierGroups() async throws {
        let h = makeHarness()
        try await install(.ads, in: h)
        try await install(.privacy, in: h)
        h.partitioner.failing = .privacy

        #expect(await h.service.addAllowlistEntry(domain: "example.com") == .reverted)

        #expect(try await ruleCount("Ads.json", in: h.store) == 1)
        #expect(try await ruleCount("Privacy.json", in: h.store) == 1)
    }

    @Test("a failed removal puts the entry back and says the allowlist wasn't changed")
    func failedRemovalSaysSo() async throws {
        let h = makeHarness()
        let entry = try await h.allowlistStore.add(domain: "example.com")
        try await install(.ads, in: h)
        h.partitioner.failing = .ads
        let model = SettingsViewModel(service: h.service)

        await model.removeAllowlistEntry(id: entry.id)

        #expect(model.allowlistEditError == compileFailed)
        #expect(await h.allowlistStore.load().map(\.domain) == ["example.com"])
    }

    @Test("re-adding a domain that's already allowlisted never removes it")
    func readdingKeepsExistingEntry() async throws {
        let h = makeHarness()
        _ = try await h.allowlistStore.add(domain: "example.com")
        try await install(.ads, in: h)
        h.partitioner.failing = .ads

        #expect(await h.service.addAllowlistEntry(domain: "example.com") == .applied)
        #expect(await h.allowlistStore.load().map(\.domain) == ["example.com"])
    }

    @Test("an edit Safari couldn't apply keeps the edit, says so, and is left for the next update to retry")
    func failedReloadSaysSoAndIsRetried() async throws {
        let h = makeHarness(reloadsFail: true)
        try await install(.ads, in: h)
        let model = SettingsViewModel(service: h.service)

        await model.addAllowlistEntry(domain: "example.com")

        #expect(model.allowlistEditError == reloadFailed)
        #expect(await h.allowlistStore.load().map(\.domain) == ["example.com"])
        let pending = await PendingReloads(store: h.store, stateProvider: EnabledBlockers()).identifiers()
        #expect(pending == [ids.ads])
    }

    @Test("a successful edit clears an earlier failure")
    func successClearsMessage() async throws {
        let h = makeHarness(reloadsFail: true)
        try await install(.ads, in: h)
        let model = SettingsViewModel(service: h.service)
        await model.addAllowlistEntry(domain: "example.com")

        h.reloads.failing = false
        await model.addAllowlistEntry(domain: "example.org")

        #expect(model.allowlistEditError == nil)
        #expect(await PendingReloads(store: h.store, stateProvider: EnabledBlockers()).identifiers().isEmpty)
    }
}

/// Fails the group it's told to, once setup is done. Not the id lookup `syncAllowlist` does
/// with an empty rule set after each group is written.
private nonisolated final class SwitchablePartitioner: RulePartitioner, @unchecked Sendable {
    private let ids: GroupExtensionIdentifiers
    private let lock = NSLock()
    private var storedFailing: FilterGroup?

    init(ids: GroupExtensionIdentifiers) { self.ids = ids }

    var failing: FilterGroup? {
        get { lock.withLock { storedFailing } }
        set { lock.withLock { storedFailing = newValue } }
    }

    func partition(_ ruleSet: CompiledRuleSet, group: FilterGroup) async throws -> PartitionedRules {
        if group == failing && ruleSet.ruleCount > 0 {
            throw RulePartitionerError.ruleBudgetExceeded(group: group, count: ruleSet.ruleCount, limit: 0)
        }
        return PartitionedRules(extensionIdentifier: ids[group], group: group, json: ruleSet.rawJSON, ruleCount: ruleSet.ruleCount)
    }
}

private nonisolated final class FailingReloads: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailing: Bool

    init(failing: Bool) { storedFailing = failing }

    var failing: Bool {
        get { lock.withLock { storedFailing } }
        set { lock.withLock { storedFailing = newValue } }
    }

    var operation: ReloadCoordinator.ReloadOperation {
        { [self] _, completion in
            completion(failing ? CocoaError(.fileWriteOutOfSpace) : nil)
        }
    }
}

private nonisolated struct EnabledBlockers: ContentBlockerStateProviding {
    func state(of extensionIdentifier: String) async -> ContentBlockerSettingsState { .enabled }
}
