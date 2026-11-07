import CryptoKit
import Foundation
import Testing
@testable import ADBLX

/// The checks the app applies to a downloaded manifest before trusting any of it
/// (docs/Security/ManifestTrust.md, "What the app checks, in order"). Each rejection test
/// breaks exactly one rule of an otherwise valid manifest.
@Suite("ManifestVerifier")
struct ManifestVerifierTests {
    private static let base = URL(string: "https://999sreeharsha.github.io/ADBLX")!
    private static let manifestURL = base.appendingPathComponent("manifest.json")
    private static let minimum = ManifestVersionFormat.lenientDate("2026-11-01")!

    private let k1 = P256.Signing.PrivateKey()
    private let k2 = P256.Signing.PrivateKey()

    private func entry(_ id: String, group: FilterGroup = .ads, sourceURL: String? = nil) -> FilterManifest.Entry {
        FilterManifest.Entry(
            id: id, name: id, group: group,
            sourceURL: URL(string: sourceURL ?? "\(Self.base.absoluteString)/filters/\(group.rawValue)/\(id).txt")!,
            version: "2026-11-06", checksumSHA256: String(repeating: "a", count: 64), ruleCount: 1,
            enabledByDefault: true, premium: false
        )
    }

    private func manifest(_ version: String = "2026-11-06T09:30:00Z", _ entries: [FilterManifest.Entry]? = nil) -> FilterManifest {
        FilterManifest(manifestVersion: version, entries: entries ?? [entry("easylist"), entry("easyprivacy", group: .privacy)])
    }

    private func bytes(_ manifest: FilterManifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(manifest)
    }

    /// The Publisher's format: base64 of the 64-byte raw signature, then a newline.
    private func signatureFile(_ data: Data, key: P256.Signing.PrivateKey) -> Data {
        Data((try! key.signature(for: data).rawRepresentation.base64EncodedString() + "\n").utf8)
    }

    private func verify(
        _ data: Data, signedBy key: P256.Signing.PrivateKey? = nil, from url: URL = manifestURL,
        cached: FilterManifest? = nil
    ) throws(ManifestRejection) -> ManifestVerdict {
        let verifier = ManifestVerifier(
            trustedKeys: [k1.publicKey, k2.publicKey], allowedBases: [Self.base], builtInMinimum: Self.minimum
        )
        return try verifier.verify(
            manifest: data, signatureFile: signatureFile(data, key: key ?? k1), from: url, cached: cached
        )
    }

