import Foundation

public enum UpstreamResolverOption: String, CaseIterable, Codable, Sendable {
    case quad9Default
    case custom
    
    public var title: String {
        switch self {
        case .quad9Default:
            return "Quad9 (Default)"
        case .custom:
            return "Custom Resolver"
        }
    }
    
    public var description: String {
        switch self {
        case .quad9Default:
            return "9.9.9.9 & 2620:fe::fe — Encrypted upstream with threat blocking and zero IP logging."
        case .custom:
            return "Specify your own upstream DNS resolver IPv4 / IPv6 address."
        }
    }
}
