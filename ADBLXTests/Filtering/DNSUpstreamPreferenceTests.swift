import Testing
import Foundation
import os
@testable import ADBLX
import ADBLXShared

/// Which upstream a query goes to first, learned per network from which upstream has been
/// answering (device results 2026-11-08: on 4G, IPv4 to 9.9.9.9 is lost and IPv6 answers).
@Suite("DNS upstream preference")
struct DNSUpstreamScoreboardTests {
    private let all: [UpstreamID] = [.ipv6, .primaryIPv4, .fallbackIPv4]

    @Test("with nothing learned, IPv6 goes first, then the IPv4 primary, then the IPv4 fallback")
    func defaultOrder() {
        #expect(UpstreamScoreboard().ordered(all) == [.ipv6, .primaryIPv4, .fallbackIPv4])
    }

    @Test("only the upstreams that exist are ordered")
    func onlyAvailable() {
        #expect(UpstreamScoreboard().ordered([.primaryIPv4, .fallbackIPv4]) == [.primaryIPv4, .fallbackIPv4])
    }

    @Test("an upstream that keeps failing drops behind one with no record yet")
    func failingDrops() {
        var board = UpstreamScoreboard()
        for _ in 0..<3 { board.record(.ipv6, success: false) }
        #expect(board.ordered(all) == [.primaryIPv4, .fallbackIPv4, .ipv6])
    }

    @Test("the one answering more of its recent queries goes first")
    func betterRateFirst() {
        var board = UpstreamScoreboard()
        for i in 0..<10 { board.record(.ipv6, success: i < 5) }        // 50%
        for i in 0..<10 { board.record(.primaryIPv4, success: i < 9) } // 90%
        #expect(board.ordered(all).first == .primaryIPv4)
    }

    @Test("equal records keep the default order")
    func tieKeepsDefault() {
        var board = UpstreamScoreboard()
        board.record(.ipv6, success: true)
        board.record(.primaryIPv4, success: true)
        #expect(board.ordered(all).prefix(2) == [.ipv6, .primaryIPv4])
    }

    @Test("only the last 20 outcomes count, so an upstream that recovers wins its place back")
    func window() {
        var board = UpstreamScoreboard()
        for _ in 0..<20 { board.record(.ipv6, success: false) }
        for _ in 0..<20 { board.record(.primaryIPv4, success: true) }
        #expect(board.ordered(all).first == .primaryIPv4)
        for _ in 0..<20 { board.record(.ipv6, success: true) }
        #expect(board.ordered(all).first == .ipv6)
        #expect(UpstreamScoreboard.window == 20)
    }
}

/// The forwarder asks the preferred upstream, races the next one after a short delay if no
/// answer has come, takes the first answer, and gives up after the outer timeout.
@Suite("DNS upstream hedging", .timeLimit(.minutes(1)))
struct DNSUpstreamHedgingTests {
    private static let v6IP = "2620:fe::fe"
    private static let fallbackIP = "149.112.112.112"

    private struct Sockets {
        var primary = ScriptedUpstreamSocket(senderIP: "9.9.9.9")
        var v6 = ScriptedUpstreamSocket(senderIP: v6IP)
        var fallback = ScriptedUpstreamSocket(senderIP: fallbackIP)
    }

    private static func answering(_ ip: String) -> ScriptedUpstreamSocket {
        ScriptedUpstreamSocket(senderIP: ip) { TestDNS.response(to: $0, answerBytes: 4) }
    }

