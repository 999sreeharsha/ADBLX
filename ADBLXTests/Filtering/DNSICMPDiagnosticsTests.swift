#if DEBUG
import Testing
import Foundation
import ADBLXShared
@testable import ADBLX

/// What the ICMP packets sent to the tunnel's DNS address are (device results 2026-11-08: 831
/// small IPv4 ICMP packets on 4G, against 801 duplicate client queries). Echo requests and
/// "port unreachable" errors need different handling, so they are counted apart. Counts only.
@Suite("ICMP to the DNS address")
struct DNSICMPDiagnosticsTests {
    private let dnsAddress: UInt32 = 0xC633_6401

    /// An IPv4 ICMP packet to the DNS address with the given type and code.
    private func icmp(type: UInt8, code: UInt8 = 0, length: Int = 56) -> Data {
        var p = Data(count: length)
        p[0] = 0x45; p[2] = UInt8(length >> 8); p[3] = UInt8(length & 0xFF); p[8] = 64; p[9] = 1
        p.replaceSubrange(12..<16, with: [192, 0, 2, 2]); p.replaceSubrange(16..<20, with: [198, 51, 100, 1])
        if length >= 22 { p[20] = type; p[21] = code }
        return p
    }

    @Test("an echo request, a destination-unreachable and anything else are told apart")
    func kinds() {
        #expect(UnparsablePacketClassifier.traits(of: icmp(type: 8), dnsAddress: dnsAddress).icmpKind == .echoRequest)
        #expect(UnparsablePacketClassifier.traits(of: icmp(type: 3, code: 3), dnsAddress: dnsAddress).icmpKind == .unreachable)
        #expect(UnparsablePacketClassifier.traits(of: icmp(type: 11), dnsAddress: dnsAddress).icmpKind == .other)
    }

    @Test("ICMPv6 echo requests and unreachables are told apart too")
    func icmpv6() {
        func v6(type: UInt8) -> Data {
            var p = Data(count: 48)
            p[0] = 0x60; p[5] = 8; p[6] = 58; p[7] = 64; p[40] = type
            return p
        }
        #expect(UnparsablePacketClassifier.traits(of: v6(type: 128), dnsAddress: dnsAddress).icmpKind == .echoRequest)
        #expect(UnparsablePacketClassifier.traits(of: v6(type: 1), dnsAddress: dnsAddress).icmpKind == .unreachable)
    }

    @Test("a packet that isn't ICMP has no ICMP kind, and a truncated ICMP header is 'other'")
    func notICMP() {
        var udp = icmp(type: 8); udp[9] = 17
        #expect(UnparsablePacketClassifier.traits(of: udp, dnsAddress: dnsAddress).icmpKind == nil)
        #expect(UnparsablePacketClassifier.traits(of: icmp(type: 8, length: 20), dnsAddress: dnsAddress).icmpKind == .other)
    }

    @Test("each kind has its own counter")
    func counted() {
        let counters = DNSTunnelCounters()
        for type: UInt8 in [8, 3, 3, 11] {
            UnparsablePacketClassifier.record(UnparsablePacketClassifier.traits(of: icmp(type: type), dnsAddress: dnsAddress), in: counters)
        }
        let s = counters.snapshot
        #expect(s.unparsableICMPEchoRequest == 1)
        #expect(s.unparsableICMPUnreachable == 2)
        #expect(s.unparsableICMPOther == 1)
        #expect(s.unparsableICMP == 4)
    }
}

/// An answer dropped because it came from an address that isn't a configured upstream is counted,
/// so "lost" can be told from "rejected".
@Suite("DNS answers from an unexpected sender", .timeLimit(.minutes(1)))
struct DNSUnexpectedSenderTests {
    @Test("a reply from an address that isn't an upstream is counted and not delivered")
    func counted() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink()
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: "2620:fe::fe", timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8),
            socketFactory: { _, _, _ in ScriptedUpstreamSocket() }, clock: ManualDNSClock(), tcpTransport: nil, counters: counters
        )
        try await fwd.start { p, _ in sink.append(p) }
        let dns = TestDNS.query("who.example")
        let packet = TestDNS.udpPacket(dns: dns)
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        guard case .forwarded(let id) = await fwd.forward(query: query, originalPacket: packet) else { return }
        var reply = TestDNS.response(to: dns)
        reply[0] = UInt8(id >> 8); reply[1] = UInt8(id & 0xFF)
        await fwd.handleUpstreamResponse(data: reply, senderIP: "2001:db8::1", senderPort: 53, isIPv6: true)
        await fwd.handleUpstreamResponse(data: reply, senderIP: "9.9.9.9", senderPort: 5353, isIPv6: false)
        #expect(counters.snapshot.answersFromUnexpectedSender == 2)
        #expect(sink.count == 0)
    }
}
#endif
