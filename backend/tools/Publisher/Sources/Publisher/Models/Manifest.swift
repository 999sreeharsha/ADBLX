struct ManifestEntry: Codable, Equatable {
    let id: String
    let name: String
    let group: String
    let sourceURL: String
    let version: String
    let checksumSHA256: String
    let ruleCount: Int
    let enabledByDefault: Bool
    let premium: Bool
}

struct Manifest: Codable, Equatable {
    let manifestVersion: String
    let entries: [ManifestEntry]
}
