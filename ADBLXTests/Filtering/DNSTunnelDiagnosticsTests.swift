#if DEBUG
import Testing
import Foundation
import os
import ADBLXShared
@testable import ADBLX

/// DEBUG-only counters and the pass-through switch. Counts only (docs/Architecture/Logging.md):
/// nothing here, and nothing the tunnel replies with, can carry a domain.
@Suite("DNS tunnel diagnostics")
struct DNSTunnelDiagnosticsTests {
    private func makeEngine(block: String = "||blocked.example^", allow: [String] = []) throws -> DNSLookupEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try DNSArtifactPublisher().publish(blocklistSources: [block], allowlistRules: allow, baseAppGroupURL: dir)
        return DNSLookupEngine(initialSnapshot: try DNSGenerationLoader().loadActiveGeneration(baseAppGroupURL: dir))
    }

    // MARK: - Counters

    @Test("counters start at zero and count what they are told")
    func counting() {
        let counters = DNSTunnelCounters()
        #expect(counters.snapshot == DNSTunnelCountersSnapshot())
        counters.increment(\.ingressPackets)
        counters.increment(\.ingressPackets)
        counters.increment(\.blockedQueries)
        #expect(counters.snapshot.ingressPackets == 2)
        #expect(counters.snapshot.blockedQueries == 1)
        counters.reset()
        #expect(counters.snapshot == DNSTunnelCountersSnapshot())
    }

    @Test("counting from many threads loses nothing")
    func concurrent() async {
        let counters = DNSTunnelCounters()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<500 { counters.increment(\.forwardedQueries) } } }
        }
        #expect(counters.snapshot.forwardedQueries == 4000)
    }

    // MARK: - Forwarder feeds the counters

    private func forwarder(
        socket: ScriptedUpstreamSocket, clock: ManualDNSClock = ManualDNSClock(),
        tcp: ScriptedTCPTransport? = nil, counters: DNSTunnelCounters
    ) -> DNSUpstreamForwarder {
        DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 2, maxInFlightQueries: 8),
            socketFactory: { _, _, _ in socket }, clock: clock, tcpTransport: tcp, counters: counters
        )
    }

    private func parsed(_ dns: Data) -> (Data, ParsedDNSQuery) {
        let packet = TestDNS.udpPacket(dns: dns)
        return (packet, packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!)
    }

    @Test("a timeout counts as a timeout and as a SERVFAIL sent")
    func timeoutCounted() async throws {
        let clock = ManualDNSClock(), sink = PacketSink(), counters = DNSTunnelCounters()
        let fwd = forwarder(socket: ScriptedUpstreamSocket(), clock: clock, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(TestDNS.query("slow.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        await sink.waitForCount(1)
        #expect(counters.snapshot.upstreamTimeouts == 1)
        #expect(counters.snapshot.servfailsSent == 1)
        #expect(counters.snapshot.upstreamSendErrors == 0)
    }

    @Test("a failed send counts as a send error and as a SERVFAIL sent")
    func sendErrorCounted() async throws {
        let counters = DNSTunnelCounters()
        let fwd = forwarder(socket: ScriptedUpstreamSocket(failure: SendFailure()), counters: counters)
        try await fwd.start { _, _ in }
        let (packet, query) = parsed(TestDNS.query("down.example"))
        _ = await fwd.forward(query: query, originalPacket: packet)
        #expect(counters.snapshot.upstreamSendErrors == 1)
        #expect(counters.snapshot.servfailsSent == 1)
        #expect(counters.snapshot.upstreamTimeouts == 0)
    }

    @Test("a truncated upstream answer is counted")
    func truncatedCounted() async throws {
        let sink = PacketSink(), counters = DNSTunnelCounters()
        let dns = TestDNS.query("big.example", udpSize: 1232)
        let tcp = ScriptedTCPTransport(.success(TestDNS.response(to: dns, answerBytes: 100)))
        let socket = ScriptedUpstreamSocket { TestDNS.response(to: $0, truncated: true) }
        let fwd = forwarder(socket: socket, tcp: tcp, counters: counters)
        try await fwd.start { p, _ in sink.append(p) }
        let (packet, query) = parsed(dns)
        _ = await fwd.forward(query: query, originalPacket: packet)
        await sink.waitForCount(1)
        #expect(counters.snapshot.truncatedUpstreamAnswers == 1)
        #expect(counters.snapshot.servfailsSent == 0)
    }

    // MARK: - Pass-through (empty blocklist)

    @Test("pass-through allows a name the blocklist blocks, and switching it off blocks it again")
    func passthrough() throws {
        let engine = try makeEngine()
        #expect(engine.lookup(domain: "ads.blocked.example") == .block)
        engine.isPassthrough = true
        #expect(engine.lookup(domain: "ads.blocked.example") == .allow)
        engine.isPassthrough = false
        #expect(engine.lookup(domain: "ads.blocked.example") == .block)
    }

    @Test("pass-through is off by default")
    func passthroughDefaultsOff() throws {
        #expect(try makeEngine().isPassthrough == false)
    }

    // MARK: - App messages

    private func handler(_ engine: DNSLookupEngine, counters: DNSTunnelCounters) -> DNSTunnelDiagnosticsHandler {
        DNSTunnelDiagnosticsHandler(counters: counters, engine: engine)
    }

    private func encode(_ message: DNSTunnelDiagnosticsMessage) -> Data { try! JSONEncoder().encode(message) }

    @Test("readCounters replies with the current snapshot")
    func readCounters() throws {
        let counters = DNSTunnelCounters(), engine = try makeEngine()
        counters.increment(\.tcpQueries)
        let reply = try #require(handler(engine, counters: counters).handle(encode(.readCounters)))
        let snapshot = try JSONDecoder().decode(DNSTunnelCountersSnapshot.self, from: reply)
        #expect(snapshot.tcpQueries == 1)
        #expect(snapshot.passthrough == false)
    }

    @Test("setPassthrough flips the engine and the reply says so")
    func setPassthrough() throws {
        let counters = DNSTunnelCounters(), engine = try makeEngine()
        let h = handler(engine, counters: counters)
        let reply = try #require(h.handle(encode(.setPassthrough(true))))
        #expect(engine.isPassthrough)
        #expect(try JSONDecoder().decode(DNSTunnelCountersSnapshot.self, from: reply).passthrough)
        _ = h.handle(encode(.setPassthrough(false)))
        #expect(!engine.isPassthrough)
    }

    @Test("resetCounters zeroes them but leaves pass-through alone")
    func resetCounters() throws {
        let counters = DNSTunnelCounters(), engine = try makeEngine()
        let h = handler(engine, counters: counters)
        _ = h.handle(encode(.setPassthrough(true)))
        counters.increment(\.blockedQueries)
        let reply = try #require(h.handle(encode(.resetCounters)))
        let snapshot = try JSONDecoder().decode(DNSTunnelCountersSnapshot.self, from: reply)
        #expect(snapshot.blockedQueries == 0)
        #expect(snapshot.passthrough)
    }

    @Test("a message it does not understand gets no reply")
    func unknownMessage() throws {
        let h = handler(try makeEngine(), counters: DNSTunnelCounters())
        #expect(h.handle(Data("not json".utf8)) == nil)
        #expect(h.handle(Data()) == nil)
    }

    @Test("the reply is numbers and one flag, never text, so it cannot carry a domain")
    func replyIsCountsOnly() throws {
        let counters = DNSTunnelCounters()
        counters.increment(\.ingressPackets)
        let reply = try #require(handler(try makeEngine(), counters: counters).handle(encode(.readCounters)))
        let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        // Literal key list, not derived from the type under test.
        #expect(Set(object.keys) == [
            "ingressPackets", "blockedQueries", "forwardedQueries", "responsesWritten",
            "upstreamTimeouts", "upstreamSendErrors", "upstreamRetries", "servfailsSent", "truncatedUpstreamAnswers",
            "tcpSegments", "tcpQueries", "unparsablePackets", "socketResets", "passthrough",
            "answersFromPrimaryIPv4", "answersFromIPv6", "answersFromFallbackIPv4",
            "lateAnswersFromPrimaryIPv4", "lateAnswersFromIPv6", "lateAnswersFromFallbackIPv4",
            "duplicateClientQueries", "upstreamTCPSucceeded", "upstreamTCPFailed", "truncatedToClient",
            "queriesA", "queriesAAAA", "queriesHTTPS", "queriesOther",
            "unparsableIPv4", "unparsableIPv6", "unparsableTCP", "unparsableUDP", "unparsableICMP",
            "unparsableOtherProtocol", "unparsableToDNSAddress", "unparsableSmall", "unparsableMedium", "unparsableLarge",
            "pathUpdates", "resetsInterfaceChange", "resetsReconnect", "resetsVirtualInterfacesOnly"
        ])
        for (key, value) in object {
            #expect(value is NSNumber, "\(key) must be a number or flag, not \(type(of: value))")
        }
    }
}
#endif
