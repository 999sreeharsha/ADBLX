import CryptoKit
import Foundation
import Testing
@testable import ADBLX

/// The manifest's `dnsNeverBlock` entry is trusted like a filter entry: covered by the signature,
/// and its `sourceURL` must be the one place the site publishes it. Each rejection breaks exactly
/// one rule of an otherwise valid manifest.
@Suite("ManifestVerifier: dnsNeverBlock")
struct ManifestVerifierNeverBlockTests {
    private static let base = URL(string: "https://999sreeharsha.github.io/ADBLX")!
    private static let manifestURL = base.appendingPathComponent("manifest.json")
    private static let goodURL = "https://999sreeharsha.github.io/ADBLX/filters/dns/never-block.txt"

    private let key = P256.Signing.PrivateKey()
    private let otherKey = P256.Signing.PrivateKey()

    private func neverBlock(_ url: String = goodURL, checksum: String = String(repeating: "b", count: 64)) -> DNSNeverBlockEntry {
        DNSNeverBlockEntry(version: "2026-11-07", sourceURL: URL(string: url)!, checksumSHA256: checksum, domainCount: 90)
    }

    private func manifest(_ neverBlock: DNSNeverBlockEntry?, version: String = "2026-11-07T09:30:00Z") -> FilterManifest {
        var m = FilterManifest(manifestVersion: version, entries: [])
        m.dnsNeverBlock = neverBlock
        return m
    }

    private func bytes(_ manifest: FilterManifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(manifest)
    }

    private func signature(_ data: Data, by key: P256.Signing.PrivateKey) -> Data {
        Data((try! key.signature(for: data).rawRepresentation.base64EncodedString() + "\n").utf8)
    }

    private var verifier: ManifestVerifier {
        ManifestVerifier(trustedKeys: [key.publicKey], allowedBases: [Self.base], builtInMinimum: .distantPast)
    }

    private func verify(
        _ data: Data, signatureOver signed: Data? = nil, by signer: P256.Signing.PrivateKey? = nil, cached: FilterManifest? = nil
    ) -> Result<ManifestVerdict, ManifestRejection> {
        do {
            return .success(try verifier.verify(
                manifest: data, signatureFile: signature(signed ?? data, by: signer ?? key), from: Self.manifestURL, cached: cached
            ))
        } catch {
            return .failure(error)
        }
    }

    private func rejection(of result: Result<ManifestVerdict, ManifestRejection>) -> ManifestRejection? {
        if case .failure(let reason) = result { return reason }
        return nil
    }

    // MARK: - Accepted

    @Test("a signed manifest with the entry at the published location is accepted, entry intact")
    func accepted() throws {
        let m = manifest(neverBlock())
        guard case .success(.accepted(let accepted)) = verify(bytes(m)) else { Issue.record("not accepted"); return }
        #expect(accepted.dnsNeverBlock == neverBlock())
    }

    @Test("a manifest without the entry is still accepted")
    func acceptedWithoutEntry() {
        guard case .success(.accepted(let accepted)) = verify(bytes(manifest(nil))) else { Issue.record("not accepted"); return }
        #expect(accepted.dnsNeverBlock == nil)
    }

    // MARK: - Signature

    @Test("an entry in a manifest signed by an unknown key is rejected")
    func unsigned() {
        #expect(rejection(of: verify(bytes(manifest(neverBlock())), by: otherKey)) == .signature)
    }

    @Test("an entry changed after signing is rejected: the signature covers it")
    func tampered() {
        let signed = bytes(manifest(neverBlock(checksum: String(repeating: "b", count: 64))))
        let tampered = bytes(manifest(neverBlock(checksum: String(repeating: "c", count: 64))))
        #expect(rejection(of: verify(tampered, signatureOver: signed)) == .signature)
    }

    @Test("an entry added after signing is rejected")
    func added() {
        #expect(rejection(of: verify(bytes(manifest(neverBlock())), signatureOver: bytes(manifest(nil)))) == .signature)
    }

    // MARK: - sourceURL against the allowed base

    @Test("a source URL on another host is rejected")
    func otherHost() {
        let url = "https://evil.example/ADBLX/filters/dns/never-block.txt"
        #expect(rejection(of: verify(bytes(manifest(neverBlock(url))))) == .sourceURL)
    }

