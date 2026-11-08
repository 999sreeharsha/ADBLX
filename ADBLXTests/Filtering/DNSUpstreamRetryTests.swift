import Testing
import Foundation
import os
@testable import ADBLX
import ADBLXShared

/// A query whose first upstream fails to send, or is silent past the hedge delay, is sent to the
/// second upstream too; the client gets a SERVFAIL only when neither answers within the outer
/// timeout. Time is a `ManualDNSClock`; nothing waits on the wall clock.
@Suite("DNS upstream retry", .timeLimit(.minutes(1)))
struct DNSUpstreamRetryTests {
    private static let fallbackIP = "149.112.112.112"

    private struct Sockets {
        let primary: ScriptedUpstreamSocket
        let fallback: ScriptedUpstreamSocket
        let v6: ScriptedUpstreamSocket
    }

    private func answer() -> @Sendable (Data) -> Data? { { TestDNS.response(to: $0, answerBytes: 10) } }

    private func make(
        sockets: Sockets, clock: ManualDNSClock, counters: DNSTunnelCounters? = nil,
        fallback: String? = fallbackIP, v6: String? = nil
    ) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(
                ipv4Address: "9.9.9.9", ipv6Address: v6, fallbackIPv4Address: fallback,
                timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8
            ),
            socketFactory: { host, _, isIPv6 in
                if isIPv6 { return sockets.v6 }
                return host == Self.fallbackIP ? sockets.fallback : sockets.primary
            },
            clock: clock, tcpTransport: nil, counters: counters
        )
    }

    private func parsed(_ dns: Data) -> (Data, ParsedDNSQuery) {
        let packet = TestDNS.udpPacket(dns: dns)
        return (packet, packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!)
    }

    private func silent(_ ip: String = "9.9.9.9") -> ScriptedUpstreamSocket { ScriptedUpstreamSocket(senderIP: ip) }
    private func answering(_ ip: String) -> ScriptedUpstreamSocket { ScriptedUpstreamSocket(senderIP: ip, reply: answer()) }
    private func failing() -> ScriptedUpstreamSocket { ScriptedUpstreamSocket(failure: SendFailure()) }

    @Test("a silent first upstream is raced by the second at the hedge delay, and the client gets that answer")
    func timeoutRetries() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let sockets = Sockets(primary: silent(), fallback: answering(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("slow.example", txID: 0x5151))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await sink.waitForCount(1)

        let dns = TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])
        #expect(TestDNS.txID(dns) == 0x5151 && TestDNS.rcode(dns) == 0 && TestDNS.answerCount(dns) == 1)
        #expect(sockets.fallback.sent.withLock { $0.count } == 1)
        #expect(counters.snapshot.upstreamTimeouts == 0)
        #expect(counters.snapshot.upstreamRetries == 1)
        #expect(counters.snapshot.servfailsSent == 0)
    }

    @Test("a failed send on the first upstream is retried at once on the second")
    func sendFailureRetries() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let sockets = Sockets(primary: failing(), fallback: answering(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("down.example"))
        let result = await fwd.forward(query: query, originalPacket: packet)
        guard case .forwarded = result else { Issue.record("expected forwarded, got \(result)"); return }
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 0)
        #expect(counters.snapshot.upstreamSendErrors == 1)
        #expect(counters.snapshot.upstreamRetries == 1)
        #expect(counters.snapshot.servfailsSent == 0)
    }

    @Test("both upstreams silent: one hedge, then a single SERVFAIL at the outer timeout")
    func bothSilent() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let sockets = Sockets(primary: silent(), fallback: silent(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("dead.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)               // hedge: the second upstream is asked
        await clock.waitForSleepers(1)
        #expect(sink.count == 0)
        clock.advance(by: 1.6)               // 2 s since the query: give up
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
        #expect(sink.count == 1)
        #expect(counters.snapshot.upstreamTimeouts == 1)
        #expect(counters.snapshot.upstreamRetries == 1)
        #expect(counters.snapshot.servfailsSent == 1)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("both upstreams failing to send give a SERVFAIL, after exactly one retry")
    func bothFail() async throws {
        let sink = PacketSink(), counters = DNSTunnelCounters()
        let sockets = Sockets(primary: failing(), fallback: failing(), v6: silent())
        let fwd = make(sockets: sockets, clock: ManualDNSClock(), counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("down.example"))
        let result = await fwd.forward(query: query, originalPacket: packet)
        guard case .socketUnavailable = result else { Issue.record("expected socketUnavailable, got \(result)"); return }
        #expect(sink.count == 1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
        #expect(counters.snapshot.upstreamSendErrors == 2)
        #expect(counters.snapshot.upstreamRetries == 1)
    }

    @Test("with no second upstream configured there is no retry, just the SERVFAIL")
    func noFallback() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let sockets = Sockets(primary: silent(), fallback: answering(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock, counters: counters, fallback: nil)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("slow.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        await sink.waitForCount(1)
        #expect(TestDNS.rcode(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 2)
        #expect(counters.snapshot.upstreamRetries == 0)
        #expect(sockets.fallback.sent.withLock { $0.isEmpty })
    }

    @Test("an answer arriving after the outer timeout is ignored")
    func lateAnswerIgnored() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        let sockets = Sockets(primary: silent(), fallback: silent(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock)
        try await fwd.start { p, _ in sink.append(p) }
        let dns = TestDNS.query("late.example")
        let (packet, query) = parsed(dns)
        guard case .forwarded(let firstID) = await fwd.forward(query: query, originalPacket: packet) else { return }
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await clock.waitForSleepers(1)
        clock.advance(by: 1.6)
        await sink.waitForCount(1)            // the SERVFAIL
        var late = TestDNS.response(to: dns, answerBytes: 4)
        late[0] = UInt8(firstID >> 8); late[1] = UInt8(firstID & 0xFF)
        await fwd.handleUpstreamResponse(data: late, senderIP: "9.9.9.9", senderPort: 53, isIPv6: false)
        #expect(sink.count == 1)
    }

    @Test("an answer from the second upstream's address is accepted; one from a stranger is not")
    func senderValidation() async throws {
        let clock = ManualDNSClock(), sink = PacketSink()
        let sockets = Sockets(primary: silent(), fallback: silent(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock)
        try await fwd.start { p, _ in sink.append(p) }
        let dns = TestDNS.query("who.example")
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await clock.waitForSleepers(1)
        let retryID = UInt16(TestDNS.txID(try #require(sockets.fallback.sent.withLock { $0.last })))
        var reply = TestDNS.response(to: dns, answerBytes: 4)
        reply[0] = UInt8(retryID >> 8); reply[1] = UInt8(retryID & 0xFF)
        await fwd.handleUpstreamResponse(data: reply, senderIP: "1.2.3.4", senderPort: 53, isIPv6: false)
        #expect(sink.count == 0)
        await fwd.handleUpstreamResponse(data: reply, senderIP: Self.fallbackIP, senderPort: 53, isIPv6: false)
        await sink.waitForCount(1)
    }

    @Test("exchange (TCP clients' path) races the second upstream too")
    func exchangeRetries() async throws {
        let clock = ManualDNSClock()
        let sockets = Sockets(primary: silent(), fallback: answering(Self.fallbackIP), v6: silent())
        let fwd = make(sockets: sockets, clock: clock)
        try await fwd.start { _, _ in }
        async let result = fwd.exchange(dnsPayload: TestDNS.query("a.example", txID: 0x2222))
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        let r = try #require(await result)
        #expect(TestDNS.txID(r) == 0x2222 && TestDNS.answerCount(r) == 1)
    }

    @Test("exchange gives up with nil when both upstreams fail to send")
    func exchangeBothFail() async throws {
        let sockets = Sockets(primary: failing(), fallback: failing(), v6: silent())
        let fwd = make(sockets: sockets, clock: ManualDNSClock())
        try await fwd.start { _, _ in }
        #expect(await fwd.exchange(dnsPayload: TestDNS.query("a.example")) == nil)
        #expect(await fwd.activeInFlightCount == 0)
    }
}

@Suite("DNS network change handling", .timeLimit(.minutes(1)))
struct DNSNetworkPathTests {
    private func wifi(_ satisfied: Bool = true) -> NetworkPathSnapshot { NetworkPathSnapshot(isSatisfied: satisfied, interfaces: ["en0"]) }
    private func cellular() -> NetworkPathSnapshot { NetworkPathSnapshot(isSatisfied: true, interfaces: ["pdp_ip0"]) }

    // MARK: - When to reset

    @Test("the first path is a baseline, not a change")
    func baseline() {
        var filter = PathChangeFilter()
        #expect(filter.shouldReset(for: wifi()) == false)
    }

    @Test("the same path again is not a change, whatever order the interfaces come in")
    func samePath() {
        var filter = PathChangeFilter()
        _ = filter.shouldReset(for: NetworkPathSnapshot(isSatisfied: true, interfaces: ["en0", "pdp_ip0"]))
        #expect(filter.shouldReset(for: NetworkPathSnapshot(isSatisfied: true, interfaces: ["pdp_ip0", "en0"])) == false)
    }

    @Test("Wi-Fi to cellular and back are changes")
    func switching() {
        var filter = PathChangeFilter()
        _ = filter.shouldReset(for: wifi())
        #expect(filter.shouldReset(for: cellular()) == true)
        #expect(filter.shouldReset(for: wifi()) == true)
    }

    @Test("going offline does nothing; coming back resets, even on the same interface")
    func offlineThenBack() {
        var filter = PathChangeFilter()
        _ = filter.shouldReset(for: wifi())
        #expect(filter.shouldReset(for: wifi(false)) == false)
        #expect(filter.shouldReset(for: wifi()) == true)
    }

    // MARK: - What a reset does

    private final class Created: @unchecked Sendable {
        let sockets = OSAllocatedUnfairLock(initialState: [ScriptedUpstreamSocket]())
        /// The first socket never answers; every later one does.
        func make() -> ScriptedUpstreamSocket {
            sockets.withLock { list in
                let socket = list.isEmpty
                    ? ScriptedUpstreamSocket()
                    : ScriptedUpstreamSocket { TestDNS.response(to: $0, answerBytes: 6) }
                list.append(socket)
                return socket
            }
        }
        var all: [ScriptedUpstreamSocket] { sockets.withLock { $0 } }
    }

    private func make(created: Created, counters: DNSTunnelCounters? = nil) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 2, maxInFlightQueries: 8),
            socketFactory: { _, _, _ in created.make() }, clock: ManualDNSClock(), tcpTransport: nil, counters: counters
        )
    }

    @Test("resetting replaces the sockets and sends a waiting query again on the new one")
    func resetResends() async throws {
        let created = Created(), sink = PacketSink(), counters = DNSTunnelCounters()
        let fwd = make(created: created, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let packet = TestDNS.udpPacket(dns: TestDNS.query("wait.example", txID: 0x6161))
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        _ = await fwd.forward(query: query, originalPacket: packet)
        #expect(sink.count == 0)

        try await fwd.resetSockets()
        await sink.waitForCount(1)

        let sockets = created.all
        #expect(sockets.count == 2)
        #expect(sockets[0].isClosed.withLock { $0 })
        #expect(sockets[1].sent.withLock { $0.count } == 1)
        #expect(TestDNS.txID(TestDNS.dnsPayload(ofUDPPacket: sink.packets[0])) == 0x6161)
        #expect(counters.snapshot.socketResets == 1)
        #expect(await fwd.activeInFlightCount == 0)
    }

    @Test("resetting with nothing in flight just replaces the sockets")
    func resetIdle() async throws {
        let created = Created()
        let fwd = make(created: created)
        try await fwd.start { _, _ in }
        try await fwd.resetSockets()
        #expect(created.all.count == 2)
        #expect(created.all[1].sent.withLock { $0.isEmpty })
    }

    private func makeMonitor(
        _ fwd: DNSUpstreamForwarder, observer: FakePathObserver, log: PacketSink
    ) -> DNSNetworkMonitor {
        DNSNetworkMonitor(observer: observer, forwarder: fwd, setReasserting: { log.append(Data([$0 ? 1 : 0])) })
    }

    @Test("a real change resets once, marking the tunnel reasserting for the duration; a repeat does not")
    func monitorHandlesChange() async throws {
        let created = Created(), log = PacketSink()
        let fwd = make(created: created)
        try await fwd.start { _, _ in }
        let monitor = makeMonitor(fwd, observer: FakePathObserver(), log: log)

        await monitor.handle(wifi())
        #expect(created.all.count == 1 && log.count == 0)
        await monitor.handle(cellular())
        #expect(created.all.count == 2)
        #expect(log.packets == [Data([1]), Data([0])])
        await monitor.handle(cellular())
        #expect(created.all.count == 2 && log.count == 2)
    }

    @Test("the observer's updates reach the monitor, in order")
    func monitorWiring() async throws {
        let created = Created(), log = PacketSink(), observer = FakePathObserver()
        let fwd = make(created: created)
        try await fwd.start { _, _ in }
        let monitor = makeMonitor(fwd, observer: observer, log: log)
        monitor.start()
        observer.emit(wifi())
        observer.emit(cellular())
        await log.waitForCount(2)
        #expect(log.packets == [Data([1]), Data([0])])
        #expect(created.all.count == 2)
        monitor.stop()
    }
}
