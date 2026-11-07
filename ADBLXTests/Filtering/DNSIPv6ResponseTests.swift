import Testing
import Foundation
@testable import ADBLX

/// The parser keeps an IPv6 address as two big-endian numbers; the response builders must write
/// it back as the same 16 bytes, in the same order, and checksum them that way.
@Suite("IPv6 DNS responses")
struct DNSIPv6ResponseTests {
    private let clientAddress: [UInt8] = [0xFD, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x02]
    private let serverAddress: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x53]

    private func queryPacket(_ dns: Data) -> Data {
        let udpLen = 8 + dns.count
        var p = Data(count: 40 + udpLen)
        p[0] = 0x60
        p[4] = UInt8(udpLen >> 8); p[5] = UInt8(udpLen & 0xFF)
        p[6] = 17; p[7] = 64
        p.replaceSubrange(8..<24, with: clientAddress)
        p.replaceSubrange(24..<40, with: serverAddress)
        p[40] = 0xD4; p[41] = 0x31; p[42] = 0; p[43] = 53
        p[44] = UInt8(udpLen >> 8); p[45] = UInt8(udpLen & 0xFF)
        p.replaceSubrange(48..<p.count, with: dns)
        return p
    }

    private func parsed(_ packet: Data) -> ParsedDNSQuery {
        packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
    }

    /// RFC 8200 section 8.1, written here independently of InternetChecksum.
    private func udpChecksumVerifies(_ packet: Data) -> Bool {
        let p = [UInt8](packet)
        let udp = Array(p[40...])
        var bytes = Array(p[8..<40])
        bytes += [0, 0, UInt8(udp.count >> 8), UInt8(udp.count & 0xFF), 0, 0, 0, 17]
        bytes += udp
        if bytes.count % 2 == 1 { bytes.append(0) }
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 2) { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]) }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return sum == 0xFFFF
    }

    @Test("the parser reads the addresses most-significant byte first")
    func parserOrder() {
        let q = parsed(queryPacket(TestDNS.query("example.com")))
        #expect(q.srcIPv6.0 == 0xFD00_0000_0000_0000 && q.srcIPv6.1 == 0x0000_0000_0000_0002)
        #expect(q.dstIPv6.0 == 0x2001_0DB8_0000_0000 && q.dstIPv6.1 == 0x0000_0000_0000_0053)
    }

    @Test("an NXDOMAIN reply is from the address that was asked, to the client, with a valid checksum")
    func nxdomain() throws {
        let packet = queryPacket(TestDNS.query("blocked.example"))
        let reply = try #require(packet.withUnsafeBytes {
            NXDOMAINResponseBuilder.buildResponse(for: parsed(packet), originalPacket: $0.bindMemory(to: UInt8.self))
        })
        #expect(Array(reply[8..<24]) == serverAddress)
        #expect(Array(reply[24..<40]) == clientAddress)
        #expect(udpChecksumVerifies(reply))
    }

    @Test("a forwarded answer is from the address that was asked, to the client, with a valid checksum")
    func forwarded() async throws {
        let sink = PacketSink()
        let dns = TestDNS.query("fine.example")
        let v4 = ScriptedUpstreamSocket { TestDNS.response(to: $0, answerBytes: 12) }
        let v6 = ScriptedUpstreamSocket(senderIP: "2620:fe::fe") { TestDNS.response(to: $0, answerBytes: 12) }
        let fwd = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: "2620:fe::fe", timeoutSeconds: 2, maxInFlightQueries: 8),
            socketFactory: { _, _, isIPv6 in isIPv6 ? v6 : v4 }, clock: ManualDNSClock(), tcpTransport: nil
        )
        try await fwd.start { packet, _ in sink.append(packet) }
        let packet = queryPacket(dns)
        _ = await fwd.forward(query: parsed(packet), originalPacket: packet)
        await sink.waitForCount(1)
        let reply = sink.packets[0]
        #expect(Array(reply[8..<24]) == serverAddress)
        #expect(Array(reply[24..<40]) == clientAddress)
        #expect(udpChecksumVerifies(reply))
    }
}
