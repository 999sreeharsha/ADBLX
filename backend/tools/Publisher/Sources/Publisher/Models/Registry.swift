import Foundation

struct RegistryEntry: Codable, Equatable {
    let id: String
    let name: String
    let upstreamProject: String
    let upstreamDownloadURL: String
    let license: String
    let group: String
    let enabledByDefault: Bool
    let premium: Bool
    let notes: String?
}

struct Registry: Codable, Equatable {
    let registryVersion: Int
    let filters: [RegistryEntry]
}
