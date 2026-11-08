#if DEBUG
import Testing
import Foundation
import os
import ADBLXShared
@testable import ADBLX

/// DEBUG counters for the mobile-data investigation (2026-11-08): which upstream answered, which
/// answered too late, what the unparsable packets are, and why sockets were reset. Counts only.
@Suite("DNS upstream diagnostics")
struct DNSUpstreamDiagnosticsTests {
    private static let fallbackIP = "149.112.112.112"

    private func make(
        primary: ScriptedUpstreamSocket, v6: ScriptedUpstreamSocket, fallback: ScriptedUpstreamSocket,
        clock: ManualDNSClock, counters: DNSTunnelCounters, tcp: ScriptedTCPTransport? = nil
    ) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(
                ipv4Address: "9.9.9.9", ipv6Address: "2620:fe::fe", fallbackIPv4Address: Self.fallbackIP,
                timeoutSeconds: 2, maxInFlightQueries: 8
            ),
            socketFactory: { host, _, isIPv6 in isIPv6 ? v6 : (host == Self.fallbackIP ? fallback : primary) },
            clock: clock, tcpTransport: tcp, counters: counters
        )
    }

    private func parsed(_ dns: Data, srcPort: UInt16 = 54321) -> (Data, ParsedDNSQuery) {
        let packet = TestDNS.udpPacket(dns: dns, srcPort: srcPort)
        return (packet, packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!)
    }

    private func answering(_ ip: String) -> ScriptedUpstreamSocket {
        ScriptedUpstreamSocket(senderIP: ip) { TestDNS.response(to: $0, answerBytes: 4) }
    }

    // MARK: - Which upstream answered

    @Test("an answer from the first upstream is counted as primary")
    func primaryAnswer() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink()
        let fwd = make(primary: answering("9.9.9.9"), v6: ScriptedUpstreamSocket(senderIP: "2620:fe::fe"),
                       fallback: ScriptedUpstreamSocket(senderIP: Self.fallbackIP), clock: ManualDNSClock(), counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("a.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(counters.snapshot.answersFromPrimaryIPv4 == 1)
        #expect(counters.snapshot.answersFromIPv6 == 0 && counters.snapshot.answersFromFallbackIPv4 == 0)
    }

    @Test("a retry answered over IPv6 is counted as IPv6, and the primary as late if it answers afterwards")
    func ipv6AnswerAndLatePrimary() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink(), clock = ManualDNSClock()
        let primary = ScriptedUpstreamSocket()
        let fwd = make(primary: primary, v6: answering("2620:fe::fe"),
                       fallback: ScriptedUpstreamSocket(senderIP: Self.fallbackIP), clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let dns = TestDNS.query("slow.example")
        let (packet, query) = parsed(dns)
        guard case .forwarded(let firstID) = await fwd.forward(query: query, originalPacket: packet) else { return }
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        await sink.waitForCount(1)
        #expect(counters.snapshot.answersFromIPv6 == 1)

        var late = TestDNS.response(to: dns)
        late[0] = UInt8(firstID >> 8); late[1] = UInt8(firstID & 0xFF)
        await fwd.handleUpstreamResponse(data: late, senderIP: "9.9.9.9", senderPort: 53, isIPv6: false)
        #expect(counters.snapshot.lateAnswersFromPrimaryIPv4 == 1)
        #expect(counters.snapshot.answersFromPrimaryIPv4 == 0)
        #expect(sink.count == 1)
    }

    @Test("an answer from the second IPv4 upstream is counted as fallback")
    func fallbackAnswer() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink()
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, fallbackIPv4Address: Self.fallbackIP,
                                           timeoutSeconds: 2, maxInFlightQueries: 8),
            socketFactory: { host, _, _ in host == Self.fallbackIP ? self.answering(Self.fallbackIP) : ScriptedUpstreamSocket(failure: SendFailure()) },
            clock: ManualDNSClock(), tcpTransport: nil, counters: counters
        )
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("b.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(counters.snapshot.answersFromFallbackIPv4 == 1)
    }

    @Test("the same client query arriving while the first copy is still waiting is counted as a duplicate")
    func duplicateClientQuery() async throws {
        let counters = DNSTunnelCounters()
        let fwd = make(primary: ScriptedUpstreamSocket(), v6: ScriptedUpstreamSocket(senderIP: "2620:fe::fe"),
                       fallback: ScriptedUpstreamSocket(senderIP: Self.fallbackIP), clock: ManualDNSClock(), counters: counters)
        try await fwd.start { _, _ in }
        let (packet, query) = parsed(TestDNS.query("again.example", txID: 0x4444))
        _ = await fwd.forward(query: query, originalPacket: packet)
        #expect(counters.snapshot.duplicateClientQueries == 0)
        _ = await fwd.forward(query: query, originalPacket: packet)
        #expect(counters.snapshot.duplicateClientQueries == 1)
        let (other, otherQuery) = parsed(TestDNS.query("again.example", txID: 0x4444), srcPort: 50000)
        _ = await fwd.forward(query: otherQuery, originalPacket: other)
        #expect(counters.snapshot.duplicateClientQueries == 1)   // another client port is another query
    }

    // MARK: - Truncated answers

    @Test("a truncated answer followed over TCP is counted as a TCP success, or a failure")
    func upstreamTCP() async throws {
        for ok in [true, false] {
            let counters = DNSTunnelCounters(), sink = PacketSink()
            let dns = TestDNS.query("big.example", udpSize: 1232)
            let tcp = ScriptedTCPTransport(ok ? .success(TestDNS.response(to: dns, answerBytes: 100)) : .failure(SendFailure()))
            let truncating = ScriptedUpstreamSocket { TestDNS.response(to: $0, truncated: true) }
            let fwd = make(primary: truncating, v6: ScriptedUpstreamSocket(senderIP: "2620:fe::fe"),
                           fallback: ScriptedUpstreamSocket(senderIP: Self.fallbackIP), clock: ManualDNSClock(), counters: counters, tcp: tcp)
            try await fwd.start { p, _ in sink.append(p) }
            let (packet, query) = parsed(dns)
            _ = await fwd.forward(query: query, originalPacket: packet)
            await sink.waitForCount(1)
            #expect(counters.snapshot.upstreamTCPSucceeded == (ok ? 1 : 0))
            #expect(counters.snapshot.upstreamTCPFailed == (ok ? 0 : 1))
            #expect(counters.snapshot.truncatedToClient == 0)
        }
    }

    @Test("an answer too big for the client's UDP limit is counted when it is cut and sent with TC")
    func truncatedToClient() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink()
        let dns = TestDNS.query("huge.example")   // no EDNS: 512 bytes
        let tcp = ScriptedTCPTransport(.success(TestDNS.response(to: dns, answerBytes: 900)))
        let truncating = ScriptedUpstreamSocket { TestDNS.response(to: $0, truncated: true) }
        let fwd = make(primary: truncating, v6: ScriptedUpstreamSocket(senderIP: "2620:fe::fe"),
                       fallback: ScriptedUpstreamSocket(senderIP: Self.fallbackIP), clock: ManualDNSClock(), counters: counters, tcp: tcp)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(counters.snapshot.truncatedToClient == 1)
    }

    // MARK: - Query types

    @Test("queries are bucketed by type: A, AAAA, HTTPS, other")
    func queryTypes() {
        #expect(DNSQueryTypeBucket.counter(for: 1) == \DNSTunnelCountersSnapshot.queriesA)
        #expect(DNSQueryTypeBucket.counter(for: 28) == \DNSTunnelCountersSnapshot.queriesAAAA)
        #expect(DNSQueryTypeBucket.counter(for: 65) == \DNSTunnelCountersSnapshot.queriesHTTPS)
        #expect(DNSQueryTypeBucket.counter(for: 16) == \DNSTunnelCountersSnapshot.queriesOther)
    }
}

