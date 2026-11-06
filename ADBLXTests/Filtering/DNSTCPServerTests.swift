import Testing
import Foundation
@testable import ADBLX

/// The TCP front end of the tunnel's fake DNS server. It is synchronous and takes the clock as
/// a value, so nothing here waits.
@Suite("DNS TCP server")
struct DNSTCPServerTests {
    private let serverIP: UInt32 = 0xC633_6401   // 198.51.100.1
    private let clientIP: UInt32 = 0xC000_0202   // 192.0.2.2
    private let clientPort: UInt16 = 50000
    private let clientISN: UInt32 = 1000
    private let serverISN: UInt32 = 5000

    private func makeServer(clock: ManualDNSClock = ManualDNSClock(), maxConnections: Int = 32, idle: TimeInterval = 30) -> DNSTCPServer {
        DNSTCPServer(serverIP: serverIP, clock: clock, maxConnections: maxConnections, idleTimeout: idle, initialSequence: { 5000 })
    }

    private func segment(
        port: UInt16? = nil, dstPort: UInt16 = 53, seq: UInt32, ack: UInt32 = 0,
        flags: TCPFlags, payload: Data = Data()
    ) -> ParsedTCPSegment {
        let raw = TCPSegmentBuilder.buildIPv4(
            srcIP: clientIP, dstIP: serverIP, srcPort: port ?? clientPort, dstPort: dstPort,
            seq: seq, ack: ack, flags: flags, payload: payload
        )
        return TCPSegmentParser.parseIPv4(raw)!
    }

    private func parse(_ packets: [Data]) -> [ParsedTCPSegment] { packets.map { TCPSegmentParser.parseIPv4($0)! } }

    /// Completes the handshake; returns the next client sequence number.
    @discardableResult
    private func connect(_ server: DNSTCPServer, port: UInt16? = nil) -> UInt32 {
        _ = server.receive(segment(port: port, seq: clientISN, flags: [.syn]))
        _ = server.receive(segment(port: port, seq: clientISN + 1, ack: serverISN + 1, flags: [.ack]))
        return clientISN + 1
    }

    @Test("a SYN is answered with a SYN-ACK that acknowledges it")
    func handshake() throws {
        let server = makeServer()
        let out = server.receive(segment(seq: clientISN, flags: [.syn]))
        let reply = try #require(parse(out.packets).first)
        #expect(out.packets.count == 1)
        #expect(reply.flags == [.syn, .ack])
        #expect(reply.seq == 5000)
        #expect(reply.ack == 1001)
        #expect(reply.srcIP == serverIP && reply.dstIP == clientIP)
        #expect(reply.srcPort == 53 && reply.dstPort == clientPort)
        #expect(server.connectionCount == 1)
    }

    @Test("a repeated SYN is answered again with the same sequence number")
    func repeatedSYN() throws {
        let server = makeServer()
        _ = server.receive(segment(seq: clientISN, flags: [.syn]))
        let again = try #require(parse(server.receive(segment(seq: clientISN, flags: [.syn])).packets).first)
        #expect(again.flags == [.syn, .ack] && again.seq == 5000)
        #expect(server.connectionCount == 1)
    }

