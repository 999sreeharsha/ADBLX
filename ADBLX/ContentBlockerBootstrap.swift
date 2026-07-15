import Foundation
import SafariServices
import OSLog

enum ContentBlockerBootstrap {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ADBLX.ADBLX",
        category: "Bootstrap"
    )

    private static let contentBlockerIdentifier = "com.ADBLX.ADBLX.AdsBlocker"

    @discardableResult
    static func ensureInitialRulesInstalled() -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else {
            logger.error("Could not resolve App Group container")
            return false
        }

        let rulesDirectory = containerURL.appendingPathComponent("Rules", isDirectory: true)
        let destinationURL = rulesDirectory.appendingPathComponent("Ads.json")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return false
        }

        guard let bundledURL = Bundle.main.url(forResource: "blockerList", withExtension: "json") else {
            logger.error("Bundled blockerList.json not found")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: bundledURL)
            let temporaryURL = rulesDirectory.appendingPathComponent("Ads.json.tmp")
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            logger.info("Copied Ads.json to App Group")
            return true
        } catch {
            logger.error("Failed to copy Ads.json to App Group: \(error, privacy: .public)")
            return false
        }
    }

    // Sprint-0-only behavior: reload is requested on every launch, not just first install.
    // Apple exposes no "extension was just enabled in Safari" callback, and the one
    // guaranteed first-install reload fires before the user has ever enabled the
    // extension — so it's guaranteed to be a no-op/failure on a fresh install with no
    // second trigger. Launch is the only observable event available before Sprint 1's
    // manifest/version-comparison logic exists; that logic replaces this with
    // "reload only when the manifest version changed."
    static func reloadIfNeeded() {
        ensureInitialRulesInstalled()

        SFContentBlockerManager.reloadContentBlocker(withIdentifier: contentBlockerIdentifier) { error in
            if let error {
                logger.error("Reload failed: \(error, privacy: .public)")
            } else {
                logger.info("Reload succeeded")
            }
        }
    }
}