@Suite("Unparsable packet breakdown")
struct UnparsablePacketTraitsTests {
    private let dnsAddress: UInt32 = 0xC633_6401

    private func ipv4(proto: UInt8, dst: [UInt8], length: Int = 40) -> Data {
        var p = Data(count: length)
        p[0] = 0x45; p[2] = UInt8(length >> 8); p[3] = UInt8(length & 0xFF); p[8] = 64; p[9] = proto
        p.replaceSubrange(12..<16, with: [192, 0, 2, 2]); p.replaceSubrange(16..<20, with: dst)
        return p
    }

    private func ipv6(nextHeader: UInt8, length: Int = 80) -> Data {
        var p = Data(count: length)
        p[0] = 0x60; p[4] = UInt8((length - 40) >> 8); p[5] = UInt8((length - 40) & 0xFF); p[6] = nextHeader; p[7] = 64
        return p
    }

    @Test("IPv4 UDP to the DNS address that the parser refused")
    func udpToDNS() {
        let t = UnparsablePacketClassifier.traits(of: ipv4(proto: 17, dst: [198, 51, 100, 1]), dnsAddress: dnsAddress)
        #expect(t == UnparsablePacketTraits(ipVersion: .v4, transport: .udp, toDNSAddress: true, size: .small))
    }

