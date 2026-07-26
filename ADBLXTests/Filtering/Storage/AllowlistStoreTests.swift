// ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("AllowlistStore", .serialized)
struct AllowlistStoreTests {
    private func makeStore() async throws -> FilterStore {
        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("allowlist.json"))
        return store
    }

    @Test("no existing file returns an empty list")
    func emptyByDefault() async throws {
        let filterStore = try await makeStore()
        let allowlistStore = AllowlistStore(store: filterStore)

        let entries = await allowlistStore.load()

        #expect(entries.isEmpty)
    }

    @Test("add persists a new entry across a fresh store instance")
    func addPersists() async throws {
        let filterStore = try await makeStore()
        let allowlistStore = AllowlistStore(store: filterStore)

        await allowlistStore.add(domain: "example.com")

        let freshInstance = AllowlistStore(store: filterStore)
        let entries = await freshInstance.load()
        #expect(entries.count == 1)
        #expect(entries.first?.domain == "example.com")
    }

    @Test("remove deletes the matching entry and persists the removal")
    func removePersists() async throws {
        let filterStore = try await makeStore()
        let allowlistStore = AllowlistStore(store: filterStore)
        await allowlistStore.add(domain: "example.com")
        let entries = await allowlistStore.load()
        let entryID = entries[0].id

        await allowlistStore.remove(id: entryID)

        let freshInstance = AllowlistStore(store: filterStore)
        let remaining = await freshInstance.load()
        #expect(remaining.isEmpty)
    }
}
