import Testing
import Foundation
import os
import ADBLXShared
@testable import ADBLX

/// The never-block list: domains DNS Protection must always resolve (payments, banks, Apple,
/// fraud checks), whatever a blocklist says. Expected domains are literals written here, not
/// read back from the list under test.
@Suite("Never-block list")
struct DNSNeverBlockListTests {
    @Test("blank lines and comments are skipped, names are lowercased and de-duplicated")
    func parse() {
        let text = """
        # payments
        Razorpay.com

        razorpay.com
        // another comment
        npci.org.in   # trailing note
        """
        #expect(DNSNeverBlockList.parse(text) == ["npci.org.in", "razorpay.com"])
    }

    @Test("entries that aren't plain domains are dropped: IPs, wildcards, paths, modifiers, exceptions")
    func rejects() {
        let text = "1.2.3.4\n*.example.com\nexample.com/path\n||ads.example.com^$third-party\n@@||ok.example.com^\nsingle\nvalid.example"
        #expect(DNSNeverBlockList.parse(text) == ["valid.example"])
    }

    @Test("the bundled seed has no line the parser silently drops")
    func seedHasNoDroppedLines() throws {
        let text = try #require(DNSNeverBlockList.bundledSeedText())
        let meaningful = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        #expect(DNSNeverBlockList.parse(text).count == Set(meaningful).count)
        #expect(meaningful.count == Set(meaningful).count, "the seed lists a domain twice")
    }

