#if DEBUG
import Foundation

/// What the DEBUG Developer screen may ask the packet tunnel, and what it may get back. Counts
/// and flags only (docs/Architecture/Logging.md): no field here can hold a domain, a URL or
/// any text. Compiled out of Release, so a shipped build has neither the type nor a way to ask.
public struct DNSTunnelCountersSnapshot: Codable, Equatable, Sendable {
    public var ingressPackets: UInt64 = 0
    public var blockedQueries: UInt64 = 0
    public var forwardedQueries: UInt64 = 0
    public var responsesWritten: UInt64 = 0
    public var upstreamTimeouts: UInt64 = 0
    public var upstreamSendErrors: UInt64 = 0
    public var servfailsSent: UInt64 = 0
    public var truncatedUpstreamAnswers: UInt64 = 0
    public var tcpSegments: UInt64 = 0
    public var tcpQueries: UInt64 = 0
    public var unparsablePackets: UInt64 = 0
    /// Every query is forwarded and nothing is blocked (an empty blocklist).
    public var passthrough: Bool = false

    public init() {}
}

public enum DNSTunnelDiagnosticsMessage: Codable, Equatable, Sendable {
    case readCounters
    case resetCounters
    case setPassthrough(Bool)
}
#endif
