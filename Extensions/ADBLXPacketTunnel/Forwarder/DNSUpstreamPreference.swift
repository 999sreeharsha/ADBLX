import Foundation

/// One of the configured upstream resolvers.
public enum UpstreamID: Hashable, Sendable {
    case ipv6, primaryIPv4, fallbackIPv4
}

/// The upstream has no socket (it is not configured, or the sockets are being replaced).
enum DNSUpstreamSocketError: Error {
    case unavailable
}

/// Which upstreams have been answering on one network, from each one's last `window` outcomes.
/// An outcome is a success when that upstream gave the answer the client got, and a failure when
/// its send failed, it was silent until the timeout, or another upstream asked after it won.
public struct UpstreamScoreboard {
    public static let window = 20
    /// The rate of an upstream with no outcomes yet: behind one that answers, ahead of one that doesn't.
    private static let unknownRate = 0.5

    private var outcomes: [UpstreamID: [Bool]] = [:]

    public init() {}

    public mutating func record(_ upstream: UpstreamID, success: Bool) {
        var list = outcomes[upstream, default: []]
        list.append(success)
        if list.count > Self.window { list.removeFirst(list.count - Self.window) }
        outcomes[upstream] = list
    }

    /// `available`, best recent rate first. `available` is in the default order (IPv6, primary,
    /// fallback), which also settles ties.
    public func ordered(_ available: [UpstreamID]) -> [UpstreamID] {
        available.enumerated()
            .sorted { a, b in
                let ra = rate(a.element), rb = rate(b.element)
                return ra != rb ? ra > rb : a.offset < b.offset
            }
            .map(\.element)
    }

    private func rate(_ upstream: UpstreamID) -> Double {
        guard let list = outcomes[upstream], !list.isEmpty else { return Self.unknownRate }
        return Double(list.filter { $0 }.count) / Double(list.count)
    }
}
