// ADBLXTests/Features/Settings/RealSettingsServiceTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("RealSettingsService", .serialized)
struct RealSettingsServiceTests {
    private func makeService() async throws -> (RealSettingsService, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RealSettingsServiceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let filterStore = FilterStore(overrideBaseURL: tempDir)
        let service = RealSettingsService(allowlistStore: AllowlistStore(store: filterStore))
        return (service, tempDir)
    }

    @Test("fetchSnapshot reflects real allowlist state and a hardcoded false iCloudSyncEnabled")
    func fetchSnapshotReflectsRealState() async throws {
        let (service, tempDir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.iCloudSyncEnabled == false)
        #expect(snapshot.allowlist.isEmpty)
    }

    @Test("addAllowlistEntry then fetchSnapshot shows the new entry")
    func addThenFetchShowsEntry() async throws {
        let (service, tempDir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        await service.addAllowlistEntry(domain: "news.example.com")
        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.allowlist.count == 1)
        #expect(snapshot.allowlist.first?.domain == "news.example.com")
    }

    @Test("removeAllowlistEntry then fetchSnapshot no longer shows the entry")
    func removeThenFetchOmitsEntry() async throws {
        let (service, tempDir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        await service.addAllowlistEntry(domain: "news.example.com")
        let firstSnapshot = await service.fetchSnapshot()
        guard !firstSnapshot.allowlist.isEmpty else {
            Issue.record("Expected allowlist entry to be present after add")
            return
        }
        let entryID = firstSnapshot.allowlist[0].id

        await service.removeAllowlistEntry(id: entryID)
        let snapshot = await service.fetchSnapshot()

        #expect(snapshot.allowlist.isEmpty)
    }
}
