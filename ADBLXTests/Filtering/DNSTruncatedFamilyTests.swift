import Testing
import Foundation
import os
@testable import ADBLX

/// A truncated UDP answer is followed over TCP to the upstream that sent it.
@Suite("DNS truncated follow-up family", .timeLimit(.minutes(1)))
struct DNSTruncatedFamilyTests {
    @Test("a truncated answer from the IPv6 upstream is fetched over TCP from the IPv6 address")
    func ipv6() async throws {
        let dns = TestDNS.query("big.example", udpSize: 1232)
        let tcp = RecordingTCPTransport(TestDNS.response(to: dns, answerBytes: 100))
        let v6 = ScriptedUpstreamSocket(senderIP: "2620:fe::fe") { TestDNS.response(to: $0, truncated: true) }
        let sink = PacketSink()
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: "2620:fe::fe", timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8),
            socketFactory: { _, _, isIPv6 in isIPv6 ? v6 : ScriptedUpstreamSocket() },
            clock: ManualDNSClock(), tcpTransport: tcp
        )
        try await fwd.start { p, _ in sink.append(p) }
        let packet = TestDNS.udpPacket(dns: dns)
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(tcp.hosts.withLock { $0 } == ["2620:fe::fe"])
    }

    @Test("a truncated answer from the IPv4 fallback is fetched over TCP from the fallback")
    func fallback() async throws {
        let dns = TestDNS.query("big.example", udpSize: 1232)
        let tcp = RecordingTCPTransport(TestDNS.response(to: dns, answerBytes: 100))
        let fb = ScriptedUpstreamSocket(senderIP: "149.112.112.112") { TestDNS.response(to: $0, truncated: true) }
        let sink = PacketSink()
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, fallbackIPv4Address: "149.112.112.112",
                                           timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8),
            socketFactory: { host, _, _ in host == "149.112.112.112" ? fb : ScriptedUpstreamSocket(failure: SendFailure()) },
            clock: ManualDNSClock(), tcpTransport: tcp
        )
        try await fwd.start { p, _ in sink.append(p) }
        let packet = TestDNS.udpPacket(dns: dns)
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(tcp.hosts.withLock { $0 } == ["149.112.112.112"])
    }
}

/// TCP transport double that records which host each exchange went to.
nonisolated final class RecordingTCPTransport: @unchecked Sendable {
    let hosts = OSAllocatedUnfairLock(initialState: [String]())
    private let answer: Data
    init(_ answer: Data) { self.answer = answer }
    func exchange(query: Data, host: String, port: UInt16) async throws -> Data {
        hosts.withLock { $0.append(host) }
        return answer
    }
}
extension RecordingTCPTransport: DNSUpstreamTCPTransport {}
