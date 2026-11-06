import Foundation
@testable import ADBLX

extension FilterStore {
    /// A store rooted in a fresh temporary directory. Tests never use the real App Group: the
    /// installed Safari extensions and the DNS tunnel read it, and two test runners sharing it
    /// made the suite order-dependent.
    nonisolated static func temporary(
        fileManager: FileManager = .default,
        swapPaths: @escaping @Sendable (URL, URL) throws -> Void = { try FilterStore.swapPathsAtomically($0, $1) }
    ) -> FilterStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilterStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return FilterStore(fileManager: fileManager, overrideBaseURL: url, swapPaths: swapPaths)
    }
}

/// Opt-in gate for the on-device harnesses that must write the real App Group (because the
/// extensions or the tunnel read it). They are skipped in normal runs, including CI. Enable with
/// `TEST_RUNNER_ADBLX_DEVICE_HARNESS=1 xcodebuild test …` (xcodebuild strips the prefix).
nonisolated enum DeviceHarness {
    static let skipMessage = "On-device harness: writes the real App Group. Set TEST_RUNNER_ADBLX_DEVICE_HARNESS=1 to run."

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ADBLX_DEVICE_HARNESS"] == "1"
    }
}
