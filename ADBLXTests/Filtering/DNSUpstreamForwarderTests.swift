import XCTest
import os
@testable import ADBLX
import ADBLXShared

// MARK: - Mock Socket Implementation

final class MockUpstreamSocket: DNSUpstreamSocketProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Data]())
    private var handler: (@Sendable (Data, String, UInt16) -> Void)?
    public private(set) var isClosed = false
    
    public func send(payload: Data) async throws {
        guard !isClosed else {
            throw NSError(domain: "MockSocket", code: -1, userInfo: nil)
        }
        lock.withLock { $0.append(payload) }
    }
    
    public func setResponseHandler(_ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
        self.handler = handler
    }
    
    public func close() {
        isClosed = true
        handler = nil
    }
    
    public func getSentPayloads() -> [Data] {
        lock.withLock { $0 }
    }
    
    public func simulateResponse(payload: Data, senderIP: String = "9.9.9.9", senderPort: UInt16 = 53) {
        handler?(payload, senderIP, senderPort)
    }
}

final class DNSUpstreamForwarderTests: XCTestCase {
    
    // MARK: - Helper to make synthetic IP query packet
    
    private func makeIPv4DNSQuery(domain: String, txID: UInt16, srcPort: UInt16 = 54321) -> (Data, ParsedDNSQuery) {
        var dnsPayload = Data()
        dnsPayload.append(UInt8((txID >> 8) & 0xFF))
        dnsPayload.append(UInt8(txID & 0xFF))
        dnsPayload.append(contentsOf: [0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        
        let labels = domain.split(separator: ".")
        for label in labels {
            dnsPayload.append(UInt8(label.utf8.count))
            dnsPayload.append(contentsOf: label.utf8)
        }
        dnsPayload.append(0x00)
        dnsPayload.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        
        let udpLen = 8 + dnsPayload.count
        let totalLen = 20 + udpLen
        
        var packet = Data(count: totalLen)
        packet.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            base[0] = 0x45
            base[2] = UInt8((totalLen >> 8) & 0xFF)
            base[3] = UInt8(totalLen & 0xFF)
            base[6] = 0x40
            base[8] = 64
            base[9] = 17
            base[12] = 192; base[13] = 168; base[14] = 1; base[15] = 50
            base[16] = 9; base[17] = 9; base[18] = 9; base[19] = 9
            
            base[20] = UInt8((srcPort >> 8) & 0xFF)
            base[21] = UInt8(srcPort & 0xFF)
            base[22] = 0; base[23] = 53
            base[24] = UInt8((udpLen >> 8) & 0xFF)
            base[25] = UInt8(udpLen & 0xFF)
            
            for i in 0..<dnsPayload.count {
                base[28 + i] = dnsPayload[i]
            }
        }
        
        let query = packet.withUnsafeBytes { DNSPacketParser.parse(packet: $0.bindMemory(to: UInt8.self)) }!
        return (packet, query)
    }
    
    // MARK: - Tests
    
    func testConcurrentQueriesAndCorrelation() async throws {
        let mockSocket = MockUpstreamSocket()
        let forwarder = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 2.0, maxInFlightQueries: 64),
            socketFactory: { _, _, _ in mockSocket }
        )
        
        let responsesLock = OSAllocatedUnfairLock(initialState: [(Data, IPVersion)]())
        try await forwarder.start { responsePacket, ipVersion in
            responsesLock.withLock { $0.append((responsePacket, ipVersion)) }
        }
        
        var queries: [(packet: Data, query: ParsedDNSQuery)] = []
        var upstreamTxIDs: [UInt16] = []
        
        // Send 10 concurrent queries with duplicate client TxIDs (e.g. 0x1111) to test collision-safety
        for i in 0..<10 {
            let (pkt, q) = makeIPv4DNSQuery(domain: "example\(i).com", txID: 0x1111, srcPort: UInt16(50000 + i))
            queries.append((pkt, q))
            
            let result = await forwarder.forward(query: q, originalPacket: pkt)
            
            if case .forwarded(let uTxID) = result {
                upstreamTxIDs.append(uTxID)
            } else {
                XCTFail("Query \(i) failed to forward")
            }
        }
        
        // Verify all 10 upstream TxIDs are unique
        let uniqueTxIDs = Set(upstreamTxIDs)
        XCTAssertEqual(uniqueTxIDs.count, 10, "Upstream transaction IDs must be uniquely rewritten to prevent collisions")
        
        let inFlight = await forwarder.activeInFlightCount
        XCTAssertEqual(inFlight, 10)
        
        // Simulate out-of-order upstream responses
        for uTxID in upstreamTxIDs.reversed() {
            var responsePayload = Data([
                UInt8((uTxID >> 8) & 0xFF), UInt8(uTxID & 0xFF),
                0x81, 0x80, // Response flags (NoError)
                0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00
            ])
            // Append dummy question & answer
            responsePayload.append(contentsOf: [0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x00, 0x00, 0x01, 0x00, 0x01])
            
            mockSocket.simulateResponse(payload: responsePayload)
        }
        