    @Test("IPv4 TCP to some other address")
    func tcpElsewhere() {
        let t = UnparsablePacketClassifier.traits(of: ipv4(proto: 6, dst: [142, 250, 1, 1], length: 600), dnsAddress: dnsAddress)
        #expect(t == UnparsablePacketTraits(ipVersion: .v4, transport: .tcp, toDNSAddress: false, size: .large))
    }

    @Test("IPv6 TCP, UDP and ICMPv6 are told apart; IPv6 is never the DNS address")
    func ipv6Kinds() {
        #expect(UnparsablePacketClassifier.traits(of: ipv6(nextHeader: 6), dnsAddress: dnsAddress)
                == UnparsablePacketTraits(ipVersion: .v6, transport: .tcp, toDNSAddress: false, size: .medium))
        #expect(UnparsablePacketClassifier.traits(of: ipv6(nextHeader: 17), dnsAddress: dnsAddress).transport == .udp)
        #expect(UnparsablePacketClassifier.traits(of: ipv6(nextHeader: 58), dnsAddress: dnsAddress).transport == .icmp)
        #expect(UnparsablePacketClassifier.traits(of: ipv6(nextHeader: 0), dnsAddress: dnsAddress).transport == .other)
    }

    @Test("ICMP over IPv4, and something that isn't IP at all")
    func icmpAndGarbage() {
        #expect(UnparsablePacketClassifier.traits(of: ipv4(proto: 1, dst: [198, 51, 100, 1]), dnsAddress: dnsAddress).transport == .icmp)
        let g = UnparsablePacketClassifier.traits(of: Data([0xFF, 1, 2]), dnsAddress: dnsAddress)
        #expect(g.ipVersion == nil && g.transport == .other && g.size == .small)
    }

    @Test("the counters record every trait of a packet")
    func countsTraits() {
        let counters = DNSTunnelCounters()
        UnparsablePacketClassifier.record(UnparsablePacketTraits(ipVersion: .v6, transport: .tcp, toDNSAddress: false, size: .large), in: counters)
        let s = counters.snapshot
        #expect(s.unparsableIPv6 == 1 && s.unparsableIPv4 == 0)
        #expect(s.unparsableTCP == 1 && s.unparsableToDNSAddress == 0)
        #expect(s.unparsableLarge == 1)
    }
}

@Suite("Socket reset causes")
struct PathChangeCauseTests {
    private func path(_ names: [String], satisfied: Bool = true) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: satisfied, interfaces: names)
    }

    @Test("the cause of a reset is reported, and matches shouldReset")
    func causes() {
        var filter = PathChangeFilter()
        #expect(filter.evaluate(path(["pdp_ip0"])) == .none)
        #expect(filter.evaluate(path(["pdp_ip0", "utun4"])) == .interfaceChange(virtualOnly: true))
        #expect(filter.evaluate(path(["en0", "utun4"])) == .interfaceChange(virtualOnly: false))
        #expect(filter.evaluate(path(["en0", "utun4"], satisfied: false)) == .none)
        #expect(filter.evaluate(path(["en0", "utun4"])) == .reconnect)
        #expect(filter.evaluate(path(["en0", "utun4"])) == .none)
    }

    @Test("the monitor counts every path update and each reset by cause")
    func monitorCounts() async throws {
        let counters = DNSTunnelCounters()
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 2, maxInFlightQueries: 8),
            socketFactory: { _, _, _ in ScriptedUpstreamSocket() }, clock: ManualDNSClock(), tcpTransport: nil
        )
        try await fwd.start { _, _ in }
        let monitor = DNSNetworkMonitor(observer: FakePathObserver(), forwarder: fwd, setReasserting: { _ in }, counters: counters)
        await monitor.handle(path(["pdp_ip0"]))
        await monitor.handle(path(["pdp_ip0", "ipsec2"]))
        await monitor.handle(path(["en0"]))
        await monitor.handle(path(["en0"], satisfied: false))
        await monitor.handle(path(["en0"]))
        let s = counters.snapshot
        #expect(s.pathUpdates == 5)
        #expect(s.resetsVirtualInterfacesOnly == 1)
        #expect(s.resetsInterfaceChange == 1)
        #expect(s.resetsReconnect == 1)
    }
}
#endif
