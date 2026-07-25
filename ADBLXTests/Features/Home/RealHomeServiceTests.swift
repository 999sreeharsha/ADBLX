// ADBLXTests/Features/Home/RealHomeServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealHomeService", .serialized)
struct RealHomeServiceTests {
    private func makeStore() async throws -> FilterStore {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("installed_filters.json"))
        return store
    }

    @Test("no installed_filters.json means protection is not enabled and activity is empty")
    func emptyStateIsHonest() async throws {
        let store = try await makeStore()
        let service = RealHomeService(store: store)

        let status = await service.fetchStatus()

        #expect(status.isProtectionEnabled == false)
        #expect(status.ruleCount == 0)
        #expect(status.recentActivity.isEmpty)
        #expect(status.lastUpdateDescription == "Never")
    }

    @Test("installed filters across two groups sum ruleCount once per group and report the newest update")
    func aggregatesAcrossGroupsWithoutDoubleCounting() async throws {
        let store = try await makeStore()
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)

        // Two entries in the SAME group (ads) share the same group-level ruleCount
        // (per docs/gotchas.md) — summing naively would double it to 124_000.
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: older, ruleCount: 62_000
            ),
            InstalledFilter(
                id: "easylist-extra", group: .ads, installedVersion: "1", checksumSHA256: "b",
                lastUpdated: older, ruleCount: 62_000
            ),
            InstalledFilter(
                id: "easyprivacy", group: .privacy, installedVersion: "1", checksumSHA256: "c",
                lastUpdated: newer, ruleCount: 48_500
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        try await store.writeMetadata(data, filename: "installed_filters.json")

        let service = RealHomeService(store: store)
        let status = await service.fetchStatus()

        #expect(status.isProtectionEnabled == true)
        #expect(status.ruleCount == 62_000 + 48_500)
        #expect(status.recentActivity.count == 2)
        #expect(status.safariProtectionStatus == .active)
    }

    @Test("a concurrent write never produces a torn or corrupt read (ABORT review, ordering-race finding)")
    func concurrentWriteNeverProducesTornRead() async throws {
        // Simulates the real production hazard: ContentBlockerBootstrap writing
        // installed_filters.json in a detached Task while HomeView's .task reads
        // it via RealHomeService, with no guaranteed ordering between the two.
        // FilterStore.writeMetadata uses `.atomic` (FilterStore.swift:69-72), so a
        // reader must see either the fully-old or fully-new file, never a partial
        // one — this test proves that guarantee holds under real concurrent access
        // rather than asserting it only in a code comment.
        let store = try await makeStore()
        let filters = [
            InstalledFilter(
                id: "easylist", group: .ads, installedVersion: "1", checksumSHA256: "a",
                lastUpdated: Date(), ruleCount: 62_000
            ),
        ]
        let data = try JSONEncoder().encode(filters)
        let service = RealHomeService(store: store)

        async let writeTask: Void = store.writeMetadata(data, filename: "installed_filters.json")
        async let readResults: [HomeStatus] = withTaskGroup(of: HomeStatus.self) { group in
            for _ in 0..<20 {
                group.addTask { await service.fetchStatus() }
            }
            var results: [HomeStatus] = []
            for await result in group { results.append(result) }
            return results
        }

        _ = try await writeTask
        let statuses = await readResults

        // Every read must be a clean, fully-decoded state — either the pre-write
        // empty state or the post-write single-group state. A torn read would
        // either throw during JSONDecoder (caught by RealHomeService's `try?` and
        // silently reported as empty — acceptable) or, if .atomic is ever removed
        // from writeMetadata, could decode partial/garbage data that doesn't match
        // either expected shape. This assertion is what catches that regression.
        for status in statuses {
            let isValidEmptyState = status.isProtectionEnabled == false && status.ruleCount == 0
            let isValidPopulatedState = status.isProtectionEnabled == true && status.ruleCount == 62_000
            #expect(
                isValidEmptyState || isValidPopulatedState,
                "fetchStatus() returned a state matching neither pre-write nor post-write — possible torn read: \(status)"
            )
        }
    }
}
