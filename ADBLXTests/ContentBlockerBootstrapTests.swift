import Testing
import Foundation
@testable import ADBLX

@Suite("ContentBlockerBootstrap")
struct ContentBlockerBootstrapTests {
    @Test("first call installs rules, second call is a no-op")
    func idempotentInstall() throws {
        let containerURL = try #require(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
        )
        let rulesURL = containerURL.appendingPathComponent("Rules/Ads.json")
        try? FileManager.default.removeItem(at: rulesURL)

        let firstResult = ContentBlockerBootstrap.ensureInitialRulesInstalled()
        #expect(firstResult == true)
        #expect(FileManager.default.fileExists(atPath: rulesURL.path))

        let secondResult = ContentBlockerBootstrap.ensureInitialRulesInstalled()
        #expect(secondResult == false)

        try? FileManager.default.removeItem(at: rulesURL)
    }
}
