import Testing
import Foundation
import os
@testable import ADBLX

/// A client must always get an answer: a SERVFAIL when the upstream is silent or unreachable,
/// the full answer when the upstream truncated its own. No test here waits on the wall clock.
@Suite("DNS forwarder fails fast")
struct DNSForwarderFailFastTests {
    private func parsed(_ dns: Data, srcPort: UInt16 = 54321) -> (packet: Data, query: ParsedDNSQuery) {
        let packet = TestDNS.udpPacket(dns: dns, srcPort: srcPort)
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        return (packet, query)
    }

    private func makeForwarder(
        socket: ScriptedUpstreamSocket, clock: ManualDNSClock = ManualDNSClock(),
        tcp: ScriptedTCPTransport? = nil, timeout: TimeInterval = 2
    ) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: timeout, maxInFlightQueries: 8),
            socketFactory: { _, _, _ in socket },
            clock: clock,
            tcpTransport: tcp
        )
    }

    // MARK: - SERVFAIL, never silence

    @Test("an upstream that never answers produces a SERVFAIL when the timeout passes")
    func timeoutServfail() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        let fwd = makeForwarder(socket: ScriptedUpstreamSocket(), clock: clock)
        try await fwd.start { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(TestDNS.query("slow.example", txID: 0xAAAA))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)

        clock.advance(by: 1.99)
        #expect(sink.count == 0)
        clock.advance(by: 0.01)
        await sink.waitForCount(1)

        let reply = sink.packets[0]
        let dns = TestDNS.dnsPayload(ofUDPPacket: reply)
        #expect(TestDNS.txID(dns) == 0xAAAA)
        #expect(TestDNS.rcode(dns) == 2)
        #expect(dns[2] & 0x80 != 0)
        // Addressed back to the client's port, from the address it asked.
        #expect(reply[22] == UInt8(54321 >> 8) && reply[23] == UInt8(54321 & 0xFF))
        #expect(Array(reply[12..<16]) == [198, 51, 100, 1])
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("a late upstream answer after the SERVFAIL is ignored, not delivered twice")
    func lateAnswerIgnored() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        let socket = ScriptedUpstreamSocket()
        let fwd = makeForwarder(socket: socket, clock: clock)
        try await fwd.start { packet, _ in sink.append(packet) }
        let dns = TestDNS.query("late.example")
        let (packet, query) = parsed(dns)
        guard case .forwarded(let upstreamID) = await fwd.forward(query: query, originalPacket: packet) else {
            Issue.record("not forwarded"); return
        }
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        await sink.waitForCount(1)
        var late = TestDNS.response(to: dns)
        late[0] = UInt8(upstreamID >> 8); late[1] = UInt8(upstreamID & 0xFF)
        await fwd.handleUpstreamResponse(data: late, senderIP: "9.9.9.9", senderPort: 53, isIPv6: false)
        #expect(sink.count == 1)
    }

    @Test("a failed send produces a SERVFAIL straight away")
    func sendFailureServfail() async throws {
        let sink = PacketSink()
        let fwd = makeForwarder(socket: ScriptedUpstreamSocket(failure: SendFailure()))
        try await fwd.start { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(TestDNS.query("down.example", txID: 0x0102))
        let result = await fwd.forward(query: query, originalPacket: packet)
        guard case .socketUnavailable = result else { Issue.record("expected socketUnavailable, got \(result)"); return }
        #expect(sink.count == 1)
        let dns = TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])
        #expect(TestDNS.txID(dns) == 0x0102 && TestDNS.rcode(dns) == 2)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("a query before the forwarder has started still gets a SERVFAIL when it has somewhere to write")
    func noSocketServfail() async throws {
        let sink = PacketSink()
        let fwd = makeForwarder(socket: ScriptedUpstreamSocket())
        await fwd.setPacketWriter { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(TestDNS.query("early.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        #expect(sink.count == 1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
    }

    // MARK: - Truncated upstream answers

    @Test("a truncated UDP answer is retried over TCP and the client gets the full answer")
    func truncatedRetriedOverTCP() async throws {
        let sink = PacketSink()
        let dns = TestDNS.query("big.example", txID: 0x4242, udpSize: 1232)
        let full = TestDNS.response(to: dns, answerBytes: 600)
        let tcp = ScriptedTCPTransport(.success(full))
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, truncated: true) }
        let fwd = makeForwarder(socket: socket, tcp: tcp)
        try await fwd.start { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)

        let reply = TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])
        #expect(TestDNS.txID(reply) == 0x4242)
        #expect(!TestDNS.isTruncated(reply))
        #expect(TestDNS.answerCount(reply) == 1)
        #expect(reply.count == full.count)
        #expect(tcp.queries.withLock { $0.count } == 1)
    }

    @Test("a full answer bigger than the client's UDP limit is truncated, so the client comes back over TCP")
    func tooBigForUDP() async throws {
        let sink = PacketSink()
        let dns = TestDNS.query("big.example")   // no EDNS: 512 bytes
        let tcp = ScriptedTCPTransport(.success(TestDNS.response(to: dns, answerBytes: 900)))
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, truncated: true) }
        let fwd = makeForwarder(socket: socket, tcp: tcp)
        try await fwd.start { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        let reply = TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])
        #expect(TestDNS.isTruncated(reply))
        #expect(TestDNS.answerCount(reply) == 0)
        #expect(reply.count <= 512)
    }

    @Test("a truncated answer with no working TCP upstream becomes a SERVFAIL, not silence")
    func truncatedTCPFails() async throws {
        let sink = PacketSink()
        let dns = TestDNS.query("big.example")
        let tcp = ScriptedTCPTransport(.failure(SendFailure()))
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, truncated: true) }
        let fwd = makeForwarder(socket: socket, tcp: tcp)
        try await fwd.start { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
    }

    @Test("a truncated answer with no TCP transport at all becomes a SERVFAIL")
    func truncatedNoTransport() async throws {
        let sink = PacketSink()
        let dns = TestDNS.query("big.example")
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, truncated: true) }
        let fwd = makeForwarder(socket: socket, tcp: nil)
        try await fwd.start { packet, _ in sink.append(packet) }
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
    }

    // MARK: - exchange(): the path TCP clients take

    @Test("exchange returns the upstream answer to a bare DNS message")
    func exchangeAnswer() async throws {
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, answerBytes: 10) }
        let fwd = makeForwarder(socket: socket)
        try await fwd.start { _, _ in }
        let q = TestDNS.query("a.example", txID: 0x7777)
        let r = try #require(await fwd.exchange(dnsPayload: q))
        #expect(TestDNS.txID(r) == 0x7777)         // the client's id, not the upstream's
        #expect(TestDNS.answerCount(r) == 1)
    }

    @Test("exchange follows a truncated answer to TCP")
    func exchangeTruncated() async throws {
        let q = TestDNS.query("a.example", txID: 0x1010)
        let full = TestDNS.response(to: q, answerBytes: 2000)
        let tcp = ScriptedTCPTransport(.success(full))
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, truncated: true) }
        let fwd = makeForwarder(socket: socket, tcp: tcp)
        try await fwd.start { _, _ in }
        let r = try #require(await fwd.exchange(dnsPayload: q))
        #expect(r == full)
    }

    @Test("exchange gives up with nil when the upstream stays silent past the timeout")
    func exchangeTimeout() async throws {
        let clock = ManualDNSClock()
        let fwd = makeForwarder(socket: ScriptedUpstreamSocket(), clock: clock)
        try await fwd.start { _, _ in }
        async let result = fwd.exchange(dnsPayload: TestDNS.query("a.example"))
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        #expect(await result == nil)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("exchange gives up with nil when the send fails")
    func exchangeSendFailure() async throws {
        let fwd = makeForwarder(socket: ScriptedUpstreamSocket(failure: SendFailure()))
        try await fwd.start { _, _ in }
        #expect(await fwd.exchange(dnsPayload: TestDNS.query("a.example")) == nil)
        #expect(await fwd.activeInFlightCount == 0)
    }
}