    private func expectRejected(
        _ reason: ManifestRejection, _ body: () throws(ManifestRejection) -> ManifestVerdict,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let verdict = try body()
            Issue.record("Expected \(reason), got \(verdict)", sourceLocation: sourceLocation)
        } catch {
            #expect(error == reason, sourceLocation: sourceLocation)
        }
    }

    // MARK: Signature

    @Test("A manifest signed by either pinned key is accepted, so K2 can take over if K1 is lost")
    func eitherPinnedKeyIsAccepted() throws {
        let manifest = manifest()

        #expect(try verify(bytes(manifest), signedBy: k1) == .accepted(manifest))
        #expect(try verify(bytes(manifest), signedBy: k2) == .accepted(manifest))
    }

    @Test("A key that isn't trusted is rejected, before any other rule is looked at")
    func untrustedKeyIsRejectedFirst() {
        let badID = bytes(manifest("2026-11-06T09:30:00Z", [entry("../escape")]))

        expectRejected(.signature) { () throws(ManifestRejection) in
            try verify(badID, signedBy: P256.Signing.PrivateKey())
        }
    }

    @Test("A signature over other bytes, or a signature file that isn't 64 base64 bytes, is rejected")
    func wrongOrMalformedSignatureIsRejected() {
        let verifier = ManifestVerifier(trustedKeys: [k1.publicKey], allowedBases: [Self.base], builtInMinimum: Self.minimum)
        let data = bytes(manifest())
        let other = bytes(manifest("2026-11-06T09:30:01Z"))
        let truncated = Data(try! k1.signature(for: data).rawRepresentation.prefix(63).base64EncodedString().utf8)

        for signature in [signatureFile(other, key: k1), Data("not base64".utf8), truncated, Data()] {
            expectRejected(.signature) { () throws(ManifestRejection) in
                try verifier.verify(manifest: data, signatureFile: signature, from: Self.manifestURL, cached: nil)
            }
        }
    }

    @Test("With no trusted keys every manifest is rejected, so a build without pinned keys stays on its bundled lists")
    func noKeysRejectsEverything() {
        let verifier = ManifestVerifier(trustedKeys: [], allowedBases: [Self.base], builtInMinimum: Self.minimum)
        let data = bytes(manifest())

        expectRejected(.signature) { () throws(ManifestRejection) in
            try verifier.verify(manifest: data, signatureFile: signatureFile(data, key: k1), from: Self.manifestURL, cached: nil)
        }
    }

    // A signature the Publisher wrote (`publisher sign`, 2026-11-07) over the committed
    // backend/public/manifest.json, with a throwaway test key whose private half was deleted.
    // Guards the format the two sides share: raw r ‖ s, base64, trailing newline.
    @Test("A signature written by the Publisher verifies")
    func publisherSignatureVerifies() throws {
        let publicKey = try P256.Signing.PublicKey(rawRepresentation: Data(base64Encoded: PublisherFixture.publicKey)!)
        let manifest = Data(base64Encoded: PublisherFixture.manifest)!
        let signature = Data((PublisherFixture.signature + "\n").utf8)
        var tampered = manifest
        tampered[tampered.startIndex + 30] ^= 1

        #expect(ManifestVerifier.signatureIsValid(manifest: manifest, signatureFile: signature, trustedKeys: [publicKey]))
        #expect(!ManifestVerifier.signatureIsValid(manifest: tampered, signatureFile: signature, trustedKeys: [publicKey]))
    }

    // MARK: Decoding and version format

    @Test("Signed bytes that don't decode as a manifest are rejected")
    func undecodableIsRejected() {
        var unknownGroup = String(decoding: bytes(manifest()), as: UTF8.self)
        unknownGroup = unknownGroup.replacingOccurrences(of: "\"privacy\"", with: "\"tracking\"")

        for data in [Data("not json".utf8), Data(unknownGroup.utf8)] {
            expectRejected(.malformed) { () throws(ManifestRejection) in try verify(data) }
        }
    }

    @Test("An incoming manifestVersion must be a full UTC timestamp")
    func incomingVersionIsStrict() {
        for version in ["2026-11-06", "2026-11-06T09:30:00+05:30", "2026-11-06T09:30Z", "2026-02-30T00:00:00Z", "1"] {
            expectRejected(.versionFormat) { () throws(ManifestRejection) in try verify(bytes(manifest(version))) }
        }
    }

    @Test("A stored version may be date-only and counts as midnight UTC; an incoming one may not")
    func storedVersionIsLenient() {
        let midnight = Date(timeIntervalSince1970: 1_793_836_800)  // 2026-11-05T00:00:00Z
        let morning = Date(timeIntervalSince1970: 1_793_871_000)   // 2026-11-05T09:30:00Z

        #expect(ManifestVersionFormat.lenientDate("2026-11-05") == midnight)
        #expect(ManifestVersionFormat.strictDate("2026-11-05T00:00:00Z") == midnight)
        #expect(ManifestVersionFormat.lenientDate("2026-11-05T09:30:00Z") == morning)
        #expect(ManifestVersionFormat.strictDate("2026-11-05") == nil)
        #expect(ManifestVersionFormat.lenientDate("2026-13-05") == nil)
        #expect(ManifestVersionFormat.lenientDate("1") == nil)
    }

    // MARK: Rollback

    @Test("A manifest older than the built-in minimum is rejected, so a fresh install can't be rolled back")
    func belowMinimumIsRejected() throws {
        expectRejected(.belowMinimum) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-10-31T23:59:59Z")))
        }
        let atMinimum = manifest("2026-11-01T00:00:00Z")
        #expect(try verify(bytes(atMinimum)) == .accepted(atMinimum))
    }

    @Test("A manifest older than the cached one is rejected")
    func olderThanCachedIsRejected() {
        let cached = manifest("2026-11-06T09:30:00Z")

        expectRejected(.rollback) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-11-06T09:29:59Z")), cached: cached)
        }
    }

    @Test("The same version with the same content is unchanged, even if the bytes are laid out differently")
    func equalVersionAndContentIsUnchanged() throws {
        let cached = manifest()
        let compact = try JSONEncoder().encode(cached)

        #expect(try verify(compact, cached: cached) == .unchanged)
    }

    @Test("The same version with different content is rejected")
    func equalVersionWithDifferentContentIsRejected() {
        let cached = manifest()
        let changed = manifest("2026-11-06T09:30:00Z", [entry("easylist")])

        expectRejected(.rollback) { () throws(ManifestRejection) in try verify(bytes(changed), cached: cached) }
    }

    // Every field counts, not only the filter entries: the DNS never-block list rides in the
    // same manifest.
    @Test("The same version with a different never-block entry is rejected")
    func equalVersionWithDifferentNeverBlockIsRejected() {
        var cached = manifest()
        cached.dnsNeverBlock = DNSNeverBlockEntry(
            version: "2026-11-06", sourceURL: URL(string: "\(Self.base.absoluteString)/dns/never-block.txt")!,
            checksumSHA256: String(repeating: "a", count: 64), domainCount: 10
        )
        var changed = cached
        changed.dnsNeverBlock?.domainCount = 11

        expectRejected(.rollback) { () throws(ManifestRejection) in try verify(bytes(changed), cached: cached) }
    }

    @Test("A date-only cached version compares as midnight UTC")
    func dateOnlyCachedVersionIsMidnight() throws {
        let cached = manifest("2026-11-06")

        expectRejected(.rollback) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-11-05T23:59:59Z")), cached: cached)
        }
        #expect(try verify(bytes(manifest("2026-11-06T00:00:00Z")), cached: cached) == .unchanged)
        expectRejected(.rollback) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-11-06T00:00:00Z", [entry("easylist")])), cached: cached)
        }
        let later = manifest("2026-11-06T00:00:01Z")
        #expect(try verify(bytes(later), cached: cached) == .accepted(later))
    }

    @Test("A cached version that isn't a date is ignored; the built-in minimum still applies")
    func unreadableCachedVersionFallsBackToMinimum() throws {
        let cached = manifest("1")
        let newer = manifest()

        #expect(try verify(bytes(newer), cached: cached) == .accepted(newer))
        expectRejected(.belowMinimum) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-10-01T00:00:00Z")), cached: cached)
        }
    }

    // MARK: Entries

    @Test("An id outside ^[a-z0-9][a-z0-9-]{0,63}$ is rejected")
    func badIDIsRejected() {
        for id in ["EasyList", "../escape", "-leading", "has.dot", "", String(repeating: "a", count: 65)] {
            let entries = [entry("easylist"), entry(id, sourceURL: "\(Self.base.absoluteString)/filters/ads/x.txt")]
            expectRejected(.id) { () throws(ManifestRejection) in
                try verify(bytes(manifest("2026-11-06T09:30:00Z", entries)))
            }
        }
    }

    @Test("Two entries with the same id are rejected")
    func duplicateIDIsRejected() {
        let entries = [entry("easylist"), entry("easyprivacy", group: .privacy), entry("easylist")]

        expectRejected(.duplicate) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-11-06T09:30:00Z", entries)))
        }
    }

    @Test("A sourceURL other than <base>/filters/<group>/<id>.txt over https is rejected")
    func badSourceURLIsRejected() {
        let base = Self.base.absoluteString
        for url in [
            "http://999sreeharsha.github.io/ADBLX/filters/ads/easylist.txt",
            "https://evil.example/ADBLX/filters/ads/easylist.txt",
            "\(base)/filters/privacy/easylist.txt",
            "\(base)/filters/ads/easylist.txt?x=1",
            "\(base)/backend/public/filters/ads/easylist.txt",
            "\(base)/filters/ads/../ads/easylist.txt"
        ] {
            expectRejected(.sourceURL) { () throws(ManifestRejection) in
                try verify(bytes(manifest("2026-11-06T09:30:00Z", [entry("easylist", sourceURL: url)])))
            }
        }
    }

    @Test("A manifest fetched from outside the allowed bases is rejected")
    func manifestOutsideAllowedBasesIsRejected() {
        let elsewhere = URL(string: "https://mirror.example/ADBLX/manifest.json")!
        let entries = [entry("easylist", sourceURL: "https://mirror.example/ADBLX/filters/ads/easylist.txt")]

        expectRejected(.sourceURL) { () throws(ManifestRejection) in
            try verify(bytes(manifest("2026-11-06T09:30:00Z", entries)), from: elsewhere)
        }
    }
}

