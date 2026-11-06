import Testing
import Foundation
@testable import ADBLX

@Suite("DNS message helpers")
struct DNSMessageTests {
    @Test("a SERVFAIL keeps the id, the question and the recursion-desired bit")
    func servfail() throws {
        let q = TestDNS.query("example.com", txID: 0xBEEF)
        let r = try #require(DNSMessage.errorResponse(for: q, rcode: 2))
        #expect(TestDNS.txID(r) == 0xBEEF)
        #expect(r[2] == 0x81)           // QR=1, RD=1
        #expect(r[3] == 0x82)           // RA=1, RCODE=2
        #expect(r.subdata(in: 4..<12) == Data([0, 1, 0, 0, 0, 0, 0, 0]))
        #expect(r.subdata(in: 12..<r.count) == TestDNS.question(of: q))
    }

    @Test("an error response drops the client's EDNS record")
    func dropsOPT() throws {
        let q = TestDNS.query("example.com", udpSize: 1232)
        let r = try #require(DNSMessage.errorResponse(for: q, rcode: 3))
        #expect(TestDNS.rcode(r) == 3)
        #expect(r.count == 12 + TestDNS.question(of: q).count)
        #expect(r[11] == 0)
    }

    @Test("something shorter than a DNS header gets no response")
    func tooShort() {
        #expect(DNSMessage.errorResponse(for: Data([1, 2, 3]), rcode: 2) == nil)
        #expect(DNSMessage.errorResponse(for: Data(repeating: 0, count: 12), rcode: 2) == nil)
    }

    @Test("truncating keeps the header and question, sets TC and clears the answers")
    func truncate() {
        let q = TestDNS.query("example.com")
        let full = TestDNS.response(to: q, answerBytes: 900)
        let t = DNSMessage.truncated(full)
        #expect(TestDNS.isTruncated(t))
        #expect(TestDNS.answerCount(t) == 0)
        #expect(TestDNS.txID(t) == TestDNS.txID(q))
        #expect(t.count == 12 + TestDNS.question(of: q).count)
    }

    @Test("isTruncated reads the TC bit")
    func tcBit() {
        let q = TestDNS.query("example.com")
        #expect(DNSMessage.isTruncated(TestDNS.response(to: q, truncated: true)))
        #expect(!DNSMessage.isTruncated(TestDNS.response(to: q)))
    }

    @Test("the client's UDP limit is 512 without EDNS, its advertised size with it, capped at 1232")
    func udpLimit() {
        #expect(DNSMessage.clientUDPLimit(of: TestDNS.query("a.example")) == 512)
        #expect(DNSMessage.clientUDPLimit(of: TestDNS.query("a.example", udpSize: 1232)) == 1232)
        #expect(DNSMessage.clientUDPLimit(of: TestDNS.query("a.example", udpSize: 4096)) == 1232)
        #expect(DNSMessage.clientUDPLimit(of: TestDNS.query("a.example", udpSize: 100)) == 512)
    }

    @Test("the reversed lowercase domain comes from a bare DNS payload")
    func reversedDomain() throws {
        let q = TestDNS.query("Ads.Example.COM")
        let reversed = try #require(DNSMessage.reversedDomain(of: q))
        let s = reversed.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
        #expect(s == "com.example.ads")
        #expect(DNSMessage.reversedDomain(of: Data([0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1])) == nil)
    }
}

@Suite("DNS over TCP framing")
struct DNSTCPFramingTests {
    @Test("a message is prefixed with its big-endian length")
    func frame() {
        let m = Data(repeating: 7, count: 300)
        let f = DNSTCPFraming.frame(m)
        #expect(Array(f.prefix(2)) == [0x01, 0x2C])
        #expect(f.dropFirst(2) == m)
    }

    @Test("two messages in one chunk come out as two")
    func twoInOne() throws {
        var r = DNSTCPFrameReader()
        let appended = r.append(DNSTCPFraming.frame(Data([1, 2, 3])) + DNSTCPFraming.frame(Data([4, 5])))
        let out = try #require(appended)
        #expect(out == [Data([1, 2, 3]), Data([4, 5])])
    }

    @Test("a message split across chunks, even inside the length, is reassembled")
    func splitAcrossChunks() throws {
        var r = DNSTCPFrameReader()
        let wire = DNSTCPFraming.frame(Data(repeating: 9, count: 20))
        let first = r.append(wire.prefix(1))
        let second = r.append(wire.subdata(in: 1..<10))
        let last = r.append(wire.subdata(in: 10..<wire.count))
        #expect(try #require(first).isEmpty)
        #expect(try #require(second).isEmpty)
        let out = try #require(last)
        #expect(out == [Data(repeating: 9, count: 20)])
    }

    @Test("a zero length is a protocol error")
    func zeroLength() {
        var r = DNSTCPFrameReader()
        let result = r.append(Data([0, 0]))
        #expect(result == nil)
    }
}

