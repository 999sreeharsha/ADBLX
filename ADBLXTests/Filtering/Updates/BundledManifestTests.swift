import Foundation
import Testing
@testable import ADBLX

/// The bundled manifest describes the bundled lists, and its version is the oldest manifest
/// the app accepts (docs/Security/ManifestTrust.md, Rollback). If the two drifted, the
/// minimum would no longer say what a fresh install is running.
@Suite("BundledManifest")
struct BundledManifestTests {
    private static let bundledFreeIDs = ["easylist", "easyprivacy"]

    @Test("The built-in minimum is the bundled manifest's version, which may be date-only")
    func minimumIsTheBundledVersion() throws {
        let manifest = try #require(BundledManifest.load())
        let version = try #require(ManifestVersionFormat.lenientDate(manifest.manifestVersion))

        #expect(BundledManifest.minimumVersion() == version)
    }

    @Test("Every bundled list is in the bundled manifest, with a matching checksum and group")
    func bundledListsMatchTheManifest() throws {
        let manifest = try #require(BundledManifest.load())
        let bundled = Self.bundledFreeIDs.map { ($0, Optional<FilterGroup>.none) }
            + BundledPremiumCatalog.bundledEntries.map { ($0.filterID, Optional($0.group)) }

        for (id, group) in bundled {
            let url = try #require(Bundle.main.url(forResource: id, withExtension: "txt"), "\(id).txt isn't bundled")
            let entry = try #require(manifest.entries.first { $0.id == id }, "\(id) isn't in the bundled manifest")
            #expect(entry.checksumSHA256 == Checksum.sha256Hex(of: try Data(contentsOf: url)), "\(id)")
            if let group { #expect(entry.group == group, "\(id)") }
        }
    }

    // Failing closed: with no minimum to compare against, no manifest is accepted.
    @Test("Without a bundled manifest the minimum rejects every manifest")
    func missingManifestRejectsEverything() {
        let bundleWithoutManifest = Bundle(for: BundleToken.self)

        #expect(BundledManifest.load(from: bundleWithoutManifest) == nil)
        #expect(BundledManifest.minimumVersion(in: bundleWithoutManifest) == .distantFuture)
    }
}

private final class BundleToken {}
