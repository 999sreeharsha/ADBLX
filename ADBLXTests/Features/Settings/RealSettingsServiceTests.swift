// ADBLXTests/Features/Settings/RealSettingsServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealSettingsService", .serialized)
struct RealSettingsServiceTests {
    private func makeService() async throws -> RealSettingsService {
        let filterStore = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await filterStore.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("allowlist.json"))
        return RealSettingsService(allowlistStore: AllowlistStore(store: filterStore))
    }

    @Test("fetchSnapshot reflects real allowlist state and a hardcoded false iCloudSyncEnabled")
    func fetchSnapshotReflectsRealState() async throws {
        let service = try await makeService()

        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.iCloudSyncEnabled == false)
        #expect(snapshot.allowlist.isEmpty)
    }

    @Test("addAllowlistEntry then fetchSnapshot shows the new entry")
    func addThenFetchShowsEntry() async throws {
        let service = try await makeService()

        await service.addAllowlistEntry(domain: "news.example.com")
        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.allowlist.count == 1)
        #expect(snapshot.allowlist.first?.domain == "news.example.com")
    }

    @Test("removeAllowlistEntry then fetchSnapshot no longer shows the entry")
    func removeThenFetchOmitsEntry() async throws {
        let service = try await makeService()
        await service.addAllowlistEntry(domain: "news.example.com")
        let firstSnapshot = await service.fetchSnapshot()
        let entryID = firstSnapshot.allowlist[0].id

        await service.removeAllowlistEntry(id: entryID)
        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.allowlist.isEmpty)
    }
}
