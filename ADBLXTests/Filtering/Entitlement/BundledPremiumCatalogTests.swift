import Testing
import Foundation
@testable import ADBLX

@Suite("BundledPremiumCatalog", .serialized)
struct BundledPremiumCatalogTests {
    private func makePipeline() -> (FilterPipeline, FilterStore, URL) {
        let ids = GroupExtensionIdentifiers(
            ads: "com.ADBLX.ADBLX.AdsBlocker", privacy: "com.ADBLX.ADBLX.PrivacyBlocker",
            annoyances: "com.ADBLX.ADBLX.AnnoyancesBlocker", regional: "com.ADBLX.ADBLX.RegionalBlocker"
        )
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let store = FilterStore(overrideBaseURL: temp)
        let pipeline = FilterPipeline(
            validator: FilterValidator(), compiler: NativeRuleCompilerAdapter(),
            compositionService: JSONArrayCompositionService(),
            partitioner: GroupPartitioner(extensionIdentifiers: ids),
            store: store, writer: AtomicRuleWriter(), reloader: ReloadCoordinator()
        )
        return (pipeline, store, temp)
    }

    private func installed(_ store: FilterStore) async throws -> [InstalledFilter] {
        try JSONDecoder().decode([InstalledFilter].self, from: try await store.read("installed_filters.json", in: .metadata))
    }

    @Test("catalog IDs and groups exactly match the premium lists the bundled snapshot installs")
    func catalogMatchesBundledPremiumLists() async throws {
        let (pipeline, store, temp) = makePipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        _ = try await pipeline.installBundledSnapshotIfNeeded(includePremium: true)
        let premium = try await installed(store).filter { $0.premium == true }

        #expect(Set(premium.map(\.id)) == Set(BundledPremiumCatalog.bundledEntries.map(\.filterID)))
        for entry in BundledPremiumCatalog.bundledEntries {
            #expect(premium.first { $0.id == entry.filterID }?.group == entry.group)
            #expect(BundledPremiumCatalog.isPremium(filterID: entry.filterID))
        }
    }

    @Test("a free bundled install contains no catalog (premium) ID")
    func freeInstallHasNoCatalogIDs() async throws {
        let (pipeline, store, temp) = makePipeline()
        defer { try? FileManager.default.removeItem(at: temp) }

        _ = try await pipeline.installBundledSnapshotIfNeeded()
        let ids = Set(try await installed(store).map(\.id))
        #expect(ids.isDisjoint(with: Set(BundledPremiumCatalog.bundledEntries.map(\.filterID))))
    }
}
