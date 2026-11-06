import Foundation

/// Answers one bare DNS message the way the UDP path does: blocked names get NXDOMAIN, the rest
/// go upstream, and an upstream that fails gets a SERVFAIL. Used for TCP clients.
public struct DNSPayloadResolver: @unchecked Sendable {
    private let engine: DNSLookupEngine
    private let forwarder: DNSUpstreamForwarder

    public init(engine: DNSLookupEngine, forwarder: DNSUpstreamForwarder) {
        self.engine = engine
        self.forwarder = forwarder
    }

    /// Nil only when `query` isn't a readable DNS question (the caller should close the connection).
    public func resolve(_ query: Data) async -> Data? {
        guard let reversed = DNSMessage.reversedDomain(of: query) else { return nil }
        switch reversed.withUnsafeBufferPointer({ engine.lookup(reversedBytes: $0) }) {
        case .block:
            return DNSMessage.errorResponse(for: query, rcode: 3)
        case .allow:
            if let answer = await forwarder.exchange(dnsPayload: query) { return answer }
            return DNSMessage.errorResponse(for: query, rcode: 2)
        }
    }
}
