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
    /// Queries tried a second time on another upstream after a timeout or send failure.
    public var upstreamRetries: UInt64 = 0
    public var servfailsSent: UInt64 = 0
    public var truncatedUpstreamAnswers: UInt64 = 0
    public var tcpSegments: UInt64 = 0
    public var tcpQueries: UInt64 = 0
    public var unparsablePackets: UInt64 = 0
    /// Times the upstream sockets were replaced after a network change.
    public var socketResets: UInt64 = 0
    /// Every query is forwarded and nothing is blocked (an empty blocklist).
    public var passthrough: Bool = false

    // Which upstream answered in time, and which answered after we had given up on it.
    public var answersFromPrimaryIPv4: UInt64 = 0
    public var answersFromIPv6: UInt64 = 0
    public var answersFromFallbackIPv4: UInt64 = 0
    public var lateAnswersFromPrimaryIPv4: UInt64 = 0
    public var lateAnswersFromIPv6: UInt64 = 0
    public var lateAnswersFromFallbackIPv4: UInt64 = 0
    /// A client query arriving again (same port and id) while its first copy still waits upstream.
    public var duplicateClientQueries: UInt64 = 0
    /// Truncated upstream answers followed over TCP to the upstream.
    public var upstreamTCPSucceeded: UInt64 = 0
    public var upstreamTCPFailed: UInt64 = 0
    /// Answers cut to the client's UDP limit and sent with TC, so the client retries over TCP.
    public var truncatedToClient: UInt64 = 0
    // UDP queries by type.
    public var queriesA: UInt64 = 0
    public var queriesAAAA: UInt64 = 0
    public var queriesHTTPS: UInt64 = 0
    public var queriesOther: UInt64 = 0
    // Unparsable packets by IP version, transport, destination and size.
    public var unparsableIPv4: UInt64 = 0
    public var unparsableIPv6: UInt64 = 0
    public var unparsableTCP: UInt64 = 0
    public var unparsableUDP: UInt64 = 0
    public var unparsableICMP: UInt64 = 0
    public var unparsableOtherProtocol: UInt64 = 0
    public var unparsableToDNSAddress: UInt64 = 0
    public var unparsableSmall: UInt64 = 0
    public var unparsableMedium: UInt64 = 0
    public var unparsableLarge: UInt64 = 0
    // Network path updates, and what caused each socket reset.
    public var pathUpdates: UInt64 = 0
    public var resetsInterfaceChange: UInt64 = 0
    public var resetsReconnect: UInt64 = 0
    /// Resets where only virtual interfaces (utun, ipsec, ppp, llw, awdl) appeared or went.
    public var resetsVirtualInterfacesOnly: UInt64 = 0

    public init() {}
}

public enum DNSTunnelDiagnosticsMessage: Codable, Equatable, Sendable {
    case readCounters
    case resetCounters
    case setPassthrough(Bool)
}
#endif