        // Allow async actor tasks to complete
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let receivedResponses = responsesLock.withLock { $0 }
        XCTAssertEqual(receivedResponses.count, 10)
        
        // Verify every response has the original clientTxID (0x1111) restored and IPVersion .v4
        for (resp, ipVer) in receivedResponses {
            XCTAssertEqual(ipVer, .v4)
            resp.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let clientTxID = (UInt16(base[28]) << 8) | UInt16(base[29])
                XCTAssertEqual(clientTxID, 0x1111)
            }
        }
        
        let remainingInFlight = await forwarder.activeInFlightCount
        XCTAssertEqual(remainingInFlight, 0)
    }
    
    func testQueryTimeoutAndEviction() async throws {
        let mockSocket = MockUpstreamSocket()
        let forwarder = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 0.05, maxInFlightQueries: 10),
            socketFactory: { _, _, _ in mockSocket }
        )
        
        try await forwarder.start { _, _ in }
        
        let (pkt, q) = makeIPv4DNSQuery(domain: "timeout.com", txID: 0x9999)
        let result = await forwarder.forward(query: q, originalPacket: pkt)
        
        XCTAssertEqual(result, DNSForwarderResult.forwarded(upstreamTxID: 1))
        let inFlightBefore = await forwarder.activeInFlightCount
        XCTAssertEqual(inFlightBefore, 1)
        
        // Wait for timeout (0.05s + margin)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let inFlightAfter = await forwarder.activeInFlightCount
        XCTAssertEqual(inFlightAfter, 0, "Timed-out query must be evicted from the transaction table")
    }
    
    func testCapacityBoundingEmitsSERVFAIL() async throws {
        let mockSocket = MockUpstreamSocket()
        let forwarder = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, timeoutSeconds: 5.0, maxInFlightQueries: 2),
            socketFactory: { _, _, _ in mockSocket }
        )
        
        let writtenPacketsLock = OSAllocatedUnfairLock(initialState: [(Data, IPVersion)]())
        try await forwarder.start { pkt, ipVer in
            writtenPacketsLock.withLock { $0.append((pkt, ipVer)) }
        }
        
        let (pkt1, q1) = makeIPv4DNSQuery(domain: "site1.com", txID: 1)
        let (pkt2, q2) = makeIPv4DNSQuery(domain: "site2.com", txID: 2)
        let (pkt3, q3) = makeIPv4DNSQuery(domain: "site3.com", txID: 3)
        
        let r1 = await forwarder.forward(query: q1, originalPacket: pkt1)
        let r2 = await forwarder.forward(query: q2, originalPacket: pkt2)
        let r3 = await forwarder.forward(query: q3, originalPacket: pkt3)
        
        XCTAssertEqual(r1, DNSForwarderResult.forwarded(upstreamTxID: 1))
        XCTAssertEqual(r2, DNSForwarderResult.forwarded(upstreamTxID: 2))
        XCTAssertEqual(r3, DNSForwarderResult.capacityExceeded, "Exceeding max in-flight queries must return capacityExceeded")
        
        // Verify immediate SERVFAIL packet was emitted for the 3rd query
        let written = writtenPacketsLock.withLock { $0 }
        XCTAssertEqual(written.count, 1, "Immediate SERVFAIL response must be emitted on capacity exhaustion")
        XCTAssertEqual(written[0].1, .v4)
        
        written[0].0.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let flags = (UInt16(base[30]) << 8) | UInt16(base[31])
            let rcode = flags & 0x000F
            XCTAssertEqual(rcode, 2, "Response RCODE must be 2 (SERVFAIL)")
        }
    }
    
    func testSourceEndpointValidationRejectsRoguePackets() async throws {
        let mockSocket = MockUpstreamSocket()
        let forwarder = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil, port: 53),
            socketFactory: { _, _, _ in mockSocket }
        )
        
        let writtenPacketsLock = OSAllocatedUnfairLock(initialState: [(Data, IPVersion)]())
        try await forwarder.start { pkt, ipVer in
            writtenPacketsLock.withLock { $0.append((pkt, ipVer)) }
        }
        
        let (pkt, q) = makeIPv4DNSQuery(domain: "secure.com", txID: 0xABCD)
        let result = await forwarder.forward(query: q, originalPacket: pkt)
        guard case .forwarded(let uTxID) = result else {
            XCTFail("Forwarding failed")
            return
        }
        
        var responsePayload = Data([
            UInt8((uTxID >> 8) & 0xFF), UInt8(uTxID & 0xFF),
            0x81, 0x80,
            0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00
        ])
        responsePayload.append(contentsOf: [0x06, 0x73, 0x65, 0x63, 0x75, 0x72, 0x65, 0x00, 0x00, 0x01, 0x00, 0x01])
        
        // 1. Rogue response from wrong IP (e.g. 1.2.3.4) should be ignored
        mockSocket.simulateResponse(payload: responsePayload, senderIP: "1.2.3.4", senderPort: 53)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writtenPacketsLock.withLock { $0.count }, 0, "Rogue sender IP must be dropped")
        let count1 = await forwarder.activeInFlightCount
        XCTAssertEqual(count1, 1)
        
        // 2. Rogue response from wrong Port (e.g. 5353) should be ignored
        mockSocket.simulateResponse(payload: responsePayload, senderIP: "9.9.9.9", senderPort: 5353)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writtenPacketsLock.withLock { $0.count }, 0, "Rogue sender port must be dropped")
        let count2 = await forwarder.activeInFlightCount
        XCTAssertEqual(count2, 1)
        
        // 3. Valid response from 9.9.9.9:53 should be accepted
        mockSocket.simulateResponse(payload: responsePayload, senderIP: "9.9.9.9", senderPort: 53)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(writtenPacketsLock.withLock { $0.count }, 1, "Valid response must be accepted")
        let count3 = await forwarder.activeInFlightCount
        XCTAssertEqual(count3, 0)
    }
    
    func testShutdownAndReconfiguration() async throws {
        let activeMockSocket = OSAllocatedUnfairLock(initialState: MockUpstreamSocket())
        let forwarder = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil),
            socketFactory: { _, _, _ in
                let s = MockUpstreamSocket()
                activeMockSocket.withLock { $0 = s }
                return s
            }
        )
        
        try await forwarder.start { _, _ in }
        
        let (pkt, q) = makeIPv4DNSQuery(domain: "test.com", txID: 0x4444)
        _ = await forwarder.forward(query: q, originalPacket: pkt)
        
        let inFlightBefore = await forwarder.activeInFlightCount
        XCTAssertEqual(inFlightBefore, 1)
        
        // Stop forwarder
        let firstSocket = activeMockSocket.withLock { $0 }
        await forwarder.stop()
        
        let inFlightAfter = await forwarder.activeInFlightCount
        XCTAssertEqual(inFlightAfter, 0)
        XCTAssertTrue(firstSocket.isClosed)
        
        // Reconfigure creates a fresh socket
        try await forwarder.reconfigure(newConfig: UpstreamResolverConfig(ipv4Address: "1.1.1.1"))
        let secondSocket = activeMockSocket.withLock { $0 }
        XCTAssertFalse(secondSocket.isClosed)
        
        let (pkt2, q2) = makeIPv4DNSQuery(domain: "test2.com", txID: 0x5555)
        let r2 = await forwarder.forward(query: q2, originalPacket: pkt2)
        if case .forwarded(let uTxID) = r2 {
            XCTAssertGreaterThan(uTxID, 0)
        } else {
            XCTFail("Query failed to forward after reconfiguration: \(r2)")
        }
    }
    
    func testRapidSynchronousResponseDoesNotRaceWithForward() async throws {
        final class SynchronousEchoSocket: DNSUpstreamSocketProtocol, @unchecked Sendable {
            private var handler: (@Sendable (Data, String, UInt16) -> Void)?
            
            func send(payload: Data) async throws {
                // Immediately simulate response during send call
                let txID = (UInt16(payload[0]) << 8) | UInt16(payload[1])
                var resp = Data([
                    UInt8((txID >> 8) & 0xFF), UInt8(txID & 0xFF),
                    0x81, 0x80,
                    0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00
                ])
                resp.append(contentsOf: [0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x01, 0x00, 0x01])
                handler?(resp, "9.9.9.9", 53)
            }
            
            func setResponseHandler(_ handler: @escaping @Sendable (Data, String, UInt16) -> Void) {
                self.handler = handler
            }
            
            func close() {}
        }
        
        let echoSocket = SynchronousEchoSocket()
        let forwarder = DNSUpstreamForwarder(
            config: UpstreamResolverConfig(ipv4Address: "9.9.9.9", ipv6Address: nil),
            socketFactory: { _, _, _ in echoSocket }
        )
        
        let responseReceived = OSAllocatedUnfairLock(initialState: false)
        try await forwarder.start { _, _ in
            responseReceived.withLock { $0 = true }
        }
        
        let (pkt, q) = makeIPv4DNSQuery(domain: "test.com", txID: 0x7777)
        let res = await forwarder.forward(query: q, originalPacket: pkt)
        
        if case .forwarded = res {
            // Allow event loop to process
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(responseReceived.withLock { $0 }, "Immediate response must be captured without race condition drop")
            let inFlight = await forwarder.activeInFlightCount
            XCTAssertEqual(inFlight, 0, "In-flight table must be cleared when immediate response is received")
        } else {
            XCTFail("Forwarding failed")
        }
    }
}