    private func make(
        _ sockets: Sockets, clock: ManualDNSClock, counters: DNSTunnelCounters? = nil,
        v6: String? = v6IP, fallback: String? = fallbackIP, tcp: ScriptedTCPTransport? = nil
    ) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(
                ipv4Address: "9.9.9.9", ipv6Address: v6, fallbackIPv4Address: fallback,
                timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8
            ),
            socketFactory: { host, _, isIPv6 in isIPv6 ? sockets.v6 : (host == Self.fallbackIP ? sockets.fallback : sockets.primary) },
            clock: clock, tcpTransport: tcp, counters: counters
        )
    }

    private func parsed(_ dns: Data) -> (Data, ParsedDNSQuery) {
        let packet = TestDNS.udpPacket(dns: dns)
        return (packet, packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!)
    }

    private func sentCount(_ socket: ScriptedUpstreamSocket) -> Int { socket.sent.withLock { $0.count } }

    /// Answers the last query `socket` was sent, as if it came from `ip`.
    private func reply(from socket: ScriptedUpstreamSocket, ip: String, isIPv6: Bool, to fwd: DNSUpstreamForwarder, truncated: Bool = false) async throws {
        let sent = try #require(socket.sent.withLock { $0.last })
        await fwd.handleUpstreamResponse(data: TestDNS.response(to: sent, truncated: truncated, answerBytes: 4), senderIP: ip, senderPort: 53, isIPv6: isIPv6)
    }

    @Test("a fast answer from the preferred upstream: nothing else is asked")
    func fastAnswerNoHedge() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        var sockets = Sockets()
        sockets.v6 = Self.answering(Self.v6IP)
        let fwd = make(sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("fast.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(sentCount(sockets.v6) == 1)
        #expect(sentCount(sockets.primary) == 0 && sentCount(sockets.fallback) == 0)
        #expect(counters.snapshot.upstreamRetries == 0)
    }

    @Test("no answer by the hedge delay: the next upstream is raced, and its answer reaches the client")
    func hedgeAfterDelay() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        var sockets = Sockets()
        sockets.primary = Self.answering("9.9.9.9")
        let fwd = make(sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("hedge.example", txID: 0x7070))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.39)
        #expect(sentCount(sockets.primary) == 0)
        clock.advance(by: 0.01)
        await sink.waitForCount(1)
        let dns = TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])
        #expect(TestDNS.txID(dns) == 0x7070 && TestDNS.rcode(dns) == 0)
        #expect(sentCount(sockets.v6) == 1 && sentCount(sockets.primary) == 1)
        #expect(counters.snapshot.upstreamRetries == 1)
        #expect(counters.snapshot.upstreamTimeouts == 0)
    }

    @Test("the first answer wins; the other upstream's answer afterwards is not sent to the client")
    func firstAnswerWins() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let sockets = Sockets()
        let fwd = make(sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("race.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await clock.waitForSleepers(1)        // hedge sent; now waiting for the outer timeout
        try await reply(from: sockets.primary, ip: "9.9.9.9", isIPv6: false, to: fwd)
        try await reply(from: sockets.v6, ip: Self.v6IP, isIPv6: true, to: fwd)
        #expect(sink.count == 1)
        #expect(counters.snapshot.answersFromPrimaryIPv4 == 1)
        #expect(counters.snapshot.lateAnswersFromIPv6 == 1)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("the outer timeout is 2 s from the query, hedge included: then a single SERVFAIL")
    func outerBound() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let fwd = make(Sockets(), clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("dead.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await clock.waitForSleepers(1)
        clock.advance(by: 1.59)
        #expect(sink.count == 0)
        clock.advance(by: 0.01)
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
        #expect(counters.snapshot.upstreamTimeouts == 1)
        #expect(counters.snapshot.servfailsSent == 1)
        #expect(counters.snapshot.upstreamRetries == 1)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("a failed send moves to the next upstream at once, without waiting for the hedge delay")
    func sendFailureMovesOn() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        var sockets = Sockets()
        sockets.v6 = ScriptedUpstreamSocket(failure: SendFailure())
        sockets.primary = Self.answering("9.9.9.9")
        let fwd = make(sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("nov6.example"))
        let result = await fwd.forward(query: query, originalPacket: packet)
        guard case .forwarded = result else { Issue.record("expected forwarded, got \(result)"); return }
        await sink.waitForCount(1)
        #expect(clock.now == 0)
        #expect(counters.snapshot.upstreamSendErrors == 1)
    }

    @Test("every upstream failing to send gives an immediate SERVFAIL")
    func allSendsFail() async throws {
        let sink = PacketSink()
        let sockets = Sockets(
            primary: ScriptedUpstreamSocket(failure: SendFailure()),
            v6: ScriptedUpstreamSocket(failure: SendFailure()),
            fallback: ScriptedUpstreamSocket(failure: SendFailure())
        )
        let fwd = make(sockets, clock: ManualDNSClock())
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("down.example"))
        let result = await fwd.forward(query: query, originalPacket: packet)
        guard case .socketUnavailable = result else { Issue.record("expected socketUnavailable, got \(result)"); return }
        #expect(sink.count == 1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("once IPv6 loses a race to IPv4 on this network, IPv4 is asked first")
    func preferenceSwitches() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        var sockets = Sockets()
        sockets.primary = Self.answering("9.9.9.9")
        let fwd = make(sockets, clock: clock, fallback: nil)
        try await fwd.start { p, _ in sink.append(p) }
        try await loseOnIPv6(fwd, clock: clock, sink: sink, txID: 1)
        #expect(sentCount(sockets.v6) == 1)
        let (packet, query) = parsed(TestDNS.query("q2.example", txID: 2))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(2)
        #expect(sentCount(sockets.v6) == 1)
        #expect(sentCount(sockets.primary) == 2)
    }

    /// One query that IPv6 doesn't answer and IPv4 answers after the hedge.
    private func loseOnIPv6(_ fwd: DNSUpstreamForwarder, clock: ManualDNSClock, sink: PacketSink, txID: UInt16) async throws {
        let before = sink.count
        let (packet, query) = parsed(TestDNS.query("q\(txID).example", txID: txID))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await sink.waitForCount(before + 1)
    }

    @Test("what one network learned does not carry to another; returning to it brings it back")
    func perNetwork() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        var sockets = Sockets()
        sockets.primary = Self.answering("9.9.9.9")
        let fwd = make(sockets, clock: clock, fallback: nil)
        try await fwd.start { p, _ in sink.append(p) }
        try await fwd.resetSockets(networkKey: "pdp_ip0")
        try await loseOnIPv6(fwd, clock: clock, sink: sink, txID: 1)

        try await fwd.resetSockets(networkKey: "en0")
        let (p1, q1) = parsed(TestDNS.query("wifi.example", txID: 10))
        _ = await fwd.forward(query: q1, originalPacket: p1)
        #expect(sentCount(sockets.v6) == 2)                    // a fresh network starts with IPv6
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await sink.waitForCount(2)

        try await fwd.resetSockets(networkKey: "pdp_ip0")
        let (p2, q2) = parsed(TestDNS.query("back.example", txID: 11))
        _ = await fwd.forward(query: q2, originalPacket: p2)
        await sink.waitForCount(3)
        #expect(sentCount(sockets.v6) == 2)                    // back on 4G: IPv4 first again
    }

    @Test("with one upstream there is nothing to race: only the outer timeout")
    func singleUpstream() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        let fwd = make(Sockets(), clock: clock, v6: nil, fallback: nil)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("one.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
    }

    @Test("exchange (TCP clients) is hedged the same way")
    func exchangeHedges() async throws {
        let clock = ManualDNSClock()
        var sockets = Sockets()
        sockets.primary = Self.answering("9.9.9.9")
        let fwd = make(sockets, clock: clock)
        try await fwd.start { _, _ in }
        async let result = fwd.exchange(dnsPayload: TestDNS.query("a.example", txID: 0x2222))
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        let r = try #require(await result)
        #expect(TestDNS.txID(r) == 0x2222 && TestDNS.answerCount(r) == 1)
    }

    @Test("a socket reset resends a waiting query to the upstream it was sent to, on the new socket")
    func resetResends() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        let created = OSAllocatedUnfairLock(initialState: [ScriptedUpstreamSocket]())
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: Self.v6IP, timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8),
            socketFactory: { _, _, isIPv6 in
                created.withLock { list in
                    // The first pair never answers; the replacements do.
                    let ip = isIPv6 ? Self.v6IP : "9.9.9.9"
                    let s = list.count < 2 ? ScriptedUpstreamSocket(senderIP: ip) : Self.answering(ip)
                    list.append(s)
                    return s
                }
            },
            clock: clock, tcpTransport: nil
        )
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("wait.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        try await fwd.resetSockets(networkKey: "en0")
        await sink.waitForCount(1)
        let all = created.withLock { $0 }                        // v4, v6, then the new v4, v6
        #expect(all.count == 4)
        #expect(all[3].sent.withLock { $0.count } == 1)
        #expect(all[2].sent.withLock { $0.isEmpty })
    }
}

