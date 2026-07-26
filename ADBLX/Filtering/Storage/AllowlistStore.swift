// ADBLX/Filtering/Storage/AllowlistStore.swift
import Foundation

/// Persists `allowlist.json` (FilterStore/Metadata) via the same atomic-write
/// mechanism as `installed_filters.json`/`filter_preferences.json`. Storage only —
/// this does not exempt any domain from blocking. Real enforcement (touching
/// FilterPipeline/CompositionService/RuleCompiler) is separate, larger, deferred
/// work (Sprint 5B design doc).
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

    func add(domain: String) async {
        var entries = await load()
        entries.append(AllowlistEntry(id: UUID().uuidString, domain: domain))
        try? await save(entries)
    }

    func remove(id: String) async {
        var entries = await load()
        entries.removeAll { $0.id == id }
        try? await save(entries)
    }

    private func save(_ entries: [AllowlistEntry]) async throws {
        let data = try JSONEncoder().encode(entries)
        try await store.writeMetadata(data, filename: Self.filename)
    }
}
