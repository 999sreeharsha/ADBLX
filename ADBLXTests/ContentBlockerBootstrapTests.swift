import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("installs the bundled snapshot via the pipeline and reports success")
    func installsBundledSnapshot() async throws {
        let store = AppCompositionRoot.makeFilterStore()
        let pipeline = AppCompositionRoot.makeFilterPipeline(store: store)
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
        #expect(result == true)

        let compiledDir = try await store.directoryURL(.compiled)
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Ads.json").path))
    }
}
