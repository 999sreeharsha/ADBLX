import Testing
import Foundation
@testable import ADBLX

/// The test host is the Debug app, so this checks the merged plist of a Debug build (ADR-0014).
/// `Scripts/check-background-modes.sh` checks the Release build in CI.
@Suite("App Info.plist background keys")
struct AppInfoPlistBackgroundTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test("both background modes are declared")
    func backgroundModes() {
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        #expect(Set(modes).isSuperset(of: ["fetch", "processing"]))
    }

    @Test("every identifier the app registers is permitted")
    func permittedIdentifiers() {
        let permitted = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        #expect(permitted == BackgroundTaskIdentifiers.all)
    }

    // XcodeGen writes literal versions into the plist by default, which would override
    // MARKETING_VERSION and CURRENT_PROJECT_VERSION. The built value can't show that while both
    // are 1.0 / 1, so this reads the source the build merges.
    @Test("the merged plist takes the version from the build settings")
    func versionFollowsBuildSettings() throws {
        let data = try Data(contentsOf: Self.mergedPlistSource)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
        #expect(plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
    }

    private static let mergedPlistSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Config/ADBLX-Info.plist")
}