    @Test("a query is acknowledged, handed out once, and its answer is sent as a framed segment")
    func queryAndAnswer() throws {
        let server = makeServer()
        let next = connect(server)
        let query = TestDNS.query("example.com")
        let framed = DNSTCPFraming.frame(query)
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.psh, .ack], payload: framed))

        let ack = try #require(parse(out.packets).first)
        #expect(ack.flags == [.ack] && ack.ack == next + UInt32(framed.count) && ack.seq == serverISN + 1)
        #expect(out.queries.count == 1)
        #expect(out.queries[0].message == query)

        let response = TestDNS.response(to: query, answerBytes: 40)
        let sent = parse(server.respond(to: out.queries[0].key, with: response))
        #expect(sent.count == 1)
        #expect(sent[0].flags == [.psh, .ack])
        #expect(sent[0].seq == serverISN + 1)
        #expect(sent[0].ack == next + UInt32(framed.count))
        #expect(sent[0].payload == DNSTCPFraming.frame(response))
    }

    @Test("a large answer is split into consecutive segments that reassemble exactly")
    func largeAnswer() throws {
        let server = makeServer()
        let next = connect(server)
        let query = TestDNS.query("big.example")
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.psh, .ack], payload: DNSTCPFraming.frame(query)))
        let response = TestDNS.response(to: query, answerBytes: 3000)
        let sent = parse(server.respond(to: out.queries[0].key, with: response))
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { $0.payload.count <= 1200 })
        var expectedSeq = serverISN + 1
        var reassembled = Data()
        for s in sent {
            #expect(s.seq == expectedSeq)
            expectedSeq += UInt32(s.payload.count)
            reassembled.append(s.payload)
        }
        #expect(reassembled == DNSTCPFraming.frame(response))
    }

    @Test("a query split over two segments is handed out once it is complete")
    func splitQuery() throws {
        let server = makeServer()
        let next = connect(server)
        let framed = DNSTCPFraming.frame(TestDNS.query("split.example"))
        let first = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: framed.prefix(5)))
        #expect(first.queries.isEmpty)
        let second = server.receive(segment(seq: next + 5, ack: serverISN + 1, flags: [.psh, .ack], payload: framed.dropFirst(5)))
        #expect(second.queries.count == 1)
    }

    @Test("two queries in one segment are both answered, in either order, each contiguous")
    func pipelined() throws {
        let server = makeServer()
        let next = connect(server)
        let q1 = TestDNS.query("one.example", txID: 1), q2 = TestDNS.query("two.example", txID: 2)
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.psh, .ack], payload: DNSTCPFraming.frame(q1) + DNSTCPFraming.frame(q2)))
        #expect(out.queries.map(\.message) == [q1, q2])
        let r2 = parse(server.respond(to: out.queries[1].key, with: TestDNS.response(to: q2)))
        let r1 = parse(server.respond(to: out.queries[0].key, with: TestDNS.response(to: q1)))
        #expect(r2[0].seq == serverISN + 1)
        #expect(r1[0].seq == r2[0].seq + UInt32(r2[0].payload.count))
    }

    @Test("old and out-of-order data is acknowledged but never handed out")
    func oldAndFuture() throws {
        let server = makeServer()
        let next = connect(server)
        let framed = DNSTCPFraming.frame(TestDNS.query("a.example"))
        _ = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: framed))
        let dup = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: framed))
        #expect(dup.queries.isEmpty)
        #expect(parse(dup.packets).first?.ack == next + UInt32(framed.count))
        let future = server.receive(segment(seq: next + 10_000, ack: serverISN + 1, flags: [.ack], payload: framed))
        #expect(future.queries.isEmpty)
        #expect(parse(future.packets).first?.ack == next + UInt32(framed.count))
    }

    @Test("a FIN after the answer is acknowledged and closed in one segment")
    func finAfterAnswer() throws {
        let server = makeServer()
        let next = connect(server)
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: DNSTCPFraming.frame(TestDNS.query("a.example"))))
        _ = server.respond(to: out.queries[0].key, with: TestDNS.response(to: TestDNS.query("a.example")))
        let fin = server.receive(segment(seq: next + UInt32(DNSTCPFraming.frame(TestDNS.query("a.example")).count), ack: 0, flags: [.fin, .ack]))
        let reply = try #require(parse(fin.packets).first)
        #expect(reply.flags == [.fin, .ack])
        #expect(server.connectionCount == 0)
    }

    @Test("a FIN while an answer is pending is acknowledged now and the answer still goes out before our FIN")
    func finWhilePending() throws {
        let server = makeServer()
        let next = connect(server)
        let query = TestDNS.query("a.example")
        let framed = DNSTCPFraming.frame(query)
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: framed))
        let fin = server.receive(segment(seq: next + UInt32(framed.count), flags: [.fin, .ack]))
        #expect(parse(fin.packets).map(\.flags) == [[.ack]])
        #expect(server.connectionCount == 1)
        let sent = parse(server.respond(to: out.queries[0].key, with: TestDNS.response(to: query)))
        #expect(sent.map(\.flags) == [[.psh, .ack], [.fin, .ack]])
        #expect(server.connectionCount == 0)
    }

    @Test("a segment for an unknown connection is reset, not ignored")
    func unknownConnection() throws {
        let server = makeServer()
        let out = server.receive(segment(seq: 77, ack: 4242, flags: [.psh, .ack], payload: Data([1, 2])))
        let rst = try #require(parse(out.packets).first)
        #expect(rst.flags == [.rst])
        #expect(rst.seq == 4242)
    }

    @Test("a segment to any port other than 53 is reset")
    func otherPort() throws {
        let server = makeServer()
        let out = server.receive(segment(dstPort: 853, seq: 1, flags: [.syn]))
        #expect(parse(out.packets).first?.flags.contains(.rst) == true)
        #expect(server.connectionCount == 0)
    }

    @Test("a client RST closes the connection quietly")
    func clientReset() {
        let server = makeServer()
        let next = connect(server)
        let out = server.receive(segment(seq: next, flags: [.rst]))
        #expect(out.packets.isEmpty && out.queries.isEmpty)
        #expect(server.connectionCount == 0)
    }

    @Test("a zero-length frame is a protocol error: reset and close")
    func badFrame() throws {
        let server = makeServer()
        let next = connect(server)
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: Data([0, 0])))
        #expect(parse(out.packets).contains { $0.flags.contains(.rst) })
        #expect(server.connectionCount == 0)
    }

    @Test("a connection idle past the timeout is dropped when the next segment arrives, with no timer")
    func idleEviction() throws {
        let clock = ManualDNSClock()
        let server = makeServer(clock: clock)
        connect(server, port: 50001)
        clock.advance(by: 31)
        _ = server.receive(segment(port: 50002, seq: clientISN, flags: [.syn]))
        #expect(server.connectionCount == 1)
        #expect(clock.sleeperCount == 0)
        let late = server.receive(segment(port: 50001, seq: 1001, ack: serverISN + 1, flags: [.ack], payload: Data([0, 1, 9])))
        #expect(parse(late.packets).first?.flags == [.rst])
    }

    @Test("past the connection cap, the oldest connection is reset to make room")
    func cap() throws {
        let clock = ManualDNSClock()
        let server = makeServer(clock: clock, maxConnections: 2)
        _ = server.receive(segment(port: 1, seq: 1, flags: [.syn])); clock.advance(by: 1)
        _ = server.receive(segment(port: 2, seq: 1, flags: [.syn])); clock.advance(by: 1)
        let out = server.receive(segment(port: 3, seq: 1, flags: [.syn]))
        let segs = parse(out.packets)
        #expect(segs.contains { $0.flags == [.rst] && $0.dstPort == 1 })
        #expect(segs.contains { $0.flags == [.syn, .ack] && $0.dstPort == 3 })
        #expect(server.connectionCount == 2)
    }

    @Test("an answer for a connection that has gone is dropped")
    func answerForGoneConnection() throws {
        let server = makeServer()
        let next = connect(server)
        let query = TestDNS.query("a.example")
        let out = server.receive(segment(seq: next, ack: serverISN + 1, flags: [.ack], payload: DNSTCPFraming.frame(query)))
        _ = server.receive(segment(seq: next + 1, flags: [.rst]))
        #expect(server.respond(to: out.queries[0].key, with: TestDNS.response(to: query)).isEmpty)
    }
}
