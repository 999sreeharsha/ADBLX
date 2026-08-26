// ADBLX/Filtering/Storage/AllowlistStore.swift
import Foundation

/// Persists `allowlist.json` (FilterStore/Metadata) via the same atomic-write
/// mechanism as `installed_filters.json`/`filter_preferences.json`.
/// Uses `SafariDomainNormalizer` to enforce valid RFC 1123 domain syntax and deduplication.
actor AllowlistStore {
    private let store: FilterStore
    private static let filename = "allowlist.json"

    init(store: FilterStore) {
        self.store = store
    }

    func load() async -> [AllowlistEntry] {
        guard let data = try? await store.read(Self.filename, in: .metadata),
              let decoded = try? JSONDecoder().decode([AllowlistEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    func loadDomains() async -> [String] {
        let entries = await load()
        return entries.map(\.domain)
    }

    @discardableResult
    func add(domain: String) async throws -> AllowlistEntry {
        let normalized = try SafariDomainNormalizer.normalize(input: domain)
        var entries = await load()
        if let existing = entries.first(where: { $0.domain.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return existing
        }
        let entry = AllowlistEntry(id: UUID().uuidString, domain: normalized)
        entries.append(entry)
        try await save(entries)
        return entry
    }

    func remove(id: String) async throws {
        var entries = await load()
        entries.removeAll { $0.id == id }
        try await save(entries)
    }

    private func save(_ entries: [AllowlistEntry]) async throws {
        let data = try JSONEncoder().encode(entries)
        try await store.writeMetadata(data, filename: Self.filename)
    }
}
