import Foundation

public enum NXDOMAINResponseBuilder {
    
    /// Constructs a valid IPv4 or IPv6 DNS NXDOMAIN response packet for a blocked query.
    ///
    /// - Parameters:
    ///   - query: The parsed DNS query information.
    ///   - originalPacket: The incoming raw IP packet.
    /// - Returns: Complete synthesized response packet with swapped endpoints and valid checksums.
    public static func buildResponse(
        for query: ParsedDNSQuery,
        originalPacket: UnsafeBufferPointer<UInt8>,
        rcode: UInt8 = 3 // 3 = NXDOMAIN, 2 = SERVFAIL
    ) -> Data? {
        guard let origBase = originalPacket.baseAddress,
              query.questionOffset + query.questionLength <= originalPacket.count else {
            return nil
        }
        
        let dnsPayloadLen = 12 + query.questionLength
        let udpLen = 8 + dnsPayloadLen
        
        var packetData: Data
        
        switch query.ipVersion {
        case .v4:
            let ipHeaderLen = 20
            let totalLen = ipHeaderLen + udpLen
            packetData = Data(count: totalLen)
            
            packetData.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                
                // 1. IPv4 Header
                base[0] = 0x45 // Version 4, IHL 5 (20 bytes)
                base[1] = 0x00 // DSCP / ECN
                base[2] = UInt8((totalLen >> 8) & 0xFF)
                base[3] = UInt8(totalLen & 0xFF)
                base[4] = 0x00 // ID
                base[5] = 0x00
                base[6] = 0x40 // Don't Fragment (DF)
                base[7] = 0x00
                base[8] = 64   // TTL
                base[9] = 17   // Protocol: UDP
                base[10] = 0x00 // Checksum (init 0)
                base[11] = 0x00
                
                // Swapped IP Addresses: Src = query.dstIPv4, Dst = query.srcIPv4
                let srcIP = query.dstIPv4
                let dstIP = query.srcIPv4
                
                base[12] = UInt8((srcIP >> 24) & 0xFF)
                base[13] = UInt8((srcIP >> 16) & 0xFF)
                base[14] = UInt8((srcIP >> 8) & 0xFF)
                base[15] = UInt8(srcIP & 0xFF)
                
                base[16] = UInt8((dstIP >> 24) & 0xFF)
                base[17] = UInt8((dstIP >> 16) & 0xFF)
                base[18] = UInt8((dstIP >> 8) & 0xFF)
                base[19] = UInt8(dstIP & 0xFF)
                
                // Compute IPv4 Header Checksum
                let ipHeaderBuf = UnsafeBufferPointer(start: base, count: 20)
                let ipChecksum = InternetChecksum.computeIPv4HeaderChecksum(headerBuffer: ipHeaderBuf)
                base[10] = UInt8((ipChecksum >> 8) & 0xFF)
                base[11] = UInt8(ipChecksum & 0xFF)
                
                // 2. UDP Header
                let udpOffset = 20
                let srcPort = query.dstPort
                let dstPort = query.srcPort
                
                base[udpOffset] = UInt8((srcPort >> 8) & 0xFF)
                base[udpOffset + 1] = UInt8(srcPort & 0xFF)
                base[udpOffset + 2] = UInt8((dstPort >> 8) & 0xFF)
                base[udpOffset + 3] = UInt8(dstPort & 0xFF)
                base[udpOffset + 4] = UInt8((udpLen >> 8) & 0xFF)
                base[udpOffset + 5] = UInt8(udpLen & 0xFF)
                base[udpOffset + 6] = 0x00 // Checksum (init 0)
                base[udpOffset + 7] = 0x00
                
                // 3. DNS Header
                let dnsOffset = udpOffset + 8
                base[dnsOffset] = UInt8((query.transactionID >> 8) & 0xFF)
                base[dnsOffset + 1] = UInt8(query.transactionID & 0xFF)
                
                // Flags: QR=1 (Response), RD preserved, RA=1, RCODE
                var responseFlags: UInt16 = 0x8000 | 0x0080 | UInt16(rcode & 0x0F)
                if (query.flags & 0x0100) != 0 {
                    responseFlags |= 0x0100 // Recursion Desired
                }
                
                base[dnsOffset + 2] = UInt8((responseFlags >> 8) & 0xFF)
                base[dnsOffset + 3] = UInt8(responseFlags & 0xFF)
                
                base[dnsOffset + 4] = 0x00 // QDCOUNT = 1
                base[dnsOffset + 5] = 0x01
                base[dnsOffset + 6] = 0x00 // ANCOUNT = 0
                base[dnsOffset + 7] = 0x00
                base[dnsOffset + 8] = 0x00 // NSCOUNT = 0
                base[dnsOffset + 9] = 0x00
                base[dnsOffset + 10] = 0x00 // ARCOUNT = 0
                base[dnsOffset + 11] = 0x00
                
                // 4. Copy Question Section
                let questionDst = dnsOffset + 12
                for i in 0..<query.questionLength {
                    base[questionDst + i] = origBase[query.questionOffset + i]
                }
                
                // 5. Compute UDP Checksum over IPv4 Pseudo-Header
                let udpBuf = UnsafeBufferPointer(start: base + udpOffset, count: udpLen)
                let udpChecksum = InternetChecksum.computeUDPChecksumIPv4(
                    srcIP: srcIP,
                    dstIP: dstIP,
                    udpPacket: udpBuf
                )
                base[udpOffset + 6] = UInt8((udpChecksum >> 8) & 0xFF)
                base[udpOffset + 7] = UInt8(udpChecksum & 0xFF)
            }
            
        case .v6:
            let ipHeaderLen = 40
            let totalLen = ipHeaderLen + udpLen
            packetData = Data(count: totalLen)
            
            packetData.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                
                // 1. IPv6 Header
                base[0] = 0x60 // Version 6
                base[1] = 0x00
                base[2] = 0x00
                base[3] = 0x00
                base[4] = UInt8((udpLen >> 8) & 0xFF)
                base[5] = UInt8(udpLen & 0xFF)
                base[6] = 17   // Next Header: UDP
                base[7] = 64   // Hop Limit
                
                // Swapped IP Addresses
                let srcIP = query.dstIPv6
                let dstIP = query.srcIPv6
                
                let srcBytes = IPv6Bytes.make(srcIP), dstBytes = IPv6Bytes.make(dstIP)
                for i in 0..<16 {
                    base[8 + i] = srcBytes[i]
                    base[24 + i] = dstBytes[i]
                }
                
                // 2. UDP Header
                let udpOffset = 40
                let srcPort = query.dstPort
                let dstPort = query.srcPort
                
                base[udpOffset] = UInt8((srcPort >> 8) & 0xFF)
                base[udpOffset + 1] = UInt8(srcPort & 0xFF)
                base[udpOffset + 2] = UInt8((dstPort >> 8) & 0xFF)
                base[udpOffset + 3] = UInt8(dstPort & 0xFF)
                base[udpOffset + 4] = UInt8((udpLen >> 8) & 0xFF)
                base[udpOffset + 5] = UInt8(udpLen & 0xFF)
                base[udpOffset + 6] = 0x00 // Checksum (init 0)
                base[udpOffset + 7] = 0x00
                
                // 3. DNS Header
                let dnsOffset = udpOffset + 8
                base[dnsOffset] = UInt8((query.transactionID >> 8) & 0xFF)
                base[dnsOffset + 1] = UInt8(query.transactionID & 0xFF)
                
                var responseFlags: UInt16 = 0x8000 | 0x0080 | UInt16(rcode & 0x0F)
                if (query.flags & 0x0100) != 0 {
                    responseFlags |= 0x0100
                }
                
                base[dnsOffset + 2] = UInt8((responseFlags >> 8) & 0xFF)
                base[dnsOffset + 3] = UInt8(responseFlags & 0xFF)
                
                base[dnsOffset + 4] = 0x00 // QDCOUNT = 1
                base[dnsOffset + 5] = 0x01
                base[dnsOffset + 6] = 0x00 // ANCOUNT = 0
                base[dnsOffset + 7] = 0x00
                base[dnsOffset + 8] = 0x00 // NSCOUNT = 0
                base[dnsOffset + 9] = 0x00
                base[dnsOffset + 10] = 0x00 // ARCOUNT = 0
                base[dnsOffset + 11] = 0x00
                
                // 4. Copy Question Section
                let questionDst = dnsOffset + 12
                for i in 0..<query.questionLength {
                    base[questionDst + i] = origBase[query.questionOffset + i]
                }
                
                // 5. Compute UDP Checksum over IPv6 Pseudo-Header
                let udpBuf = UnsafeBufferPointer(start: base + udpOffset, count: udpLen)
                let udpChecksum = InternetChecksum.computeUDPChecksumIPv6(
                    srcIP: srcIP,
                    dstIP: dstIP,
                    udpPacket: udpBuf
                )
                base[udpOffset + 6] = UInt8((udpChecksum >> 8) & 0xFF)
                base[udpOffset + 7] = UInt8(udpChecksum & 0xFF)
            }
        }
        
        return packetData
    }
}
