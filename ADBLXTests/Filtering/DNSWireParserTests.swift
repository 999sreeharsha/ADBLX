import XCTest
import os
@testable import ADBLX
import ADBLXShared

final class DNSWireParserTests: XCTestCase {
    
    // MARK: - Test Helpers
    
    /// Helper to construct a synthetic IPv4 UDP DNS Query packet
    private func makeIPv4DNSQuery(
        domain: String,
        txID: UInt16 = 0x1234,
        srcIP: UInt32 = 0xC0A80105, // 192.168.1.5
        dstIP: UInt32 = 0x09090909, // 9.9.9.9
        srcPort: UInt16 = 54321,
        dstPort: UInt16 = 53
    ) -> Data {
        let dnsPayload = makeDNSQueryPayload(domain: domain, txID: txID)
        let udpLen = 8 + dnsPayload.count
        let totalLen = 20 + udpLen
        
        var packet = Data(count: totalLen)
        packet.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            // IPv4
            base[0] = 0x45
            base[1] = 0x00
            base[2] = UInt8((totalLen >> 8) & 0xFF)
            base[3] = UInt8(totalLen & 0xFF)
            base[4] = 0xAB
            base[5] = 0xCD
            base[6] = 0x40 // DF
            base[7] = 0x00
            base[8] = 64
            base[9] = 17 // UDP
            base[10] = 0
            base[11] = 0
            base[12] = UInt8((srcIP >> 24) & 0xFF)
            base[13] = UInt8((srcIP >> 16) & 0xFF)
            base[14] = UInt8((srcIP >> 8) & 0xFF)
            base[15] = UInt8(srcIP & 0xFF)
            base[16] = UInt8((dstIP >> 24) & 0xFF)
            base[17] = UInt8((dstIP >> 16) & 0xFF)
            base[18] = UInt8((dstIP >> 8) & 0xFF)
            base[19] = UInt8(dstIP & 0xFF)
            
            let ipCheck = InternetChecksum.computeIPv4HeaderChecksum(headerBuffer: UnsafeBufferPointer(start: base, count: 20))
            base[10] = UInt8((ipCheck >> 8) & 0xFF)
            base[11] = UInt8(ipCheck & 0xFF)
            
            // UDP
            base[20] = UInt8((srcPort >> 8) & 0xFF)
            base[21] = UInt8(srcPort & 0xFF)
            base[22] = UInt8((dstPort >> 8) & 0xFF)
            base[23] = UInt8(dstPort & 0xFF)
            base[24] = UInt8((udpLen >> 8) & 0xFF)
            base[25] = UInt8(udpLen & 0xFF)
            base[26] = 0
            base[27] = 0
            
            // DNS Payload
            for i in 0..<dnsPayload.count {
                base[28 + i] = dnsPayload[i]
            }
            
            let udpCheck = InternetChecksum.computeUDPChecksumIPv4(
                srcIP: srcIP,
                dstIP: dstIP,
                udpPacket: UnsafeBufferPointer(start: base + 20, count: udpLen)
            )
            base[26] = UInt8((udpCheck >> 8) & 0xFF)
            base[27] = UInt8(udpCheck & 0xFF)
        }
        