@Suite("DNS payload resolver")
struct DNSPayloadResolverTests {
    private func makeEngine(block: String) throws -> DNSLookupEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try DNSArtifactPublisher().publish(blocklistSources: [block], allowlistRules: [], baseAppGroupURL: dir)
        return DNSLookupEngine(initialSnapshot: try DNSGenerationLoader().loadActiveGeneration(baseAppGroupURL: dir))
    }

    private func makeResolver(
        socket: ScriptedUpstreamSocket, clock: ManualDNSClock = ManualDNSClock(), tcp: ScriptedTCPTransport? = nil
    ) async throws -> DNSPayloadResolver {
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 2, maxInFlightQueries: 8),
            socketFactory: { _, _, _ in socket }, clock: clock, tcpTransport: tcp
        )
        try await fwd.start { _, _ in }
        return DNSPayloadResolver(engine: try makeEngine(block: "||blocked.example^"), forwarder: fwd)
    }

    @Test("a blocked name is answered NXDOMAIN without asking upstream")
    func blocked() async throws {
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent) }
        let resolver = try await makeResolver(socket: socket)
        let q = TestDNS.query("ads.blocked.example", txID: 0x0909)
        let r = try #require(await resolver.resolve(q))
        #expect(TestDNS.txID(r) == 0x0909 && TestDNS.rcode(r) == 3)
        #expect(socket.sent.withLock { $0.isEmpty })
    }

    @Test("an allowed name is answered from upstream")
    func allowed() async throws {
        let socket = ScriptedUpstreamSocket { sent in TestDNS.response(to: sent, answerBytes: 8) }
        let resolver = try await makeResolver(socket: socket)
        let r = try #require(await resolver.resolve(TestDNS.query("fine.example")))
        #expect(TestDNS.answerCount(r) == 1)
    }

    @Test("a silent upstream becomes a SERVFAIL")
    func silent() async throws {
        let clock = ManualDNSClock()
        let resolver = try await makeResolver(socket: ScriptedUpstreamSocket(), clock: clock)
        async let r = resolver.resolve(TestDNS.query("fine.example", txID: 0x0303))
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        let reply = try #require(await r)
        #expect(TestDNS.txID(reply) == 0x0303 && TestDNS.rcode(reply) == 2)
    }

    @Test("something that is not a DNS question gets no answer")
    func junk() async throws {
        let resolver = try await makeResolver(socket: ScriptedUpstreamSocket())
        #expect(await resolver.resolve(Data([1, 2, 3, 4])) == nil)
    }
}
