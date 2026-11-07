import Foundation

/// The manifest's pointer to the never-block list: a plain-text file, one domain per line,
/// downloaded and checked like a filter list (SHA-256) but kept apart from them.
struct DNSNeverBlockEntry: Codable, Equatable {
    var version: String
    var sourceURL: URL
    var checksumSHA256: String
    var domainCount: Int
}

/// Domains DNS Protection always resolves (payment gateways, UPI, banks, Apple, fraud checks),
/// whatever a blocklist says. It is its own list: not the user's allowlist (the user never sees
/// or edits it) and not a filter list (it is delivered through the manifest on its own). At
/// publish time it is compiled into the allowlist artifact, which the tunnel checks before any
/// blocklist, so it needs no hot-path code of its own.
nonisolated enum DNSNeverBlockList {
    /// Plain domains from list text: comments and blank lines skipped, lowercased, de-duplicated,
    /// sorted. Anything that isn't a plain domain (IP, wildcard, path, modifier, exception) is dropped.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        text.enumerateLines { line, _ in
            if let reversed = DNSDomainNormalizer.normalizeToReversedDomain(line: line) {
                seen.insert(reversed.split(separator: ".").reversed().joined(separator: "."))
            }
        }
        return seen.sorted()
    }

    static func bundledSeedText() -> String? {
        let url = Bundle.main.url(forResource: "never-block", withExtension: "txt", subdirectory: "Filters/DNS")
            ?? Bundle.main.url(forResource: "never-block", withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The list shipped in the app, used until a newer one arrives through the manifest.
    static func bundledSeed() -> [String]? {
        bundledSeedText().map(parse)
    }
}

nonisolated struct DNSNeverBlockInstalled: Codable, Equatable {
    var version: String
    var checksumSHA256: String
    var domains: [String]
}

nonisolated enum DNSNeverBlockError: Error, Equatable {
    case badStatus(Int)
    case checksumMismatch
    case emptyList
    case countMismatch
}

/// The installed never-block list (App Group metadata), falling back to the bundled seed.
actor DNSNeverBlockStore {
    private static let filename = "dns-never-block.json"

    private let filterStore: FilterStore
    private let seed: @Sendable () -> [String]

    init(filterStore: FilterStore, seed: @escaping @Sendable () -> [String] = { DNSNeverBlockList.bundledSeed() ?? [] }) {
        self.filterStore = filterStore
        self.seed = seed
    }

    func installed() async -> DNSNeverBlockInstalled? {
        guard let data = try? await filterStore.read(Self.filename, in: .metadata) else { return nil }
        return try? JSONDecoder().decode(DNSNeverBlockInstalled.self, from: data)
    }

    /// What to publish: the installed list, or the seed when none is installed, it can't be read,
    /// or it has no domains. Never an empty list while a seed exists: an empty never-block list
    /// would leave payments to whatever the blocklists say.
    func current() async -> [String] {
        if let domains = await installed()?.domains, !domains.isEmpty { return domains }
        return seed()
    }

    func install(_ list: DNSNeverBlockInstalled) async throws {
        try await filterStore.writeMetadata(try JSONEncoder().encode(list), filename: Self.filename)
    }
}

/// Fetches the never-block list the manifest points at. Nothing is installed unless it
/// downloads whole, matches the manifest's checksum and count, and has at least one domain.
actor DNSNeverBlockUpdater {
    private let store: DNSNeverBlockStore
    private let session: HTTPSession

    init(store: DNSNeverBlockStore, session: HTTPSession) {
        self.store = store
        self.session = session
    }

    /// True if a new list was installed; false if the installed one already matches `entry`.
    @discardableResult
    func update(to entry: DNSNeverBlockEntry) async throws -> Bool {
        if let installed = await store.installed(),
           installed.version == entry.version, installed.checksumSHA256 == entry.checksumSHA256 {
            return false
        }
        let (data, response) = try await session.data(for: URLRequest(url: entry.sourceURL))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DNSNeverBlockError.badStatus(status) }
        guard Checksum.sha256Hex(of: data) == entry.checksumSHA256 else { throw DNSNeverBlockError.checksumMismatch }
        let domains = DNSNeverBlockList.parse(String(decoding: data, as: UTF8.self))
        guard !domains.isEmpty else { throw DNSNeverBlockError.emptyList }
        guard domains.count == entry.domainCount else { throw DNSNeverBlockError.countMismatch }
        try await store.install(DNSNeverBlockInstalled(version: entry.version, checksumSHA256: entry.checksumSHA256, domains: domains))
        return true
    }
}