        return packet
    }
    
    /// Helper to construct a synthetic IPv6 UDP DNS Query packet
    private func makeIPv6DNSQuery(
        domain: String,
        txID: UInt16 = 0x5678,
        srcIP: (UInt64, UInt64) = (0x20010DB800000000, 0x0000000000000001),
        dstIP: (UInt64, UInt64) = (0x262000FE00000000, 0x00000000000000FE),
        srcPort: UInt16 = 51234,
        dstPort: UInt16 = 53
    ) -> Data {
        let dnsPayload = makeDNSQueryPayload(domain: domain, txID: txID)
        let udpLen = 8 + dnsPayload.count
        let totalLen = 40 + udpLen
        
        var packet = Data(count: totalLen)
        packet.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            // IPv6
            base[0] = 0x60
            base[1] = 0x00
            base[2] = 0x00
            base[3] = 0x00
            base[4] = UInt8((udpLen >> 8) & 0xFF)
            base[5] = UInt8(udpLen & 0xFF)
            base[6] = 17 // UDP
            base[7] = 64
            
            withUnsafeBytes(of: srcIP) { rawSrc in
                for i in 0..<16 { base[8 + i] = rawSrc[i] }
            }
            withUnsafeBytes(of: dstIP) { rawDst in
                for i in 0..<16 { base[24 + i] = rawDst[i] }
            }
            
            // UDP
            base[40] = UInt8((srcPort >> 8) & 0xFF)
            base[41] = UInt8(srcPort & 0xFF)
            base[42] = UInt8((dstPort >> 8) & 0xFF)
            base[43] = UInt8(dstPort & 0xFF)
            base[44] = UInt8((udpLen >> 8) & 0xFF)
            base[45] = UInt8(udpLen & 0xFF)
            base[46] = 0
            base[47] = 0
            
            // DNS Payload
            for i in 0..<dnsPayload.count {
                base[48 + i] = dnsPayload[i]
            }
            
            let udpCheck = InternetChecksum.computeUDPChecksumIPv6(
                srcIP: srcIP,
                dstIP: dstIP,
                udpPacket: UnsafeBufferPointer(start: base + 40, count: udpLen)
            )
            base[46] = UInt8((udpCheck >> 8) & 0xFF)
            base[47] = UInt8(udpCheck & 0xFF)
        }
        
        return packet
    }
    
    private func makeDNSQueryPayload(domain: String, txID: UInt16) -> Data {
        var payload = Data()
        // ID
        payload.append(UInt8((txID >> 8) & 0xFF))
        payload.append(UInt8(txID & 0xFF))
        // Flags: Standard query, RD=1 (0x0100)
        payload.append(0x01)
        payload.append(0x00)
        // QDCOUNT = 1
        payload.append(0x00)
        payload.append(0x01)
        // ANCOUNT = 0, NSCOUNT = 0, ARCOUNT = 0
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0])
        
        // QNAME
        let labels = domain.split(separator: ".")
        for label in labels {
            payload.append(UInt8(label.utf8.count))
            payload.append(contentsOf: label.utf8)
        }
        payload.append(0x00) // Root null
        
        // QTYPE = A (1), QCLASS = IN (1)
        payload.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return payload
    }
    
    // MARK: - Parsing Tests
    
    func testParseIPv4DNSQuery() {
        let packet = makeIPv4DNSQuery(domain: "ad.doubleclick.net", txID: 0x4A21)
        
        let query = packet.withUnsafeBytes { raw in
            DNSPacketParser.parse(packet: raw.bindMemory(to: UInt8.self))
        }
        
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.ipVersion, .v4)
        XCTAssertEqual(query?.transactionID, 0x4A21)
        XCTAssertEqual(query?.srcPort, 54321)
        XCTAssertEqual(query?.dstPort, 53)
        XCTAssertEqual(query?.qtype, 1)
        XCTAssertEqual(query?.qclass, 1)
        
        // Verify reversed domain buffer
        query?.reversedDomain.withUnsafeBufferPointer { buf in
            let str = String(bytes: buf, encoding: .utf8)
            XCTAssertEqual(str, "net.doubleclick.ad")
        }
    }
    
    func testParseIPv6DNSQuery() {
        let packet = makeIPv6DNSQuery(domain: "TRACKER.Example.COM", txID: 0x9876)
        
        let query = packet.withUnsafeBytes { raw in
            DNSPacketParser.parse(packet: raw.bindMemory(to: UInt8.self))
        }
        
        XCTAssertNotNil(query)
        XCTAssertEqual(query?.ipVersion, .v6)
        XCTAssertEqual(query?.transactionID, 0x9876)
        XCTAssertEqual(query?.srcPort, 51234)
        XCTAssertEqual(query?.dstPort, 53)
        
        // Canonical lowercase label reversal
        query?.reversedDomain.withUnsafeBufferPointer { buf in
            let str = String(bytes: buf, encoding: .utf8)
            XCTAssertEqual(str, "com.example.tracker")
        }
    }
    
    func testMalformedAndTruncatedPacketsRejected() {
        // 1. Truncated packet (< 28 bytes)
        var packet = makeIPv4DNSQuery(domain: "example.com")
        let truncated = packet.subdata(in: 0..<20)
        let q1 = truncated.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }
        XCTAssertNil(q1)
        
        // 2. The UDP parser takes only UDP. TCP is no longer *rejected* by the tunnel: it goes to the
        //    TCP path (TunnelPacketClassifierTests.tcpIsAccepted), where it used to be dropped silently.
        packet[9] = 6
        let q2 = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }
        XCTAssertNil(q2)
        
        // 3. QR bit = 1 (Response packet)
        var responsePacket = makeIPv4DNSQuery(domain: "example.com")
        responsePacket[28 + 2] = 0x81 // QR = 1
        let q3 = responsePacket.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }
        XCTAssertNil(q3)
        
        // 4. Compression pointer in question section (0xC0)
        var compPacket = makeIPv4DNSQuery(domain: "example.com")
        compPacket[28 + 12] = 0xC0 // Illegal pointer in QNAME
        let q4 = compPacket.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }
        XCTAssertNil(q4)
    }
    
    // MARK: - NXDOMAIN Response Builder Tests
    
    func testNXDOMAINResponseSynthesisIPv4() {
        let originalPacket = makeIPv4DNSQuery(domain: "ad.doubleclick.net", txID: 0xABCD)
        
        let query = originalPacket.withUnsafeBytes { raw in
            DNSPacketParser.parse(packet: raw.bindMemory(to: UInt8.self))
        }!
        
        let responseData = originalPacket.withUnsafeBytes { raw in
            NXDOMAINResponseBuilder.buildResponse(for: query, originalPacket: raw.bindMemory(to: UInt8.self))
        }!
        
        // Verify response packet structure
        XCTAssertEqual(responseData.count, originalPacket.count)
        
        responseData.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            // 1. IPv4 Header Checksum Valid
            let ipHeaderChecksum = InternetChecksum.computeIPv4HeaderChecksum(headerBuffer: UnsafeBufferPointer(start: base, count: 20))
            // When checksum is verified over the header including the checksum field, result must be 0 or 0xFFFF
            XCTAssertEqual(ipHeaderChecksum, 0xFFFF)
            
            // 2. Swapped Endpoints: Src is 9.9.9.9, Dst is 192.168.1.5
            let srcIP = (UInt32(base[12]) << 24) | (UInt32(base[13]) << 16) | (UInt32(base[14]) << 8) | UInt32(base[15])
            let dstIP = (UInt32(base[16]) << 24) | (UInt32(base[17]) << 16) | (UInt32(base[18]) << 8) | UInt32(base[19])
            XCTAssertEqual(srcIP, 0x09090909)
            XCTAssertEqual(dstIP, 0xC0A80105)
            
            // 3. UDP Ports Swapped: Src is 53, Dst is 54321
            let srcPort = (UInt16(base[20]) << 8) | UInt16(base[21])
            let dstPort = (UInt16(base[22]) << 8) | UInt16(base[23])
            XCTAssertEqual(srcPort, 53)
            XCTAssertEqual(dstPort, 54321)
            
            // 4. DNS Header: Same TxID, Flags QR=1, RA=1, RD=1, RCODE=3
            let txID = (UInt16(base[28]) << 8) | UInt16(base[29])
            let flags = (UInt16(base[30]) << 8) | UInt16(base[31])
            let qdCount = (UInt16(base[32]) << 8) | UInt16(base[33])
            let anCount = (UInt16(base[34]) << 8) | UInt16(base[35])
            
            XCTAssertEqual(txID, 0xABCD)
            XCTAssertEqual(flags & 0x8000, 0x8000) // QR = 1
            XCTAssertEqual(flags & 0x000F, 0x0003) // RCODE = 3 (NXDOMAIN)
            XCTAssertEqual(flags & 0x0100, 0x0100) // RD = 1 preserved
            XCTAssertEqual(flags & 0x0080, 0x0080) // RA = 1
            XCTAssertEqual(qdCount, 1)
            XCTAssertEqual(anCount, 0)
            
            // 5. UDP Checksum Valid (recomputed checksum matches written checksum in packet)
            let udpLen = (Int(base[24]) << 8) | Int(base[25])
            let writtenChecksum = (UInt16(base[26]) << 8) | UInt16(base[27])
            let recomputedChecksum = InternetChecksum.computeUDPChecksumIPv4(
                srcIP: srcIP,
                dstIP: dstIP,
                udpPacket: UnsafeBufferPointer(start: base + 20, count: udpLen)
            )
            XCTAssertNotEqual(writtenChecksum, 0)
            XCTAssertEqual(writtenChecksum, recomputedChecksum)
        }
    }
    
    func testNXDOMAINResponseSynthesisIPv6() {
        let originalPacket = makeIPv6DNSQuery(domain: "tracker.com", txID: 0x9999)
        
        let query = originalPacket.withUnsafeBytes { raw in
            DNSPacketParser.parse(packet: raw.bindMemory(to: UInt8.self))
        }!
        
        let responseData = originalPacket.withUnsafeBytes { raw in
            NXDOMAINResponseBuilder.buildResponse(for: query, originalPacket: raw.bindMemory(to: UInt8.self))
        }!
        
        XCTAssertEqual(responseData.count, originalPacket.count)
        
        responseData.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            // Version 6
            XCTAssertEqual(base[0] >> 4, 6)
            
            // UDP Ports Swapped
            let srcPort = (UInt16(base[40]) << 8) | UInt16(base[41])
            let dstPort = (UInt16(base[42]) << 8) | UInt16(base[43])
            XCTAssertEqual(srcPort, 53)
            XCTAssertEqual(dstPort, 51234)
            
            // DNS Header: TxID, RCODE = 3
            let txID = (UInt16(base[48]) << 8) | UInt16(base[49])
            let flags = (UInt16(base[50]) << 8) | UInt16(base[51])
            XCTAssertEqual(txID, 0x9999)
            XCTAssertEqual(flags & 0x000F, 0x0003) // NXDOMAIN
            
            // UDP Checksum Valid
            let udpLen = (Int(base[44]) << 8) | Int(base[45])
            let writtenChecksum = (UInt16(base[46]) << 8) | UInt16(base[47])
            let recomputedChecksum = InternetChecksum.computeUDPChecksumIPv6(
                srcIP: query.dstIPv6,
                dstIP: query.srcIPv6,
                udpPacket: UnsafeBufferPointer(start: base + 40, count: udpLen)
            )
            XCTAssertNotEqual(writtenChecksum, 0)
            XCTAssertEqual(writtenChecksum, recomputedChecksum)
        }
    }
    
    // MARK: - Full End-to-End Parsing + Lookup Integration
    
    func testEndToEndParsingAndLookupEnginePipeline() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let publisher = DNSArtifactPublisher()
        _ = try publisher.publish(
            blocklistSources: ["||doubleclick.net^"],
            allowlistRules: ["||allow.doubleclick.net^"],
            baseAppGroupURL: tempDir
        )
        
        let loader = DNSGenerationLoader()
        let snapshot = try loader.loadActiveGeneration(baseAppGroupURL: tempDir)
        let engine = DNSLookupEngine(initialSnapshot: snapshot)
        
        // Scenario A: Blocked Query (ad.doubleclick.net)
        let blockedPacket = makeIPv4DNSQuery(domain: "ad.doubleclick.net")
        let queryA = blockedPacket.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        
        let verdictA = queryA.reversedDomain.withUnsafeBufferPointer { engine.lookup(reversedBytes: $0) }
        XCTAssertEqual(verdictA, .block)
        
        let nxdomainA = blockedPacket.withUnsafeBytes { NXDOMAINResponseBuilder.buildResponse(for: queryA, originalPacket: $0.bindMemory(to: UInt8.self)) }
        XCTAssertNotNil(nxdomainA)
        
        // Scenario B: Allowlisted Exception (allow.doubleclick.net)
        let allowedPacket = makeIPv4DNSQuery(domain: "allow.doubleclick.net")
        let queryB = allowedPacket.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        
        let verdictB = queryB.reversedDomain.withUnsafeBufferPointer { engine.lookup(reversedBytes: $0) }
        XCTAssertEqual(verdictB, .allow) // Precedence short-circuits block!
        
        // Scenario C: Non-Blocked Query (apple.com)
        let neutralPacket = makeIPv4DNSQuery(domain: "apple.com")
        let queryC = neutralPacket.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        
        let verdictC = queryC.reversedDomain.withUnsafeBufferPointer { engine.lookup(reversedBytes: $0) }
        XCTAssertEqual(verdictC, .allow)
    }
}