    @Test("the seed covers payment gateways, UPI, wallets, banks, Apple and fraud checks")
    func seedCoverage() {
        let seed = Set(DNSNeverBlockList.bundledSeed() ?? [])
        let expected = [
            // gateways and card networks
            "razorpay.com", "paytm.com", "phonepe.com", "payu.in", "juspay.in", "billdesk.com", "ccavenue.com",
            "cashfree.com", "stripe.com", "paypal.com", "adyen.com", "visa.com", "mastercard.com",
            // UPI, NPCI, wallets
            "npci.org.in", "bhimupi.org.in", "pay.google.com", "amazonpay.in", "mobikwik.com",
            // major Indian banks
            "hdfcbank.com", "icicibank.com", "sbi.co.in", "onlinesbi.sbi", "axisbank.com", "kotak.com",
            "yesbank.in", "idfcfirstbank.com", "indusind.com", "pnbindia.in", "bankofbaroda.in",
            // Apple services
            "apple.com", "icloud.com", "mzstatic.com", "apple-cloudkit.com",
            // fraud and device checks
            "online-metrix.net", "threatmetrix.com", "iovation.com", "cardinalcommerce.com"
        ]
        for domain in expected { #expect(seed.contains(domain), "\(domain) is missing from the never-block seed") }
    }

    @Test("the seed stays small and specific: nothing broad enough to un-block ads or trackers")
    func seedIsNarrow() {
        let seed = Set(DNSNeverBlockList.bundledSeed() ?? [])
        let tooBroad = [
            "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "doubleclick.net",
            "facebook.com", "amazon.com", "amazonaws.com", "cloudfront.net", "akamaihd.net", "akamai.net",
            "cloudflare.com", "microsoft.com", "azure.com", "fastly.net", "googlesyndication.com"
        ]
        for domain in tooBroad { #expect(!seed.contains(domain), "\(domain) is too broad for the never-block list") }
        #expect(seed.count >= 60 && seed.count <= 400, "never-block has \(seed.count) entries")
    }
}

@Suite("Never-block precedence")
struct DNSNeverBlockPrecedenceTests {
    private func engine(block: [String], allow: [String] = [], neverBlock: [String]) throws -> DNSLookupEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try DNSArtifactPublisher().publish(
            blocklistSources: block, allowlistRules: allow, neverBlockRules: neverBlock, baseAppGroupURL: dir
        )
        return DNSLookupEngine(initialSnapshot: try DNSGenerationLoader().loadActiveGeneration(baseAppGroupURL: dir))
    }

    @Test("a never-block domain resolves although the blocklist blocks it, subdomains included")
    func beatsBlocklist() throws {
        let e = try engine(block: ["||pay.example^"], neverBlock: ["pay.example"])
        #expect(e.lookup(domain: "pay.example") == .allow)
        #expect(e.lookup(domain: "checkout.pay.example") == .allow)
    }

    @Test("a never-block domain beats even a more specific blocklist entry under it")
    func beatsSpecificBlock() throws {
        let e = try engine(block: ["||ads.pay.example^"], neverBlock: ["pay.example"])
        #expect(e.lookup(domain: "ads.pay.example") == .allow)
    }

    @Test("other blocked names stay blocked")
    func othersStayBlocked() throws {
        let e = try engine(block: ["||pay.example^", "||tracker.example^"], neverBlock: ["pay.example"])
        #expect(e.lookup(domain: "tracker.example") == .block)
        #expect(e.lookup(domain: "sub.tracker.example") == .block)
        #expect(e.lookup(domain: "notpay.example") == .allow)   // never on a list
    }

    @Test("an empty never-block list changes nothing")
    func emptyNeverBlock() throws {
        let e = try engine(block: ["||pay.example^"], neverBlock: [])
        #expect(e.lookup(domain: "pay.example") == .block)
    }

    @Test("the user's allowlist and the never-block list both apply, and neither depends on the other")
    func withUserAllowlist() throws {
        let both = try engine(block: ["||a.example^", "||b.example^"], allow: ["a.example"], neverBlock: ["b.example"])
        #expect(both.lookup(domain: "a.example") == .allow)
        #expect(both.lookup(domain: "b.example") == .allow)
        let noUser = try engine(block: ["||a.example^", "||b.example^"], allow: [], neverBlock: ["b.example"])
        #expect(noUser.lookup(domain: "a.example") == .block)
        #expect(noUser.lookup(domain: "b.example") == .allow)
    }

    // MARK: - Against the real bundled lists

    private func bundledBlocklists() throws -> [String] {
        try ["oisd", "peter-lowe"].map { name in
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Filters/DNS")
                ?? Bundle.main.url(forResource: name, withExtension: "txt"))
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func engine(realListsWith neverBlock: [String]) throws -> DNSLookupEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try DNSArtifactPublisher().publish(
            blocklistSources: try bundledBlocklists(), allowlistRules: [], neverBlockRules: neverBlock, baseAppGroupURL: dir
        )
        return DNSLookupEngine(initialSnapshot: try DNSGenerationLoader().loadActiveGeneration(baseAppGroupURL: dir))
    }

    @Test("without the never-block list the real blocklists do block a bank's fraud-check domain")
    func realListsBlockFraudCheck() throws {
        let e = try engine(realListsWith: [])
        #expect(e.lookup(domain: "h.online-metrix.net") == .block)
    }

    @Test("with the seed, the fraud-check, gateway, bank and Apple domains resolve against the real lists")
    func seedAgainstRealLists() throws {
        let e = try engine(realListsWith: try #require(DNSNeverBlockList.bundledSeed()))
        for domain in [
            "h.online-metrix.net", "online-metrix.net", "api.razorpay.com", "checkout.razorpay.com",
            "securegw.paytm.in", "netbanking.hdfcbank.com", "www.icicibank.com", "upi.npci.org.in",
            "gateway.push.apple.com", "buy.itunes.apple.com"
        ] { #expect(e.lookup(domain: domain) == .allow, "\(domain) must resolve") }
        // The list narrows blocking; it doesn't switch it off.
        #expect(e.lookup(domain: "ad.doubleclick.net") == .block)
        #expect(e.lookup(domain: "googleadservices.com") == .block)
    }
}

// MARK: - Store and update

private nonisolated final class CountingSession: HTTPSession, @unchecked Sendable {
    let requests = OSAllocatedUnfairLock(initialState: [URL]())
    private let body: Data
    private let status: Int
    init(body: Data, status: Int = 200) { self.body = body; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.withLock { $0.append(request.url!) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Never-block store and update")
struct DNSNeverBlockUpdateTests {
    private let url = URL(string: "https://example.invalid/filters/dns/never-block.txt")!
    private let text = "# list\nrazorpay.com\nnpci.org.in\nonline-metrix.net\n"

    private func makeStore() -> (DNSNeverBlockStore, FilterStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filterStore = FilterStore(overrideBaseURL: dir)
        return (DNSNeverBlockStore(filterStore: filterStore, seed: { ["seed.example"] }), filterStore)
    }

    private func entry(_ body: String? = nil, version: String = "2026-11-07", count: Int = 3) -> DNSNeverBlockEntry {
        let data = Data((body ?? text).utf8)
        return DNSNeverBlockEntry(version: version, sourceURL: url, checksumSHA256: Checksum.sha256Hex(of: data), domainCount: count)
    }

    @Test("with nothing installed the bundled seed is used")
    func seedFallback() async {
        let (store, _) = makeStore()
        #expect(await store.current() == ["seed.example"])
        #expect(await store.installed() == nil)
    }

    @Test("a downloaded list is verified, installed and then used instead of the seed")
    func installs() async throws {
        let (store, _) = makeStore()
        let session = CountingSession(body: Data(text.utf8))
        let changed = try await DNSNeverBlockUpdater(store: store, session: session).update(to: entry())
        #expect(changed)
        #expect(await store.current() == ["npci.org.in", "online-metrix.net", "razorpay.com"])
        #expect(await store.installed()?.version == "2026-11-07")
    }

    @Test("the same version and checksum is not downloaded again")
    func upToDate() async throws {
        let (store, _) = makeStore()
        let session = CountingSession(body: Data(text.utf8))
        let updater = DNSNeverBlockUpdater(store: store, session: session)
        _ = try await updater.update(to: entry())
        let again = try await updater.update(to: entry())
        #expect(!again)
        #expect(session.requests.withLock { $0.count } == 1)
    }

    @Test("a new version replaces the installed one")
    func newVersion() async throws {
        let (store, _) = makeStore()
        let updater = DNSNeverBlockUpdater(store: store, session: CountingSession(body: Data(text.utf8)))
        _ = try await updater.update(to: entry())
        let v2 = "razorpay.com\nstripe.com\n"
        let updater2 = DNSNeverBlockUpdater(store: store, session: CountingSession(body: Data(v2.utf8)))
        #expect(try await updater2.update(to: entry(v2, version: "2026-11-08", count: 2)))
        #expect(await store.current() == ["razorpay.com", "stripe.com"])
    }

    @Test("a checksum mismatch installs nothing and keeps the current list")
    func checksumMismatch() async throws {
        let (store, _) = makeStore()
        var bad = entry()
        bad.checksumSHA256 = String(repeating: "0", count: 64)
        let updater = DNSNeverBlockUpdater(store: store, session: CountingSession(body: Data(text.utf8)))
        await #expect(throws: DNSNeverBlockError.checksumMismatch) { try await updater.update(to: bad) }
        #expect(await store.current() == ["seed.example"])
        #expect(await store.installed() == nil)
    }

    @Test("a domain count that disagrees with the manifest is rejected")
    func countMismatch() async throws {
        let (store, _) = makeStore()
        let updater = DNSNeverBlockUpdater(store: store, session: CountingSession(body: Data(text.utf8)))
        await #expect(throws: DNSNeverBlockError.countMismatch) { try await updater.update(to: entry(count: 99)) }
        #expect(await store.installed() == nil)
    }

    @Test("a list with no usable domains is rejected, never installed as empty")
    func emptyList() async throws {
        let (store, _) = makeStore()
        let body = "# nothing here\n*.example.com\n"
        let updater = DNSNeverBlockUpdater(store: store, session: CountingSession(body: Data(body.utf8)))
        await #expect(throws: DNSNeverBlockError.emptyList) { try await updater.update(to: entry(body, count: 0)) }
        #expect(await store.current() == ["seed.example"])
    }

    @Test("a non-200 response installs nothing")
    func badStatus() async throws {
        let (store, _) = makeStore()
        let updater = DNSNeverBlockUpdater(store: store, session: CountingSession(body: Data(), status: 503))
        await #expect(throws: DNSNeverBlockError.badStatus(503)) { try await updater.update(to: entry()) }
        #expect(await store.installed() == nil)
    }

    @Test("a corrupt stored file falls back to the seed")
    func corruptStore() async throws {
        let (store, filterStore) = makeStore()
        try await filterStore.writeMetadata(Data("not json".utf8), filename: "dns-never-block.json")
        #expect(await store.current() == ["seed.example"])
    }
}

@Suite("Manifest carries the never-block entry")
struct DNSNeverBlockManifestTests {
    @Test("a manifest without the field still decodes, with no never-block entry")
    func oldManifest() throws {
        let json = #"{"manifestVersion":"2026-11-05","entries":[]}"#
        let m = try JSONDecoder().decode(FilterManifest.self, from: Data(json.utf8))
        #expect(m.dnsNeverBlock == nil)
    }

    @Test("a manifest with the field decodes it")
    func newManifest() throws {
        let json = """
        {"manifestVersion":"2026-11-07","entries":[],
         "dnsNeverBlock":{"version":"2026-11-07","sourceURL":"https://example.invalid/never-block.txt",
                          "checksumSHA256":"abc","domainCount":3}}
        """
        let m = try JSONDecoder().decode(FilterManifest.self, from: Data(json.utf8))
        #expect(m.dnsNeverBlock?.version == "2026-11-07")
        #expect(m.dnsNeverBlock?.domainCount == 3)
    }

    @Test("a manifest with no entry encodes without the key, so older builds and the golden file are unchanged")
    func omitsKeyWhenNil() throws {
        let data = try JSONEncoder().encode(FilterManifest(manifestVersion: "x", entries: []))
        #expect(!String(decoding: data, as: UTF8.self).contains("dnsNeverBlock"))
    }
}
