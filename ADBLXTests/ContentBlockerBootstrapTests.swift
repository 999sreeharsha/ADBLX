import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("installs the bundled snapshot via the pipeline and reports success")
    func installsBundledSnapshot() async throws {
        let store = AppCompositionRoot.makeFilterStore()
        let manifestStore = ManifestStore(filterStore: store)
        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))

        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(
            pipeline: pipeline, manifestStore: manifestStore
        )
        #expect(result == true)

        let compiledDir = try await store.directoryURL(.compiled)
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Ads.json").path))
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Privacy.json").path))
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Annoyances.json").path))
    }

    @Test("skips bundled snapshot install when a manifest is already cached")
    func skipsInstallWhenManifestCached() async throws {
        let store = AppCompositionRoot.makeFilterStore()
        let manifestStore = ManifestStore(filterStore: store)
        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        try await manifestStore.save(manifest, etag: "\"etag-1\"")

        let compiledDir = try await store.directoryURL(.compiled)
        let adsCompiledFile = compiledDir.appendingPathComponent("Ads.json")
        try? FileManager.default.removeItem(at: adsCompiledFile)

        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(
            pipeline: pipeline, manifestStore: manifestStore
        )

        #expect(result == false)
        #expect(!FileManager.default.fileExists(atPath: adsCompiledFile.path))

        let metadataDir = try await store.directoryURL(.metadata)
        try? FileManager.default.removeItem(at: metadataDir.appendingPathComponent("manifest.json"))
    }
}
