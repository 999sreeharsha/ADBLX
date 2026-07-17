import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("installs the bundled snapshot via the pipeline and reports success")
    func installsBundledSnapshot() async throws {
        let pipeline = AppCompositionRoot.makeFilterPipeline()
        let result = await ContentBlockerBootstrap.ensureInitialRulesInstalled(pipeline: pipeline)
        #expect(result == true)

        let store = FilterStore(appGroupIdentifier: AppGroup.identifier)
        let compiledDir = try await store.directoryURL(.compiled)
        #expect(FileManager.default.fileExists(atPath: compiledDir.appendingPathComponent("Ads.json").path))
    }
}
