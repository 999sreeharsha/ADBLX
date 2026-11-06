import Foundation

public struct TCPFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let fin = TCPFlags(rawValue: 0x01)
    public static let syn = TCPFlags(rawValue: 0x02)
    public static let rst = TCPFlags(rawValue: 0x04)
    public static let psh = TCPFlags(rawValue: 0x08)
    public static let ack = TCPFlags(rawValue: 0x10)
}

public struct ParsedTCPSegment: Equatable, Sendable {
    public let srcIP: UInt32
    public let dstIP: UInt32
    public let srcPort: UInt16
    public let dstPort: UInt16
    public let seq: UInt32
    public let ack: UInt32
    public let flags: TCPFlags
    public let payload: Data
}

/// IPv4 TCP only: the tunnel's one DNS address is IPv4, so no IPv6 packet is routed to it.
public enum TCPSegmentParser {
    public static func parseIPv4(_ packet: Data) -> ParsedTCPSegment? {
        let p = [UInt8](packet)
        guard p.count >= 40, p[0] >> 4 == 4 else { return nil }
        let ihl = Int(p[0] & 0x0F) * 4
        let total = Int(p[2]) << 8 | Int(p[3])
        guard ihl >= 20, total <= p.count, total >= ihl + 20 else { return nil }
        guard (UInt16(p[6]) << 8 | UInt16(p[7])) & 0x3FFF == 0 else { return nil }   // fragmented
        guard p[9] == 6 else { return nil }
        let offset = Int(p[ihl + 12] >> 4) * 4
        guard offset >= 20, ihl + offset <= total else { return nil }
        func u32(_ i: Int) -> UInt32 { UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3]) }
        func u16(_ i: Int) -> UInt16 { UInt16(p[i]) << 8 | UInt16(p[i + 1]) }
        return ParsedTCPSegment(
            srcIP: u32(12), dstIP: u32(16),
            srcPort: u16(ihl), dstPort: u16(ihl + 2),
            seq: u32(ihl + 4), ack: u32(ihl + 8),
            flags: TCPFlags(rawValue: p[ihl + 13] & 0x1F),
            payload: Data(p[(ihl + offset)..<total])
        )
    }
}

public enum TCPSegmentBuilder {
    /// A complete IPv4 packet: 20-byte IP header, 20-byte TCP header (no options), payload.
    public static func buildIPv4(
        srcIP: UInt32, dstIP: UInt32, srcPort: UInt16, dstPort: UInt16,
        seq: UInt32, ack: UInt32, flags: TCPFlags, payload: Data
    ) -> Data {
        let tcpLength = 20 + payload.count
        let total = 20 + tcpLength
        var p = [UInt8](repeating: 0, count: total)
        p[0] = 0x45
        p[2] = UInt8(total >> 8); p[3] = UInt8(total & 0xFF)
        p[6] = 0x40                       // don't fragment
        p[8] = 64; p[9] = 6
        for i in 0..<4 {
            p[12 + i] = UInt8((srcIP >> UInt32(24 - 8 * i)) & 0xFF)
            p[16 + i] = UInt8((dstIP >> UInt32(24 - 8 * i)) & 0xFF)
        }
        let ipSum = p.withUnsafeBufferPointer { InternetChecksum.computeIPv4HeaderChecksum(headerBuffer: UnsafeBufferPointer(rebasing: $0[0..<20])) }
        p[10] = UInt8(ipSum >> 8); p[11] = UInt8(ipSum & 0xFF)

        p[20] = UInt8(srcPort >> 8); p[21] = UInt8(srcPort & 0xFF)
        p[22] = UInt8(dstPort >> 8); p[23] = UInt8(dstPort & 0xFF)
        for i in 0..<4 {
            p[24 + i] = UInt8((seq >> UInt32(24 - 8 * i)) & 0xFF)
            p[28 + i] = UInt8((ack >> UInt32(24 - 8 * i)) & 0xFF)
        }
        p[32] = 5 << 4
        p[33] = flags.rawValue
        p[34] = 0xFF; p[35] = 0xFF        // window 65535
        for (i, byte) in payload.enumerated() { p[40 + i] = byte }
        let tcpSum = p.withUnsafeBufferPointer {
            InternetChecksum.computeTCPChecksumIPv4(srcIP: srcIP, dstIP: dstIP, tcpSegment: UnsafeBufferPointer(rebasing: $0[20..<total]))
        }
        p[36] = UInt8(tcpSum >> 8); p[37] = UInt8(tcpSum & 0xFF)
        return Data(p)
    }
}

/// What the tunnel's read loop makes of one packet.
public enum TunnelPacket {
    case udpQuery(ParsedDNSQuery)
    case tcp(ParsedTCPSegment)
    /// Not something we can answer; counted, never silently the only record.
    case unparsable
}

public enum TunnelPacketClassifier {
    public static func classify(_ packet: Data) -> TunnelPacket {
        guard packet.count >= 20 else { return .unparsable }
        let version = packet[packet.startIndex] >> 4
        if version == 4, packet[packet.startIndex + 9] == 6 {
            return TCPSegmentParser.parseIPv4(packet).map(TunnelPacket.tcp) ?? .unparsable
        }
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }
        return query.map(TunnelPacket.udpQuery) ?? .unparsable
    }
}
