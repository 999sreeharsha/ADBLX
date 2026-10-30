import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("installs the bundled snapshot via the pipeline and reports success")
    func installsBundledSnapshot() async throws {
        let store = FilterStore.temporary()
        let manifestStore = ManifestStore(filterStore: store)

        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(
            pipeline: pipeline, manifestStore: manifestStore
        )
        #expect(result == true)

        let compiledDir = try await store.directoryURL(.compiled)
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Ads.json").path))
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Privacy.json").path))
        // Annoyances is premium: the free bootstrap must not install it (see
        // FilterPipelineTests "bundled snapshot is free-only unless premium is requested").
    }

    @Test("skips bundled snapshot install when a manifest is already cached")
    func skipsInstallWhenManifestCached() async throws {
        let store = FilterStore.temporary()
        let manifestStore = ManifestStore(filterStore: store)
        let manifest = FilterManifest(manifestVersion: "1", entries: [])
        try await manifestStore.save(manifest, etag: "\"etag-1\"")

        let compiledDir = try await store.directoryURL(.compiled)
        let adsCompiledFile = compiledDir.appendingPathComponent("Ads.json")
        // A real-looking Ads.json (>10k bytes) so the bootstrap's "already installed" gate applies.
        let sampleRules = Array(repeating: ["trigger": ["url-filter": ".*"], "action": ["type": "block"]], count: 300)
        let sampleData = try JSONSerialization.data(withJSONObject: sampleRules)
        try sampleData.write(to: adsCompiledFile, options: .atomic)

        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(
            pipeline: pipeline, manifestStore: manifestStore
        )

        #expect(result == false)
    }
}

