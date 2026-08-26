// ADBLXTests/Filtering/Storage/AllowlistStoreTests.swift
import Testing
import Foundation
@testable import ADBLX

@Suite("AllowlistStore", .serialized)
struct AllowlistStoreTests {
    private func makeStore() async throws -> (FilterStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AllowlistStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = FilterStore(overrideBaseURL: tempDir)
        return (store, tempDir)
    }

    @Test("no existing file returns an empty list")
    func emptyByDefault() async throws {
        let (filterStore, tempDir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let allowlistStore = AllowlistStore(store: filterStore)

        let entries = await allowlistStore.load()

        #expect(entries.isEmpty)
    }

    @Test("add persists a new entry across a fresh store instance")
    func addPersists() async throws {
        let (filterStore, tempDir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let allowlistStore = AllowlistStore(store: filterStore)

        try await allowlistStore.add(domain: "example.com")

        let freshInstance = AllowlistStore(store: filterStore)
        let entries = await freshInstance.load()
        #expect(entries.count == 1)
        #expect(entries.first?.domain == "example.com")
    }

    @Test("remove deletes the matching entry and persists the removal")
    func removePersists() async throws {
        let (filterStore, tempDir) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let allowlistStore = AllowlistStore(store: filterStore)
        try await allowlistStore.add(domain: "example.com")
        let entries = await allowlistStore.load()
        let entryID = entries[0].id

        try await allowlistStore.remove(id: entryID)

        let freshInstance = AllowlistStore(store: filterStore)
        let remaining = await freshInstance.load()
        #expect(remaining.isEmpty)
    }
}
