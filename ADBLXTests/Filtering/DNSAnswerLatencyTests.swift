#if DEBUG
import Testing
import Foundation
import ADBLXShared
@testable import ADBLX

/// DEBUG counters: how long the first answer took, from the query arriving, in buckets. Counts only.
@Suite("DNS first-answer latency", .timeLimit(.minutes(1)))
struct DNSAnswerLatencyTests {
    @Test("latency falls into buckets up to and including each bound")
    func buckets() {
        let cases: [(TimeInterval, WritableKeyPath<DNSTunnelCountersSnapshot, UInt64>)] = [
            (0, \.firstAnswerUnder50ms), (0.05, \.firstAnswerUnder50ms),
            (0.051, \.firstAnswerUnder100ms), (0.1, \.firstAnswerUnder100ms),
            (0.2, \.firstAnswerUnder250ms), (0.25, \.firstAnswerUnder250ms),
            (0.4, \.firstAnswerUnder500ms), (0.5, \.firstAnswerUnder500ms),
            (0.9, \.firstAnswerUnder1s), (1.0, \.firstAnswerUnder1s),
            (1.5, \.firstAnswerOver1s), (30, \.firstAnswerOver1s)
        ]
        for (seconds, expected) in cases {
            #expect(DNSAnswerLatencyBucket.counter(forSeconds: seconds) == expected, "\(seconds) s")
        }
    }

    private func forwarder(v6: ScriptedUpstreamSocket, v4: ScriptedUpstreamSocket, clock: ManualDNSClock, counters: DNSTunnelCounters) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: "2620:fe::fe", timeoutSeconds: 2, hedgeDelaySeconds: 0.4, maxInFlightQueries: 8),
            socketFactory: { _, _, isIPv6 in isIPv6 ? v6 : v4 }, clock: clock, tcpTransport: nil, counters: counters
        )
    }

    private func forward(_ fwd: DNSUpstreamForwarder) async {
        let packet = TestDNS.udpPacket(dns: TestDNS.query("time.example"))
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        _ = await fwd.forward(query: query, originalPacket: packet)
    }

    @Test("an answer at once is counted under 50 ms; nothing else is")
    func immediate() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink(), clock = ManualDNSClock()
        let v6 = ScriptedUpstreamSocket(senderIP: "2620:fe::fe") { TestDNS.response(to: $0, answerBytes: 4) }
        let fwd = forwarder(v6: v6, v4: ScriptedUpstreamSocket(), clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        await forward(fwd)
        await sink.waitForCount(1)
        let s = counters.snapshot
        #expect(s.firstAnswerUnder50ms == 1)
        #expect(s.firstAnswerUnder500ms == 0 && s.firstAnswerOver1s == 0)
    }

    @Test("an answer from the hedge is timed from the query, not from the hedge")
    func hedged() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink(), clock = ManualDNSClock()
        let v4 = ScriptedUpstreamSocket(senderIP: "9.9.9.9") { TestDNS.response(to: $0, answerBytes: 4) }
        let fwd = forwarder(v6: ScriptedUpstreamSocket(senderIP: "2620:fe::fe"), v4: v4, clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        await forward(fwd)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await sink.waitForCount(1)
        let s = counters.snapshot
        #expect(s.firstAnswerUnder500ms == 1)
        #expect(s.firstAnswerUnder50ms == 0)
    }

    @Test("a timeout is not an answer and is not timed")
    func timeoutNotTimed() async throws {
        let counters = DNSTunnelCounters(), sink = PacketSink(), clock = ManualDNSClock()
        let fwd = forwarder(v6: ScriptedUpstreamSocket(senderIP: "2620:fe::fe"), v4: ScriptedUpstreamSocket(), clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        await forward(fwd)
        await clock.waitForSleepers(1)
        clock.advance(by: 0.4)
        await clock.waitForSleepers(1)
        clock.advance(by: 1.6)
        await sink.waitForCount(1)
        let s = counters.snapshot
        let timed = s.firstAnswerUnder50ms + s.firstAnswerUnder100ms + s.firstAnswerUnder250ms
            + s.firstAnswerUnder500ms + s.firstAnswerUnder1s + s.firstAnswerOver1s
        #expect(timed == 0)
    }
}
#endif
