import Foundation
import Testing
@testable import ADBLX

/// Installed rules carry the compiler version that produced them (in each group's sidecar), and
/// a launch recompiles every group when any was compiled by another version. Otherwise a
/// compiler fix reaches a device only when a list update or an allowlist edit happens to
/// recompile that group (docs/gotchas.md, "dropping an unsupported domain").
@Suite("Compiler-version recompile", .serialized, .timeLimit(.minutes(1)))
struct CompilerVersionRecompileTests {
    private let ids = GroupExtensionIdentifiers(
        ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
        annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
    )
    /// Compiled in name order: ads, annoyances, privacy.
    private let groups: [(FilterGroup, String)] = [(.ads, "easylist"), (.annoyances, "fanboy-annoyances"), (.privacy, "easyprivacy")]

    private struct Fixture {
        let store: FilterStore
        let gate: FilterTransactionGate
        let compiler: CountingCompiler
        let pipeline: FilterPipeline
    }

    private func installedFixture() async throws -> Fixture {
        let store = FilterStore.temporary()
        let gate = FilterTransactionGate()
        let compiler = CountingCompiler()
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: compiler,
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator(), gate: gate
        )
        for (group, id) in groups {
            let rules = Data("[{\"trigger\":{\"url-filter\":\"\(id)\"},\"action\":{\"type\":\"block\"}}]".utf8)
            _ = try await pipeline.install(GroupComposition(group: group, sources: [FilterSource(
                filterID: id, version: "v1", checksumSHA256: Checksum.sha256Hex(of: rules), data: rules
            )]), reloadStrategy: .deferred)
        }
        compiler.reset()
        return Fixture(store: store, gate: gate, compiler: compiler, pipeline: pipeline)
    }

    private func sidecar(_ group: FilterGroup, in store: FilterStore) async throws -> [String: Any] {
        let data = try await store.read(CompiledSources.filename(for: group), in: .compiled)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Rewrites a group's sidecar as an older app would have left it: another compiler version,
    /// or (nil) no version field at all.
    private func makeStale(_ group: FilterGroup, version: Int?, in store: FilterStore) async throws {
        var object = try await sidecar(group, in: store)
        object["compilerVersion"] = version
        let directory = try await store.directoryURL(.compiled)
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(CompiledSources.filename(for: group)))
    }

    /// Every compiled rules file and sidecar, by name.
    private func compiledFiles(_ store: FilterStore) async throws -> [String: Data] {
        let directory = try await store.directoryURL(.compiled)
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return files
    }

    @Test("A compile records the current compiler version in the group's sidecar")
    func compileRecordsTheVersion() async throws {
        let fixture = try await installedFixture()

        for (group, _) in groups {
            #expect(try await sidecar(group, in: fixture.store)["compilerVersion"] as? Int == CompiledSources.currentCompilerVersion)
        }
    }

    @Test("One group compiled by another version recompiles every group to the current one")
    func oneStaleGroupRecompilesAll() async throws {
        let fixture = try await installedFixture()
        try await makeStale(.privacy, version: CompiledSources.currentCompilerVersion - 1, in: fixture.store)

        let results = try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred)

        #expect(results?.map(\.group).sorted { $0.rawValue < $1.rawValue } == [.ads, .annoyances, .privacy])
        #expect(fixture.compiler.compiledGroups == [.ads, .annoyances, .privacy])
        for (group, _) in groups {
            #expect(try await sidecar(group, in: fixture.store)["compilerVersion"] as? Int == CompiledSources.currentCompilerVersion)
        }
    }

    @Test("A sidecar from before compiler versions were recorded counts as another version")
    func missingVersionIsStale() async throws {
        let fixture = try await installedFixture()
        try await makeStale(.ads, version: nil, in: fixture.store)

        let results = try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred)

        #expect(results?.count == 3)
        #expect(try await sidecar(.ads, in: fixture.store)["compilerVersion"] as? Int == CompiledSources.currentCompilerVersion)
    }

    // A group emptied by a downgrade keeps a rules file with no installed source. Left stale, it
    // would trigger a full recompile on every launch.
    @Test("A stale group with rules but no installed source is recompiled too, so the next launch does nothing")
    func staleEmptyGroupIsRecompiled() async throws {
        let fixture = try await installedFixture()
        _ = try await fixture.pipeline.remove(filterIDs: ["fanboy-annoyances"], group: .annoyances, reloadStrategy: .deferred)
        try await makeStale(.annoyances, version: nil, in: fixture.store)

        _ = try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred)

        #expect(try await sidecar(.annoyances, in: fixture.store)["compilerVersion"] as? Int == CompiledSources.currentCompilerVersion)
        #expect(try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred) == nil)
    }

    @Test("Nothing is recompiled when every group is current")
    func currentGroupsAreLeftAlone() async throws {
        let fixture = try await installedFixture()
        let before = try await compiledFiles(fixture.store)

        let results = try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred)

        #expect(results == nil)
        #expect(fixture.compiler.compiledGroups.isEmpty)
        #expect(try await compiledFiles(fixture.store) == before)
    }

    // The second of three groups fails after the first has been rewritten: every group must
    // come back exactly as it was, still stale, so the next launch tries again.
    @Test("A failure partway through the groups restores every group and leaves them stale for the next launch")
    func partialFailureRestoresEveryGroup() async throws {
        let fixture = try await installedFixture()
        for (group, _) in groups {
            try await makeStale(group, version: CompiledSources.currentCompilerVersion - 1, in: fixture.store)
        }
        let before = try await compiledFiles(fixture.store)
        fixture.compiler.failOn(.annoyances)

        await #expect(throws: CountingCompiler.Failure.self) {
            _ = try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred)
        }

        #expect(fixture.compiler.compiledGroups == [.ads, .annoyances])
        #expect(try await compiledFiles(fixture.store) == before)

        fixture.compiler.failOn(nil)
        let retried = try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred)
        #expect(retried?.count == 3)
    }

    @Test("The recompile waits for a transaction that holds the gate")
    func recompileWaitsForTheGate() async throws {
        let fixture = try await installedFixture()
        try await makeStale(.ads, version: nil, in: fixture.store)
        let entered = Release()
        let release = Release()
        let holder = Task {
            await fixture.gate.run {
                entered.open()
                await release.wait()
            }
        }
        await entered.wait()

        let recompile = Task { try await fixture.pipeline.recompileIfCompilerChanged(reloadStrategy: .deferred) }
        while await fixture.gate.waiterCount == 0 { await Task.yield() }
        #expect(fixture.compiler.compiledGroups.isEmpty, "recompiled while another transaction held the gate")

        release.open()
        await holder.value
        #expect(try await recompile.value?.count == 3)
    }
}

/// Compiles as `PassthroughRuleCompiler` does, records each group compiled, and can fail on one.
private nonisolated final class CountingCompiler: RuleCompiler, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var groups: [FilterGroup] = []
    private var failing: FilterGroup?

    var compiledGroups: [FilterGroup] { lock.withLock { groups } }
    func reset() { lock.withLock { groups = [] } }
    func failOn(_ group: FilterGroup?) { lock.withLock { failing = group; groups = [] } }

    func compile(source: Data, group: FilterGroup) async throws -> CompiledRuleSet {
        let shouldFail = lock.withLock { () -> Bool in
            groups.append(group)
            return failing == group
        }
        if shouldFail { throw Failure() }
        return try await PassthroughRuleCompiler().compile(source: source, group: group)
    }
}

/// Opens once; waiters before and after the opening all continue.
private final class Release: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        ready.forEach { $0.resume() }
    }
}