/// The network monitor names the network the forwarder learns on: physical interfaces only.
@Suite("DNS upstream preference per network", .timeLimit(.minutes(1)))
struct DNSUpstreamNetworkKeyTests {
    @Test("the network key leaves out virtual interfaces")
    func physicalKey() {
        let snapshot = NetworkPathSnapshot(isSatisfied: true, interfaces: ["utun3", "pdp_ip0", "ipsec1", "en0"])
        #expect(snapshot.physicalKey == "en0,pdp_ip0")
    }

    private static func answering(_ ip: String) -> ScriptedUpstreamSocket {
        ScriptedUpstreamSocket(senderIP: ip) { TestDNS.response(to: $0, answerBytes: 4) }
    }

    private static func path(_ interfaces: String...) -> NetworkPathSnapshot {
        NetworkPathSnapshot(isSatisfied: true, interfaces: interfaces)
    }

    /// Sees the `before` paths, learns that IPv6 is silent there, sees the `after` paths, and
    /// returns whether the next query still went to IPv4 first.
    private func keepsPreference(before: [NetworkPathSnapshot], after: [NetworkPathSnapshot]) async throws -> Bool {
        let clock = ManualDNSClock(), sink = PacketSink()
        let v6 = ScriptedUpstreamSocket(senderIP: "2620:fe::fe")
        let v4 = Self.answering("9.9.9.9")
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: "2620:fe::fe", timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8),
            socketFactory: { _, _, isIPv6 in isIPv6 ? v6 : v4 }, clock: clock, tcpTransport: nil
        )
        try await fwd.start { p, _ in sink.append(p) }
        let monitor = DNSNetworkMonitor(observer: FakePathObserver(), forwarder: fwd, setReasserting: { _ in })
        for snapshot in before { await monitor.handle(snapshot) }
        let packet = TestDNS.udpPacket(dns: TestDNS.query("learn.example", txID: 1))
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await sink.waitForCount(1)

        for snapshot in after { await monitor.handle(snapshot) }
        let before = v6.sent.withLock { $0.count }
        let p2 = TestDNS.udpPacket(dns: TestDNS.query("next.example", txID: 2))
        let q2 = p2.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        _ = await fwd.forward(query: q2, originalPacket: p2)
        let askedIPv6First = v6.sent.withLock { $0.count } > before
        if askedIPv6First {
            await clock.waitForSleepers(1)
            clock.advance(by: 0.4)
        }
        await sink.waitForCount(2)
        return !askedIPv6First
    }

    @Test("a VPN interface appearing on the same 4G network keeps what was learned")
    func virtualChangeKeeps() async throws {
        #expect(try await keepsPreference(before: [Self.path("pdp_ip0")], after: [Self.path("pdp_ip0", "utun4")]))
    }

    @Test("the first path seen names the network, so what was learned before any change comes back with it")
    func baselineNamesNetwork() async throws {
        #expect(try await keepsPreference(before: [Self.path("pdp_ip0")], after: [Self.path("en0"), Self.path("pdp_ip0")]))
    }

    @Test("another network starts from nothing")
    func otherNetworkFresh() async throws {
        #expect(try await keepsPreference(before: [Self.path("pdp_ip0")], after: [Self.path("en0")]) == false)
    }
}