    @Test("a source URL over http is rejected")
    func notHTTPS() {
        let url = "http://999sreeharsha.github.io/ADBLX/filters/dns/never-block.txt"
        #expect(rejection(of: verify(bytes(manifest(neverBlock(url))))) == .sourceURL)
    }

    @Test("a source URL under the allowed host but at another path is rejected")
    func otherPath() {
        for path in ["never-block.txt", "filters/ads/never-block.txt", "filters/dns/other.txt", "../elsewhere/never-block.txt"] {
            let url = "https://999sreeharsha.github.io/ADBLX/\(path)"
            #expect(rejection(of: verify(bytes(manifest(neverBlock(url))))) == .sourceURL, "\(path) must be rejected")
        }
    }

    @Test("a source URL with a query or fragment is rejected")
    func queryAndFragment() {
        for suffix in ["?x=1", "#top"] {
            #expect(rejection(of: verify(bytes(manifest(neverBlock(Self.goodURL + suffix))))) == .sourceURL, "\(suffix) must be rejected")
        }
    }

    @Test("a source URL on a look-alike host is rejected")
    func lookAlike() {
        let url = "https://999sreeharsha.github.io.evil.example/ADBLX/filters/dns/never-block.txt"
        #expect(rejection(of: verify(bytes(manifest(neverBlock(url))))) == .sourceURL)
    }

    @Test("the host is the parsed host: userinfo, a port, a trailing dot, another case or an encoded dot cannot pass for the allowed one")
    func parsedHostNotPrefix() {
        let urls = [
            "https://999sreeharsha.github.io@evil.example/ADBLX/filters/dns/never-block.txt",
            "https://999sreeharsha.github.io:evil@evil.example/ADBLX/filters/dns/never-block.txt",
            "https://evil.example\\@999sreeharsha.github.io/ADBLX/filters/dns/never-block.txt",
            "https://999sreeharsha.github.io:8443/ADBLX/filters/dns/never-block.txt",
            "https://999sreeharsha.github.io./ADBLX/filters/dns/never-block.txt",
            "https://999SREEHARSHA.github.io/ADBLX/filters/dns/never-block.txt",
            "https://999sreeharsha%2Egithub.io/ADBLX/filters/dns/never-block.txt",
            "https://999sreeharsha.github.io/ADBLX/filters/dns/never%2Dblock.txt",
            "https://999sreeharsha.github.io/ADBLX/filters/dns/never-block.txt/"
        ]
        for url in urls {
            guard let parsed = URL(string: url) else { continue }   // an unparseable URL can't reach the verifier at all
            let entry = DNSNeverBlockEntry(version: "2026-11-07", sourceURL: parsed, checksumSHA256: String(repeating: "b", count: 64), domainCount: 90)
            #expect(rejection(of: verify(bytes(manifest(entry)))) == .sourceURL, "\(url) must be rejected")
        }
    }

    @Test("the same holds for a filter entry's source URL")
    func filterEntryParsedHost() {
        let urls = [
            "https://999sreeharsha.github.io@evil.example/ADBLX/filters/ads/easylist.txt",
            "https://999sreeharsha.github.io:8443/ADBLX/filters/ads/easylist.txt",
            "https://999sreeharsha.github.io.evil.example/ADBLX/filters/ads/easylist.txt"
        ]
        for url in urls {
            let entry = FilterManifest.Entry(
                id: "easylist", name: "EasyList", group: .ads, sourceURL: URL(string: url)!, version: "2026-11-06",
                checksumSHA256: String(repeating: "a", count: 64), ruleCount: 1, enabledByDefault: true, premium: false
            )
            let m = FilterManifest(manifestVersion: "2026-11-07T09:30:00Z", entries: [entry])
            #expect(rejection(of: verify(bytes(m))) == .sourceURL, "\(url) must be rejected")
        }
    }

    // MARK: - Same version

    @Test("the same version with a different entry is refused, like any other changed field")
    func sameVersionChanged() {
        let cached = manifest(neverBlock(checksum: String(repeating: "b", count: 64)))
        let incoming = manifest(neverBlock(checksum: String(repeating: "c", count: 64)))
        #expect(rejection(of: verify(bytes(incoming), cached: cached)) == .rollback)
    }

    @Test("the same version and the same entry is unchanged")
    func sameVersionSame() {
        let m = manifest(neverBlock())
        guard case .success(.unchanged) = verify(bytes(m), cached: m) else { Issue.record("not unchanged"); return }
    }
}
