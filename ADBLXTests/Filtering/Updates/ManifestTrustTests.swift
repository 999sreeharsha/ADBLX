import Foundation
import Testing
@testable import ADBLX

@Suite("ManifestTrust")
struct ManifestTrustTests {
    // A key that doesn't parse would be dropped from the trusted set without a sound.
    @Test("Every listed public key parses as a P-256 key")
    func everyListedKeyParses() {
        let listed = ManifestTrust.productionPublicKeys + ManifestTrust.debugPublicKeys

        #expect(ManifestTrust.pinnedPublicKeys.count == listed.count)
    }

    @Test("Manifests are trusted only from the published site")
    func allowedBases() {
        #expect(ManifestTrust.allowedBases == [URL(string: "https://999sreeharsha.github.io/ADBLX")!])
    }

    // A visible reminder. Scripts/check-manifest-trust.sh is what stops an archive without them.
    @Test(
        "Both production keys, K1 and K2, are pinned",
        .disabled("Enable once the owner pins K1 and K2 (release checklist, docs/AppStoreSetup.md).")
    )
    func bothProductionKeysArePinned() {
        #expect(Set(ManifestTrust.productionPublicKeys).count == 2)
    }
}
