import Foundation

public struct UpstreamResolverConfig: Equatable {
    public let ipv4Address: String
    public let ipv6Address: String?
    public let port: UInt16
    public let timeoutSeconds: TimeInterval
    public let maxInFlightQueries: Int
    
    public init(
        ipv4Address: String = "9.9.9.9",
        ipv6Address: String? = "2620:fe::fe",
        port: UInt16 = 53,
        timeoutSeconds: TimeInterval = 3.0,
        maxInFlightQueries: Int = 256
    ) {
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.port = port
        self.timeoutSeconds = timeoutSeconds
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
}

public enum DNSForwarderResult: Equatable {
    case forwarded(upstreamTxID: UInt16)
    case capacityExceeded
    case socketUnavailable(String)
}