private enum PublisherFixture {
    static let publicKey = "sN62bob0fFo4DrKj51F8Yo4ptABPsgpntoTlX58UwswxQFgcDSXSIUgtxy1H29p6+d59IcFSvV9eoYXEcgrwkw=="
    static let signature = "kObOHjBnyHpXUs2trrvc5TCRSsGYhCyixqpoRmbFW9nU88rGKINFLmnGD/cqVmE+mMtxHZIU9EoBRKjNotrt2Q=="
    static let manifest = """
        ewogICJtYW5pZmVzdFZlcnNpb24iOiAiMjAyNi0xMS0wNSIsCiAgImVudHJpZXMiOiBbCiAgICB7CiAgICAgICJpZCI6ICJlYXN5\
        bGlzdCIsCiAgICAgICJuYW1lIjogIkVhc3lMaXN0IiwKICAgICAgImdyb3VwIjogImFkcyIsCiAgICAgICJzb3VyY2VVUkwiOiAi\
        aHR0cHM6Ly85OTlzcmVlaGFyc2hhLmdpdGh1Yi5pby9BREJMWC9maWx0ZXJzL2Fkcy9lYXN5bGlzdC50eHQiLAogICAgICAidmVy\
        c2lvbiI6ICIyMDI2LTA4LTE4IiwKICAgICAgImNoZWNrc3VtU0hBMjU2IjogImM3ZTBlOGI1NjBkY2M4OGFkMzY0NzE5NjMxMGE0\
        ZDU5MmY0ZTYyYWEyODhiZjgxOWQwNTllMmVhZDE5YTlmODIiLAogICAgICAicnVsZUNvdW50IjogNzgwNDMsCiAgICAgICJlbmFi\
        bGVkQnlEZWZhdWx0IjogdHJ1ZSwKICAgICAgInByZW1pdW0iOiBmYWxzZQogICAgfSwKICAgIHsKICAgICAgImlkIjogImVhc3lw\
        cml2YWN5IiwKICAgICAgIm5hbWUiOiAiRWFzeVByaXZhY3kiLAogICAgICAiZ3JvdXAiOiAicHJpdmFjeSIsCiAgICAgICJzb3Vy\
        Y2VVUkwiOiAiaHR0cHM6Ly85OTlzcmVlaGFyc2hhLmdpdGh1Yi5pby9BREJMWC9maWx0ZXJzL3ByaXZhY3kvZWFzeXByaXZhY3ku\
        dHh0IiwKICAgICAgInZlcnNpb24iOiAiMjAyNi0wOC0xOCIsCiAgICAgICJjaGVja3N1bVNIQTI1NiI6ICJjMWFiZWJjMGVlZWM2\
        ZGM0ODViMGQ5Nzc3ZmJlYzExMzkxOThkZWJmYTkyYWNkZTVkYmQ2MmQwYjgzOTVlYmE1IiwKICAgICAgInJ1bGVDb3VudCI6IDU1\
        ODgxLAogICAgICAiZW5hYmxlZEJ5RGVmYXVsdCI6IHRydWUsCiAgICAgICJwcmVtaXVtIjogZmFsc2UKICAgIH0sCiAgICB7CiAg\
        ICAgICJpZCI6ICJmYW5ib3ktYW5ub3lhbmNlcyIsCiAgICAgICJuYW1lIjogIkZhbmJveSBBbm5veWFuY2VzIiwKICAgICAgImdy\
        b3VwIjogImFubm95YW5jZXMiLAogICAgICAic291cmNlVVJMIjogImh0dHBzOi8vOTk5c3JlZWhhcnNoYS5naXRodWIuaW8vQURC\
        TFgvZmlsdGVycy9hbm5veWFuY2VzL2ZhbmJveS1hbm5veWFuY2VzLnR4dCIsCiAgICAgICJ2ZXJzaW9uIjogIjIwMjYtMDgtMTgi\
        LAogICAgICAiY2hlY2tzdW1TSEEyNTYiOiAiNTYxODA1M2MyZTYwMjdmYWJkZDE3OGEyYzdkZDFiMmYzZWIwZWNlZDMxNGY1Mzkx\
        Y2VjZWNmZmMzMTI0OGUxZSIsCiAgICAgICJydWxlQ291bnQiOiA0ODk2MiwKICAgICAgImVuYWJsZWRCeURlZmF1bHQiOiBmYWxz\
        ZSwKICAgICAgInByZW1pdW0iOiB0cnVlCiAgICB9LAogICAgewogICAgICAiaWQiOiAic2hpZWxkLWZpeGVzIiwKICAgICAgIm5h\
        bWUiOiAiU0hJRUxEIEZpeGVzIiwKICAgICAgImdyb3VwIjogImFubm95YW5jZXMiLAogICAgICAic291cmNlVVJMIjogImh0dHBz\
        Oi8vOTk5c3JlZWhhcnNoYS5naXRodWIuaW8vQURCTFgvZmlsdGVycy9hbm5veWFuY2VzL3NoaWVsZC1maXhlcy50eHQiLAogICAg\
        ICAidmVyc2lvbiI6ICIyMDI2LTExLTA1IiwKICAgICAgImNoZWNrc3VtU0hBMjU2IjogIjg2YWViMDk4MWU3OTFiZjIyNWMyODQy\
        YjZhYzcyMzVlNGFhM2EwMDQ5ZmY4YWMzNDc0NmU0ZGM1OTgxOWI0NDciLAogICAgICAicnVsZUNvdW50IjogMSwKICAgICAgImVu\
        YWJsZWRCeURlZmF1bHQiOiBmYWxzZSwKICAgICAgInByZW1pdW0iOiB0cnVlCiAgICB9CiAgXQp9Cg==
        """
}
