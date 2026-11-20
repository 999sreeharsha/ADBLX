import Foundation

public struct UpstreamResolverConfig: Equatable {
    public let ipv4Address: String
    public let ipv6Address: String?
    /// A second IPv4 upstream, tried once when the first times out or fails to send.
    public let fallbackIPv4Address: String?
    public let port: UInt16
    /// How long a query may wait for any answer, from when it arrived.
    public let timeoutSeconds: TimeInterval
    /// How long the preferred upstream gets before the next one is asked as well. Nil: never.
    public let hedgeDelaySeconds: TimeInterval?
    public let maxInFlightQueries: Int

    public init(
        ipv4Address: String = "9.9.9.9",
        ipv6Address: String? = "2620:fe::fe",
        fallbackIPv4Address: String? = nil,
        port: UInt16 = 53,
        timeoutSeconds: TimeInterval = 3.0,
        hedgeDelaySeconds: TimeInterval? = 0.4,
        maxInFlightQueries: Int = 256
    ) {
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.fallbackIPv4Address = fallbackIPv4Address
        self.port = port
        self.timeoutSeconds = timeoutSeconds
        self.hedgeDelaySeconds = hedgeDelaySeconds
        self.maxInFlightQueries = maxInFlightQueries
    }
}

public struct PendingQuery {
    public let upstreamTxID: UInt16
    public let clientTxID: UInt16
    public let ipVersion: IPVersion
    
    public let clientSrcIPv4: UInt32
    public let clientDstIPv4: UInt32
    
    public let clientSrcIPv6: (UInt64, UInt64)
    public let clientDstIPv6: (UInt64, UInt64)
    
    public let clientSrcPort: UInt16
    public let clientDstPort: UInt16
    
    public let requestTimestamp: TimeInterval
    public var timeoutTask: Task<Void, Never>?

    /// The query as the client sent it (DNS payload only), to build a SERVFAIL or retry over TCP.
    public let clientQuery: Data
    /// Set when the caller is waiting for the answer (`exchange`) rather than a client packet.
    public var exchangeContinuation: CheckedContinuation<Data?, Never>?
    /// Upstreams not asked yet, best first.
    var remaining: [UpstreamID] = []
    /// Upstreams asked and still waited on, in the order they were asked.
    var asked: [UpstreamID] = []
    /// How many upstreams have been asked, counting failed sends.
    var timesAsked = 0
    /// The network the query started on, whose scoreboard its outcomes go to.
    var network = ""
}

public enum DNSForwarderResult: Equatable {
    case forwarded(upstreamTxID: UInt16)
    case capacityExceeded
    case socketUnavailable(String)
}
