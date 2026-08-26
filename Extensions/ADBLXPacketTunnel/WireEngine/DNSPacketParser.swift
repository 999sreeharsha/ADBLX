import Foundation

public enum DNSPacketParser {
    
    /// Parses an incoming raw IP packet (IPv4 or IPv6) and extracts DNS query details.
    ///
    /// Returns `nil` if the packet is malformed, not UDP, not DNS, a non-query, contains compression pointers
    /// in the question section, or exceeds protocol bounds.
    public static func parse(packet: UnsafeBufferPointer<UInt8>) -> ParsedDNSQuery? {
        guard let base = packet.baseAddress, packet.count >= 28 else {
            return nil
        }
        
        let firstByte = base[0]
        let version = firstByte >> 4
        
        if version == 4 {
            return parseIPv4(packet: packet)
        } else if version == 6 {
            return parseIPv6(packet: packet)
        } else {
            return nil
        }
    }
    
    // MARK: - IPv4 Parser
    
    private static func parseIPv4(packet: UnsafeBufferPointer<UInt8>) -> ParsedDNSQuery? {
        guard let base = packet.baseAddress, packet.count >= 28 else { return nil }
        
        let ihl = Int(base[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 20 else { return nil }
        
        let totalLength = (Int(base[2]) << 8) | Int(base[3])
        guard totalLength <= packet.count, totalLength >= ihl + 20 else { return nil }
        
        // Reject fragmented packets (MF flag or fragment offset > 0)
        let flagsAndOffset = (UInt16(base[6]) << 8) | UInt16(base[7])
        if (flagsAndOffset & 0x3FFF) != 0 {
            return nil
        }
        
        // Protocol must be UDP (17)
        let proto = base[9]
        guard proto == 17 else { return nil }
        
        let srcIP = (UInt32(base[12]) << 24) | (UInt32(base[13]) << 16) | (UInt32(base[14]) << 8) | UInt32(base[15])
        let dstIP = (UInt32(base[16]) << 24) | (UInt32(base[17]) << 16) | (UInt32(base[18]) << 8) | UInt32(base[19])
        
        let udpOffset = ihl
        return parseUDPAndDNS(
            packet: packet,
            ipVersion: .v4,
            srcIPv4: srcIP,
            dstIPv4: dstIP,
            srcIPv6: (0, 0),
            dstIPv6: (0, 0),
            ipHeaderLength: ihl,
            udpOffset: udpOffset
        )
    }
    
    // MARK: - IPv6 Parser
    
    private static func parseIPv6(packet: UnsafeBufferPointer<UInt8>) -> ParsedDNSQuery? {
        guard let base = packet.baseAddress, packet.count >= 60 else { return nil }
        
        let payloadLength = (Int(base[4]) << 8) | Int(base[5])
        guard packet.count >= 40 + payloadLength, payloadLength >= 20 else { return nil }
        
        let nextHeader = base[6]
        guard nextHeader == 17 else { return nil } // UDP
        
        let srcIPHigh = (UInt64(base[8]) << 56) | (UInt64(base[9]) << 48) | (UInt64(base[10]) << 40) | (UInt64(base[11]) << 32)
            | (UInt64(base[12]) << 24) | (UInt64(base[13]) << 16) | (UInt64(base[14]) << 8) | UInt64(base[15])
        let srcIPLow = (UInt64(base[16]) << 56) | (UInt64(base[17]) << 48) | (UInt64(base[18]) << 40) | (UInt64(base[19]) << 32)
            | (UInt64(base[20]) << 24) | (UInt64(base[21]) << 16) | (UInt64(base[22]) << 8) | UInt64(base[23])
        
        let dstIPHigh = (UInt64(base[24]) << 56) | (UInt64(base[25]) << 48) | (UInt64(base[26]) << 40) | (UInt64(base[27]) << 32)
            | (UInt64(base[28]) << 24) | (UInt64(base[29]) << 16) | (UInt64(base[30]) << 8) | UInt64(base[31])
        let dstIPLow = (UInt64(base[32]) << 56) | (UInt64(base[33]) << 48) | (UInt64(base[34]) << 40) | (UInt64(base[35]) << 32)
            | (UInt64(base[36]) << 24) | (UInt64(base[37]) << 16) | (UInt64(base[38]) << 8) | UInt64(base[39])
        
        let ipHeaderLength = 40
        let udpOffset = 40
        
        return parseUDPAndDNS(
            packet: packet,
            ipVersion: .v6,
            srcIPv4: 0,
            dstIPv4: 0,
            srcIPv6: (srcIPHigh, srcIPLow),
            dstIPv6: (dstIPHigh, dstIPLow),
            ipHeaderLength: ipHeaderLength,
            udpOffset: udpOffset
        )
    }
    
    // MARK: - UDP & DNS Parser
    
    private static func parseUDPAndDNS(
        packet: UnsafeBufferPointer<UInt8>,
        ipVersion: IPVersion,
        srcIPv4: UInt32,
        dstIPv4: UInt32,
        srcIPv6: (UInt64, UInt64),
        dstIPv6: (UInt64, UInt64),
        ipHeaderLength: Int,
        udpOffset: Int
    ) -> ParsedDNSQuery? {
        guard let base = packet.baseAddress, packet.count >= udpOffset + 8 + 12 else {
            return nil
        }
        
        let srcPort = (UInt16(base[udpOffset]) << 8) | UInt16(base[udpOffset + 1])
        let dstPort = (UInt16(base[udpOffset + 2]) << 8) | UInt16(base[udpOffset + 3])
        let udpLen = (Int(base[udpOffset + 4]) << 8) | Int(base[udpOffset + 5])
        
        guard udpLen >= 20, packet.count >= udpOffset + udpLen else { return nil }
        
        let dnsOffset = udpOffset + 8
        let txID = (UInt16(base[dnsOffset]) << 8) | UInt16(base[dnsOffset + 1])
        let flags = (UInt16(base[dnsOffset + 2]) << 8) | UInt16(base[dnsOffset + 3])
        
        // QR bit must be 0 (Query)
        guard (flags & 0x8000) == 0 else { return nil }
        // Opcode must be 0 (Standard Query)
        guard (flags & 0x7800) == 0 else { return nil }
        
        let qdCount = (UInt16(base[dnsOffset + 4]) << 8) | UInt16(base[dnsOffset + 5])
        guard qdCount >= 1 else { return nil }
        
        // Parse Question Name starting at dnsOffset + 12
        let questionStart = dnsOffset + 12
        var curr = questionStart
        let maxLimit = udpOffset + udpLen
        
        // Fixed inline array of label ranges (max 32 labels)
        var labelOffsets: [Int] = []
        var labelLengths: [Int] = []
        labelOffsets.reserveCapacity(16)
        labelLengths.reserveCapacity(16)
        
        var totalDomainLength = 0
        
        while curr < maxLimit {
            let labelLen = Int(base[curr])
            if labelLen == 0 {
                curr += 1
                break
            }
            
            // Reject compression pointers in question section (RFC 1035)
            if (labelLen & 0xC0) != 0 {
                return nil
            }
            
            if labelLen > 63 {
                return nil
            }
            
            curr += 1
            guard curr + labelLen <= maxLimit else { return nil }
            
            labelOffsets.append(curr)
            labelLengths.append(labelLen)
            totalDomainLength += labelLen + 1
            
            guard totalDomainLength <= 255 else { return nil }
            curr += labelLen
        }
        
        guard labelOffsets.count >= 1 else { return nil }
        
        // Ensure QTYPE and QCLASS are present (4 bytes after null byte)
        guard curr + 4 <= maxLimit else { return nil }
        let qtype = (UInt16(base[curr]) << 8) | UInt16(base[curr + 1])
        let qclass = (UInt16(base[curr + 2]) << 8) | UInt16(base[curr + 3])
        curr += 4
        
        let questionLength = curr - questionStart
        
        // Build reversed-label buffer (e.g. net.doubleclick.ad)
        var reversedBuf = InlineReversedDomainBuffer()
        for idx in stride(from: labelOffsets.count - 1, through: 0, by: -1) {
            let start = labelOffsets[idx]
            let len = labelLengths[idx]
            
            for j in 0..<len {
                var byte = base[start + j]
                // Canonical lowercase
                if byte >= 65 && byte <= 90 {
                    byte += 32
                }
                guard reversedBuf.append(byte: byte) else { return nil }
            }
            
            if idx > 0 {
                guard reversedBuf.append(byte: 46 /* '.' */) else { return nil }
            }
        }
        
        return ParsedDNSQuery(
            ipVersion: ipVersion,
            srcIPv4: srcIPv4,
            dstIPv4: dstIPv4,
            srcIPv6: srcIPv6,
            dstIPv6: dstIPv6,
            srcPort: srcPort,
            dstPort: dstPort,
            ipHeaderLength: ipHeaderLength,
            udpHeaderOffset: udpOffset,
            dnsHeaderOffset: dnsOffset,
            questionOffset: questionStart,
            questionLength: questionLength,
            transactionID: txID,
            flags: flags,
            questionCount: qdCount,
            qtype: qtype,
            qclass: qclass,
            reversedDomain: reversedBuf
        )
    }
}