@Suite("TCP segments")
struct TCPSegmentTests {
    // Built with an independent script (RFC 1071 checksums), not with TCPSegmentBuilder.
    private let synAck: [UInt8] = [
        0x45, 0x00, 0x00, 0x28, 0x00, 0x00, 0x40, 0x00, 0x40, 0x06, 0x4e, 0x99, 0xc6, 0x33, 0x64, 0x01,
        0xc0, 0x00, 0x02, 0x02, 0x00, 0x35, 0xc3, 0x50, 0x00, 0x00, 0x13, 0x88, 0x00, 0x00, 0x03, 0xe9,
        0x50, 0x12, 0xff, 0xff, 0xe8, 0xa4, 0x00, 0x00
    ]
    private let dataPsh: [UInt8] = [
        0x45, 0x00, 0x00, 0x2d, 0x00, 0x00, 0x40, 0x00, 0x40, 0x06, 0x4e, 0x94, 0xc0, 0x00, 0x02, 0x02,
        0xc6, 0x33, 0x64, 0x01, 0xc3, 0x50, 0x00, 0x35, 0x00, 0x00, 0x03, 0xe9, 0x00, 0x00, 0x13, 0x89,
        0x50, 0x18, 0xff, 0xff, 0x24, 0x33, 0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63
    ]

    @Test("the builder produces the reference SYN-ACK byte for byte")
    func buildsSynAck() {
        let p = TCPSegmentBuilder.buildIPv4(
            srcIP: 0xC633_6401, dstIP: 0xC000_0202, srcPort: 53, dstPort: 50000,
            seq: 5000, ack: 1001, flags: [.syn, .ack], payload: Data()
        )
        #expect(Array(p) == synAck)
    }

    @Test("the builder produces the reference data segment byte for byte")
    func buildsData() {
        let p = TCPSegmentBuilder.buildIPv4(
            srcIP: 0xC000_0202, dstIP: 0xC633_6401, srcPort: 50000, dstPort: 53,
            seq: 1001, ack: 5001, flags: [.psh, .ack], payload: Data([0, 3, 0x61, 0x62, 0x63])
        )
        #expect(Array(p) == dataPsh)
    }

    @Test("the parser reads every field of the reference data segment")
    func parses() throws {
        let s = try #require(TCPSegmentParser.parseIPv4(Data(dataPsh)))
        #expect(s.srcIP == 0xC000_0202)
        #expect(s.dstIP == 0xC633_6401)
        #expect(s.srcPort == 50000)
        #expect(s.dstPort == 53)
        #expect(s.seq == 1001)
        #expect(s.ack == 5001)
        #expect(s.flags == [.psh, .ack])
        #expect(s.payload == Data([0, 3, 0x61, 0x62, 0x63]))
    }

    @Test("a segment with TCP options still yields its payload")
    func options() throws {
        var p = Data(dataPsh)
        // Rebuild with a 4-byte MSS option: header length 6 words.
        let payload = p.suffix(5)
        p = Data(p.prefix(20)) + Data(p[20..<32]) + Data([0x60, 0x18, 0xff, 0xff, 0, 0, 0, 0, 0x02, 0x04, 0x05, 0xb4]) + payload
        p[2] = 0; p[3] = UInt8(p.count)
        let s = try #require(TCPSegmentParser.parseIPv4(p))
        #expect(s.payload == Data(payload))
    }

    @Test("truncated, fragmented and non-TCP packets are not segments")
    func rejects() {
        #expect(TCPSegmentParser.parseIPv4(Data(dataPsh.prefix(30))) == nil)
        var fragmented = Data(dataPsh); fragmented[6] = 0x20
        #expect(TCPSegmentParser.parseIPv4(fragmented) == nil)
        var udp = Data(dataPsh); udp[9] = 17
        #expect(TCPSegmentParser.parseIPv4(udp) == nil)
    }
}

@Suite("Tunnel packet classification")
struct TunnelPacketClassifierTests {
    @Test("a TCP packet to the DNS server is a TCP segment to answer, not a packet to drop")
    func tcpIsAccepted() {
        // Was DNSWireParserTests' "Non-UDP protocol (e.g. TCP = 6)" case, which asserted that
        // TCP is rejected. Rejecting it left clients hanging after a truncated UDP answer.
        let syn = TCPSegmentBuilder.buildIPv4(
            srcIP: 0xC000_0202, dstIP: 0xC633_6401, srcPort: 50000, dstPort: 53,
            seq: 1000, ack: 0, flags: [.syn], payload: Data()
        )
        guard case .tcp(let segment) = TunnelPacketClassifier.classify(syn) else {
            Issue.record("TCP packet was not classified as TCP"); return
        }
        #expect(segment.flags == [.syn])
    }

    @Test("a UDP query is classified as a query")
    func udp() {
        let packet = TestDNS.udpPacket(dns: TestDNS.query("example.com"))
        guard case .udpQuery(let q) = TunnelPacketClassifier.classify(packet) else {
            Issue.record("UDP packet was not classified as a query"); return
        }
        #expect(q.srcPort == 54321)
    }

    @Test("anything else is reported as unparsable so it can be counted")
    func other() {
        var icmp = TestDNS.udpPacket(dns: TestDNS.query("example.com")); icmp[9] = 1
        guard case .unparsable = TunnelPacketClassifier.classify(icmp) else {
            Issue.record("ICMP was not unparsable"); return
        }
        guard case .unparsable = TunnelPacketClassifier.classify(Data([1, 2, 3])) else {
            Issue.record("garbage was not unparsable"); return
        }
    }
}
