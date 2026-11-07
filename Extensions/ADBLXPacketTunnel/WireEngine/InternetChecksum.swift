import Foundation

public enum InternetChecksum {
    /// Computes the 16-bit one's complement internet checksum over a byte buffer.
    public static func computeChecksum(buffer: UnsafeBufferPointer<UInt8>) -> UInt16 {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        
        var sum: UInt32 = 0
        var idx = 0
        let count = buffer.count
        
        while idx + 1 < count {
            let word = (UInt32(base[idx]) << 8) | UInt32(base[idx + 1])
            sum &+= word
            idx += 2
        }
        
        if idx < count {
            sum &+= (UInt32(base[idx]) << 8)
        }
        
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        
        let checksum = ~UInt16(sum & 0xFFFF)
        return checksum == 0 ? 0xFFFF : checksum
    }
    
    /// Computes IPv4 header checksum.
    public static func computeIPv4HeaderChecksum(headerBuffer: UnsafeBufferPointer<UInt8>) -> UInt16 {
        return computeChecksum(buffer: headerBuffer)
    }
    
    /// Computes UDP checksum over IPv4 pseudo-header, UDP header, and DNS payload.
    public static func computeUDPChecksumIPv4(
        srcIP: UInt32,
        dstIP: UInt32,
        udpPacket: UnsafeBufferPointer<UInt8>
    ) -> UInt16 {
        guard let udpBase = udpPacket.baseAddress, udpPacket.count >= 8 else { return 0 }
        
        var sum: UInt32 = 0
        
        // Pseudo-header:
        // Src IP (4 bytes)
        sum &+= (srcIP >> 16) & 0xFFFF
        sum &+= srcIP & 0xFFFF
        // Dst IP (4 bytes)
        sum &+= (dstIP >> 16) & 0xFFFF
        sum &+= dstIP & 0xFFFF
        // Zero (1 byte) + Protocol (1 byte = 17)
        sum &+= 17
        // UDP length (2 bytes)
        sum &+= UInt32(udpPacket.count)
        
        // UDP header + payload (with checksum field treated as 0)
        var idx = 0
        let count = udpPacket.count
        
        while idx + 1 < count {
            if idx == 6 {
                // Checksum field in UDP header: skip (treat as 0)
                idx += 2
                continue
            }
            let word = (UInt32(udpBase[idx]) << 8) | UInt32(udpBase[idx + 1])
            sum &+= word
            idx += 2
        }
        
        if idx < count {
            sum &+= (UInt32(udpBase[idx]) << 8)
        }
        
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        
        let checksum = ~UInt16(sum & 0xFFFF)
        return checksum == 0 ? 0xFFFF : checksum
    }
    
    /// Computes UDP checksum over IPv6 pseudo-header, UDP header, and DNS payload.
    public static func computeUDPChecksumIPv6(
        srcIP: (UInt64, UInt64),
        dstIP: (UInt64, UInt64),
        udpPacket: UnsafeBufferPointer<UInt8>
    ) -> UInt16 {
        guard let udpBase = udpPacket.baseAddress, udpPacket.count >= 8 else { return 0 }
        
        var sum: UInt32 = 0
        
        // IPv6 Pseudo-header:
        // Src IP (16 bytes = 8 16-bit words)
        let srcBytes = IPv6Bytes.make(srcIP)
        for i in stride(from: 0, to: 16, by: 2) {
            sum &+= (UInt32(srcBytes[i]) << 8) | UInt32(srcBytes[i + 1])
        }
        // Dst IP (16 bytes = 8 16-bit words)
        let dstBytes = IPv6Bytes.make(dstIP)
        for i in stride(from: 0, to: 16, by: 2) {
            sum &+= (UInt32(dstBytes[i]) << 8) | UInt32(dstBytes[i + 1])
        }
        // Upper-Layer Packet Length (4 bytes)
        sum &+= (UInt32(udpPacket.count) >> 16) & 0xFFFF
        sum &+= UInt32(udpPacket.count) & 0xFFFF
        // Next Header (4 bytes: 3 zero bytes + 17)
        sum &+= 17
        
        // UDP header + payload
        var idx = 0
        let count = udpPacket.count
        
        while idx + 1 < count {
            if idx == 6 {
                // Checksum field in UDP header: skip (treat as 0)
                idx += 2
                continue
            }
            let word = (UInt32(udpBase[idx]) << 8) | UInt32(udpBase[idx + 1])
            sum &+= word
            idx += 2
        }
        
        if idx < count {
            sum &+= (UInt32(udpBase[idx]) << 8)
        }
        
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        
        let checksum = ~UInt16(sum & 0xFFFF)
        return checksum == 0 ? 0xFFFF : checksum
    }

    /// Computes the TCP checksum over an IPv4 pseudo-header and the TCP segment (header + payload).
    public static func computeTCPChecksumIPv4(
        srcIP: UInt32,
        dstIP: UInt32,
        tcpSegment: UnsafeBufferPointer<UInt8>
    ) -> UInt16 {
        guard let base = tcpSegment.baseAddress, tcpSegment.count >= 20 else { return 0 }
        var sum: UInt32 = 0
        sum &+= (srcIP >> 16) & 0xFFFF
        sum &+= srcIP & 0xFFFF
        sum &+= (dstIP >> 16) & 0xFFFF
        sum &+= dstIP & 0xFFFF
        sum &+= 6
        sum &+= UInt32(tcpSegment.count)

        var idx = 0
        let count = tcpSegment.count
        while idx + 1 < count {
            if idx == 16 { idx += 2; continue }   // the checksum field counts as zero
            sum &+= (UInt32(base[idx]) << 8) | UInt32(base[idx + 1])
            idx += 2
        }
        if idx < count { sum &+= UInt32(base[idx]) << 8 }
        while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        let checksum = ~UInt16(sum & 0xFFFF)
        return checksum == 0 ? 0xFFFF : checksum
    }
}
